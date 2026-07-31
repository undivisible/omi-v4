//! Rinf IPC boundary between the Flutter isolate and the Rust hub.
//!
//! Every [`ClientCommand`] crosses a trust boundary: the Dart side is treated
//! as an untrusted peer for security-sensitive operations. The hub validates,
//! caps, and pins externally visible behaviour instead of trusting caller
//! strings — managed-worker origins are allowlisted, cloud memory applies
//! require a configured trusted assistant and monotonic sequences, deletion
//! log records apply only when [`Command::ApplyMemory::apply_deletions`] is
//! true, client memory and Live session context are size-capped, and audio
//! chunks are bounded. Credentials and message bodies in debug output are
//! redacted in generated Dart bindings.
use rinf::{DartSignal, DartSignalBinary, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub const MAX_AUDIO_CHUNK_BYTES: usize = 256 * 1024;
pub const MAX_CLIENT_MEMORY_CONTEXT_BYTES: usize = 32 * 1024;
pub const MAX_LIVE_SESSION_CONTEXT_BYTES: usize = 64 * 1024;

#[derive(Deserialize, DartSignal)]
pub struct ClientCommand {
    pub request_id: String,
    pub command: Command,
}

#[derive(Deserialize, SignalPiece)]
pub enum Command {
    ConfigureMemory {
        database_path: String,
        tenant_id: String,
        person_id: String,
    },
    SendMessage {
        text: String,
        conversation_id: Option<String>,
        memory_context: Option<String>,
        origin: Option<MessageOrigin>,
    },
    ConfigureAssistant {
        provider: AssistantProvider,
        model: String,
        endpoint: Option<String>,
        credential: String,
    },
    ConfigureTrustedAssistant {
        managed_worker_origin: String,
    },
    ConfigureCloudMemory {
        managed_worker_origin: String,
        credential: String,
    },
    ClearAssistant,
    StartTranscription {
        audio_stream_id: String,
        device_id: String,
        auth: TranscriptionAuth,
        language: String,
        sample_rate_hz: u32,
        channels: u8,
        encoding: AudioEncoding,
        tempo: u8,
    },
    StopTranscription {
        audio_stream_id: String,
    },
    StartLiveVoice {
        live_stream_id: String,
        ephemeral_token: String,
        model: String,
        resumption_handle: Option<String>,
        /// Optional read-only screen/AX context for the Live session.
        session_context: Option<String>,
    },
    StopLiveVoice {
        live_stream_id: String,
    },
    CaptureEvent {
        ingestion_key: String,
        source: CaptureSource,
        occurred_at_ms: i64,
        recorded_at_ms: i64,
        text: Option<String>,
        application: Option<String>,
        window_title: Option<String>,
        transcript_locator: Option<TranscriptLocator>,
    },
    SearchMemory {
        query: String,
        limit: u32,
        as_of_valid_at_ms: Option<i64>,
        as_of_recorded_at_ms: Option<i64>,
    },
    ExportMemory {
        after_commit: i64,
        after_event_index: i64,
        high_water_mark: Option<i64>,
        limit: u32,
    },
    /// Apply authoritative cloud memory-log commits into the local zkr database.
    ApplyMemory {
        commits: Vec<MemoryApplyCommit>,
        /// When true, `deletion` log records may retract local zkr rows. Omitted
        /// or false keeps deletions out of the apply so a compromised isolate
        /// cannot wipe memory through this IPC surface.
        apply_deletions: Option<bool>,
    },
    ListMemoryItems {
        limit: u32,
    },
    CorrectMemory {
        claim_id: String,
        text: String,
        value: String,
        occurred_at_ms: i64,
        recorded_at_ms: i64,
    },
    DeleteMemorySource {
        source_id: String,
        deleted_at_ms: i64,
    },
    ScanOnboarding {
        roots: Vec<String>,
        include_apple_notes: bool,
        include_apple_mail: bool,
        recorded_at_ms: i64,
    },
    ApprovalDecision {
        proposal_id: String,
        decision: ApprovalDecision,
        authority_receipt: Option<ComputerUseAuthorityReceipt>,
    },
    DeviceState {
        device_id: String,
        connected: bool,
        battery_percent: Option<u8>,
        firmware_version: Option<String>,
    },
    Cancel,
    StartMeeting {
        title: Option<String>,
    },
    StopMeeting,
    JotMeetingNote {
        text: String,
    },
    ProvideMeetingAuth {
        auth: TranscriptionAuth,
        trusted_worker_origin: Option<String>,
    },
    SetSystemAudioCaptureMode {
        mode: crate::capture_policy::SystemAudioCaptureMode,
    },
    /// Turn client-side voice-activity gating of the device audio path on or
    /// off, and optionally retune it. Every tuning field is optional so a
    /// client that only wants the kill switch does not have to restate the
    /// values it never chose. Answered by exactly one [`ToolProgress`] naming
    /// the policy that ended up in force.
    ///
    /// `threshold_basis_points` is the root-mean-square level at which audio
    /// counts as speech, in basis points of full scale; `pre_roll_ms` is how
    /// much audio ahead of a detected onset is kept so the first word is not
    /// clipped; `hangover_ms` is how long the gate stays open after speech
    /// stops so a pause does not split one utterance in two.
    SetVoiceGate {
        enabled: bool,
        threshold_basis_points: Option<u32>,
        pre_roll_ms: Option<u32>,
        hangover_ms: Option<u32>,
    },
    /// Compose the currents brief for the items the client just refreshed.
    /// Answered by exactly one [`BriefComposed`], whose `crepus` is `None`
    /// whenever the brief could not be composed — the client then keeps the
    /// hand-built brief it already drew.
    ComposeBrief {
        now_local: String,
        items: Vec<BriefItem>,
    },
    /// Join a call link with the headless-browser leg and bridge it to a
    /// realtime voice session. `ephemeral_token` and `model` are the same
    /// short-lived session credentials [`Command::StartLiveVoice`] carries:
    /// the hub never mints them.
    JoinCall {
        link: String,
        display_name: Option<String>,
        video: bool,
        ephemeral_token: String,
        model: String,
    },
    /// Resolve the dev-only Gemini access the client falls back to when no
    /// account is configured. Answered by exactly one [`DevAssistant`].
    ResolveDevAssistant,
    /// Mid-session screen/AX context refresh for an active Live voice stream.
    UpdateLiveVoiceContext {
        live_stream_id: String,
        session_context: String,
    },
    /// One step of the Rewind capture handshake, or one thing the user asked
    /// the screen-history engine to do. Answered by exactly one
    /// [`NativeEvent::Rewind`].
    Rewind {
        request: RewindRequest,
    },
    /// Open (creating if needed) the pendant capture write-ahead log under the
    /// client's shared `.omi` data directory. Answered by exactly one
    /// [`CaptureWalOpened`], whose `error` is set when the log could not be
    /// opened at all — read-only storage, no space — which the client treats
    /// as "capture works, durability does not" rather than as a capture
    /// failure. Every bound is optional; omitting one takes the hub's default.
    OpenCaptureWal {
        directory: String,
        max_bytes: Option<u64>,
        max_age_ms: Option<i64>,
        max_segment_bytes: Option<u64>,
    },
    /// Supply (or withdraw) the credentials sealed segments are uploaded with.
    /// Either half missing leaves the log holding every segment until it ages
    /// or size-evicts out, which is the only safe answer when nobody is signed
    /// in: audio is never dropped because the route was unreachable.
    ConfigureCaptureUpload {
        endpoint: Option<String>,
        firebase_token: Option<String>,
    },
    /// Seal whatever is open and start a new segment. Answered by exactly one
    /// [`CaptureSegmentBegun`] carrying the id that will be the upload's
    /// idempotency key.
    BeginCaptureSegment {
        device_id: String,
        audio_stream_id: String,
        encoding: AudioEncoding,
        sample_rate_hz: u32,
        channels: u8,
        gap_before: bool,
    },
    /// Append one decoded audio frame to the open segment. Answered by exactly
    /// one [`CaptureAudioAppended`], because the client must not hand the same
    /// frame to the transcription socket until the bytes are with the operating
    /// system: disk first is what makes a frame that was in flight when the
    /// process died recoverable. The acknowledgement is also the capture path's
    /// only backpressure — without it the client would read the pendant faster
    /// than the log could absorb it and the queue would simply move somewhere
    /// nobody can see. It shares the command channel with
    /// [`Command::BeginCaptureSegment`] and [`Command::SealCaptureSegment`] so
    /// that an append can never overtake the segment boundary it belongs to.
    AppendCaptureAudio {
        bytes: Vec<u8>,
    },
    ImportRingRange {
        source_id: String,
        device_id: String,
        started_at_ms: i64,
        frames: Vec<Vec<u8>>,
    },
    /// Seal the open segment so it becomes uploadable, then re-apply the
    /// bounds. Answered by exactly one [`CaptureWalState`].
    SealCaptureSegment,
    /// Run one upload pass now. Answered by exactly one [`CaptureWalState`];
    /// concurrent requests share the pass already in flight.
    DrainCaptureWal,
    /// Report what the log is holding, without uploading anything. Answered by
    /// exactly one [`CaptureWalState`].
    ReadCaptureWalState,
    /// Seal the open segment and release the file handle. Answered by exactly
    /// one [`CaptureWalState`].
    CloseCaptureWal,
    /// Record that capture stopped. The resume side arrives separately, as
    /// [`Command::RecordCaptureResume`], because a device that never comes
    /// back still has a discontinuity worth showing.
    RecordCaptureGap {
        device_id: String,
        reason: String,
        ended_at_ms: i64,
        ended_stream_id: String,
    },
    /// Attach the resume side to the most recent open gap for this device.
    /// `stream_id` is always the *new* stream, which is what makes the two
    /// sides of the discontinuity impossible to read as one recording.
    RecordCaptureResume {
        device_id: String,
        at_ms: i64,
        stream_id: String,
    },
    /// Answered by exactly one [`CaptureGaps`].
    ReadCaptureGaps,
    /// The speech profiles this account has, newest state first. Answered by
    /// exactly one [`SpeechProfileUpdate`].
    ListSpeechProfiles {
        scope: SpeechProfileScope,
    },
    /// Give a profile the name the user typed, or clear it with `None`. The
    /// hub never invents a name, so this is the only way one is set.
    RenameSpeechProfile {
        scope: SpeechProfileScope,
        profile_id: String,
        display_name: Option<String>,
    },
    /// Fold `source_profile_id` into `target_profile_id`: voiceprints and
    /// session links move, the source is tombstoned.
    MergeSpeechProfiles {
        scope: SpeechProfileScope,
        target_profile_id: String,
        source_profile_id: String,
    },
    /// Forget a person: every voiceprint is deleted, not merely hidden.
    ForgetSpeechProfile {
        scope: SpeechProfileScope,
        profile_id: String,
    },
    /// Stop (or resume) learning new voiceprints for one profile. Only the
    /// automatic path is paused; an enrollment the user runs by hand still
    /// works.
    PauseSpeechLearning {
        scope: SpeechProfileScope,
        profile_id: String,
        paused: bool,
    },
    /// Point the live meeting path at this account's voiceprints, or turn it
    /// off with `None`. Unanswered: it configures, it does not query.
    ///
    /// Nothing else tells the hub which account is signed in or where its data
    /// directory is, and the hub must not guess either, so voice recognition
    /// stays off until this arrives.
    ConfigureSpeechProfiles {
        scope: Option<SpeechProfileScope>,
    },
}

/// Which account's voiceprints a speech-profile command addresses, and where
/// they live.
///
/// The client resolves `directory` from the same `~/.omi` convention every
/// other local store uses; the hub never invents a location for someone's
/// voiceprints. `uid` scopes every row, so a shared machine cannot show one
/// account the other's people.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub struct SpeechProfileScope {
    pub directory: String,
    pub uid: String,
}

