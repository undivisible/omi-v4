//! The live path that turns a diarized meeting segment into a named speaker.
//!
//! Everything it needs already exists and is tested in isolation:
//! [`crate::speech_segments`] keeps the recent capture PCM on the STT stream
//! clock, [`crate::speech_embedding`] turns a span of that PCM into a
//! voiceprint, and [`crate::speech_profiles`] decides who the voiceprint
//! belongs to. This module is the wiring, and it owns the three pieces of
//! process state the wiring needs: the account scope, the ring buffer the STT
//! socket feeds, and the embedding model.
//!
//! # Scope
//!
//! The store is `(directory, uid)`, and the meeting loop knows neither: the
//! client resolves both from the same `~/.omi` convention every other local
//! store uses. It supplies them once, through
//! [`crate::signals::Command::ConfigureSpeechProfiles`], and they are cached
//! here. Until that arrives — and that is the state a fresh install is in —
//! [`enabled`] is false and every entry point on this module returns before it
//! touches a lock. Nothing here invents a path.
//!
//! # The model
//!
//! Resolved from the same directory convention as the store: the store is
//! `directory/speech/profiles.sqlite3` and the model is
//! `directory/speech/ecapa.onnx`. No weights ship, so
//! [`crate::speech_embedding::resolve_embedding_source`] normally answers the
//! fail-closed null source. The graph is loaded once per scope and held in an
//! `Arc`; loading an ONNX model per segment would cost more than the meeting.
//!
//! # Where the work runs
//!
//! Pushing PCM happens on the STT websocket task for every audio frame, so it
//! is an atomic load, a slice decode and a `VecDeque` extend under a mutex held
//! for the length of that extend and nothing else. Slicing happens once per
//! finalized segment, takes the same mutex just long enough to copy the window
//! out, and then releases it. Embedding and every database call run on
//! `spawn_blocking`, off both the websocket task and the meeting control loop;
//! the answer re-enters the meeting loop as
//! [`crate::meeting::MeetingControl::BindSpeechProfile`], which is the only
//! part that needs the session.

use crate::signals::{AudioEncoding, NativeEvent, SpeechProfileMatched, SpeechProfileScope};
use crate::speech_embedding::resolve_embedding_source;
use crate::speech_profiles::{
    Attribution, EmbeddingProvenance, EmbeddingSource, MatchOutcome, ProfileKind,
    SpeechProfileStore, embed_segment,
};
use crate::speech_segments::{SpeechSegmentBuffer, StreamWindow};
use crate::stt::SttConfig;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};

/// The model file, beside the profile database in the same `speech` directory.
pub const MODEL_FILE: &str = "ecapa.onnx";

/// The confidence attached to a voiceprint the matcher learned by itself.
///
/// Deliberately below anything the user recorded on purpose, because
/// [`SpeechProfileStore::add_embedding`] evicts by quality within an
/// attribution and an inferred row must never displace a deliberate one.
pub const INFERRED_QUALITY: f32 = 0.5;

static ENABLED: AtomicBool = AtomicBool::new(false);
static SCOPE: RwLock<Option<SpeechProfileScope>> = RwLock::new(None);
static BUFFER: Mutex<Option<SpeechSegmentBuffer>> = Mutex::new(None);
static SOURCE: Mutex<Option<(PathBuf, Arc<dyn EmbeddingSource>)>> = Mutex::new(None);

/// The audio a finalized diarized segment was spoken in, as far as the STT
/// stream clock can describe it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SegmentAudio {
    pub window: StreamWindow,
    pub segment_id: String,
}

/// Which meeting, which diarized voice, and when.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SegmentContext {
    pub meeting_id: String,
    pub diarized_key: u64,
    pub segment_id: String,
    pub now_ms: i64,
}

/// What one segment did to the store.
#[derive(Clone, Debug, PartialEq)]
pub enum SegmentOutcome {
    /// No model, too little audio, or a voiceprint the encoder refused. The
    /// default state of a fresh install, and deliberately silent.
    NoVoiceprint,
    /// A known person, with whether the voiceprint was also learned.
    Matched {
        profile_id: String,
        display_name: Option<String>,
        distance: f32,
        runner_up: Option<f32>,
        learned: bool,
    },
    /// Two people are equally close. The segment keeps its `Speaker N`.
    Ambiguous,
    /// Nobody was close, so the voice now has an unnamed profile of its own.
    Enrolled { profile_id: String },
    /// The store could not be read or written.
    StoreFailed(String),
}

