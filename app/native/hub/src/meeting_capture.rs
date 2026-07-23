use crate::capture_policy::CapturePlan;
use crate::signals::TranscriptionAuth;
use std::sync::RwLock;
use std::time::{Duration, Instant};

pub(crate) const CAPTURE_STREAM_ID: &str = "meeting-capture";
pub(crate) const CAPTURE_SAMPLE_RATE_HZ: u32 = 16_000;

/// Which side of the call an utterance came from.
///
/// The macOS capture writes a two-track WAV where `ch0` is the local
/// microphone ("me") and `ch1` is the process tap ("them"), so the two sides
/// of a call are already separated at the source. Comparing their short-term
/// energy attributes each finalized transcript segment without a diarization
/// model.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum MeetingSpeaker {
    /// Neither track dominates: silence, simultaneous speech, or a capture
    /// path (such as the microphone-only fallback) that has no far end.
    #[default]
    Unknown,
    /// The local microphone track dominated.
    You,
    /// The far end of the call, captured from system audio, dominated.
    Them,
}

impl MeetingSpeaker {
    /// The transcript prefix for this speaker, or `None` when the side is
    /// unknown and the line should read exactly as it did before speaker
    /// attribution existed.
    pub fn label(self) -> Option<&'static str> {
        match self {
            Self::Unknown => None,
            Self::You => Some("You"),
            Self::Them => Some("Them"),
        }
    }

    pub fn name(self) -> &'static str {
        self.label().unwrap_or_default()
    }
}

/// Mean squared amplitude of each track over one decoded chunk.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub(crate) struct TrackEnergy {
    pub(crate) microphone: f64,
    pub(crate) system: f64,
    pub(crate) frames: usize,
}

/// Averages the two capture tracks into the mono stream the transcription
/// provider receives, and measures each track on the way through so the two
/// sides of the call can be told apart without changing what is sent.
pub(crate) fn mix_two_track_to_mono_measured(
    bytes: &[u8],
    remainder: &mut Vec<u8>,
) -> (Vec<i16>, TrackEnergy) {
    remainder.extend_from_slice(bytes);
    let complete = remainder.len() / 4 * 4;
    let mut energy = TrackEnergy::default();
    let mono = remainder[..complete]
        .chunks_exact(4)
        .map(|frame| {
            let microphone = i32::from(i16::from_le_bytes([frame[0], frame[1]]));
            let system = i32::from(i16::from_le_bytes([frame[2], frame[3]]));
            energy.microphone += f64::from(microphone) * f64::from(microphone);
            energy.system += f64::from(system) * f64::from(system);
            energy.frames += 1;
            ((microphone + system) / 2) as i16
        })
        .collect();
    remainder.drain(..complete);
    if energy.frames > 0 {
        let frames = energy.frames as f64;
        energy.microphone /= frames;
        energy.system /= frames;
    }
    (mono, energy)
}

/// Short-memory comparison of the two capture tracks.
///
/// Each observation decays the previous one so the tracker reflects roughly
/// the last quarter second of audio, which is the window a finalized segment
/// lands in. Ambiguous frames stay `Unknown` rather than guessing: with the
/// macOS voice-processing echo canceller active on the microphone the far end
/// barely bleeds into `ch0`, but double talk still lights up both tracks.
#[derive(Debug)]
pub(crate) struct SpeakerTracker {
    microphone: f64,
    system: f64,
    updated_at: Option<Instant>,
}

/// Weight retained from previous observations on each new chunk.
const TRACKER_DECAY: f64 = 0.7;
/// Mean square below which a track counts as silent (about -50 dBFS).
const TRACKER_SILENCE_ENERGY: f64 = 4_000.0;
/// How much louder one track must be before it is called the speaker.
const TRACKER_DOMINANCE: f64 = 2.5;
/// Attribution older than this no longer describes the current segment.
const TRACKER_FRESHNESS: Duration = Duration::from_secs(3);

impl SpeakerTracker {
    pub(crate) const fn new() -> Self {
        Self {
            microphone: 0.0,
            system: 0.0,
            updated_at: None,
        }
    }

    pub(crate) fn observe(&mut self, energy: TrackEnergy, now: Instant) {
        if energy.frames == 0 {
            return;
        }
        self.microphone = self.microphone * TRACKER_DECAY + energy.microphone;
        self.system = self.system * TRACKER_DECAY + energy.system;
        self.updated_at = Some(now);
    }