/// The Rewind engine's request surface.
///
/// The three capture variants are a strict sequence, and the sequence is the
/// frame-economy invariant: `Tick` carries only what can be sampled without
/// reading a pixel, `PreviewTaken` carries 72 bytes of luminance while the
/// full frame is still held unencoded on the native side, and `FrameEncoded`
/// is only ever sent in answer to [`RewindDirective::Encode`], which the
/// engine only issues once the similarity gate has said keep. Each carries the
/// `step_id` the engine handed out, so a frame can never skip the gate.
#[derive(Clone, Deserialize, SignalPiece)]
pub enum RewindRequest {
    /// Opens (or reopens) the timeline under `root`, which the client resolves
    /// from the same `~/.omi` convention every other local store uses. The
    /// hub never invents this path.
    Open {
        root: String,
    },
    /// A scheduled policy evaluation. Sampled before any pixels are read.
    Tick {
        context: RewindWindowContext,
        display: RewindDisplay,
        idle_ms: i64,
        locked: bool,
        permitted: bool,
    },
    /// The luminance preview for `step_id`. Empty means the capture failed.
    PreviewTaken {
        step_id: u64,
        luma: Vec<u8>,
    },
    /// The encoded frame for `step_id`. Empty bytes mean the held frame was
    /// gone by the time the encoder ran. This is the only variant that carries
    /// pixels, and the client may only send it in answer to
    /// [`RewindDirective::Encode`].
    FrameEncoded {
        step_id: u64,
        jpeg: Vec<u8>,
        /// Text read off this frame on-device, when recognition was asked for.
        ocr_text: Option<String>,
    },
    SetEnabled {
        enabled: bool,
    },
    SetPaused {
        paused: bool,
    },
    SetRetention {
        max_age_days: i64,
        max_bytes: u64,
    },
    /// The three privacy switches. The exclusion list is deliberately not
    /// settable wholesale — it is only ever added to or removed from one id at
    /// a time, so no single message can wipe the default denials.
    SetPrivacyFlags {
        skip_private_browsing: bool,
        record_window_titles: bool,
        read_on_screen_text: bool,
    },
    DenyBundleId {
        bundle_id: String,
    },
    AllowBundleId {
        bundle_id: String,
    },
    ListFrames {
        limit: u32,
    },
    Search {
        query: String,
        limit: u32,
    },
    DeleteAll,
    /// "Forget the last hour": everything captured within `window_ms` of now.
    DeleteLast {
        window_ms: i64,
    },
    DeleteFrame {
        relative_path: String,
    },
    Status,
}