/// Points the live path at an account's voiceprints, or turns it off.
///
/// Called from the command dispatcher. Clears the ring buffer and the cached
/// model, because both belong to the scope that is being replaced.
pub fn configure(scope: Option<SpeechProfileScope>) {
    let scope =
        scope.filter(|scope| !scope.directory.trim().is_empty() && !scope.uid.trim().is_empty());
    ENABLED.store(scope.is_some(), Ordering::Release);
    scope_write(scope);
    *guard(&BUFFER) = None;
    *guard(&SOURCE) = None;
}

/// Whether a scope has been supplied.
pub fn enabled() -> bool {
    ENABLED.load(Ordering::Acquire)
}

/// Forgets the buffered audio. Called when capture stops.
pub fn reset() {
    *guard(&BUFFER) = None;
}

/// Records the PCM that has just been handed to the transcription socket.
///
/// This must be called for every byte the provider receives and for no byte it
/// does not, because the window offsets the provider reports back are counted
/// against exactly that stream. `epoch` is the connection those bytes belong
/// to; a change restarts the buffer, since the provider's clock restarts too.
pub(crate) fn observe_stream_audio(config: &SttConfig, epoch: u32, bytes: &[u8]) {
    if !enabled() || config.request_id != crate::meeting_capture::CAPTURE_STREAM_ID {
        return;
    }
    let Some(pcm) = decode_pcm(bytes, config.encoding, config.channels) else {
        return;
    };
    let mut held = guard(&BUFFER);
    let buffer = held.get_or_insert_with(|| {
        SpeechSegmentBuffer::with_default_retention(config.sample_rate_hz.max(1), epoch)
    });
    if buffer.epoch() != epoch {
        buffer.begin_epoch(epoch);
    }
    buffer.push(&pcm);
}

/// Cuts the segment's own audio back out of the buffer.
///
/// Returns the PCM and the rate it was captured at, or nothing at all — a
/// window from a previous connection, one that aged out, or one shorter than a
/// voiceprint needs is answered the same way, because in every case the honest
/// result is no voiceprint.
pub fn take_segment_pcm(window: StreamWindow) -> Option<(Vec<i16>, u32)> {
    segment_pcm(guard(&BUFFER).as_ref()?, window)
}

/// The same cut against a buffer the caller holds.
pub fn segment_pcm(buffer: &SpeechSegmentBuffer, window: StreamWindow) -> Option<(Vec<i16>, u32)> {
    let pcm = buffer.try_slice(window).ok()?;
    Some((pcm, buffer.sample_rate_hz()))
}

/// Identifies one finalized diarized segment, off the meeting control loop.
///
/// Slicing happens here, on the caller's thread, so the ring buffer's mutex is
/// released before any of the expensive work starts. Everything after it —
/// embedding, matching, writing — runs on a blocking thread, and a match comes
/// back to the meeting loop as a control message.
pub fn identify(context: SegmentContext, audio: &SegmentAudio) {
    if !enabled() {
        return;
    }
    if !audio.window.is_embeddable() {
        return;
    }
    let Some(scope) = scope_read() else {
        return;
    };
    let Some((pcm, sample_rate)) = take_segment_pcm(audio.window) else {
        return;
    };
    tokio::task::spawn_blocking(move || {
        let outcome = identify_blocking(&scope, &pcm, sample_rate, &context);
        publish(&context, outcome);
    });
}

fn identify_blocking(
    scope: &SpeechProfileScope,
    pcm: &[i16],
    sample_rate: u32,
    context: &SegmentContext,
) -> SegmentOutcome {
    let source = embedding_source(scope);
    let store = match SpeechProfileStore::open(&store_path(&scope.directory), &scope.uid) {
        Ok(store) => store,
        Err(error) => return SegmentOutcome::StoreFailed(error.to_string()),
    };
    attribute(&store, source.as_ref(), pcm, sample_rate, context)
}

