use rinf::{DartSignal, DartSignalBinary, RustSignal, SignalPiece};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

pub const MAX_AUDIO_CHUNK_BYTES: usize = 256 * 1024;

#[derive(Debug, Deserialize, DartSignal)]
pub struct ClientCommand {
    pub request_id: String,
    pub command: Command,
}

#[derive(Debug, Deserialize, SignalPiece)]
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
    CaptureEvent {
        ingestion_key: String,
        source: CaptureSource,
        occurred_at_ms: i64,
        text: Option<String>,
        application: Option<String>,
        window_title: Option<String>,
    },
    SearchMemory {
        query: String,
        limit: u32,
    },
    ApprovalDecision {
        proposal_id: String,
        decision: ApprovalDecision,
    },
    DeviceState {
        device_id: String,
        connected: bool,
        battery_percent: Option<u8>,
        firmware_version: Option<String>,
    },
    Cancel,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, SignalPiece)]
pub enum CaptureSource {
    Screen,
    Clipboard,
    Accessibility,
    OmiDevice,
    Chat,
}

#[derive(Debug, Deserialize, SignalPiece)]
pub enum ApprovalDecision {
    ApproveOnce,
    Reject,
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

#[derive(Debug, Serialize, RustSignal)]
pub enum NativeEvent {
    TranscriptDelta(TranscriptDelta),
    AssistantDelta(AssistantDelta),
    CurrentUpdate(CurrentUpdate),
    ActionProposal(ActionProposal),
    ToolProgress(ToolProgress),
    Error(NativeError),
    RuntimeStatus(RuntimeStatus),
    MemoryCaptured(MemoryCaptured),
    MemorySearchResults(MemorySearchResults),
}

#[derive(Debug, Serialize, SignalPiece)]
pub struct TranscriptDelta {
    pub request_id: String,
    pub segment_sequence: u64,
    pub occurred_at_ms: i64,
    pub text: String,
    pub final_segment: bool,
    pub language: Option<String>,
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

#[derive(Debug, Serialize, SignalPiece)]
pub struct ActionProposal {
    pub proposal_id: String,
    pub request_id: String,
    pub title: String,
    pub summary: String,
    pub risk: ActionRisk,
    pub expires_at_ms: Option<i64>,
}

#[derive(Debug, Serialize, SignalPiece)]
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
    pub local_ai_available: bool,
    pub memory_available: bool,
    pub agent_harness_available: bool,
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