/// A window title names documents, tabs and correspondents, so it is the one
/// field that never reaches a log.
impl std::fmt::Debug for RewindRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Open { .. } => formatter.write_str("Open"),
            Self::Tick { context, .. } => formatter
                .debug_struct("Tick")
                .field("context", context)
                .finish(),
            Self::PreviewTaken { step_id, luma } => formatter
                .debug_struct("PreviewTaken")
                .field("step_id", step_id)
                .field("luma", &luma.len())
                .finish(),
            Self::FrameEncoded {
                step_id,
                jpeg,
                ocr_text,
            } => formatter
                .debug_struct("FrameEncoded")
                .field("step_id", step_id)
                .field("jpeg", &jpeg.len())
                .field("ocr_text", &ocr_text.as_ref().map(|_| "[redacted]"))
                .finish(),
            Self::SetEnabled { enabled } => formatter
                .debug_struct("SetEnabled")
                .field("enabled", enabled)
                .finish(),
            Self::SetPaused { paused } => formatter
                .debug_struct("SetPaused")
                .field("paused", paused)
                .finish(),
            Self::SetRetention { .. } => formatter.write_str("SetRetention"),
            Self::SetPrivacyFlags { .. } => formatter.write_str("SetPrivacyFlags"),
            Self::DenyBundleId { bundle_id } | Self::AllowBundleId { bundle_id } => formatter
                .debug_struct("BundleIdRule")
                .field("bundle_id", bundle_id)
                .finish(),
            Self::ListFrames { limit } => formatter
                .debug_struct("ListFrames")
                .field("limit", limit)
                .finish(),
            Self::Search { .. } => formatter.write_str("Search"),
            Self::DeleteAll => formatter.write_str("DeleteAll"),
            Self::DeleteLast { window_ms } => formatter
                .debug_struct("DeleteLast")
                .field("window_ms", window_ms)
                .finish(),
            Self::DeleteFrame { .. } => formatter.write_str("DeleteFrame"),
            Self::Status => formatter.write_str("Status"),
        }
    }
}

/// What Omi knows about the screen at the instant the policy is asked whether
/// to capture. Deliberately tiny: the frontmost app, its bundle id, and the
/// window title. Nothing here is stored unless a frame is stored.
#[derive(Clone, Deserialize, SignalPiece)]
pub struct RewindWindowContext {
    pub bundle_id: Option<String>,
    pub app_name: Option<String>,
    pub window_title: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, SignalPiece)]
pub struct RewindDisplay {
    pub id: String,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub width: u32,
    pub height: u32,
    pub scale: f32,
    pub primary: bool,
}

impl std::fmt::Debug for RewindWindowContext {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RewindWindowContext")
            .field("bundle_id", &self.bundle_id)
            .field("app_name", &self.app_name)
            .field(
                "window_title",
                &self.window_title.as_ref().map(|_| "[redacted]"),
            )
            .finish()
    }
}

/// One current, flattened to the few facts the brief may state. Mirrors
/// [`crate::brief::BriefItem`], which is the shape the prompt is built from.
#[derive(Clone, Deserialize, SignalPiece)]
pub struct BriefItem {
    pub title: String,
    pub when: String,
    pub detail: String,
    pub next_step: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum MessageOrigin {
    Chat,
    Overlay,
    /// Telegram DM or group thread routed through the channel inbox.
    ChannelTelegram,
    /// iMessage/SMS (stored channel id `imessage`, Sendblue provider).
    ChannelImessage,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum AssistantProvider {
    OpenAi,
    Anthropic,
    Gemini,
    Xai,
    Compatible,
    Worker,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum CaptureSource {
    Screen,
    Clipboard,
    Accessibility,
    OmiDevice,
    Chat,
    Workspace,
    AppleNotes,
    AppleMail,
    AppleCalendar,
    AppleReminders,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, SignalPiece)]
pub enum ApprovalDecision {
    ApproveOnce,
    Reject,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize, SignalPiece)]
pub enum ComputerUseAction {
    Invoke {
        target_name: String,
        background_only: bool,
    },
    SetValue {
        target_name: String,
        value: String,
        background_only: bool,
    },
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize, SignalPiece)]
pub struct ComputerUseAuthorityReceipt {
    pub version: String,
    pub execution_id: String,
    pub receipt_id: String,
    pub receipt_token: String,
    pub firebase_token: String,
    pub subject: String,
    pub policy_generation: u64,
    pub operation_id: String,
    pub proposal_id: String,
    pub action_hash: String,
    pub risk: ActionRisk,
    pub issued_at_ms: i64,
    pub expires_at_ms: i64,
}