fn publish(context: &SegmentContext, outcome: SegmentOutcome) {
    match outcome {
        SegmentOutcome::Matched {
            profile_id,
            display_name,
            distance,
            runner_up,
            ..
        } => {
            if let Some(name) = display_name.as_deref() {
                crate::meeting::bind_speech_profile(context.diarized_key, &profile_id, name);
            }
            NativeEvent::SpeechProfileMatched(SpeechProfileMatched {
                profile_id,
                display_name,
                meeting_id: context.meeting_id.clone(),
                diarized_key: context.diarized_key as i64,
                distance,
                runner_up,
            })
            .send();
        }
        SegmentOutcome::StoreFailed(detail) => {
            eprintln!("omi speech profile store is unusable: {detail}");
        }
        SegmentOutcome::NoVoiceprint
        | SegmentOutcome::Ambiguous
        | SegmentOutcome::Enrolled { .. } => {}
    }
}

/// The whole decision, with the store and the encoder passed in.
///
/// Every branch of the runtime behaviour is reachable from here with a fake
/// [`EmbeddingSource`] and an in-memory store, which is why the wiring above
/// holds no logic of its own.
pub fn attribute(
    store: &SpeechProfileStore,
    source: &dyn EmbeddingSource,
    pcm: &[i16],
    sample_rate: u32,
    context: &SegmentContext,
) -> SegmentOutcome {
    let Ok(probe) = embed_segment(source, pcm, sample_rate) else {
        return SegmentOutcome::NoVoiceprint;
    };
    let outcome = match store.match_embedding(&probe) {
        Ok(outcome) => outcome,
        Err(error) => return SegmentOutcome::StoreFailed(error.to_string()),
    };
    let provenance = EmbeddingProvenance::from_meeting(
        Attribution::LlmInferred,
        &context.meeting_id,
        &context.segment_id,
    );
    match outcome {
        MatchOutcome::Matched {
            profile_id,
            distance,
            runner_up,
        } => {
            if let Err(error) = store.record_sighting(
                &context.meeting_id,
                context.diarized_key,
                &profile_id,
                context.now_ms,
            ) {
                return SegmentOutcome::StoreFailed(error.to_string());
            }
            let profile = match store.profile(&profile_id) {
                Ok(Some(profile)) => profile,
                Ok(None) => return SegmentOutcome::StoreFailed(format!("no profile {profile_id}")),
                Err(error) => return SegmentOutcome::StoreFailed(error.to_string()),
            };
            let learned = !profile.learning_paused
                && store
                    .add_embedding(
                        &profile_id,
                        &probe,
                        INFERRED_QUALITY,
                        &provenance,
                        context.now_ms,
                    )
                    .is_ok();
            SegmentOutcome::Matched {
                profile_id,
                display_name: profile.display_name,
                distance,
                runner_up,
                learned,
            }
        }
        MatchOutcome::Ambiguous { .. } => SegmentOutcome::Ambiguous,
        MatchOutcome::NoMatch { .. } => {
            let profile = match store.create_profile(ProfileKind::Other, None, context.now_ms) {
                Ok(profile) => profile,
                Err(error) => return SegmentOutcome::StoreFailed(error.to_string()),
            };
            if let Err(error) = store.add_embedding(
                &profile.id,
                &probe,
                INFERRED_QUALITY,
                &provenance,
                context.now_ms,
            ) {
                return SegmentOutcome::StoreFailed(error.to_string());
            }
            if let Err(error) = store.record_sighting(
                &context.meeting_id,
                context.diarized_key,
                &profile.id,
                context.now_ms,
            ) {
                return SegmentOutcome::StoreFailed(error.to_string());
            }
            SegmentOutcome::Enrolled {
                profile_id: profile.id,
            }
        }
    }
}

/// The voiceprint database for a data directory, matching `runtime.rs`.
pub fn store_path(directory: &str) -> PathBuf {
    PathBuf::from(directory)
        .join("speech")
        .join("profiles.sqlite3")
}

/// The speaker encoder for a data directory, beside the database.
pub fn model_path(directory: &str) -> PathBuf {
    PathBuf::from(directory).join("speech").join(MODEL_FILE)
}

fn embedding_source(scope: &SpeechProfileScope) -> Arc<dyn EmbeddingSource> {
    let path = model_path(&scope.directory);
    let mut held = guard(&SOURCE);
    if let Some((cached, source)) = held.as_ref()
        && cached == &path
    {
        return Arc::clone(source);
    }
    let source: Arc<dyn EmbeddingSource> = Arc::from(resolve_embedding_source(&path));
    *held = Some((path, Arc::clone(&source)));
    source
}

