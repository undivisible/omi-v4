//! Lasting speaker identity: the voiceprints that let a voice heard in one
//! meeting be recognized in the next one.
//!
//! The hub owns all of it — the arithmetic, the store, the user's control
//! surface — so macOS, Windows and (later) Linux share one brain and the
//! platform layer only ever produces PCM. See
//! `docs/speech-profiles-and-displays.md`.
//!
//! Two things this module deliberately does *not* do:
//!
//! * It does not ship an embedding model. No transcription provider omi-v4
//!   can reach returns speaker embeddings — Deepgram's `diarize=true` gives
//!   meeting-local indices, `x-ai/grok-stt-1.0` returns text only, and Gemini
//!   Live returns its own transcription — so the only honest source is a local
//!   model, and until one is vendored [`NullEmbeddingSource`] answers
//!   [`EmbeddingError::Unavailable`] the way the local STT route answers
//!   `SttError::Unavailable`. Nothing silently degrades to guessing.
//! * It does not send anything anywhere. Embeddings are written to the local
//!   SQLite file and read back from it; only the profile metadata a user typed
//!   is ever a candidate for sync.

use crate::capture_wal::random_id;
use rusqlite::{Connection, OptionalExtension, params};
use std::fmt;
use std::path::Path;

/// The shortest span of audio that may be handed to an embedding model.
///
/// Upstream omi uses the same half second. Below it an fbank front end has
/// fewer frames than its context window and either panics or returns a vector
/// dominated by padding, which is worse than no answer at all.
pub const MIN_EMBEDDING_MS: u32 = 500;

/// The lowest sample rate a speaker-embedding front end can be asked for.
/// Narrowband telephony audio carries too little of the spectrum the model was
/// trained on to be worth a voiceprint.
pub const MIN_EMBEDDING_SAMPLE_RATE_HZ: u32 = 8_000;

/// How many voiceprints one profile keeps. Plan doc §3.1.
pub const MAX_EMBEDDINGS_PER_PROFILE: usize = 32;

/// The cosine distance under which two voiceprints may be the same person.
///
/// 0.45 is the value upstream omi hardcodes as its single accept/reject test.
/// It is kept here as the *outer* bound only: on its own it misidentifies
/// people (upstream omi issue #5565, item 6), because in a room of similar
/// voices several profiles sit under it at once and whichever happens to be
/// nearest wins by a rounding error.
pub const MATCH_THRESHOLD: f32 = 0.45;

/// How much closer the best profile must be than the runner-up before the
/// match is accepted.
///
/// This is the half upstream omi is missing. A bare threshold answers "is
/// anyone close enough"; the margin answers "is exactly one person close
/// enough", which is the question a label on a transcript is really asking.
/// Failing the margin degrades to `Speaker N`, because mis-identification is
/// worse than non-identification: a wrong name is quoted, acted on, and
/// eventually enrolled, and the bad voiceprint then poisons every later match
/// invisibly.
pub const MATCH_MARGIN: f32 = 0.08;

/// The version the schema in [`SpeechProfileStore::migrate`] produces.
const SCHEMA_VERSION: i32 = 1;

// ---------------------------------------------------------------------------
// Embeddings
// ---------------------------------------------------------------------------

/// Why no voiceprint came back.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EmbeddingError {
    /// No embedding model is present in this build. The fail-closed default.
    Unavailable,
    /// The segment is shorter than [`MIN_EMBEDDING_MS`].
    TooShort { have_ms: u32, need_ms: u32 },
    /// The audio is not at a rate a speaker model can use.
    UnsupportedSampleRate(u32),
    /// The model produced an empty, non-finite, or zero-length vector.
    Degenerate,
}

impl fmt::Display for EmbeddingError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable => formatter.write_str("no speaker embedding model is available"),
            Self::TooShort { have_ms, need_ms } => write!(
                formatter,
                "speech segment is {have_ms}ms, shorter than the {need_ms}ms an embedding needs"
            ),
            Self::UnsupportedSampleRate(rate) => {
                write!(formatter, "{rate}Hz audio cannot be embedded")
            }
            Self::Degenerate => {
                formatter.write_str("the embedding model returned no usable vector")
            }
        }
    }
}

/// One L2-normalized speaker vector.
///
/// Normalizing at construction is what makes [`Self::cosine_distance`] a plain
/// dot product and, more usefully, makes every distance in the store
/// comparable against the same [`MATCH_THRESHOLD`] no matter which model or
/// which scaling produced the vector.
#[derive(Clone, Debug, PartialEq)]
pub struct SpeakerEmbedding(Vec<f32>);

impl SpeakerEmbedding {
    /// Normalizes `values` to unit length.
    pub fn new(mut values: Vec<f32>) -> Result<Self, EmbeddingError> {
        if values.is_empty() || values.iter().any(|value| !value.is_finite()) {
            return Err(EmbeddingError::Degenerate);
        }
        let norm = values.iter().map(|value| value * value).sum::<f32>().sqrt();
        if !norm.is_finite() || norm <= f32::EPSILON {
            return Err(EmbeddingError::Degenerate);
        }
        for value in &mut values {
            *value /= norm;
        }
        Ok(Self(values))
    }

    pub fn values(&self) -> &[f32] {
        &self.0
    }

    pub fn dimensions(&self) -> usize {
        self.0.len()
    }

    /// Cosine distance in `[0, 2]`, or `None` when the two vectors came from
    /// different models. Comparing across dimensions is never a small error —
    /// it is a category error — so it is refused rather than truncated.
    pub fn cosine_distance(&self, other: &Self) -> Option<f32> {
        if self.0.len() != other.0.len() {
            return None;
        }
        let dot: f32 = self
            .0
            .iter()
            .zip(other.0.iter())
            .map(|(left, right)| left * right)
            .sum();
        Some((1.0 - dot).clamp(0.0, 2.0))
    }