    pub(crate) fn reset(&mut self) {
        *self = Self::new();
    }

    pub(crate) fn dominant(&self, now: Instant) -> MeetingSpeaker {
        let Some(updated_at) = self.updated_at else {
            return MeetingSpeaker::Unknown;
        };
        if now.saturating_duration_since(updated_at) > TRACKER_FRESHNESS {
            return MeetingSpeaker::Unknown;
        }
        let microphone = self.microphone.max(0.0);
        let system = self.system.max(0.0);
        if microphone < TRACKER_SILENCE_ENERGY && system < TRACKER_SILENCE_ENERGY {
            return MeetingSpeaker::Unknown;
        }
        if microphone >= system * TRACKER_DOMINANCE {
            return MeetingSpeaker::You;
        }
        if system >= microphone * TRACKER_DOMINANCE {
            return MeetingSpeaker::Them;
        }
        MeetingSpeaker::Unknown
    }
}

static SPEAKER: RwLock<SpeakerTracker> = RwLock::new(SpeakerTracker::new());

pub(crate) fn observe_track_energy(energy: TrackEnergy) {
    SPEAKER
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .observe(energy, Instant::now());
}

pub(crate) fn reset_speaker_tracker() {
    SPEAKER
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .reset();
}

/// The side of the call that is speaking right now, as far as the two capture
/// tracks can tell.
pub fn dominant_speaker() -> MeetingSpeaker {
    SPEAKER
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .dominant(Instant::now())
}

/// Watches for a far end that never arrives.
///
/// The most common way meeting capture silently fails is a tap that runs but
/// carries no remote audio — the call app routes playback somewhere the global
/// tap does not see, or the user has the call muted. The microphone track then
/// records a healthy one-sided conversation and nothing downstream notices.
/// This raises a single advisory once enough audio has gone by to be sure.
#[derive(Debug, Default)]
pub(crate) struct FarEndWatch {
    frames: usize,
    microphone: f64,
    system: f64,
    reported: bool,
}

/// Audio that must elapse before a silent far end is called out.
const FAR_END_WINDOW: Duration = Duration::from_secs(25);
/// Mean square the local side must reach for the meeting to look one-sided.
const FAR_END_LOCAL_ENERGY: f64 = 40_000.0;
/// Mean square below which the far end counts as never having arrived.
const FAR_END_REMOTE_ENERGY: f64 = 400.0;

impl FarEndWatch {
    pub(crate) fn observe(&mut self, energy: TrackEnergy, sample_rate_hz: u32) -> bool {
        if self.reported || energy.frames == 0 {
            return false;
        }
        let frames = energy.frames as f64;
        self.microphone += energy.microphone * frames;
        self.system += energy.system * frames;
        self.frames += energy.frames;
        let window_frames = u64::from(sample_rate_hz.max(1)) * FAR_END_WINDOW.as_secs().max(1);
        if (self.frames as u64) < window_frames {
            return false;
        }
        let observed = self.frames as f64;
        let one_sided = self.microphone / observed >= FAR_END_LOCAL_ENERGY
            && self.system / observed < FAR_END_REMOTE_ENERGY;
        self.reported = true;
        one_sided
    }
}

#[derive(Debug)]
pub(crate) struct LinearResampler {
    step: f64,
    position: f64,
    previous: Option<i16>,
}

impl LinearResampler {
    pub(crate) fn new(input_hz: u32, output_hz: u32) -> Self {
        Self {
            step: f64::from(input_hz.max(1)) / f64::from(output_hz.max(1)),
            position: 0.0,
            previous: None,
        }
    }

    pub(crate) fn process(&mut self, input: &[i16]) -> Vec<i16> {
        if input.is_empty() {
            return Vec::new();
        }
        let mut samples: Vec<i16> = Vec::with_capacity(input.len() + 1);
        if let Some(previous) = self.previous {
            samples.push(previous);
        }
        samples.extend_from_slice(input);
        let last = samples.len() - 1;
        let mut output = Vec::new();
        while self.position <= last as f64 {
            let index = self.position.floor() as usize;
            let fraction = self.position - index as f64;
            let value = if index >= last {
                f64::from(samples[last])
            } else {
                f64::from(samples[index]) * (1.0 - fraction)
                    + f64::from(samples[index + 1]) * fraction
            };
            output.push(
                value
                    .round()
                    .clamp(f64::from(i16::MIN), f64::from(i16::MAX)) as i16,
            );
            self.position += self.step;
        }
        self.previous = Some(samples[last]);
        self.position -= last as f64;
        output
    }
}