/// The samples the provider is about to be sent, as mono `i16`.
///
/// `None` for anything this path cannot read back: a compressed encoding has no
/// samples to buffer, and a multi-channel stream is not what capture sends.
fn decode_pcm(bytes: &[u8], encoding: AudioEncoding, channels: u8) -> Option<Vec<i16>> {
    if channels != 1 {
        return None;
    }
    match encoding {
        AudioEncoding::PcmS16Le => Some(
            bytes
                .chunks_exact(2)
                .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
                .collect(),
        ),
        AudioEncoding::PcmU8 => Some(
            bytes
                .iter()
                .map(|sample| (i16::from(*sample) - 128) << 8)
                .collect(),
        ),
        AudioEncoding::Opus => None,
    }
}

fn guard<T>(lock: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    lock.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn scope_read() -> Option<SpeechProfileScope> {
    SCOPE
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

fn scope_write(value: Option<SpeechProfileScope>) {
    *SCOPE
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = value;
}

#[cfg(test)]
mod tests {
    use super::{
        INFERRED_QUALITY, SegmentContext, SegmentOutcome, attribute, decode_pcm, model_path,
        segment_pcm, store_path,
    };
    use crate::signals::AudioEncoding;
    use crate::speech_profiles::{
        Attribution, EmbeddingError, EmbeddingProvenance, EmbeddingSource, NullEmbeddingSource,
        ProfileKind, SpeakerEmbedding, SpeechProfileStore,
    };
    use crate::speech_segments::{SpeechSegmentBuffer, stream_window};
    use std::time::Duration;

    const RATE: u32 = 16_000;

    /// Answers one fixed voiceprint, whatever the audio. Standing in for a
    /// model file that this repository deliberately does not ship.
    struct AlwaysAnswers(Vec<f32>);

    impl EmbeddingSource for AlwaysAnswers {
        fn embed(&self, _pcm: &[i16], _rate: u32) -> Result<SpeakerEmbedding, EmbeddingError> {
            SpeakerEmbedding::new(self.0.clone())
        }
    }

    fn voice(values: &[f32]) -> Vec<f32> {
        values.to_vec()
    }

    fn embedding(values: &[f32]) -> SpeakerEmbedding {
        match SpeakerEmbedding::new(values.to_vec()) {
            Ok(value) => value,
            Err(error) => panic!("a finite non-zero vector normalizes: {error}"),
        }
    }

    fn store() -> SpeechProfileStore {
        match SpeechProfileStore::open_in_memory("uid-1") {
            Ok(store) => store,
            Err(error) => panic!("an in-memory store opens: {error}"),
        }
    }

    fn context() -> SegmentContext {
        SegmentContext {
            meeting_id: "meeting-1".to_owned(),
            diarized_key: 3,
            segment_id: "segment-1".to_owned(),
            now_ms: 1_000,
        }
    }

    fn audio() -> Vec<i16> {
        vec![64; RATE as usize]
    }

    fn enrol(store: &SpeechProfileStore, values: &[f32], name: Option<&str>) -> String {
        let profile = match store.create_profile(ProfileKind::Other, name, 10) {
            Ok(profile) => profile,
            Err(error) => panic!("creating a profile succeeds: {error}"),
        };
        if let Err(error) = store.add_embedding(
            &profile.id,
            &embedding(values),
            1.0,
            &EmbeddingProvenance::enrolled(),
            10,
        ) {
            panic!("enrolling a voiceprint succeeds: {error}");
        }
        profile.id
    }

    fn embeddings(store: &SpeechProfileStore, profile_id: &str) -> usize {
        match store.profile(profile_id) {
            Ok(Some(profile)) => profile.embeddings.len(),
            Ok(None) => panic!("the profile exists"),
            Err(error) => panic!("reading a profile succeeds: {error}"),
        }
    }

    #[test]
    fn a_match_names_the_speaker_and_learns_the_voiceprint() {
        let store = store();
        let known = enrol(&store, &[1.0, 0.0, 0.0], Some("Ada"));
        let source = AlwaysAnswers(voice(&[0.99, 0.05, 0.0]));
        let outcome = attribute(&store, &source, &audio(), RATE, &context());
        let SegmentOutcome::Matched {
            profile_id,
            display_name,
            learned,
            ..
        } = outcome
        else {
            panic!("a near-identical voice matches: {outcome:?}");
        };
        assert_eq!(profile_id, known);
        assert_eq!(display_name.as_deref(), Some("Ada"));
        assert!(learned);
        assert_eq!(embeddings(&store, &known), 2);
        assert_eq!(
            store.sighting("meeting-1", 3).ok().flatten().as_deref(),
            Some(known.as_str())
        );
    }

    #[test]
    fn a_learned_voiceprint_records_where_it_came_from() {
        let store = store();
        let known = enrol(&store, &[1.0, 0.0, 0.0], Some("Ada"));
        let source = AlwaysAnswers(voice(&[0.99, 0.05, 0.0]));
        let _ = attribute(&store, &source, &audio(), RATE, &context());
        let Ok(Some(profile)) = store.profile(&known) else {
            panic!("the profile exists");
        };
        let Some(learned) = profile
            .embeddings
            .iter()
            .find(|stored| stored.provenance.attribution == Attribution::LlmInferred)
        else {
            panic!("the inferred row is stored");
        };
        assert_eq!(
            learned.provenance.source_meeting_id.as_deref(),
            Some("meeting-1")
        );
        assert_eq!(
            learned.provenance.source_segment_id.as_deref(),
            Some("segment-1")
        );
        assert!((learned.quality - INFERRED_QUALITY).abs() < 1e-6);
    }

    #[test]
    fn an_ambiguous_probe_changes_nothing() {
        let store = store();
        let first = enrol(&store, &[1.0, 0.0, 0.0], Some("Ada"));
        let second = enrol(&store, &[0.98, 0.2, 0.0], Some("Bea"));
        let source = AlwaysAnswers(voice(&[0.995, 0.1, 0.0]));
        assert_eq!(
            attribute(&store, &source, &audio(), RATE, &context()),
            SegmentOutcome::Ambiguous
        );
        assert_eq!(embeddings(&store, &first), 1);
        assert_eq!(embeddings(&store, &second), 1);
        assert_eq!(store.sighting("meeting-1", 3).ok().flatten(), None);
        let Ok(profiles) = store.profiles() else {
            panic!("listing profiles succeeds");
        };
        assert_eq!(profiles.len(), 2);
    }

    #[test]
    fn an_unknown_voice_gets_an_unnamed_profile_of_its_own() {
        let store = store();
        let _ = enrol(&store, &[1.0, 0.0, 0.0], Some("Ada"));
        let source = AlwaysAnswers(voice(&[0.0, 0.0, 1.0]));
        let outcome = attribute(&store, &source, &audio(), RATE, &context());
        let SegmentOutcome::Enrolled { profile_id } = outcome else {
            panic!("a distant voice enrols: {outcome:?}");
        };
        let Ok(Some(profile)) = store.profile(&profile_id) else {
            panic!("the new profile exists");
        };
        assert_eq!(profile.display_name, None);
        assert_eq!(profile.kind, ProfileKind::Other);
        assert_eq!(profile.embeddings.len(), 1);
        assert_eq!(
            store.sighting("meeting-1", 3).ok().flatten().as_deref(),
            Some(profile_id.as_str())
        );
    }

    #[test]
    fn the_second_meeting_recognises_the_voice_the_first_one_enrolled() {
        let store = store();
        let source = AlwaysAnswers(voice(&[0.0, 0.0, 1.0]));
        let SegmentOutcome::Enrolled { profile_id } =
            attribute(&store, &source, &audio(), RATE, &context())
        else {
            panic!("the first sighting enrols");
        };
        let mut later = context();
        later.meeting_id = "meeting-2".to_owned();
        let outcome = attribute(&store, &source, &audio(), RATE, &later);
        let SegmentOutcome::Matched {
            profile_id: seen, ..
        } = outcome
        else {
            panic!("the same voice matches next time: {outcome:?}");
        };
        assert_eq!(seen, profile_id);
    }

    #[test]
    fn paused_learning_still_names_the_speaker_but_writes_nothing() {
        let store = store();
        let known = enrol(&store, &[1.0, 0.0, 0.0], Some("Ada"));
        if let Err(error) = store.set_learning_paused(&known, true, 20) {
            panic!("pausing learning succeeds: {error}");
        }
        let source = AlwaysAnswers(voice(&[0.99, 0.05, 0.0]));
        let outcome = attribute(&store, &source, &audio(), RATE, &context());
        let SegmentOutcome::Matched {
            display_name,
            learned,
            ..
        } = outcome
        else {
            panic!("a paused profile still matches: {outcome:?}");
        };
        assert_eq!(display_name.as_deref(), Some("Ada"));
        assert!(!learned);
        assert_eq!(embeddings(&store, &known), 1);
    }

    #[test]
    fn a_missing_model_is_a_silent_no_op() {
        let store = store();
        let known = enrol(&store, &[1.0, 0.0, 0.0], Some("Ada"));
        assert_eq!(
            attribute(&store, &NullEmbeddingSource, &audio(), RATE, &context()),
            SegmentOutcome::NoVoiceprint
        );
        assert_eq!(embeddings(&store, &known), 1);
        assert_eq!(store.sighting("meeting-1", 3).ok().flatten(), None);
        let Ok(profiles) = store.profiles() else {
            panic!("listing profiles succeeds");
        };
        assert_eq!(profiles.len(), 1);
    }

    #[test]
    fn audio_too_short_to_embed_never_reaches_the_model() {
        let store = store();
        let source = AlwaysAnswers(voice(&[1.0, 0.0, 0.0]));
        assert_eq!(
            attribute(&store, &source, &[0_i16; 400], RATE, &context()),
            SegmentOutcome::NoVoiceprint
        );
        let Ok(profiles) = store.profiles() else {
            panic!("listing profiles succeeds");
        };
        assert!(profiles.is_empty());
    }

    #[test]
    fn a_window_from_the_previous_connection_yields_no_audio() {
        let mut buffer = SpeechSegmentBuffer::with_default_retention(RATE, 4);
        buffer.push(&vec![64_i16; RATE as usize * 2]);
        let Some(stale) = stream_window(3, 0, 1_000, true) else {
            panic!("a word-derived window is built");
        };
        assert_eq!(segment_pcm(&buffer, stale), None);
        let Some(current) = stream_window(4, 0, 1_000, true) else {
            panic!("a word-derived window is built");
        };
        assert!(segment_pcm(&buffer, current).is_some());
    }

    #[test]
    fn an_evicted_or_unbuffered_window_yields_no_audio() {
        let mut buffer = SpeechSegmentBuffer::new(RATE, Duration::from_millis(2_000), 0);
        buffer.push(&vec![64_i16; RATE as usize * 10]);
        let Some(aged) = stream_window(0, 0, 1_000, true) else {
            panic!("a word-derived window is built");
        };
        assert_eq!(segment_pcm(&buffer, aged), None);
        let Some(ahead) = stream_window(0, 20_000, 21_000, true) else {
            panic!("a word-derived window is built");
        };
        assert_eq!(segment_pcm(&buffer, ahead), None);
    }

    #[test]
    fn a_wall_clock_segment_never_becomes_a_window_at_all() {
        assert_eq!(
            stream_window(0, 1_764_000_000_000, 1_764_000_002_000, false),
            None
        );
    }

    #[test]
    fn the_model_sits_beside_the_database_it_belongs_to() {
        assert_eq!(
            store_path("/data/.omi"),
            std::path::Path::new("/data/.omi/speech/profiles.sqlite3")
        );
        assert_eq!(
            model_path("/data/.omi"),
            std::path::Path::new("/data/.omi/speech/ecapa.onnx")
        );
    }

    #[test]
    fn capture_bytes_decode_to_the_samples_the_provider_receives() {
        assert_eq!(
            decode_pcm(&[0x00, 0x01, 0xff, 0xff], AudioEncoding::PcmS16Le, 1),
            Some(vec![256, -1])
        );
        assert_eq!(
            decode_pcm(&[128, 129], AudioEncoding::PcmU8, 1),
            Some(vec![0, 256])
        );
        assert_eq!(decode_pcm(&[0, 1], AudioEncoding::Opus, 1), None);
        assert_eq!(decode_pcm(&[0, 1], AudioEncoding::PcmS16Le, 2), None);
        assert_eq!(
            decode_pcm(&[0x00, 0x01, 0x02], AudioEncoding::PcmS16Le, 1),
            Some(vec![256])
        );
    }
}