    /// Little-endian `f32` blob, the on-disk form.
    pub fn to_bytes(&self) -> Vec<u8> {
        self.0
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect()
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, EmbeddingError> {
        if bytes.is_empty() || !bytes.len().is_multiple_of(4) {
            return Err(EmbeddingError::Degenerate);
        }
        let values = bytes
            .chunks_exact(4)
            .map(|chunk| {
                let mut word = [0_u8; 4];
                word.copy_from_slice(chunk);
                f32::from_le_bytes(word)
            })
            .collect();
        Self::new(values)
    }
}

/// Anything that can turn a span of mono PCM into a voiceprint.
///
/// Implementors must assume nothing about duration: run [`guard_segment`] (or
/// call through [`embed_segment`]) before touching the audio.
pub trait EmbeddingSource: Send + Sync {
    fn embed(&self, pcm: &[i16], sample_rate: u32) -> Result<SpeakerEmbedding, EmbeddingError>;
}

/// The source omi-v4 ships today: none.
///
/// Every provider in the transcription path returns text or meeting-local
/// speaker indices, never embeddings, so there is nothing to wrap. Answering
/// [`EmbeddingError::Unavailable`] on every call is the same fail-closed
/// posture the local STT route takes — the feature is off, visibly, rather
/// than on and wrong.
#[derive(Clone, Copy, Debug, Default)]
pub struct NullEmbeddingSource;

impl EmbeddingSource for NullEmbeddingSource {
    fn embed(&self, _pcm: &[i16], _sample_rate: u32) -> Result<SpeakerEmbedding, EmbeddingError> {
        Err(EmbeddingError::Unavailable)
    }
}

/// How long `sample_count` mono frames last at `sample_rate`.
pub fn segment_duration_ms(sample_count: usize, sample_rate: u32) -> u32 {
    if sample_rate == 0 {
        return 0;
    }
    let millis = sample_count as u64 * 1_000 / u64::from(sample_rate);
    u32::try_from(millis).unwrap_or(u32::MAX)
}

/// The minimum-duration and sample-rate guard every embedding path runs first.
pub fn guard_segment(pcm: &[i16], sample_rate: u32) -> Result<(), EmbeddingError> {
    if sample_rate < MIN_EMBEDDING_SAMPLE_RATE_HZ {
        return Err(EmbeddingError::UnsupportedSampleRate(sample_rate));
    }
    let have_ms = segment_duration_ms(pcm.len(), sample_rate);
    if have_ms < MIN_EMBEDDING_MS {
        return Err(EmbeddingError::TooShort {
            have_ms,
            need_ms: MIN_EMBEDDING_MS,
        });
    }
    Ok(())
}

/// Embeds one segment through `source`, applying [`guard_segment`] first.
/// This is the seam the meeting path calls; a real model drops in behind it
/// without any caller learning about it.
pub fn embed_segment(
    source: &dyn EmbeddingSource,
    pcm: &[i16],
    sample_rate: u32,
) -> Result<SpeakerEmbedding, EmbeddingError> {
    guard_segment(pcm, sample_rate)?;
    source.embed(pcm, sample_rate)
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum ProfileKind {
    /// The person running the app.
    Owner,
    #[default]
    Other,
}

impl ProfileKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Other => "other",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "owner" => Self::Owner,
            _ => Self::Other,
        }
    }
}

/// How a stored voiceprint came to be attached to this profile.
///
/// Kept on every row because a voiceprint enrolled from a wrong attribution is
/// otherwise unrecoverable: it matches, it wins, it gets reinforced, and there
/// is no record of which meeting introduced the mistake. With provenance the
/// user (or a repair pass) can quarantine exactly the rows a bad session
/// produced instead of deleting the person.
#[derive(Clone, Copy, Debug, Default, Eq, Ord, PartialEq, PartialOrd)]
pub enum Attribution {
    /// The model inferred it from context. Least trusted; ordered first so it
    /// is evicted first.
    #[default]
    LlmInferred,
    /// The user named this speaker in a transcript.
    UserTagged,
    /// The user recorded it deliberately in the enrollment flow.
    Enrolled,
}

impl Attribution {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Enrolled => "enrolled",
            Self::UserTagged => "user_tagged",
            Self::LlmInferred => "llm_inferred",
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "enrolled" => Self::Enrolled,
            "user_tagged" => Self::UserTagged,
            _ => Self::LlmInferred,
        }
    }

    /// Whether the user asked for this row directly. Learning that is paused
    /// stops the automatic path, not the user's own hands.
    pub fn is_user_directed(self) -> bool {
        matches!(self, Self::Enrolled | Self::UserTagged)
    }
}

/// Where one stored voiceprint came from.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct EmbeddingProvenance {
    pub attribution: Attribution,
    pub source_meeting_id: Option<String>,
    pub source_segment_id: Option<String>,
}

impl EmbeddingProvenance {
    pub fn enrolled() -> Self {
        Self {
            attribution: Attribution::Enrolled,
            ..Self::default()
        }
    }

    pub fn from_meeting(attribution: Attribution, meeting_id: &str, segment_id: &str) -> Self {
        Self {
            attribution,
            source_meeting_id: Some(meeting_id.to_owned()),
            source_segment_id: Some(segment_id.to_owned()),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct StoredEmbedding {
    pub id: i64,
    pub embedding: SpeakerEmbedding,
    /// The caller's confidence in the audio this came from, `0.0..=1.0`.
    pub quality: f32,
    pub provenance: EmbeddingProvenance,
    pub created_at_ms: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SpeechProfile {
    pub id: String,
    pub kind: ProfileKind,
    pub display_name: Option<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub learning_paused: bool,
    pub tombstoned_at_ms: Option<i64>,
    pub embeddings: Vec<StoredEmbedding>,
}

impl SpeechProfile {
    pub fn is_active(&self) -> bool {
        self.tombstoned_at_ms.is_none()
    }

    /// The closest stored voiceprint to `probe`, ignoring any recorded by a
    /// different model.
    pub fn best_distance(&self, probe: &SpeakerEmbedding) -> Option<f32> {
        self.embeddings
            .iter()
            .filter_map(|stored| stored.embedding.cosine_distance(probe))
            .min_by(|left, right| left.total_cmp(right))
    }
}

/// The verdict on one probe.
#[derive(Clone, Debug, PartialEq)]
pub enum MatchOutcome {
    Matched {
        profile_id: String,
        distance: f32,
        runner_up: Option<f32>,
    },
    /// Close enough to one profile, but a second is nearly as close. Refusing
    /// here is what stops two similar voices from being merged by a rounding
    /// error; the caller falls back to `Speaker N`.
    Ambiguous {
        profile_id: String,
        distance: f32,
        runner_up: f32,
    },
    /// Nobody is inside [`MATCH_THRESHOLD`]. `best` is how close the nearest
    /// profile got, for diagnostics.
    NoMatch { best: Option<f32> },
}

impl MatchOutcome {
    /// The profile this outcome may be acted on with. `Ambiguous` deliberately
    /// yields nothing.
    pub fn accepted(&self) -> Option<&str> {
        match self {
            Self::Matched { profile_id, .. } => Some(profile_id),
            Self::Ambiguous { .. } | Self::NoMatch { .. } => None,
        }
    }
}

/// Matches `probe` against every active profile, threshold *and* margin.
pub fn match_profiles(profiles: &[SpeechProfile], probe: &SpeakerEmbedding) -> MatchOutcome {
    let mut ranked: Vec<(f32, &str)> = profiles
        .iter()
        .filter(|profile| profile.is_active())
        .filter_map(|profile| {
            profile
                .best_distance(probe)
                .map(|distance| (distance, profile.id.as_str()))
        })
        .collect();
    ranked.sort_by(|left, right| left.0.total_cmp(&right.0));
    let Some(&(distance, profile_id)) = ranked.first() else {
        return MatchOutcome::NoMatch { best: None };
    };
    if distance >= MATCH_THRESHOLD {
        return MatchOutcome::NoMatch {
            best: Some(distance),
        };
    }
    let runner_up = ranked.get(1).map(|&(second, _)| second);
    match runner_up {
        Some(second) if second - distance < MATCH_MARGIN => MatchOutcome::Ambiguous {
            profile_id: profile_id.to_owned(),
            distance,
            runner_up: second,
        },
        _ => MatchOutcome::Matched {
            profile_id: profile_id.to_owned(),
            distance,
            runner_up,
        },
    }
}

// ---------------------------------------------------------------------------
// Store
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum StoreError {
    Database(String),
    UnknownProfile(String),
    /// Learning is paused for this profile and the caller was the automatic
    /// path. Not a fault — the user asked for it.
    LearningPaused(String),
}

impl fmt::Display for StoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database(detail) => write!(formatter, "speech profile store: {detail}"),
            Self::UnknownProfile(id) => write!(formatter, "no speech profile {id}"),
            Self::LearningPaused(id) => {
                write!(formatter, "learning is paused for speech profile {id}")
            }
        }
    }
}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Database(error.to_string())
    }
}