pub(crate) fn pcm_bytes(samples: &[i16]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    bytes
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct WavHeader {
    pub(crate) sample_rate: u32,
    /// Byte offset of the first sample in the `data` chunk, from the start
    /// of the file.
    pub(crate) data_offset: u64,
}

fn skip_bytes(reader: &mut impl std::io::Read, mut count: u64) -> std::io::Result<()> {
    let mut buffer = [0u8; 4096];
    while count > 0 {
        let take = count.min(buffer.len() as u64) as usize;
        reader.read_exact(&mut buffer[..take])?;
        count -= take as u64;
    }
    Ok(())
}

/// Walks the RIFF chunk structure of a WAV stream to find the `fmt ` chunk's
/// sample rate and the byte offset where the `data` chunk's samples begin.
///
/// This does not assume a canonical 16-byte `fmt ` chunk immediately followed
/// by `data`: it tolerates a `WAVE_FORMAT_EXTENSIBLE` `fmt ` chunk (bigger
/// than 16 bytes) and any number of other chunks (e.g. `LIST`, `fact`)
/// appearing before `data`.
pub(crate) fn parse_wav_header(reader: &mut impl std::io::Read) -> Option<WavHeader> {
    let mut riff = [0u8; 12];
    reader.read_exact(&mut riff).ok()?;
    if &riff[0..4] != b"RIFF" || &riff[8..12] != b"WAVE" {
        return None;
    }
    let mut pos: u64 = 12;
    let mut sample_rate: Option<u32> = None;
    loop {
        let mut chunk_header = [0u8; 8];
        reader.read_exact(&mut chunk_header).ok()?;
        let id = &chunk_header[0..4];
        let size = u32::from_le_bytes(chunk_header[4..8].try_into().ok()?);
        pos += 8;
        let padded_size = u64::from(size) + (size % 2 != 0) as u64;
        if id == b"fmt " {
            let read_len = (size as usize).min(16);
            let mut fmt = vec![0u8; read_len];
            reader.read_exact(&mut fmt).ok()?;
            if read_len >= 8 {
                sample_rate = fmt[4..8].try_into().ok().map(u32::from_le_bytes);
            }
            skip_bytes(reader, padded_size - read_len as u64).ok()?;
            pos += padded_size;
        } else if id == b"data" {
            return sample_rate.map(|sample_rate| WavHeader {
                sample_rate,
                data_offset: pos,
            });
        } else {
            skip_bytes(reader, padded_size).ok()?;
            pos += padded_size;
        }
    }
}

#[cfg(target_os = "macos")]
mod platform {
    use super::{
        CAPTURE_SAMPLE_RATE_HZ, CAPTURE_STREAM_ID, FarEndWatch, LinearResampler, WavHeader,
        mix_two_track_to_mono_measured, observe_track_energy, parse_wav_header, pcm_bytes,
        reset_speaker_tracker,
    };
    use crate::capture_policy::CapturePlan;
    use crate::signals::{AudioEncoding, NativeError, NativeEvent, TranscriptionAuth};
    use crate::stt::{SttConfig, SttHandle};
    use corti_coreaudio::{CaptureSession, OutputLayout, TapTarget};
    use std::fs::File;
    use std::io::{Read, Seek, SeekFrom};
    use std::path::PathBuf;
    use std::sync::mpsc;
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

    const TAP_READY_TIMEOUT: Duration = Duration::from_secs(2);
    const READ_POLL: Duration = Duration::from_millis(20);
    const SESSION_LOST_AFTER: Duration = Duration::from_secs(5);

    pub struct MeetingCaptureHandle {
        control: Option<mpsc::Sender<()>>,
    }

    impl MeetingCaptureHandle {
        fn signal(&mut self) {
            if let Some(control) = self.control.take() {
                let _ = control.send(());
            }
        }
    }

    impl Drop for MeetingCaptureHandle {
        fn drop(&mut self) {
            self.signal();
        }
    }

    /// Generates a per-run random value without pulling in a `rand`-style
    /// dependency: `RandomState`'s keys are seeded from OS randomness, so
    /// hashing a fixed input with a fresh `RandomState` yields an
    /// effectively random, unpredictable output.
    fn random_component() -> u64 {
        use std::collections::hash_map::RandomState;
        use std::hash::{BuildHasher, Hasher};
        RandomState::new().build_hasher().finish()
    }

    /// Creates a private, per-run subdirectory under the system temp
    /// directory (restricted to the owner on Unix) to hold the meeting
    /// capture WAV file, and returns the path to that file within it.
    ///
    /// The directory name mixes the pid, a timestamp, and a random
    /// component so it cannot be predicted or pre-created by another
    /// process, and the 0700 permissions on the directory (plus a
    /// best-effort 0600 on the file itself once it exists) keep the audio
    /// unreadable to other local users even though the underlying capture
    /// library creates the file with default permissions.
    fn capture_path() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let random = random_component();
        let dir = std::env::temp_dir().join(format!(
            "omi-meeting-capture-{}-{stamp}-{random:016x}",
            std::process::id()
        ));
        if std::fs::create_dir(&dir).is_ok() {
            restrict_permissions(&dir);
        }
        dir.join("capture.wav")
    }

    #[cfg(unix)]
    fn restrict_permissions(path: &std::path::Path) {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }

    #[cfg(not(unix))]
    fn restrict_permissions(_path: &std::path::Path) {}

    fn cleanup_capture(path: &PathBuf) {
        let _ = std::fs::remove_file(path);
        if let Some(dir) = path.parent() {
            let _ = std::fs::remove_dir(dir);
        }
    }

    fn wav_header(path: &PathBuf) -> Option<WavHeader> {
        let mut file = File::open(path).ok()?;
        parse_wav_header(&mut file)
    }

    fn wait_for_wav_header(path: &PathBuf) -> Option<WavHeader> {
        let deadline = Instant::now() + TAP_READY_TIMEOUT;
        loop {
            if let Some(header) = wav_header(path)
                && header.sample_rate > 0
            {
                // The capture library creates the file with default
                // permissions; tighten them now that it exists.
                restrict_permissions(path);
                return Some(header);
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(READ_POLL);
        }
    }

    fn emit_error(code: &str) {
        let retryable = code != "meeting_far_end_silent";
        NativeEvent::Error(NativeError {
            request_id: Some(CAPTURE_STREAM_ID.to_owned()),
            code: code.to_owned(),
            message: match code {
                "meeting_system_audio_unavailable" => {
                    "system audio capture is unavailable; fall back to microphone capture"
                }
                "meeting_far_end_silent" => {
                    "only your microphone is being recorded; the call's audio is not reaching \
                     system audio capture"
                }
                _ => "meeting capture transcription session was lost",
            }
            .to_owned(),
            retryable,
        })
        .send();
    }

    fn stream_capture(
        path: &PathBuf,
        header: WavHeader,
        stt: &SttHandle,
        control: &mpsc::Receiver<()>,
    ) -> bool {
        let Ok(mut file) = File::open(path) else {
            return true;
        };
        if file.seek(SeekFrom::Start(header.data_offset)).is_err() {
            return true;
        }
        let mut resampler = LinearResampler::new(header.sample_rate, CAPTURE_SAMPLE_RATE_HZ);
        let mut bytes = [0u8; 16_384];
        let mut remainder = Vec::new();
        let mut failing_since: Option<Instant> = None;
        let mut far_end = FarEndWatch::default();
        reset_speaker_tracker();
        loop {
            match control.recv_timeout(READ_POLL) {
                Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => return true,
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
            let read = match file.read(&mut bytes) {
                Ok(0) => continue,
                Ok(read) => read,
                Err(_) => return true,
            };
            let (frames, energy) = mix_two_track_to_mono_measured(&bytes[..read], &mut remainder);
            observe_track_energy(energy);
            if far_end.observe(energy, header.sample_rate) {
                emit_error("meeting_far_end_silent");
            }
            let mono = resampler.process(&frames);
            if mono.is_empty() {
                continue;
            }
            match stt.send_audio(&pcm_bytes(&mono)) {
                Ok(()) => failing_since = None,
                Err(_) => {
                    let since = *failing_since.get_or_insert_with(Instant::now);
                    if since.elapsed() >= SESSION_LOST_AFTER {
                        emit_error("meeting_capture_session_lost");
                        return false;
                    }
                }
            }
        }
    }

    pub fn start(
        plan: CapturePlan,
        auth: TranscriptionAuth,
        trusted_worker_origin: Option<String>,
    ) -> Result<MeetingCaptureHandle, String> {
        if !plan.system_audio {
            return Err("system audio capture is disallowed by the current mode".to_owned());
        }
        let config = SttConfig {
            request_id: CAPTURE_STREAM_ID.to_owned(),
            audio_stream_id: CAPTURE_STREAM_ID.to_owned(),
            device_id: CAPTURE_STREAM_ID.to_owned(),
            language: "multi".to_owned(),
            sample_rate_hz: CAPTURE_SAMPLE_RATE_HZ,
            channels: 1,
            encoding: AudioEncoding::PcmS16Le,
        };
        let stt = crate::stt::spawn(config, &auth, trusted_worker_origin.as_deref())
            .map_err(|error| error.to_string())?;
        let report_unavailable = plan.microphone;
        let (control_tx, control_rx) = mpsc::channel();
        std::thread::Builder::new()
            .name("omi-meeting-capture".into())
            .spawn(move || {
                let path = capture_path();
                let Ok(session) = CaptureSession::start_recording(
                    TapTarget::Global,
                    path.clone(),
                    OutputLayout::TwoTrack,
                ) else {
                    stt.cancel();
                    if report_unavailable {
                        emit_error("meeting_system_audio_unavailable");
                    }
                    return;
                };
                let Some(header) = wait_for_wav_header(&path) else {
                    let _ = session.stop();
                    cleanup_capture(&path);
                    stt.cancel();
                    if report_unavailable {
                        emit_error("meeting_system_audio_unavailable");
                    }
                    return;
                };
                let finished = stream_capture(&path, header, &stt, &control_rx);
                reset_speaker_tracker();
                if finished {
                    stt.finish();
                } else {
                    stt.cancel();
                }
                let _ = session.stop();
                cleanup_capture(&path);
            })
            .map_err(|error| error.to_string())?;
        Ok(MeetingCaptureHandle {
            control: Some(control_tx),
        })
    }
}

#[cfg(not(target_os = "macos"))]
mod platform {
    use crate::capture_policy::CapturePlan;
    use crate::signals::TranscriptionAuth;

    pub struct MeetingCaptureHandle;

    pub fn start(
        _plan: CapturePlan,
        _auth: TranscriptionAuth,
        _trusted_worker_origin: Option<String>,
    ) -> Result<MeetingCaptureHandle, String> {
        Err("meeting system audio capture is unavailable on this platform".to_owned())
    }
}

pub(crate) use platform::MeetingCaptureHandle;

pub(crate) fn start(
    plan: CapturePlan,
    auth: TranscriptionAuth,
    trusted_worker_origin: Option<String>,
) -> Result<MeetingCaptureHandle, String> {
    platform::start(plan, auth, trusted_worker_origin)
}

#[cfg(test)]
mod tests {
    use super::{
        FarEndWatch, LinearResampler, MeetingSpeaker, SpeakerTracker, TrackEnergy, WavHeader,
        mix_two_track_to_mono_measured, parse_wav_header, pcm_bytes,
    };
    use std::time::{Duration, Instant};

    fn le32(value: u32) -> [u8; 4] {
        value.to_le_bytes()
    }

    fn le16(value: u16) -> [u8; 2] {
        value.to_le_bytes()
    }

    /// Builds a synthetic WAV with a `LIST` chunk (and an odd-sized `fmt `
    /// payload padded to an even boundary) inserted between `fmt ` and
    /// `data`, to prove the parser walks chunks instead of assuming a fixed
    /// 44-byte header.
    fn synthetic_wav_with_extra_chunk(sample_rate: u32, samples: &[i16]) -> Vec<u8> {
        let mut fmt_chunk = Vec::new();
        fmt_chunk.extend_from_slice(&le16(1)); // PCM
        fmt_chunk.extend_from_slice(&le16(1)); // mono
        fmt_chunk.extend_from_slice(&le32(sample_rate));
        fmt_chunk.extend_from_slice(&le32(sample_rate * 2)); // byte rate
        fmt_chunk.extend_from_slice(&le16(2)); // block align
        fmt_chunk.extend_from_slice(&le16(16)); // bits per sample

        let list_payload = b"INFOIART\x05\x00\x00\x00abcd\x00".to_vec();

        let data_payload: Vec<u8> = samples.iter().flat_map(|s| s.to_le_bytes()).collect();

        let mut body = Vec::new();
        body.extend_from_slice(b"WAVE");
        body.extend_from_slice(b"fmt ");
        body.extend_from_slice(&le32(fmt_chunk.len() as u32));
        body.extend_from_slice(&fmt_chunk);
        body.extend_from_slice(b"LIST");
        body.extend_from_slice(&le32(list_payload.len() as u32));
        body.extend_from_slice(&list_payload);
        if list_payload.len() % 2 == 1 {
            body.push(0);
        }
        body.extend_from_slice(b"data");
        body.extend_from_slice(&le32(data_payload.len() as u32));
        body.extend_from_slice(&data_payload);

        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&le32(body.len() as u32));
        wav.extend_from_slice(&body);
        wav
    }

    #[test]
    fn parses_wav_with_an_extra_chunk_before_data() {
        let samples: Vec<i16> = vec![1, -2, 3, -4];
        let wav = synthetic_wav_with_extra_chunk(48_000, &samples);
        let mut reader = std::io::Cursor::new(wav.clone());
        let header = parse_wav_header(&mut reader).unwrap_or_else(|| panic!("header parses"));
        assert_eq!(
            header,
            WavHeader {
                sample_rate: 48_000,
                data_offset: (wav.len() - samples.len() * 2) as u64,
            }
        );
        let recovered: Vec<i16> = wav[header.data_offset as usize..]
            .chunks_exact(2)
            .map(|chunk| i16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();
        assert_eq!(recovered, samples);
    }

    #[test]
    fn rejects_a_non_wav_header() {
        let mut reader = std::io::Cursor::new(b"not-a-wav-file-at-all".to_vec());
        assert!(parse_wav_header(&mut reader).is_none());
    }

    #[test]
    fn two_track_mix_averages_and_keeps_partial_frames() {
        let mut remainder = Vec::new();
        assert!(
            mix_two_track_to_mono_measured(&[16, 0, 32], &mut remainder)
                .0
                .is_empty()
        );
        assert_eq!(remainder, vec![16, 0, 32]);
        assert_eq!(
            mix_two_track_to_mono_measured(&[0], &mut remainder).0,
            vec![24]
        );
        assert!(remainder.is_empty());
        assert_eq!(
            mix_two_track_to_mono_measured(&[0x00, 0x80, 0x00, 0x80], &mut remainder).0,
            vec![i16::MIN]
        );
    }

    #[test]
    fn resampler_converts_a_ramp_from_44_1k_to_16k() {
        let input: Vec<i16> = (0..44_100).map(|value| (value % 20_000) as i16).collect();
        let mut resampler = LinearResampler::new(44_100, 16_000);
        let output = resampler.process(&input);
        assert!(
            (output.len() as i64 - 16_000).abs() <= 1,
            "unexpected output length {}",
            output.len()
        );
        let step = 44_100.0 / 16_000.0;
        for (index, sample) in output.iter().take(1_000).enumerate() {
            let expected = (index as f64 * step).round() as i64;
            assert!(
                (i64::from(*sample) - expected).abs() <= 2,
                "sample {index} was {sample}, expected about {expected}"
            );
        }
    }

    #[test]
    fn resampler_is_continuous_across_chunks() {
        let input: Vec<i16> = (0..2_000).collect();
        let mut whole = LinearResampler::new(44_100, 16_000);
        let mut chunked = LinearResampler::new(44_100, 16_000);
        let expected = whole.process(&input);
        let mut actual = chunked.process(&input[..777]);
        actual.extend(chunked.process(&input[777..]));
        assert_eq!(actual.len(), expected.len());
        for (index, (left, right)) in actual.iter().zip(&expected).enumerate() {
            assert!(
                (i32::from(*left) - i32::from(*right)).abs() <= 1,
                "sample {index} diverged: {left} vs {right}"
            );
        }
    }

    #[test]
    fn pcm_bytes_are_little_endian() {
        assert_eq!(pcm_bytes(&[1, -2]), vec![1, 0, 254, 255]);
    }

    fn two_track_frames(microphone: i16, system: i16, frames: usize) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(frames * 4);
        for _ in 0..frames {
            bytes.extend_from_slice(&microphone.to_le_bytes());
            bytes.extend_from_slice(&system.to_le_bytes());
        }
        bytes
    }

    #[test]
    fn measured_mix_reports_per_track_energy_alongside_the_same_mono_audio() {
        let bytes = two_track_frames(1_000, 200, 4);
        let mut measured_remainder = Vec::new();
        let (mono, energy) = mix_two_track_to_mono_measured(&bytes, &mut measured_remainder);
        assert_eq!(mono, vec![600i16; 4]);
        assert_eq!(energy.frames, 4);
        assert!((energy.microphone - 1_000_000.0).abs() < 1.0);
        assert!((energy.system - 40_000.0).abs() < 1.0);
        let (empty, silent) = mix_two_track_to_mono_measured(&[], &mut measured_remainder);
        assert!(empty.is_empty());
        assert_eq!(silent, TrackEnergy::default());
    }

    #[test]
    fn tracker_attributes_the_louder_track_and_abstains_when_ambiguous() {
        let now = Instant::now();
        let mut tracker = SpeakerTracker::new();
        assert_eq!(tracker.dominant(now), MeetingSpeaker::Unknown);

        tracker.observe(
            TrackEnergy {
                microphone: 1_000_000.0,
                system: 100.0,
                frames: 4_096,
            },
            now,
        );
        assert_eq!(tracker.dominant(now), MeetingSpeaker::You);

        tracker.reset();
        tracker.observe(
            TrackEnergy {
                microphone: 100.0,
                system: 1_000_000.0,
                frames: 4_096,
            },
            now,
        );
        assert_eq!(tracker.dominant(now), MeetingSpeaker::Them);

        tracker.reset();
        tracker.observe(
            TrackEnergy {
                microphone: 900_000.0,
                system: 800_000.0,
                frames: 4_096,
            },
            now,
        );
        assert_eq!(tracker.dominant(now), MeetingSpeaker::Unknown);
    }

    #[test]
    fn tracker_ignores_silence_empty_chunks_and_stale_observations() {
        let now = Instant::now();
        let mut tracker = SpeakerTracker::new();
        tracker.observe(
            TrackEnergy {
                microphone: 10.0,
                system: 1.0,
                frames: 4_096,
            },
            now,
        );
        assert_eq!(tracker.dominant(now), MeetingSpeaker::Unknown);

        tracker.reset();
        tracker.observe(TrackEnergy::default(), now);
        assert_eq!(tracker.dominant(now), MeetingSpeaker::Unknown);

        tracker.observe(
            TrackEnergy {
                microphone: 1_000_000.0,
                system: 100.0,
                frames: 4_096,
            },
            now,
        );
        assert_eq!(tracker.dominant(now), MeetingSpeaker::You);
        assert_eq!(
            tracker.dominant(now + Duration::from_secs(4)),
            MeetingSpeaker::Unknown
        );
    }

    #[test]
    fn speaker_labels_leave_unknown_lines_unprefixed() {
        assert_eq!(MeetingSpeaker::You.label(), Some("You"));
        assert_eq!(MeetingSpeaker::Them.label(), Some("Them"));
        assert_eq!(MeetingSpeaker::Unknown.label(), None);
        assert_eq!(MeetingSpeaker::Unknown.name(), "");
        assert_eq!(MeetingSpeaker::default(), MeetingSpeaker::Unknown);
    }

    #[test]
    fn far_end_watch_reports_a_one_sided_meeting_exactly_once() {
        let mut watch = FarEndWatch::default();
        let loud_local = TrackEnergy {
            microphone: 1_000_000.0,
            system: 0.0,
            frames: 16_000,
        };
        for _ in 0..24 {
            assert!(!watch.observe(loud_local, 16_000));
        }
        assert!(watch.observe(loud_local, 16_000));
        assert!(!watch.observe(loud_local, 16_000));
    }

    #[test]
    fn far_end_watch_stays_quiet_when_both_sides_are_heard_or_nobody_speaks() {
        let mut two_sided = FarEndWatch::default();
        let balanced = TrackEnergy {
            microphone: 1_000_000.0,
            system: 900_000.0,
            frames: 16_000,
        };
        for _ in 0..40 {
            assert!(!two_sided.observe(balanced, 16_000));
        }

        let mut quiet = FarEndWatch::default();
        let silence = TrackEnergy {
            microphone: 10.0,
            system: 0.0,
            frames: 16_000,
        };
        for _ in 0..40 {
            assert!(!quiet.observe(silence, 16_000));
        }
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn non_macos_capture_is_unavailable() {
        use crate::capture_policy::{SystemAudioCaptureMode, capture_plan};
        use crate::signals::TranscriptionAuth;
        assert!(
            super::start(
                capture_plan(SystemAudioCaptureMode::Always, true, true),
                TranscriptionAuth::Local,
                None,
            )
            .is_err()
        );
    }
}