impl std::fmt::Debug for ComputerUseAuthorityReceipt {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ComputerUseAuthorityReceipt")
            .field("version", &self.version)
            .field("execution_id", &self.execution_id)
            .field("receipt_id", &self.receipt_id)
            .field("receipt_token", &"[redacted]")
            .field("firebase_token", &"[redacted]")
            .field("subject", &"[redacted]")
            .field("policy_generation", &self.policy_generation)
            .field("operation_id", &self.operation_id)
            .field("proposal_id", &self.proposal_id)
            .field("action_hash", &self.action_hash)
            .field("risk", &self.risk)
            .field("issued_at_ms", &self.issued_at_ms)
            .field("expires_at_ms", &self.expires_at_ms)
            .finish()
    }
}

impl std::fmt::Debug for ComputerUseAction {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Invoke {
                background_only, ..
            } => formatter
                .debug_struct("Invoke")
                .field("target_name", &"[redacted]")
                .field("background_only", background_only)
                .finish(),
            Self::SetValue {
                background_only, ..
            } => formatter
                .debug_struct("SetValue")
                .field("target_name", &"[redacted]")
                .field("value", &"[redacted]")
                .field("background_only", background_only)
                .finish(),
        }
    }
}

#[derive(Debug, Deserialize, DartSignalBinary)]
pub struct AudioChunk {
    pub request_id: String,
    pub sequence: u64,
    pub sample_rate_hz: u32,
    pub channels: u8,
    pub encoding: AudioEncoding,
    pub end_of_stream: bool,
    #[serde(skip)]
    pub bytes: Vec<u8>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum AudioEncoding {
    PcmS16Le,
    PcmU8,
    Opus,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum TranscriptionRoute {
    Managed,
    Byok,
    Local,
}

#[derive(Clone, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum TranscriptionAuth {
    Managed {
        endpoint: String,
        firebase_token: String,
    },
    Byok {
        endpoint: String,
        api_key: String,
    },
    Local,
}

impl TranscriptionAuth {
    pub fn route(&self) -> TranscriptionRoute {
        match self {
            Self::Managed { .. } => TranscriptionRoute::Managed,
            Self::Byok { .. } => TranscriptionRoute::Byok,
            Self::Local => TranscriptionRoute::Local,
        }
    }
}

#[derive(Debug, Serialize, RustSignal)]
pub enum NativeEvent {
    TranscriptDelta(TranscriptDelta),
    TranscriptionStatus(TranscriptionStatus),
    TranscriptionStopAcknowledged(TranscriptionStopAcknowledgement),
    TranscriptGap(TranscriptGap),
    AssistantDelta(AssistantDelta),
    ActionProposal(ActionProposal),
    ApprovalDecisionAcknowledged(ApprovalDecisionAcknowledgement),
    ToolProgress(ToolProgress),
    Error(NativeError),
    RuntimeStatus(RuntimeStatus),
    MemoryCaptured(MemoryCaptured),
    MemorySearchResults(MemorySearchResults),
    MemoryCorrected(MemoryCorrected),
    MemorySourceDeleted(MemorySourceDeleted),
    MemoryExported(MemoryExported),
    MemoryApplied(MemoryApplied),
    MemoryItems(MemoryItems),
    OnboardingScanCompleted(OnboardingScanCompleted),
    LiveVoiceState(LiveVoiceState),
    LiveVoiceTranscript(LiveVoiceTranscript),
    LiveVoiceAudio(LiveVoiceAudio),
    MeetingStateChanged(MeetingStateChanged),
    MeetingInsight(MeetingInsight),
    MeetingTranscriptTurn(MeetingTranscriptTurn),
    MeetingCompleted(MeetingCompleted),
    BriefComposed(BriefComposed),
    CallState(CallState),
    DevAssistantResolved(DevAssistant),
    AudioGateStats(AudioGateStats),
    Rewind(RewindUpdate),
    CaptureWalOpened(CaptureWalOpened),
    CaptureSegmentBegun(CaptureSegmentBegun),
    CaptureAudioAppended(CaptureAudioAppended),
    CaptureWalState(CaptureWalState),
    CaptureGaps(CaptureGaps),
    SpeechProfiles(SpeechProfileUpdate),
    SpeechProfileMatched(SpeechProfileMatched),
}

/// The answer to exactly one speech-profile command.
#[derive(Debug, Serialize, SignalPiece)]
pub struct SpeechProfileUpdate {
    pub request_id: String,
    pub payload: SpeechProfilePayload,
}

#[derive(Debug, Serialize, SignalPiece)]
pub enum SpeechProfilePayload {
    /// The account's live profiles after whatever the command changed.
    Profiles { profiles: Vec<SpeechProfileRecord> },
    /// The store could not be opened, or the profile named does not exist.
    /// Never an error event: the settings screen simply has nothing to show.
    Unavailable { detail: String },
}

/// One profile, as the settings list needs it.
///
/// Voiceprints are deliberately absent. They are the one thing in this module
/// that must never leave the device, and a signal is a bridge to code the hub
/// does not control — so the count is published and the vectors are not.
#[derive(Debug, Serialize, SignalPiece)]
pub struct SpeechProfileRecord {
    pub id: String,
    /// `owner` or `other`.
    pub kind: String,
    pub display_name: Option<String>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
    pub learning_paused: bool,
    pub embedding_count: i64,
}

/// A voiceprint match against a live meeting's diarized voice.
///
/// `distance` and `runner_up` travel with it because "who is this?" and "how
/// sure are we?" are the same question to anyone reading a name on a
/// transcript, and the margin between the two is what the acceptance test
/// actually turned on.
#[derive(Debug, Serialize, SignalPiece)]
pub struct SpeechProfileMatched {
    pub profile_id: String,
    pub display_name: Option<String>,
    pub meeting_id: String,
    pub diarized_key: i64,
    pub distance: f32,
    pub runner_up: Option<f32>,
}

/// The answer to a [`Command::AppendCaptureAudio`]. Sent once the bytes have
/// been handed to the operating system, or once the write has failed — either
/// way the client may stop holding the frame. `error` never means the frame
/// should be re-sent: the log has already moved past it, and a duplicate
/// append would put the same audio into the segment twice.
#[derive(Debug, Serialize, SignalPiece)]
pub struct CaptureAudioAppended {
    pub request_id: String,
    pub error: Option<String>,
}

/// The answer to a [`Command::OpenCaptureWal`]. `directory` is the log the hub
/// settled on, so the client can show where audio is being kept; `error`
/// carries why there is no log at all, which degrades capture to "live only"
/// rather than stopping it.
#[derive(Debug, Serialize, SignalPiece)]
pub struct CaptureWalOpened {
    pub request_id: String,
    pub directory: Option<String>,
    pub error: Option<String>,
}

/// The answer to a [`Command::BeginCaptureSegment`]. `segment_id` is the
/// client-supplied idempotency key the transcription endpoint deduplicates on;
/// it is `None` exactly when `error` explains why no segment was opened.
#[derive(Debug, Serialize, SignalPiece)]
pub struct CaptureSegmentBegun {
    pub request_id: String,
    pub segment_id: Option<String>,
    pub error: Option<String>,
}

/// What the write-ahead log is holding, and what the last pass did with it.
///
/// `pending_segments` is what the UI surfaces as "N clips waiting to upload":
/// durability the user cannot see is durability they will not trust.
/// `last_error` is the reason the pass stopped early, and is not fatal — the
/// segments it left behind are still on disk.
#[derive(Debug, Serialize, SignalPiece)]
pub struct CaptureWalState {
    pub request_id: String,
    pub pending_segments: u64,
    pub pending_bytes: u64,
    pub oldest_started_at_ms: Option<i64>,
    pub uploaded: u64,
    pub last_error: Option<String>,
}

/// One recorded discontinuity in capture. The two stream ids are always
/// different: a restart opens a new stream rather than continuing the old one,
/// which is what makes the audio either side impossible to re-splice.
#[derive(Clone, Debug, Serialize, SignalPiece)]
pub struct CaptureGap {
    pub device_id: String,
    pub reason: String,
    pub ended_at_ms: i64,
    pub ended_stream_id: String,
    pub resumed_at_ms: Option<i64>,
    pub resumed_stream_id: Option<String>,
}

/// The answer to a [`Command::ReadCaptureGaps`], oldest first.
#[derive(Debug, Serialize, SignalPiece)]
pub struct CaptureGaps {
    pub request_id: String,
    pub gaps: Vec<CaptureGap>,
}

/// What the voice-activity gate kept off the metered transcription socket for
/// one audio stream, so the saving can be seen rather than assumed. It is a
/// local signal to the client and goes nowhere else.
///
/// `gateable` is `false` for an encoding whose loudness cannot be read without
/// decoding it — Opus, today — and such a stream is passed through in full
/// rather than gated on a guess. Reading `suppressed_bytes` as a saving is only
/// meaningful when `enabled` and `gateable` are both true.
#[derive(Debug, Serialize, SignalPiece)]
pub struct AudioGateStats {
    pub audio_stream_id: String,
    pub enabled: bool,
    pub gateable: bool,
    pub forwarded_bytes: u64,
    pub suppressed_bytes: u64,
    pub forwarded_ms: u64,
    pub suppressed_ms: u64,
    pub provider_bytes: u64,
    pub provider_ms: u64,
    pub tempo_milli: u32,
}

/// The answer to exactly one [`RewindRequest`].
#[derive(Debug, Serialize, SignalPiece)]
pub struct RewindUpdate {
    pub request_id: String,
    pub payload: RewindPayload,
}

#[derive(Debug, Serialize, SignalPiece)]
pub enum RewindPayload {
    /// The one thing the client may do next for `step_id`.
    Directive {
        step_id: u64,
        directive: RewindDirective,
    },
    /// The engine's published state, after whatever the request changed.
    Status(RewindStatus),
    /// The answer to a listing or a search, newest first.
    Frames { frames: Vec<RewindFrameRecord> },
    /// Rewind is not built into this platform's hub, or the timeline has not
    /// been opened yet. Never an error: the client simply has nothing to show.
    Unavailable { detail: String },
}

/// The single instruction the capture surface is allowed to carry out.
///
/// `Preview` is the only one that reads pixels, and it is never issued for a
/// screen the privacy rules refused. `Encode` is never issued for a frame the
/// similarity gate rejected. Between them, no frame is ever encoded and then
/// thrown away.
#[derive(Debug, Serialize, SignalPiece)]
pub enum RewindDirective {
    /// Capture a preview and hold the frame natively.
    Preview,
    /// Nothing is held; do nothing.
    Idle { reason: RewindSkipReason },
    /// Encode the held frame, recognizing text in the same pass when asked.
    Encode { recognize_text: bool },
    /// Drop the held frame without encoding it.
    Discard { reason: RewindSkipReason },
    /// The frame is on disk.
    Stored,
}

/// Why a frame was not taken. Carried into the UI so a user who wonders "is it
/// recording right now?" gets a truthful answer instead of a spinner.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, SignalPiece)]
pub enum RewindSkipReason {
    DeniedApp,
    PrivateWindow,
    ScreenLocked,
    Paused,
    Idle,
    Heartbeat,
    MinimumInterval,
    Busy,
    Unchanged,
    NoPermission,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct RewindStatus {
    pub enabled: bool,
    pub paused: bool,
    /// True only when a frame could actually be taken right now: enabled, not
    /// paused, permission granted, screen unlocked.
    pub recording: bool,
    pub retention_max_age_days: i64,
    pub retention_max_bytes: u64,
    /// The bounds the settings dropdown offers, already labelled. Which bounds
    /// a user may pick is a policy decision about how much screen history
    /// exists at all, so the list is the engine's to state.
    pub retention_options: Vec<RewindRetentionOption>,
    pub denied_bundle_ids: Vec<String>,
    pub skip_private_browsing: bool,
    pub record_window_titles: bool,
    pub read_on_screen_text: bool,
    pub last_skip_reason: Option<RewindSkipReason>,
    pub last_capture_at_ms: Option<i64>,
    pub captured_this_session: u64,
    pub frame_count: u64,
    pub total_bytes: u64,
    pub oldest_capture_at_ms: Option<i64>,
    pub permitted: bool,
    pub locked: bool,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct RewindRetentionOption {
    pub max_age_days: i64,
    pub max_bytes: u64,
    pub label: String,
}

/// One stored screenshot, as the timeline renders it.
#[derive(Serialize, SignalPiece)]
pub struct RewindFrameRecord {
    pub captured_at_ms: i64,
    pub relative_path: String,
    /// The absolute path on this machine, so the timeline can draw the image
    /// without re-deriving the store's layout.
    pub absolute_path: String,
    pub bytes: u64,
    pub hash: String,
    pub display: RewindDisplay,
    pub app_name: Option<String>,
    pub bundle_id: Option<String>,
    pub window_title: Option<String>,
    pub ocr_text: Option<String>,
}

/// A frame row is a description of what was on someone's screen, so the two
/// fields that quote it are never printed.
impl std::fmt::Debug for RewindFrameRecord {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RewindFrameRecord")
            .field("captured_at_ms", &self.captured_at_ms)
            .field("relative_path", &self.relative_path)
            .field("bytes", &self.bytes)
            .field("hash", &self.hash)
            .field("app_name", &self.app_name)
            .field("bundle_id", &self.bundle_id)
            .field(
                "window_title",
                &self.window_title.as_ref().map(|_| "[redacted]"),
            )
            .field("ocr_text", &self.ocr_text.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

/// The answer to a [`Command::ResolveDevAssistant`]. `credential` is the
/// developer Gemini key when one was found — the client needs the value
/// itself to open a Gemini Live session — and `None` otherwise, in which case
/// `missing_key_hint` names every place a key may be put.
#[derive(Serialize, SignalPiece)]
pub struct DevAssistant {
    pub request_id: String,
    pub credential: Option<String>,
    pub live_model: String,
    pub missing_key_hint: String,
}

impl std::fmt::Debug for DevAssistant {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("DevAssistant")
            .field("request_id", &self.request_id)
            .field(
                "credential",
                &self.credential.as_ref().map(|_| "[redacted]"),
            )
            .field("live_model", &self.live_model)
            .finish()
    }
}

/// The answer to a [`Command::ComposeBrief`]. `crepus` carries a document the
/// renderer has already been checked to accept, or `None` when nothing was
/// composed — no generator, a model failure, a timeout, a cancellation, or a
/// document the renderer would refuse. `None` is not an error and never
/// raises one: the client's hand-built brief is the answer then.
#[derive(Serialize, SignalPiece)]
pub struct BriefComposed {
    pub request_id: String,
    pub crepus: Option<String>,
}

impl std::fmt::Debug for BriefComposed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("BriefComposed")
            .field("request_id", &self.request_id)
            .field("crepus", &self.crepus.as_ref().map(|_| "[redacted]"))
            .finish()
    }
}

/// Where a [`Command::JoinCall`] has got to. Exactly one terminal phase
/// (`Ended` or `Failed`) is sent per call.
#[derive(Debug, Serialize, SignalPiece)]
pub struct CallState {
    pub request_id: String,
    pub state: CallPhase,
    pub detail: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, SignalPiece)]
pub enum CallPhase {
    Joining,
    Joined,
    Ended,
    Failed,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MeetingStateChanged {
    pub active: bool,
    pub suggested_title: Option<String>,
}

#[derive(Serialize, SignalPiece)]
pub struct MeetingInsight {
    pub kind: String,
    pub text: String,
    pub source_text: String,
    /// Which side of the call the utterance came from: `You`, `Them`, or empty
    /// when the two capture tracks could not tell them apart.
    pub speaker: String,
}

impl std::fmt::Debug for MeetingInsight {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MeetingInsight")
            .field("kind", &self.kind)
            .field("text", &self.text)
            .field("source_text", &"[redacted]")
            .field("speaker", &self.speaker)
            .finish()
    }
}

/// A finalized transcript segment attributed to a side of the call.
///
/// The assist panel renders these instead of raw transcript deltas so the
/// live rolling transcript shows who is speaking.
#[derive(Serialize, SignalPiece)]
pub struct MeetingTranscriptTurn {
    /// The label as it was known when the turn was spoken. A voiceprint match
    /// lands later, so this is provisional whenever [`diarized_key`] is set:
    /// the reader is expected to prefer whatever [`SpeechProfileMatched`] has
    /// since said about that key.
    ///
    /// [`diarized_key`]: Self::diarized_key
    pub speaker: String,