type StoreResult<T> = Result<T, StoreError>;

/// The local voiceprint database, scoped to one account uid.
///
/// One file may hold several accounts on a shared machine, so every read and
/// every write carries the uid — a profile belonging to another account is not
/// merely hidden, it is unreachable.
pub struct SpeechProfileStore {
    connection: Connection,
    uid: String,
}

impl SpeechProfileStore {
    /// Opens (creating if needed) the database at `path`.
    pub fn open(path: &Path, uid: &str) -> StoreResult<Self> {
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)
                .map_err(|error| StoreError::Database(error.to_string()))?;
        }
        Self::from_connection(Connection::open(path)?, uid)
    }

    /// The same store with no file behind it. Used by the tests, and by any
    /// caller that has no durable location to write to.
    pub fn open_in_memory(uid: &str) -> StoreResult<Self> {
        Self::from_connection(Connection::open_in_memory()?, uid)
    }

    fn from_connection(connection: Connection, uid: &str) -> StoreResult<Self> {
        let store = Self {
            connection,
            uid: uid.to_owned(),
        };
        store.connection.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;",
        )?;
        store.migrate()?;
        Ok(store)
    }

    pub fn uid(&self) -> &str {
        &self.uid
    }

    /// Brings the schema up to [`SCHEMA_VERSION`], recorded in
    /// `PRAGMA user_version` so a later version can migrate forward without
    /// guessing what is already there.
    fn migrate(&self) -> StoreResult<()> {
        let version: i32 = self
            .connection
            .query_row("PRAGMA user_version", [], |row| row.get(0))?;
        if version >= SCHEMA_VERSION {
            return Ok(());
        }
        self.connection.execute_batch(
            "CREATE TABLE IF NOT EXISTS speech_profiles (
                 id TEXT PRIMARY KEY,
                 uid TEXT NOT NULL,
                 kind TEXT NOT NULL,
                 display_name TEXT,
                 created_at_ms INTEGER NOT NULL,
                 updated_at_ms INTEGER NOT NULL,
                 learning_paused INTEGER NOT NULL DEFAULT 0,
                 tombstoned_at_ms INTEGER
             );
             CREATE INDEX IF NOT EXISTS speech_profiles_by_uid
                 ON speech_profiles (uid, tombstoned_at_ms);
             CREATE TABLE IF NOT EXISTS speech_profile_embeddings (
                 id INTEGER PRIMARY KEY AUTOINCREMENT,
                 profile_id TEXT NOT NULL REFERENCES speech_profiles (id) ON DELETE CASCADE,
                 embedding BLOB NOT NULL,
                 dimensions INTEGER NOT NULL,
                 quality REAL NOT NULL,
                 attribution TEXT NOT NULL,
                 source_meeting_id TEXT,
                 source_segment_id TEXT,
                 created_at_ms INTEGER NOT NULL
             );
             CREATE INDEX IF NOT EXISTS speech_profile_embeddings_by_profile
                 ON speech_profile_embeddings (profile_id);
             CREATE TABLE IF NOT EXISTS speech_profile_aliases (
                 profile_id TEXT NOT NULL REFERENCES speech_profiles (id) ON DELETE CASCADE,
                 source TEXT NOT NULL,
                 external_id TEXT NOT NULL,
                 PRIMARY KEY (profile_id, source, external_id)
             );
             CREATE TABLE IF NOT EXISTS speech_profile_sightings (
                 uid TEXT NOT NULL,
                 meeting_id TEXT NOT NULL,
                 diarized_key INTEGER NOT NULL,
                 profile_id TEXT NOT NULL REFERENCES speech_profiles (id) ON DELETE CASCADE,
                 created_at_ms INTEGER NOT NULL,
                 PRIMARY KEY (uid, meeting_id, diarized_key)
             );",
        )?;
        self.connection
            .pragma_update(None, "user_version", SCHEMA_VERSION)?;
        Ok(())
    }

    /// Creates a profile and returns it. `display_name` stays `None` until a
    /// person types one: the hub never invents a name.
    pub fn create_profile(
        &self,
        kind: ProfileKind,
        display_name: Option<&str>,
        now_ms: i64,
    ) -> StoreResult<SpeechProfile> {
        let id = format!("sp_{}", random_id());
        let display_name = display_name.map(clean_name).unwrap_or_default();
        self.connection.execute(
            "INSERT INTO speech_profiles
                 (id, uid, kind, display_name, created_at_ms, updated_at_ms, learning_paused)
             VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0)",
            params![id, self.uid, kind.as_str(), display_name, now_ms],
        )?;
        Ok(SpeechProfile {
            id,
            kind,
            display_name: Some(display_name).filter(|value| !value.is_empty()),
            created_at_ms: now_ms,
            updated_at_ms: now_ms,
            learning_paused: false,
            tombstoned_at_ms: None,
            embeddings: Vec::new(),
        })
    }

    /// Every live profile for this uid, oldest first, with its voiceprints.
    pub fn profiles(&self) -> StoreResult<Vec<SpeechProfile>> {
        self.select_profiles("uid = ?1 AND tombstoned_at_ms IS NULL")
    }

    /// Including the forgotten ones. Their voiceprints are already gone.
    pub fn all_profiles(&self) -> StoreResult<Vec<SpeechProfile>> {
        self.select_profiles("uid = ?1")
    }

    pub fn profile(&self, profile_id: &str) -> StoreResult<Option<SpeechProfile>> {
        Ok(self
            .all_profiles()?
            .into_iter()
            .find(|profile| profile.id == profile_id))
    }

    fn select_profiles(&self, predicate: &str) -> StoreResult<Vec<SpeechProfile>> {
        let sql = format!(
            "SELECT id, kind, display_name, created_at_ms, updated_at_ms, learning_paused, \
             tombstoned_at_ms FROM speech_profiles WHERE {predicate} ORDER BY created_at_ms, id"
        );
        let mut statement = self.connection.prepare(&sql)?;
        let rows = statement.query_map(params![self.uid], |row| {
            let display_name: String = row.get(2)?;
            Ok(SpeechProfile {
                id: row.get(0)?,
                kind: ProfileKind::parse(&row.get::<_, String>(1)?),
                display_name: Some(display_name).filter(|value| !value.is_empty()),
                created_at_ms: row.get(3)?,
                updated_at_ms: row.get(4)?,
                learning_paused: row.get::<_, i64>(5)? != 0,
                tombstoned_at_ms: row.get(6)?,
                embeddings: Vec::new(),
            })
        })?;
        let mut profiles: Vec<SpeechProfile> = rows.collect::<rusqlite::Result<_>>()?;
        for profile in &mut profiles {
            profile.embeddings = self.embeddings_of(&profile.id)?;
        }
        Ok(profiles)
    }

    fn embeddings_of(&self, profile_id: &str) -> StoreResult<Vec<StoredEmbedding>> {
        let mut statement = self.connection.prepare(
            "SELECT id, embedding, quality, attribution, source_meeting_id, source_segment_id, \
             created_at_ms FROM speech_profile_embeddings WHERE profile_id = ?1 \
             ORDER BY created_at_ms, id",
        )?;
        let rows = statement.query_map(params![profile_id], |row| {
            let blob: Vec<u8> = row.get(1)?;
            Ok((
                row.get::<_, i64>(0)?,
                blob,
                row.get::<_, f64>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
                row.get::<_, i64>(6)?,
            ))
        })?;
        let mut stored = Vec::new();
        for row in rows {
            let (id, blob, quality, attribution, meeting, segment, created_at_ms) = row?;
            // A row whose bytes will not decode is skipped rather than
            // failing the whole read: one corrupt voiceprint must not cost a
            // user every other person they have ever met.
            let Ok(embedding) = SpeakerEmbedding::from_bytes(&blob) else {
                continue;
            };
            stored.push(StoredEmbedding {
                id,
                embedding,
                quality: quality as f32,
                provenance: EmbeddingProvenance {
                    attribution: Attribution::parse(&attribution),
                    source_meeting_id: meeting,
                    source_segment_id: segment,
                },
                created_at_ms,
            });
        }
        Ok(stored)
    }

    /// Attaches one voiceprint, then enforces [`MAX_EMBEDDINGS_PER_PROFILE`].
    ///
    /// Returns the new row's id so the caller can quarantine exactly this one
    /// later if the attribution turns out to have been wrong.
    pub fn add_embedding(
        &self,
        profile_id: &str,
        embedding: &SpeakerEmbedding,
        quality: f32,
        provenance: &EmbeddingProvenance,
        now_ms: i64,
    ) -> StoreResult<i64> {
        let profile = self
            .profile(profile_id)?
            .ok_or_else(|| StoreError::UnknownProfile(profile_id.to_owned()))?;
        if !profile.is_active() {
            return Err(StoreError::UnknownProfile(profile_id.to_owned()));
        }
        if profile.learning_paused && !provenance.attribution.is_user_directed() {
            return Err(StoreError::LearningPaused(profile_id.to_owned()));
        }
        self.connection.execute(
            "INSERT INTO speech_profile_embeddings
                 (profile_id, embedding, dimensions, quality, attribution, source_meeting_id,
                  source_segment_id, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                profile_id,
                embedding.to_bytes(),
                embedding.dimensions() as i64,
                f64::from(quality.clamp(0.0, 1.0)),
                provenance.attribution.as_str(),
                provenance.source_meeting_id,
                provenance.source_segment_id,
                now_ms,
            ],
        )?;
        let id = self.connection.last_insert_rowid();
        self.touch(profile_id, now_ms)?;
        self.evict(profile_id)?;
        Ok(id)
    }

    /// Drops the weakest rows until the profile is back inside the cap.
    ///
    /// Weakest means least trusted attribution first, then lowest quality,
    /// then oldest — so a deliberate enrollment is never displaced by a stream
    /// of inferred sightings, which is exactly how a profile drifts onto the
    /// wrong person.
    fn evict(&self, profile_id: &str) -> StoreResult<usize> {
        let mut stored = self.embeddings_of(profile_id)?;
        if stored.len() <= MAX_EMBEDDINGS_PER_PROFILE {
            return Ok(0);
        }
        stored.sort_by(|left, right| {
            right
                .provenance
                .attribution
                .cmp(&left.provenance.attribution)
                .then_with(|| right.quality.total_cmp(&left.quality))
                .then_with(|| right.created_at_ms.cmp(&left.created_at_ms))
        });
        let doomed: Vec<i64> = stored
            .split_off(MAX_EMBEDDINGS_PER_PROFILE)
            .into_iter()
            .map(|entry| entry.id)
            .collect();
        for id in &doomed {
            self.connection.execute(
                "DELETE FROM speech_profile_embeddings WHERE id = ?1",
                params![id],
            )?;
        }
        Ok(doomed.len())
    }

    /// Removes one voiceprint and leaves the person alone.
    ///
    /// The repair for a poisoned profile: the segment that was attributed to
    /// the wrong speaker goes, the name, the history and every other
    /// voiceprint stay. Without it the only cure is forgetting the person.
    pub fn quarantine_embedding(&self, embedding_id: i64, now_ms: i64) -> StoreResult<bool> {
        let profile_id: Option<String> = self
            .connection
            .query_row(
                "SELECT e.profile_id FROM speech_profile_embeddings e
                 JOIN speech_profiles p ON p.id = e.profile_id
                 WHERE e.id = ?1 AND p.uid = ?2",
                params![embedding_id, self.uid],
                |row| row.get(0),
            )
            .optional()?;
        let Some(profile_id) = profile_id else {
            return Ok(false);
        };
        self.connection.execute(
            "DELETE FROM speech_profile_embeddings WHERE id = ?1",
            params![embedding_id],
        )?;
        self.touch(&profile_id, now_ms)?;
        Ok(true)
    }

    /// Removes every voiceprint a given meeting contributed, across all
    /// profiles — the "that whole session was mis-attributed" repair.
    pub fn quarantine_meeting(&self, meeting_id: &str, now_ms: i64) -> StoreResult<usize> {
        let ids: Vec<i64> = {
            let mut statement = self.connection.prepare(
                "SELECT e.id FROM speech_profile_embeddings e
                 JOIN speech_profiles p ON p.id = e.profile_id
                 WHERE e.source_meeting_id = ?1 AND p.uid = ?2",
            )?;
            let rows = statement.query_map(params![meeting_id, self.uid], |row| row.get(0))?;
            rows.collect::<rusqlite::Result<_>>()?
        };
        let mut removed = 0;
        for id in ids {
            if self.quarantine_embedding(id, now_ms)? {
                removed += 1;
            }
        }
        Ok(removed)
    }

    /// Sets (or with `None`, clears) the name a person typed.
    pub fn rename_profile(
        &self,
        profile_id: &str,
        display_name: Option<&str>,
        now_ms: i64,
    ) -> StoreResult<()> {
        let name = display_name.map(clean_name).unwrap_or_default();
        let changed = self.connection.execute(
            "UPDATE speech_profiles SET display_name = ?1, updated_at_ms = ?2
             WHERE id = ?3 AND uid = ?4 AND tombstoned_at_ms IS NULL",
            params![name, now_ms, profile_id, self.uid],
        )?;
        if changed == 0 {
            return Err(StoreError::UnknownProfile(profile_id.to_owned()));
        }
        Ok(())
    }

    pub fn set_learning_paused(
        &self,
        profile_id: &str,
        paused: bool,
        now_ms: i64,
    ) -> StoreResult<()> {
        let changed = self.connection.execute(
            "UPDATE speech_profiles SET learning_paused = ?1, updated_at_ms = ?2
             WHERE id = ?3 AND uid = ?4 AND tombstoned_at_ms IS NULL",
            params![i64::from(paused), now_ms, profile_id, self.uid],
        )?;
        if changed == 0 {
            return Err(StoreError::UnknownProfile(profile_id.to_owned()));
        }
        Ok(())
    }

    /// Folds `source` into `target`: voiceprints, sightings and aliases move,
    /// `source` is tombstoned, and the cap is re-applied to the survivor.
    ///
    /// A name on `target` wins; a name only `source` had is inherited, because
    /// the user typed it once and should not have to type it again.
    pub fn merge_profiles(&self, target: &str, source: &str, now_ms: i64) -> StoreResult<()> {
        if target == source {
            return Ok(());
        }
        let target_profile = self
            .profile(target)?
            .filter(SpeechProfile::is_active)
            .ok_or_else(|| StoreError::UnknownProfile(target.to_owned()))?;
        let source_profile = self
            .profile(source)?
            .filter(SpeechProfile::is_active)
            .ok_or_else(|| StoreError::UnknownProfile(source.to_owned()))?;
        // A half-applied merge leaves the source alive with no voiceprints:
        // a duplicate person the user cannot merge away again.
        let merge = self.connection.unchecked_transaction()?;
        self.connection.execute(
            "UPDATE speech_profile_embeddings SET profile_id = ?1 WHERE profile_id = ?2",
            params![target, source],
        )?;
        self.connection.execute(
            "UPDATE OR REPLACE speech_profile_sightings SET profile_id = ?1 WHERE profile_id = ?2",
            params![target, source],
        )?;
        self.connection.execute(
            "UPDATE OR REPLACE speech_profile_aliases SET profile_id = ?1 WHERE profile_id = ?2",
            params![target, source],
        )?;
        if target_profile.display_name.is_none()
            && let Some(name) = source_profile.display_name.as_deref()
        {
            self.rename_profile(target, Some(name), now_ms)?;
        }
        self.connection.execute(
            "UPDATE speech_profiles SET tombstoned_at_ms = ?1, updated_at_ms = ?1
             WHERE id = ?2 AND uid = ?3",
            params![now_ms, source, self.uid],
        )?;
        self.touch(target, now_ms)?;
        self.evict(target)?;
        merge.commit()?;
        Ok(())
    }

    /// Forgets a person: every voiceprint is deleted outright, the row is
    /// tombstoned rather than dropped so a stale id in a transcript resolves
    /// to "forgotten" instead of silently matching a future profile.
    pub fn forget_profile(&self, profile_id: &str, now_ms: i64) -> StoreResult<()> {
        // The tombstone hides the profile from every read path, so a delete
        // that failed after it would leave voiceprints on disk for someone
        // who was told they were gone, with nothing left to surface them.
        let forget = self.connection.unchecked_transaction()?;
        let changed = self.connection.execute(
            "UPDATE speech_profiles SET tombstoned_at_ms = ?1, updated_at_ms = ?1, display_name = ''
             WHERE id = ?2 AND uid = ?3 AND tombstoned_at_ms IS NULL",
            params![now_ms, profile_id, self.uid],
        )?;
        if changed == 0 {
            return Err(StoreError::UnknownProfile(profile_id.to_owned()));
        }
        self.connection.execute(
            "DELETE FROM speech_profile_embeddings WHERE profile_id = ?1",
            params![profile_id],
        )?;
        self.connection.execute(
            "DELETE FROM speech_profile_sightings WHERE profile_id = ?1",
            params![profile_id],
        )?;
        self.connection.execute(
            "DELETE FROM speech_profile_aliases WHERE profile_id = ?1",
            params![profile_id],
        )?;
        forget.commit()?;
        Ok(())
    }

    /// Runs [`match_profiles`] over this account's live profiles.
    pub fn match_embedding(&self, probe: &SpeakerEmbedding) -> StoreResult<MatchOutcome> {
        Ok(match_profiles(&self.profiles()?, probe))
    }

    /// Soft-links a meeting-local diarization index to a profile for the
    /// duration of one session.
    pub fn record_sighting(
        &self,
        meeting_id: &str,
        diarized_key: u64,
        profile_id: &str,
        now_ms: i64,
    ) -> StoreResult<()> {
        if self.profile(profile_id)?.is_none_or(|p| !p.is_active()) {
            return Err(StoreError::UnknownProfile(profile_id.to_owned()));
        }
        self.connection.execute(
            "INSERT INTO speech_profile_sightings
                 (uid, meeting_id, diarized_key, profile_id, created_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT (uid, meeting_id, diarized_key)
             DO UPDATE SET profile_id = excluded.profile_id, created_at_ms = excluded.created_at_ms",
            params![self.uid, meeting_id, diarized_key as i64, profile_id, now_ms],
        )?;
        Ok(())
    }

    pub fn sighting(&self, meeting_id: &str, diarized_key: u64) -> StoreResult<Option<String>> {
        Ok(self
            .connection
            .query_row(
                "SELECT profile_id FROM speech_profile_sightings
                 WHERE uid = ?1 AND meeting_id = ?2 AND diarized_key = ?3",
                params![self.uid, meeting_id, diarized_key as i64],
                |row| row.get(0),
            )
            .optional()?)
    }

    /// Every soft link this meeting has made so far, as
    /// `(diarized_key, profile_id, display_name)`. This is what the roster
    /// bridge loads when a meeting resumes.
    pub fn meeting_sightings(&self, meeting_id: &str) -> StoreResult<Vec<(u64, String, String)>> {
        let mut statement = self.connection.prepare(
            "SELECT s.diarized_key, s.profile_id, p.display_name
             FROM speech_profile_sightings s
             JOIN speech_profiles p ON p.id = s.profile_id
             WHERE s.uid = ?1 AND s.meeting_id = ?2 AND p.tombstoned_at_ms IS NULL
               AND p.display_name <> ''
             ORDER BY s.diarized_key",
        )?;
        let rows = statement.query_map(params![self.uid, meeting_id], |row| {
            Ok((
                row.get::<_, i64>(0)? as u64,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
            ))
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    fn touch(&self, profile_id: &str, now_ms: i64) -> StoreResult<()> {
        self.connection.execute(
            "UPDATE speech_profiles SET updated_at_ms = ?1 WHERE id = ?2 AND uid = ?3",
            params![now_ms, profile_id, self.uid],
        )?;
        Ok(())
    }
}

/// Names are user text on their way into a transcript, so they are trimmed and
/// bounded here rather than wherever they are eventually rendered.
fn clean_name(value: &str) -> String {
    value
        .trim()
        .chars()
        .filter(|character| !character.is_control())
        .take(64)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        Attribution, EmbeddingError, EmbeddingProvenance, EmbeddingSource, MATCH_MARGIN,
        MATCH_THRESHOLD, MAX_EMBEDDINGS_PER_PROFILE, MIN_EMBEDDING_MS, MatchOutcome,
        NullEmbeddingSource, ProfileKind, SpeakerEmbedding, SpeechProfileStore, StoreError,
        embed_segment, guard_segment, match_profiles, segment_duration_ms,
    };

    const NOW: i64 = 1_784_800_800_000;

    fn embedding(values: &[f32]) -> SpeakerEmbedding {
        match SpeakerEmbedding::new(values.to_vec()) {
            Ok(value) => value,
            Err(error) => panic!("a finite non-zero vector normalizes: {error}"),
        }
    }

    /// A unit vector `angle` radians from `[1, 0]`, so a test can name the
    /// cosine distance it wants directly.
    fn at_angle(angle: f32) -> SpeakerEmbedding {
        embedding(&[angle.cos(), angle.sin()])
    }

    /// A unit vector whose cosine distance from `[1, 0]` is exactly
    /// `distance`.
    fn at_distance(distance: f32) -> SpeakerEmbedding {
        at_angle((1.0 - distance).clamp(-1.0, 1.0).acos())
    }

    fn store() -> SpeechProfileStore {
        match SpeechProfileStore::open_in_memory("uid-1") {
            Ok(store) => store,
            Err(error) => panic!("an in-memory store opens: {error}"),
        }
    }

    fn profile(store: &SpeechProfileStore, name: Option<&str>) -> String {
        match store.create_profile(ProfileKind::Other, name, NOW) {
            Ok(profile) => profile.id,
            Err(error) => panic!("creating a profile succeeds: {error}"),
        }
    }

    fn inferred() -> EmbeddingProvenance {
        EmbeddingProvenance::from_meeting(Attribution::LlmInferred, "meeting-1", "segment-1")
    }

    // -- embeddings ------------------------------------------------------

    #[test]
    fn embeddings_are_normalized_and_degenerate_input_is_refused() {
        let unit = embedding(&[3.0, 4.0]);
        let norm: f32 = unit.values().iter().map(|value| value * value).sum();
        assert!((norm - 1.0).abs() < 1e-5);
        assert_eq!(
            SpeakerEmbedding::new(Vec::new()),
            Err(EmbeddingError::Degenerate)
        );
        assert_eq!(
            SpeakerEmbedding::new(vec![0.0, 0.0]),
            Err(EmbeddingError::Degenerate)
        );
        assert_eq!(
            SpeakerEmbedding::new(vec![f32::NAN, 1.0]),
            Err(EmbeddingError::Degenerate)
        );
    }

    #[test]
    fn cosine_distance_is_zero_for_the_same_voice_and_refuses_other_models() {
        let left = embedding(&[1.0, 0.0]);
        let scaled = embedding(&[7.0, 0.0]);
        let orthogonal = embedding(&[0.0, 1.0]);
        assert!(left.cosine_distance(&scaled).is_some_and(|d| d < 1e-6));
        assert!(
            left.cosine_distance(&orthogonal)
                .is_some_and(|d| (d - 1.0).abs() < 1e-6)
        );
        assert_eq!(left.cosine_distance(&embedding(&[1.0, 0.0, 0.0])), None);
    }

    #[test]
    fn embeddings_survive_the_on_disk_blob_round_trip() {
        let original = embedding(&[0.1, -0.2, 0.9, 0.4]);
        let bytes = original.to_bytes();
        assert_eq!(bytes.len(), 16);
        assert_eq!(SpeakerEmbedding::from_bytes(&bytes), Ok(original));
        assert_eq!(
            SpeakerEmbedding::from_bytes(&[0, 1, 2]),
            Err(EmbeddingError::Degenerate)
        );
        assert_eq!(
            SpeakerEmbedding::from_bytes(&[]),
            Err(EmbeddingError::Degenerate)
        );
    }

    // -- the guard and the fail-closed source ----------------------------

    #[test]
    fn segments_shorter_than_the_minimum_are_refused_before_the_model_runs() {
        assert_eq!(segment_duration_ms(8_000, 16_000), 500);
        assert_eq!(guard_segment(&vec![0_i16; 8_000], 16_000), Ok(()));
        assert_eq!(
            guard_segment(&vec![0_i16; 7_999], 16_000),
            Err(EmbeddingError::TooShort {
                have_ms: 499,
                need_ms: MIN_EMBEDDING_MS,
            })
        );
        assert_eq!(
            guard_segment(&vec![0_i16; 100_000], 4_000),
            Err(EmbeddingError::UnsupportedSampleRate(4_000))
        );
        assert_eq!(
            guard_segment(&[], 16_000),
            Err(EmbeddingError::TooShort {
                have_ms: 0,
                need_ms: MIN_EMBEDDING_MS,
            })
        );
    }

    /// A source that would answer, so the guard is observably what refuses the
    /// short segment rather than the model being missing.
    struct AlwaysAnswers;

    impl EmbeddingSource for AlwaysAnswers {
        fn embed(&self, _pcm: &[i16], _rate: u32) -> Result<SpeakerEmbedding, EmbeddingError> {
            Ok(embedding(&[1.0, 0.0]))
        }
    }

    #[test]
    fn the_guard_runs_before_the_source() {
        assert!(embed_segment(&AlwaysAnswers, &vec![0_i16; 8_000], 16_000).is_ok());
        assert_eq!(
            embed_segment(&AlwaysAnswers, &[0_i16; 10], 16_000),
            Err(EmbeddingError::TooShort {
                have_ms: 0,
                need_ms: MIN_EMBEDDING_MS,
            })
        );
    }

    #[test]
    fn the_shipped_source_is_fail_closed() {
        // No embedding model ships with omi-v4, so every call must say so
        // rather than returning something the matcher would act on.
        assert_eq!(
            NullEmbeddingSource.embed(&vec![0_i16; 48_000], 16_000),
            Err(EmbeddingError::Unavailable)
        );
        assert_eq!(
            embed_segment(&NullEmbeddingSource, &vec![0_i16; 48_000], 16_000),
            Err(EmbeddingError::Unavailable)
        );
    }

    // -- matching --------------------------------------------------------

    fn with_embeddings(specs: &[(&str, f32)]) -> Vec<super::SpeechProfile> {
        let store = store();
        for (name, distance) in specs {
            let id = profile(&store, Some(name));
            assert!(
                store
                    .add_embedding(&id, &at_distance(*distance), 0.9, &inferred(), NOW)
                    .is_ok()
            );
        }
        match store.profiles() {
            Ok(profiles) => profiles,
            Err(error) => panic!("listing profiles succeeds: {error}"),
        }
    }

    #[test]
    fn a_lone_close_profile_matches() {
        let profiles = with_embeddings(&[("Alex", 0.10)]);
        let outcome = match_profiles(&profiles, &embedding(&[1.0, 0.0]));
        let MatchOutcome::Matched { distance, .. } = &outcome else {
            panic!("one close profile matches, got {outcome:?}");
        };
        assert!(*distance < MATCH_THRESHOLD);
        assert!(outcome.accepted().is_some());
    }

    #[test]
    fn nothing_inside_the_threshold_is_no_match() {
        let profiles = with_embeddings(&[("Alex", MATCH_THRESHOLD + 0.05)]);
        let outcome = match_profiles(&profiles, &embedding(&[1.0, 0.0]));
        let MatchOutcome::NoMatch { best } = outcome else {
            panic!("a distant profile is not a match, got {outcome:?}");
        };
        assert!(best.is_some_and(|value| value >= MATCH_THRESHOLD));
    }

    #[test]
    fn two_nearly_equal_candidates_are_refused_rather_than_guessed() {
        // Both are inside the bare threshold upstream omi uses, so a
        // threshold-only matcher would label this segment with whichever came
        // out marginally nearer. The margin test refuses instead.
        let profiles = with_embeddings(&[("Alex", 0.20), ("Sam", 0.20 + MATCH_MARGIN / 2.0)]);
        let outcome = match_profiles(&profiles, &embedding(&[1.0, 0.0]));
        let MatchOutcome::Ambiguous {
            distance,
            runner_up,
            ..
        } = outcome
        else {
            panic!("two close profiles are ambiguous, got {outcome:?}");
        };
        assert!(distance < MATCH_THRESHOLD);
        assert!(runner_up - distance < MATCH_MARGIN);
        assert_eq!(
            match_profiles(&profiles, &embedding(&[1.0, 0.0])).accepted(),
            None
        );
    }

    #[test]
    fn a_clear_winner_beats_a_second_candidate_inside_the_threshold() {
        let profiles = with_embeddings(&[("Alex", 0.05), ("Sam", 0.05 + MATCH_MARGIN * 2.0)]);
        let outcome = match_profiles(&profiles, &embedding(&[1.0, 0.0]));
        let MatchOutcome::Matched { runner_up, .. } = outcome else {
            panic!("a clear winner matches, got {outcome:?}");
        };
        assert!(runner_up.is_some());
    }

    #[test]
    fn an_empty_store_matches_nothing() {
        assert_eq!(
            match_profiles(&[], &embedding(&[1.0, 0.0])),
            MatchOutcome::NoMatch { best: None }
        );
    }

    #[test]
    fn a_forgotten_profile_stops_matching() {
        let store = store();
        let id = profile(&store, Some("Alex"));
        assert!(
            store
                .add_embedding(&id, &at_distance(0.02), 0.9, &inferred(), NOW)
                .is_ok()
        );
        assert!(matches!(
            store.match_embedding(&embedding(&[1.0, 0.0])),
            Ok(MatchOutcome::Matched { .. })
        ));
        assert!(store.forget_profile(&id, NOW + 1).is_ok());
        assert!(matches!(
            store.match_embedding(&embedding(&[1.0, 0.0])),
            Ok(MatchOutcome::NoMatch { best: None })
        ));
    }

    // -- store -----------------------------------------------------------

    #[test]
    fn profiles_round_trip_through_sqlite() {
        let store = store();
        let id = profile(&store, Some("  Alex  "));
        assert!(
            store
                .add_embedding(&id, &at_distance(0.1), 0.8, &inferred(), NOW)
                .is_ok()
        );
        let Ok(profiles) = store.profiles() else {
            panic!("listing profiles succeeds");
        };
        assert_eq!(profiles.len(), 1);
        let Some(stored) = profiles.first() else {
            panic!("one profile was created");
        };
        assert_eq!(stored.display_name.as_deref(), Some("Alex"));
        assert_eq!(stored.kind, ProfileKind::Other);
        assert_eq!(stored.embeddings.len(), 1);
        let Some(first) = stored.embeddings.first() else {
            panic!("one embedding was added");
        };
        assert_eq!(
            first.provenance.source_meeting_id.as_deref(),
            Some("meeting-1")
        );
        assert_eq!(first.provenance.attribution, Attribution::LlmInferred);
    }

    #[test]
    fn another_account_cannot_see_these_profiles() {
        // Both accounts have to share one file, or the isolation being
        // asserted is just two unrelated databases being empty.
        let directory = std::env::temp_dir().join(format!(
            "speech_profiles_uid_{}_{}",
            std::process::id(),
            NOW
        ));
        let _ = std::fs::remove_dir_all(&directory);
        let path = directory.join("speech_profiles.sqlite3");
        let Ok(store) = SpeechProfileStore::open(&path, "uid-1") else {
            panic!("the first store opens");
        };
        let Ok(other) = SpeechProfileStore::open(&path, "uid-2") else {
            panic!("a second store opens on the same file");
        };
        let id = profile(&store, Some("Alex"));
        assert!(store.rename_profile(&id, Some("Alexandra"), NOW).is_ok());

        assert!(other.profiles().is_ok_and(|profiles| profiles.is_empty()));
        assert!(matches!(
            other.rename_profile(&id, Some("Mallory"), NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        assert!(matches!(
            other.forget_profile(&id, NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        assert!(matches!(
            other.set_learning_paused(&id, true, NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        assert!(matches!(
            other.add_embedding(&id, &at_distance(0.1), 0.9, &inferred(), NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        let intruder = profile(&other, Some("Mallory"));
        assert!(matches!(
            other.merge_profiles(&intruder, &id, NOW),
            Err(StoreError::UnknownProfile(_))
        ));

        // The victim is untouched by every one of those attempts.
        let Ok(Some(kept)) = store.profile(&id) else {
            panic!("the profile survives");
        };
        assert_eq!(kept.display_name.as_deref(), Some("Alexandra"));
        assert!(kept.tombstoned_at_ms.is_none());
        assert!(!kept.learning_paused);
        let _ = std::fs::remove_dir_all(&directory);
    }

    #[test]
    fn the_embedding_cap_evicts_the_least_trusted_first() {
        let store = store();
        let id = profile(&store, None);
        let Ok(enrolled) = store.add_embedding(
            &id,
            &at_distance(0.01),
            0.1,
            &EmbeddingProvenance::enrolled(),
            NOW,
        ) else {
            panic!("adding the enrolled voiceprint succeeds");
        };
        // Every later row is inferred and higher quality, so only the
        // attribution ordering can keep the enrollment alive.
        for index in 0..(MAX_EMBEDDINGS_PER_PROFILE as i64 + 8) {
            assert!(
                store
                    .add_embedding(&id, &at_distance(0.3), 1.0, &inferred(), NOW + index)
                    .is_ok()
            );
        }
        let Ok(Some(stored)) = store.profile(&id) else {
            panic!("the profile still exists");
        };
        assert_eq!(stored.embeddings.len(), MAX_EMBEDDINGS_PER_PROFILE);
        assert!(stored.embeddings.iter().any(|entry| entry.id == enrolled));
    }

    #[test]
    fn quarantine_removes_one_voiceprint_and_keeps_the_person() {
        let store = store();
        let id = profile(&store, Some("Alex"));
        let Ok(good) = store.add_embedding(
            &id,
            &at_distance(0.01),
            0.9,
            &EmbeddingProvenance::enrolled(),
            NOW,
        ) else {
            panic!("adding a voiceprint succeeds");
        };
        let Ok(poisoned) = store.add_embedding(
            &id,
            &at_distance(0.02),
            0.9,
            &EmbeddingProvenance::from_meeting(Attribution::LlmInferred, "bad-meeting", "seg-9"),
            NOW,
        ) else {
            panic!("adding a voiceprint succeeds");
        };
        assert_eq!(
            store.quarantine_embedding(poisoned, NOW + 1).ok(),
            Some(true)
        );
        assert_eq!(
            store.quarantine_embedding(poisoned, NOW + 1).ok(),
            Some(false)
        );
        let Ok(Some(stored)) = store.profile(&id) else {
            panic!("the person is still there");
        };
        assert_eq!(stored.display_name.as_deref(), Some("Alex"));
        assert_eq!(stored.embeddings.len(), 1);
        assert!(stored.embeddings.iter().any(|entry| entry.id == good));
    }

    #[test]
    fn quarantining_a_meeting_removes_only_that_meetings_rows() {
        let store = store();
        let id = profile(&store, Some("Alex"));
        for meeting in ["good", "bad", "bad"] {
            assert!(
                store
                    .add_embedding(
                        &id,
                        &at_distance(0.1),
                        0.9,
                        &EmbeddingProvenance::from_meeting(
                            Attribution::LlmInferred,
                            meeting,
                            "seg"
                        ),
                        NOW,
                    )
                    .is_ok()
            );
        }
        assert_eq!(store.quarantine_meeting("bad", NOW + 1).ok(), Some(2));
        assert!(
            store
                .profile(&id)
                .is_ok_and(|found| found.is_some_and(|p| p.embeddings.len() == 1))
        );
    }

    #[test]
    fn merging_moves_the_voiceprints_and_inherits_a_name() {
        let store = store();
        let target = profile(&store, None);
        let source = profile(&store, Some("Alex"));
        assert!(
            store
                .add_embedding(&target, &at_distance(0.1), 0.9, &inferred(), NOW)
                .is_ok()
        );
        assert!(
            store
                .add_embedding(&source, &at_distance(0.2), 0.9, &inferred(), NOW)
                .is_ok()
        );
        assert!(store.record_sighting("meeting-1", 3, &source, NOW).is_ok());
        assert!(store.merge_profiles(&target, &source, NOW + 1).is_ok());
        let Ok(profiles) = store.profiles() else {
            panic!("listing profiles succeeds");
        };
        assert_eq!(profiles.len(), 1);
        let Some(survivor) = profiles.first() else {
            panic!("one profile survives a merge");
        };
        assert_eq!(survivor.id, target);
        assert_eq!(survivor.display_name.as_deref(), Some("Alex"));
        assert_eq!(survivor.embeddings.len(), 2);
        assert_eq!(
            store.sighting("meeting-1", 3).ok().flatten().as_deref(),
            Some(target.as_str())
        );
        // The merged-away profile is gone from the list, and merging it again
        // is refused rather than resurrecting it.
        assert!(matches!(
            store.merge_profiles(&target, &source, NOW + 2),
            Err(StoreError::UnknownProfile(_))
        ));
    }

    #[test]
    fn merging_a_profile_into_itself_changes_nothing() {
        let store = store();
        let id = profile(&store, Some("Alex"));
        assert!(
            store
                .add_embedding(&id, &at_distance(0.1), 0.9, &inferred(), NOW)
                .is_ok()
        );
        assert!(store.merge_profiles(&id, &id, NOW + 1).is_ok());
        assert!(
            store
                .profile(&id)
                .is_ok_and(|found| found.is_some_and(|p| p.embeddings.len() == 1))
        );
    }

    #[test]
    fn forgetting_deletes_the_voiceprints_not_just_the_row() {
        let store = store();
        let id = profile(&store, Some("Alex"));
        assert!(
            store
                .add_embedding(&id, &at_distance(0.1), 0.9, &inferred(), NOW)
                .is_ok()
        );
        assert!(store.forget_profile(&id, NOW + 1).is_ok());
        assert!(store.profiles().is_ok_and(|profiles| profiles.is_empty()));
        let Ok(Some(tombstoned)) = store.profile(&id) else {
            panic!("the tombstone is still addressable");
        };
        assert!(!tombstoned.is_active());
        assert!(tombstoned.embeddings.is_empty());
        assert_eq!(tombstoned.display_name, None);
        assert!(matches!(
            store.forget_profile(&id, NOW + 2),
            Err(StoreError::UnknownProfile(_))
        ));
    }

    #[test]
    fn paused_learning_stops_the_automatic_path_only() {
        let store = store();
        let id = profile(&store, Some("Alex"));
        assert!(store.set_learning_paused(&id, true, NOW).is_ok());
        assert!(matches!(
            store.add_embedding(&id, &at_distance(0.1), 0.9, &inferred(), NOW),
            Err(StoreError::LearningPaused(_))
        ));
        assert!(
            store
                .add_embedding(
                    &id,
                    &at_distance(0.1),
                    0.9,
                    &EmbeddingProvenance::enrolled(),
                    NOW,
                )
                .is_ok()
        );
        assert!(store.set_learning_paused(&id, false, NOW + 1).is_ok());
        assert!(
            store
                .add_embedding(&id, &at_distance(0.1), 0.9, &inferred(), NOW + 1)
                .is_ok()
        );
    }

    #[test]
    fn sightings_are_one_profile_per_diarized_index_per_meeting() {
        let store = store();
        let first = profile(&store, Some("Alex"));
        let second = profile(&store, Some("Sam"));
        assert!(store.record_sighting("meeting-1", 2, &first, NOW).is_ok());
        assert!(
            store
                .record_sighting("meeting-1", 2, &second, NOW + 1)
                .is_ok()
        );
        assert_eq!(
            store.sighting("meeting-1", 2).ok().flatten().as_deref(),
            Some(second.as_str())
        );
        assert_eq!(store.sighting("meeting-2", 2).ok().flatten(), None);
        let Ok(links) = store.meeting_sightings("meeting-1") else {
            panic!("reading the meeting's soft links succeeds");
        };
        assert_eq!(links.len(), 1);
        assert_eq!(
            links.first().map(|(key, _, name)| (*key, name.as_str())),
            Some((2, "Sam"))
        );
    }

    #[test]
    fn unnamed_profiles_do_not_reach_the_roster() {
        let store = store();
        let id = profile(&store, None);
        assert!(store.record_sighting("meeting-1", 1, &id, NOW).is_ok());
        assert!(
            store
                .meeting_sightings("meeting-1")
                .is_ok_and(|links| links.is_empty())
        );
    }

    #[test]
    fn operations_on_a_missing_profile_are_typed_errors() {
        let store = store();
        assert!(matches!(
            store.rename_profile("sp_nope", Some("Alex"), NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        assert!(matches!(
            store.set_learning_paused("sp_nope", true, NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        assert!(matches!(
            store.record_sighting("meeting-1", 0, "sp_nope", NOW),
            Err(StoreError::UnknownProfile(_))
        ));
        assert!(matches!(
            store.add_embedding("sp_nope", &at_distance(0.1), 0.9, &inferred(), NOW),
            Err(StoreError::UnknownProfile(_))
        ));
    }

    #[test]
    fn the_schema_survives_reopening_the_same_file() {
        let directory = std::env::temp_dir().join(format!(
            "speech_profiles_test_{}_{}",
            std::process::id(),
            NOW
        ));
        let _ = std::fs::remove_dir_all(&directory);
        let path = directory.join("nested").join("speech_profiles.sqlite3");
        let id = {
            let Ok(store) = SpeechProfileStore::open(&path, "uid-1") else {
                panic!("the store opens");
            };
            let id = profile(&store, Some("Alex"));
            assert!(
                store
                    .add_embedding(&id, &at_distance(0.1), 0.9, &inferred(), NOW)
                    .is_ok()
            );
            id
        };
        let Ok(reopened) = SpeechProfileStore::open(&path, "uid-1") else {
            panic!("the store reopens");
        };
        assert!(
            reopened
                .profile(&id)
                .is_ok_and(|found| found.is_some_and(|p| p.embeddings.len() == 1))
        );
        let _ = std::fs::remove_dir_all(&directory);
    }
}
