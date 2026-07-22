use rinf::{DartSignal, DartSignalBinary, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub const MAX_AUDIO_CHUNK_BYTES: usize = 256 * 1024;

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
    ClearAssistant,
    StartTranscription {
        audio_stream_id: String,
        device_id: String,
        auth: TranscriptionAuth,
        language: String,
        sample_rate_hz: u32,
        channels: u8,
        encoding: AudioEncoding,
    },
    StopTranscription {
        audio_stream_id: String,
    },
    StartLiveVoice {
        live_stream_id: String,
        ephemeral_token: String,
        model: String,
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
    CurrentUpdate(CurrentUpdate),
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
    MemoryItems(MemoryItems),
    OnboardingScanCompleted(OnboardingScanCompleted),
    LiveVoiceState(LiveVoiceState),
    LiveVoiceTranscript(LiveVoiceTranscript),
    LiveVoiceAudio(LiveVoiceAudio),
    MeetingStateChanged(MeetingStateChanged),
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct MeetingStateChanged {
    pub active: bool,
    pub suggested_title: Option<String>,
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct LiveVoiceState {
    pub live_stream_id: String,
    pub state: LiveVoicePhase,
    pub detail: Option<String>,
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
}

impl std::fmt::Debug for LiveVoiceTranscript {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("LiveVoiceTranscript")
            .field("live_stream_id", &self.live_stream_id)
            .field("text", &"[redacted]")
            .field("final_segment", &self.final_segment)
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

#[derive(Debug, Serialize, SignalPiece)]
pub struct CurrentUpdate {
    pub current_id: String,
    pub title: String,
    pub summary: String,
    pub updated_at_ms: i64,
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
        self.send_signal_to_dart();
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