    /// The provider's diarized voice this turn belongs to, when it gave one.
    ///
    /// Identity is a property of the voice, not of the sentence, so this — not
    /// a per-turn id — is what a late match is keyed on. One
    /// [`SpeechProfileMatched`] therefore names every turn that voice has
    /// already spoken as well as the ones it has yet to.
    pub diarized_key: Option<i64>,

    pub text: String,
    pub occurred_at_ms: i64,
}

impl std::fmt::Debug for MeetingTranscriptTurn {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MeetingTranscriptTurn")
            .field("speaker", &self.speaker)
            .field("text", &"[redacted]")
            .field("occurred_at_ms", &self.occurred_at_ms)
            .finish()
    }
}

#[derive(Serialize, SignalPiece)]
pub struct MeetingCompleted {
    pub title: String,
    pub summary: String,
    pub meeting_type: String,
    pub raw_transcript: String,
    pub actions: Vec<String>,
    pub started_at_ms: i64,
    pub ended_at_ms: i64,
    pub participants: Vec<String>,
    pub key_points: Vec<String>,
    pub decisions: Vec<String>,
    pub note_markdown: String,
    pub metadata_json: String,
}

impl std::fmt::Debug for MeetingCompleted {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("MeetingCompleted")
            .field("title", &self.title)
            .field("summary", &"[redacted]")
            .field("meeting_type", &self.meeting_type)
            .field("raw_transcript", &"[redacted]")
            .field("actions", &self.actions.len())
            .field("started_at_ms", &self.started_at_ms)
            .field("ended_at_ms", &self.ended_at_ms)
            .field("participants", &self.participants.len())
            .field("key_points", &self.key_points.len())
            .field("decisions", &self.decisions.len())
            .field("note_markdown", &"[redacted]")
            .field("metadata_json", &"[redacted]")
            .finish()
    }
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct LiveVoiceState {
    pub live_stream_id: String,
    pub state: LiveVoicePhase,
    pub detail: Option<String>,
    pub resumption_handle: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, SignalPiece)]
pub enum LiveVoicePhase {
    Started,
    Interrupted,
    Ended,
    Failed,
}

#[derive(Serialize, SignalPiece)]
pub struct LiveVoiceTranscript {
    pub live_stream_id: String,
    pub text: String,
    pub final_segment: bool,
    pub assistant: bool,
}

impl std::fmt::Debug for LiveVoiceTranscript {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LiveVoiceTranscript")
            .field("live_stream_id", &self.live_stream_id)
            .field("text", &"[redacted]")
            .field("final_segment", &self.final_segment)
            .field("assistant", &self.assistant)
            .finish()
    }
}

#[derive(Serialize, SignalPiece)]
pub struct LiveVoiceAudio {
    pub live_stream_id: String,
    pub sequence: u64,
    pub sample_rate_hz: u32,
    pub bytes: Vec<u8>,
}

impl std::fmt::Debug for LiveVoiceAudio {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LiveVoiceAudio")
            .field("live_stream_id", &self.live_stream_id)
            .field("sequence", &self.sequence)
            .field("sample_rate_hz", &self.sample_rate_hz)
            .field("bytes", &self.bytes.len())
            .finish()
    }
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct TranscriptionStopAcknowledgement {
    pub request_id: String,
    pub audio_stream_id: String,
    pub accepted: bool,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct ApprovalDecisionAcknowledgement {
    pub request_id: String,
    pub proposal_id: String,
    pub decision: ApprovalDecision,
    pub accepted: bool,
    pub execution_pending: bool,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct TranscriptDelta {
    pub request_id: String,
    pub audio_stream_id: String,
    pub segment_id: String,
    pub segment_sequence: u64,
    pub stt_epoch: u32,
    pub device_id: String,
    pub provider: String,
    pub start_ms: i64,
    pub end_ms: i64,
    pub occurred_at_ms: i64,
    pub text: String,
    pub final_segment: bool,
    /// The provider's diarization index for this segment, when the provider
    /// was asked for diarization and returned one.
    pub speaker: Option<u32>,
    /// The provider channel the segment came from, when the provider reports
    /// one. Always `0` on the mono streams the hub sends today.
    pub channel_index: Option<u32>,
    pub language: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub struct TranscriptLocator {
    pub device_id: String,
    pub provider: String,
    pub stream_id: String,
    pub segment_id: String,
    pub start_ms: i64,
    pub end_ms: i64,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct TranscriptionStatus {
    pub request_id: String,
    pub audio_stream_id: String,
    pub state: TranscriptionState,
    pub stt_epoch: u32,
}

#[derive(Clone, Copy, Debug, Serialize, SignalPiece)]
pub enum TranscriptionState {
    Started,
    Reconnecting,
    Draining,
    Finished,
    Cancelled,
    Failed,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct TranscriptGap {
    pub request_id: String,
    pub audio_stream_id: String,
    pub stt_epoch: u32,
    pub start_ms: i64,
    pub end_ms: i64,
    pub reason: String,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct AssistantDelta {
    pub request_id: String,
    pub text: String,
    pub final_segment: bool,
}

#[derive(Clone, Serialize, SignalPiece)]
pub struct ActionProposal {
    pub proposal_id: String,
    pub request_id: String,
    pub title: String,
    pub summary: String,
    pub risk: ActionRisk,
    pub computer_action: Option<ComputerUseAction>,
    pub operation_id: Option<String>,
    pub action_hash: Option<String>,
    pub target_provenance: Option<ComputerUseTargetProvenance>,
    pub expires_at_ms: Option<i64>,
}

#[derive(Clone, Deserialize, Eq, PartialEq, Serialize, SignalPiece)]
pub struct ComputerUseTargetProvenance {
    pub process_id: u32,
    pub process_generation: String,
    pub window_id: String,
    pub role: String,
    pub observation_generation: u64,
}

impl std::fmt::Debug for ComputerUseTargetProvenance {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ComputerUseTargetProvenance")
            .field("process_id", &"[redacted]")
            .field("process_generation", &"[redacted]")
            .field("window_id", &"[redacted]")
            .field("role", &self.role)
            .field("observation_generation", &self.observation_generation)
            .finish()
    }
}

impl std::fmt::Debug for ActionProposal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ActionProposal")
            .field("proposal_id", &self.proposal_id)
            .field("request_id", &self.request_id)
            .field("title", &self.title)
            .field("summary", &"[redacted]")
            .field("risk", &self.risk)
            .field("computer_action", &self.computer_action)
            .field("operation_id", &self.operation_id)
            .field("action_hash", &self.action_hash)
            .field("target_provenance", &self.target_provenance)
            .field("expires_at_ms", &self.expires_at_ms)
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize, SignalPiece)]
pub enum ActionRisk {
    Reversible,
    External,
    Destructive,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct ToolProgress {
    pub request_id: String,
    pub tool: String,
    pub status: ToolStatus,
    pub detail: Option<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub enum ToolStatus {
    Queued,
    Running,
    WaitingForApproval,
    Complete,
    Failed,
    Cancelled,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct NativeError {
    pub request_id: Option<String>,
    pub code: String,
    pub message: String,
    pub retryable: bool,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct RuntimeStatus {
    pub phase: RuntimePhase,
    pub detail: Option<String>,
    pub computer_use_available: bool,
    pub computer_use_capabilities: Option<ComputerUseCapabilities>,
    pub local_ai_available: bool,
    pub memory_available: bool,
    pub agent_harness_available: bool,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct ComputerUseCapabilities {
    pub platform: String,
    pub backend: String,
    pub session_isolation: ComputerUseSessionIsolation,
    pub permissions: Vec<ComputerUsePermission>,
    pub actions: Vec<ComputerUseActionCapability>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, SignalPiece)]
pub enum ComputerUseSessionIsolation {
    SharedDesktop,
    HostIsolated,
    Unknown,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct ComputerUsePermission {
    pub name: String,
    pub granted: bool,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct ComputerUseActionCapability {
    pub name: String,
    pub available: bool,
    pub delivery_route: ComputerUseDeliveryRoute,
    pub background_support: ComputerUseBackgroundSupport,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, SignalPiece)]
pub enum ComputerUseDeliveryRoute {
    TargetAddressed,
    PerProcessEvent,
    Pointer,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, SignalPiece)]
pub enum ComputerUseBackgroundSupport {
    Guarded,
    HostIsolatedOnly,
    Unavailable,
    Unknown,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryCaptured {
    pub request_id: String,
    pub source_id: String,
    pub evidence_id: String,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemorySearchResults {
    pub request_id: String,
    pub query: String,
    pub items: Vec<MemorySearchItem>,
    pub gaps: Vec<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemorySearchItem {
    pub kind: String,
    pub id: String,
    pub excerpt: String,
    pub relevance_basis_points: u16,
    pub evidence_ids: Vec<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryCorrected {
    pub request_id: String,
    pub source_id: String,
    pub evidence_id: String,
    pub claim_id: String,
    pub superseded_claim_id: String,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemorySourceDeleted {
    pub request_id: String,
    pub source_id: String,
    pub evidence_count: u64,
    pub claim_count: u64,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryExported {
    pub request_id: String,
    pub export_format: u32,
    pub database_schema_version: i64,
    pub high_water_mark: i64,
    pub next_after_commit: i64,
    pub next_after_event_index: i64,
    pub complete: bool,
    pub commits: Vec<MemoryExportCommit>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryExportCommit {
    pub sequence: i64,
    pub recorded_at_ms: i64,
    pub event_count: i64,
    pub first_event_index: i64,
    pub records_json: Vec<String>,
}

/// One cloud memory-log entry packaged as a single-record zkr export commit.
#[derive(Clone, Debug, Deserialize, SignalPiece)]
pub struct MemoryApplyCommit {
    pub sequence: i64,
    pub recorded_at_ms: i64,
    pub record_kind: String,
    pub record_json: String,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryApplied {
    pub request_id: String,
    pub commits_applied: u64,
    pub commits_skipped: u64,
    pub records_applied: u64,
    pub records_skipped: u64,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryItems {
    pub request_id: String,
    pub items: Vec<MemoryItem>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MemoryItem {
    pub kind: String,
    pub id: String,
    pub title: String,
    pub body: String,
    pub recorded_at_ms: i64,
    pub evidence_ids: Vec<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct OnboardingScanCompleted {
    pub request_id: String,
    pub sources: Vec<OnboardingScanSource>,
    pub summary: Option<String>,
    pub detected_name: Option<String>,
    pub detected_languages: Vec<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct OnboardingScanSource {
    pub source: String,
    pub state: OnboardingScanState,
    pub items_found: u64,
    pub detail: String,
    pub memory_source_id: Option<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub enum OnboardingScanState {
    Complete,
    Denied,
    Unavailable,
    Failed,
}

#[derive(Debug, Serialize, SignalPiece)]
pub enum RuntimePhase {
    Starting,
    Ready,
    Busy,
    Degraded,
    Stopping,
}

#[derive(Debug, PartialEq, Eq)]
pub enum ValidationError {
    EmptyRequestId,
    EmptyAudio,
    AudioChunkTooLarge,
    InvalidSampleRate,
    InvalidChannels,
}

impl ClientCommand {
    pub async fn listen(sender: mpsc::Sender<Self>) {
        let receiver = Self::get_dart_signal_receiver();
        while let Some(pack) = receiver.recv().await {
            if pack.message.request_id.trim().is_empty() {
                NativeEvent::Error(NativeError {
                    request_id: None,
                    code: "invalid_request".into(),
                    message: "request_id must not be empty".into(),
                    retryable: false,
                })
                .send();
            } else if sender.send(pack.message).await.is_err() {
                break;
            }
        }
    }
}

impl AudioChunk {
    pub async fn listen(sender: mpsc::Sender<Self>) {
        let receiver = Self::get_dart_signal_receiver();
        while let Some(pack) = receiver.recv().await {
            let mut chunk = pack.message;
            chunk.bytes = pack.binary;
            if let Err(error) = chunk.validate() {
                NativeEvent::Error(NativeError {
                    request_id: Some(chunk.request_id),
                    code: "invalid_audio_chunk".into(),
                    message: error.message().into(),
                    retryable: false,
                })
                .send();
            } else if sender.send(chunk).await.is_err() {
                break;
            }
        }
    }

    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.request_id.trim().is_empty() {
            return Err(ValidationError::EmptyRequestId);
        }
        if self.bytes.is_empty() && !self.end_of_stream {
            return Err(ValidationError::EmptyAudio);
        }
        if self.bytes.len() > MAX_AUDIO_CHUNK_BYTES {
            return Err(ValidationError::AudioChunkTooLarge);
        }
        if !(8_000..=96_000).contains(&self.sample_rate_hz) {
            return Err(ValidationError::InvalidSampleRate);
        }
        if !(1..=2).contains(&self.channels) {
            return Err(ValidationError::InvalidChannels);
        }
        Ok(())
    }
}

impl NativeEvent {
    pub(crate) fn send(self) {
        #[cfg(test)]
        {
            test_events::record(self);
        }
        #[cfg(not(test))]
        self.send_signal_to_dart();
    }
}

/// Unit tests have no Dart end to receive signals, so `send` diverts them into
/// a per-thread log instead. The log is per-thread because libtest gives each
/// test its own thread, which keeps concurrently running tests from seeing one
/// another's events.
#[cfg(test)]
pub(crate) mod test_events {
    use super::NativeEvent;
    use std::cell::RefCell;

    thread_local! {
        static EVENTS: RefCell<Vec<NativeEvent>> = const { RefCell::new(Vec::new()) };
    }

    pub(crate) fn record(event: NativeEvent) {
        EVENTS.with(|events| events.borrow_mut().push(event));
    }

    pub(crate) fn take() -> Vec<NativeEvent> {
        EVENTS.with(|events| events.borrow_mut().drain(..).collect())
    }
}

impl ValidationError {
    fn message(&self) -> &'static str {
        match self {
            Self::EmptyRequestId => "request_id must not be empty",
            Self::EmptyAudio => "audio chunk must not be empty",
            Self::AudioChunkTooLarge => "audio chunk exceeds 262144 bytes",
            Self::InvalidSampleRate => "sample rate must be between 8000 and 96000 Hz",
            Self::InvalidChannels => "audio must have one or two channels",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{ActionRisk, ComputerUseAction, ComputerUseAuthorityReceipt};

    #[test]
    fn computer_use_debug_redacts_target_and_value() {
        let debug = format!(
            "{:?}",
            ComputerUseAction::SetValue {
                target_name: "Private field".to_owned(),
                value: "credential-value".to_owned(),
                background_only: false,
            }
        );

        assert!(!debug.contains("Private field"));
        assert!(!debug.contains("credential-value"));
        assert!(debug.contains("[redacted]"));
    }

    #[test]
    fn computer_use_receipt_debug_redacts_credentials_and_subject() {
        let debug = format!(
            "{:?}",
            ComputerUseAuthorityReceipt {
                version: "omi-current-authority-v1".to_owned(),
                execution_id: "execution-1".to_owned(),
                receipt_id: "receipt-1".to_owned(),
                receipt_token: "receipt-secret".to_owned(),
                firebase_token: "firebase-secret".to_owned(),
                subject: "private-user".to_owned(),
                policy_generation: 1,
                operation_id: "operation-1".to_owned(),
                proposal_id: "proposal-1".to_owned(),
                action_hash: "a".repeat(64),
                risk: ActionRisk::Destructive,
                issued_at_ms: 1,
                expires_at_ms: 2,
            }
        );

        assert!(!debug.contains("receipt-secret"));
        assert!(!debug.contains("firebase-secret"));
        assert!(!debug.contains("private-user"));
        assert!(debug.contains("[redacted]"));
    }
}
