use crate::signals::{
    ActionProposal, ActionRisk, ApprovalDecision, ApprovalExecutionAcknowledgement, AssistantDelta,
    AssistantProvider as ProviderKind, AudioChunk, AudioEncoding, CaptureSource, ClientCommand,
    Command, ComputerUseAction, MemoryCaptured, MemoryCorrected, MemoryExportCommit,
    MemoryExported, MemoryItem, MemoryItems, MemorySearchItem, MemorySearchResults,
    MemorySourceDeleted, NativeError, NativeEvent, RuntimePhase, RuntimeStatus, ToolProgress,
    ToolStatus, TranscriptDelta, TranscriptGap, TranscriptLocator, TranscriptionAuth,
    TranscriptionRoute, TranscriptionState, TranscriptionStatus, TranscriptionStopAcknowledgement,
};
use crate::stt::{self, SttConfig, SttHandle};
use futures::StreamExt;
use rs_ai_core::{StreamEvent, ToolChoice, ToolDefinition};
use std::collections::{HashMap, VecDeque, hash_map::Entry};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, mpsc};
use tokio::task::{JoinError, JoinHandle, JoinSet, spawn_blocking};
use tokio_util::sync::CancellationToken;
use url::{Host, Url};
use zkr::{
    ClaimId, CorrectInput, DeleteInput, EXPORT_FORMAT_VERSION, ExportInput, MemoryDb, MemoryRef,
    PersonId, ProfilesInput, RememberInput, ReviewsInput, SearchInput, SourceId, SourceKind,
    TenantId, TranscriptLocator as ZkrTranscriptLocator,
};

const COMMAND_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_COMMANDS: usize = 32;
const COMPLETED_CAPTURE_CAPACITY: usize = 256;
const PENDING_PROPOSAL_CAPACITY: usize = 64;
const TERMINAL_PROPOSAL_CAPACITY: usize = 256;
const PROVIDER_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const PROVIDER_EVENT_TIMEOUT: Duration = Duration::from_secs(45);
const COMPUTER_USE_PROPOSAL_TTL_MS: i64 = 5 * 60 * 1_000;
const MAX_COMPUTER_TYPE_DURATION_MS: u64 = 30_000;
const COMPUTER_CLICK_TOOL: &str = "computer_click";
const COMPUTER_TYPE_TOOL: &str = "computer_type";
const AUDIO_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_RECONNECT_BUFFER_BYTES: usize = 64 * 1024;

struct MemoryContext {
    database: MemoryDb,
    tenant_id: TenantId,
    person_id: PersonId,
}

#[derive(Default)]
struct RuntimeState {
    memory: Option<Arc<StdMutex<MemoryContext>>>,
    configuration_generation: u64,
    authority_uid: Option<String>,
    proposals: ProposalRegistry,
    managed_worker_origin: Option<String>,
}

struct AudioSession {
    start_request_id: String,
    next_sequence: u64,
    accepted_bytes: u64,
    sample_rate_hz: u32,
    channels: u8,
    encoding: crate::signals::AudioEncoding,
    last_seen: Instant,
    device_id: String,
    route: TranscriptionRoute,
    language: String,
    epoch: u32,
    logical_sequence: u64,
    phase: TranscriptionPhase,
    reconnect_buffer: VecDeque<Vec<u8>>,
    reconnect_buffer_bytes: usize,
    provider: Option<SttHandle>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum TranscriptionPhase {
    Streaming,
    Reconnecting,
    Draining,
}

#[allow(dead_code)]
trait LiveSttProvider: Send {
    fn start(&mut self, stream_id: &str) -> Result<(), String>;
    fn send_audio(&mut self, bytes: &[u8]) -> Result<(), String>;
    fn finish(&mut self) -> Result<(), String>;
    fn cancel(&mut self);
}

pub(crate) struct StartTranscription {
    request_id: String,
    audio_stream_id: String,
    device_id: String,
    auth: TranscriptionAuth,
    trusted_worker_origin: Option<String>,
    language: String,
    sample_rate_hz: u32,
    channels: u8,
    encoding: AudioEncoding,
}

struct ProviderTranscript {
    provider: String,
    start_ms: i64,
    end_ms: i64,
    text: String,
    final_segment: bool,
}

pub(crate) enum TranscriptionControl {
    Start(StartTranscription),
    Stop {
        request_id: String,
        stream_id: String,
    },
    Fence,
}

#[derive(Default)]
struct AudioSessions(HashMap<String, AudioSession>);

struct AudioProgress {
    request_id: String,
    status: ToolStatus,
    detail: String,
}

struct AudioAcceptError {
    request_id: String,
    code: &'static str,
    message: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CaptureFingerprint {
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
    transcript_locator: Option<TranscriptLocator>,
}

struct ActiveCommand {
    cancellation: CancellationToken,
    capture: Option<CaptureFingerprint>,
    authority_generation: u64,
}

#[allow(dead_code)]
enum AssistantProviderEvent {
    Delta { text: String, final_segment: bool },
    Proposal(ActionProposal),
}

enum ProviderReceive {
    Event(Result<AssistantProviderEvent, String>),
    Closed,
    Cancelled,
    TimedOut,
}

async fn receive_provider_event(
    events: &mut mpsc::Receiver<Result<AssistantProviderEvent, String>>,
    cancellation: &CancellationToken,
    timeout: Duration,
) -> ProviderReceive {
    tokio::select! {
        () = cancellation.cancelled() => ProviderReceive::Cancelled,
        result = tokio::time::timeout(timeout, events.recv()) => match result {
            Ok(Some(event)) => ProviderReceive::Event(event),
            Ok(None) => ProviderReceive::Closed,
            Err(_) => ProviderReceive::TimedOut,
        },
    }
}

trait AssistantProvider: Send + Sync {
    fn dispatch(
        &self,
        request_id: String,
        text: String,
        cancellation: CancellationToken,
    ) -> mpsc::Receiver<Result<AssistantProviderEvent, String>>;
}

struct UnavailableAssistantProvider {
    reason: String,
}

impl AssistantProvider for UnavailableAssistantProvider {
    fn dispatch(
        &self,
        _request_id: String,
        _text: String,
        _cancellation: CancellationToken,
    ) -> mpsc::Receiver<Result<AssistantProviderEvent, String>> {
        let (sender, receiver) = mpsc::channel(1);
        let reason = self.reason.clone();
        tokio::spawn(async move {
            let _ = sender.send(Err(reason)).await;
        });
        receiver
    }
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum AssistantProviderKind {
    OpenAi,
    Anthropic,
    Gemini,
    Xai,
    Compatible,
    Worker,
}

#[derive(Clone)]
struct AssistantProviderConfig {
    kind: AssistantProviderKind,
    model: String,
    credential: String,
    endpoint: Option<String>,
}

#[derive(Clone)]
struct ValidatedEndpoint {
    url: String,
    host: String,
    port: u16,
}

impl AssistantProviderConfig {
    fn from_runtime(
        provider: ProviderKind,
        model: String,
        endpoint: Option<String>,
        credential: String,
        managed_worker_origin: Option<&str>,
    ) -> Result<Self, String> {
        let kind = match provider {
            ProviderKind::OpenAi => AssistantProviderKind::OpenAi,
            ProviderKind::Anthropic => AssistantProviderKind::Anthropic,
            ProviderKind::Gemini => AssistantProviderKind::Gemini,
            ProviderKind::Xai => AssistantProviderKind::Xai,
            ProviderKind::Compatible => AssistantProviderKind::Compatible,
            ProviderKind::Worker => AssistantProviderKind::Worker,
        };
        if model.trim().is_empty() {
            return Err("assistant model must not be empty".to_owned());
        }
        if credential.trim().is_empty() {
            return Err("assistant credential must not be empty".to_owned());
        }
        let endpoint = match kind {
            AssistantProviderKind::Compatible | AssistantProviderKind::Worker => {
                let endpoint = endpoint
                    .filter(|value| !value.trim().is_empty())
                    .ok_or_else(|| "assistant endpoint is required".to_owned())?;
                let validated = validate_endpoint(&endpoint, false, None)?;
                if kind == AssistantProviderKind::Worker {
                    let trusted = managed_worker_origin
                        .ok_or_else(|| "managed assistant origin is not configured".to_owned())?;
                    let expected = managed_worker_base(trusted)?;
                    if validated.url.trim_end_matches('/') != expected.trim_end_matches('/') {
                        return Err("managed assistant endpoint is not trusted".to_owned());
                    }
                }
                Some(validated.url)
            }
            _ => None,
        };
        Ok(Self {
            kind,
            model,
            credential,
            endpoint,
        })
    }

    fn from_values(mut value: impl FnMut(&str) -> Option<String>) -> Result<Option<Self>, String> {
        let Some(provider) = value("OMI_AI_PROVIDER") else {
            return Ok(None);
        };
        let kind = match provider.trim().to_ascii_lowercase().as_str() {
            "openai" => AssistantProviderKind::OpenAi,
            "anthropic" => AssistantProviderKind::Anthropic,
            "gemini" => AssistantProviderKind::Gemini,
            "xai" => AssistantProviderKind::Xai,
            "compatible" => AssistantProviderKind::Compatible,
            "worker" => AssistantProviderKind::Worker,
            _ => return Err("OMI_AI_PROVIDER is unsupported".to_owned()),
        };
        let model = required_configuration(&mut value, "OMI_AI_MODEL")?;
        let credential_name = if kind == AssistantProviderKind::Worker {
            "OMI_AI_AUTH_TOKEN"
        } else {
            "OMI_AI_API_KEY"
        };
        let credential = required_configuration(&mut value, credential_name)?;
        let endpoint = match kind {
            AssistantProviderKind::Compatible | AssistantProviderKind::Worker => {
                let endpoint = required_configuration(&mut value, "OMI_AI_ENDPOINT")?;
                let validated = validate_endpoint(
                    &endpoint,
                    kind == AssistantProviderKind::Worker,
                    value("OMI_MANAGED_AI_ORIGINS").as_deref(),
                )?;
                Some(validated.url)
            }
            _ => None,
        };
        Ok(Some(Self {
            kind,
            model,
            credential,
            endpoint,
        }))
    }
}

fn managed_worker_base(origin: &str) -> Result<String, String> {
    let validated = validate_endpoint(origin, false, None)?;
    let parsed =
        Url::parse(&validated.url).map_err(|_| "managed assistant origin is invalid".to_owned())?;
    if parsed.path() != "/" {
        return Err("managed assistant origin must not contain a path".to_owned());
    }
    Ok(parsed
        .join("/v1")
        .map_err(|_| "managed assistant origin is invalid".to_owned())?
        .to_string())
}

fn validate_endpoint(
    endpoint: &str,
    managed_worker: bool,
    managed_allowlist: Option<&str>,
) -> Result<ValidatedEndpoint, String> {
    let parsed = Url::parse(endpoint).map_err(|_| "assistant endpoint is invalid".to_owned())?;
    if parsed.scheme() != "https" {
        return Err("assistant endpoint must use HTTPS".to_owned());
    }
    if !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return Err("assistant endpoint contains forbidden URL components".to_owned());
    }
    let host = match parsed.host() {
        Some(Host::Domain(host)) => host.trim_end_matches('.').to_ascii_lowercase(),
        Some(Host::Ipv4(_)) | Some(Host::Ipv6(_)) => {
            return Err("assistant endpoint must not use an IP literal".to_owned());
        }
        None => return Err("assistant endpoint host is required".to_owned()),
    };
    if host == "localhost" || host.ends_with(".localhost") || host.ends_with(".local") {
        return Err("assistant endpoint host is not public".to_owned());
    }
    let port = parsed.port_or_known_default().unwrap_or(443);
    if managed_worker {
        let origin = parsed.origin().ascii_serialization();
        let allowed = managed_allowlist.is_some_and(|values| {
            values
                .split(',')
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .any(|value| value == origin)
        });
        if !allowed {
            return Err("managed assistant origin is not allowlisted".to_owned());
        }
    }
    Ok(ValidatedEndpoint {
        url: parsed.to_string(),
        host,
        port,
    })
}

async fn endpoint_resolves_publicly(endpoint: &str) -> Result<(), String> {
    let validated = validate_endpoint(endpoint, false, None)?;
    let addresses = tokio::time::timeout(
        PROVIDER_CONNECT_TIMEOUT,
        tokio::net::lookup_host((validated.host.as_str(), validated.port)),
    )
    .await
    .map_err(|_| "assistant endpoint resolution timed out".to_owned())?
    .map_err(|_| "assistant endpoint could not be resolved".to_owned())?
    .collect::<Vec<_>>();
    if addresses.is_empty() || addresses.iter().any(|address| !public_ip(address.ip())) {
        return Err("assistant endpoint did not resolve to public addresses".to_owned());
    }
    Ok(())
}

fn public_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => public_ipv4(ip),
        IpAddr::V6(ip) => {
            if let Some(mapped) = ip.to_ipv4_mapped() {
                return public_ipv4(mapped);
            }
            !ip.is_loopback()
                && !ip.is_unspecified()
                && !ip.is_multicast()
                && !is_unique_local(ip)
                && !is_link_local(ip)
        }
    }
}

fn public_ipv4(ip: Ipv4Addr) -> bool {
    !ip.is_private()
        && !ip.is_loopback()
        && !ip.is_link_local()
        && !ip.is_unspecified()
        && !ip.is_multicast()
        && ip != Ipv4Addr::BROADCAST
}

fn is_unique_local(ip: Ipv6Addr) -> bool {
    ip.octets()[0] & 0xfe == 0xfc
}

fn is_link_local(ip: Ipv6Addr) -> bool {
    let octets = ip.octets();
    octets[0] == 0xfe && octets[1] & 0xc0 == 0x80
}

fn required_configuration(
    value: &mut impl FnMut(&str) -> Option<String>,
    name: &str,
) -> Result<String, String> {
    value(name)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| format!("{name} is required"))
}

struct RsAiAssistantProvider {
    config: AssistantProviderConfig,
    computer_use_enabled: bool,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ComputerClickArgs {
    x: i64,
    y: i64,
    button: ComputerClickButton,
    count: u32,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "snake_case")]
enum ComputerClickButton {
    Left,
    Right,
    Middle,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ComputerTypeArgs {
    text: String,
    clear: bool,
    press_return: bool,
    delay_ms: Option<u64>,
}

fn computer_use_tools() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: COMPUTER_CLICK_TOOL.to_owned(),
            description: "Propose clicking a screen coordinate after user approval".to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "x": {"type": "integer"},
                    "y": {"type": "integer"},
                    "button": {"type": "string", "enum": ["left", "right", "middle"]},
                    "count": {"type": "integer", "minimum": 1, "maximum": 3}
                },
                "required": ["x", "y", "button", "count"]
            }),
            examples: None,
        },
        ToolDefinition {
            name: COMPUTER_TYPE_TOOL.to_owned(),
            description: "Propose typing text after user approval".to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "text": {"type": "string", "minLength": 1, "maxLength": 16384},
                    "clear": {"type": "boolean"},
                    "press_return": {"type": "boolean"},
                    "delay_ms": {"type": ["integer", "null"], "minimum": 0, "maximum": 1000}
                },
                "required": ["text", "clear", "press_return"]
            }),
            examples: None,
        },
    ]
}

fn should_enable_computer_tools(configured: bool, available: bool) -> bool {
    configured && available
}

fn valid_computer_tool_identity(call_id: &str, tool_name: &str) -> bool {
    !call_id.is_empty()
        && call_id.len() <= 256
        && call_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        && matches!(tool_name, COMPUTER_CLICK_TOOL | COMPUTER_TYPE_TOOL)
}

fn valid_computer_type(text: &str, delay_ms: Option<u64>) -> bool {
    if text.is_empty() || text.len() > 16 * 1024 || delay_ms.is_some_and(|delay| delay > 1_000) {
        return false;
    }
    let character_count = u64::try_from(text.chars().count()).unwrap_or(u64::MAX);
    character_count
        .checked_mul(delay_ms.unwrap_or_default())
        .is_some_and(|duration| duration <= MAX_COMPUTER_TYPE_DURATION_MS)
}

fn computer_use_proposal(
    request_id: &str,
    call_id: &str,
    tool_name: &str,
    arguments: serde_json::Value,
) -> Result<ActionProposal, String> {
    if !valid_computer_tool_identity(call_id, tool_name) {
        return Err("assistant provider returned an invalid computer-use tool call".to_owned());
    }
    let (title, summary, action) = match tool_name {
        COMPUTER_CLICK_TOOL => {
            let args: ComputerClickArgs = serde_json::from_value(arguments).map_err(|_| {
                "assistant provider returned an invalid computer-use tool call".to_owned()
            })?;
            if !(1..=3).contains(&args.count) {
                return Err(
                    "assistant provider returned an invalid computer-use tool call".to_owned(),
                );
            }
            let button = match args.button {
                ComputerClickButton::Left => crate::signals::MouseButton::Left,
                ComputerClickButton::Right => crate::signals::MouseButton::Right,
                ComputerClickButton::Middle => crate::signals::MouseButton::Middle,
            };
            (
                "Click on screen".to_owned(),
                format!("Click at ({}, {})", args.x, args.y),
                ComputerUseAction::Click {
                    x: args.x,
                    y: args.y,
                    button,
                    count: args.count,
                },
            )
        }
        COMPUTER_TYPE_TOOL => {
            let args: ComputerTypeArgs = serde_json::from_value(arguments).map_err(|_| {
                "assistant provider returned an invalid computer-use tool call".to_owned()
            })?;
            if !valid_computer_type(&args.text, args.delay_ms) {
                return Err(
                    "assistant provider returned an invalid computer-use tool call".to_owned(),
                );
            }
            let summary = format!("Type {} bytes", args.text.len());
            (
                "Type text".to_owned(),
                summary,
                ComputerUseAction::TypeText {
                    text: args.text,
                    clear: args.clear,
                    press_return: args.press_return,
                    delay_ms: args.delay_ms,
                },
            )
        }
        _ => {
            return Err("assistant provider returned an invalid computer-use tool call".to_owned());
        }
    };
    Ok(ActionProposal {
        proposal_id: format!("{request_id}:tool:{call_id}"),
        request_id: request_id.to_owned(),
        title,
        summary,
        risk: ActionRisk::External,
        computer_action: Some(action),
        expires_at_ms: Some(unix_time_ms().saturating_add(COMPUTER_USE_PROPOSAL_TTL_MS)),
    })
}

impl AssistantProvider for RsAiAssistantProvider {
    fn dispatch(
        &self,
        request_id: String,
        text: String,
        cancellation: CancellationToken,
    ) -> mpsc::Receiver<Result<AssistantProviderEvent, String>> {
        let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        let config = self.config.clone();
        let computer_use_enabled = self.computer_use_enabled;
        tokio::spawn(async move {
            if let Some(endpoint) = config.endpoint.as_deref() {
                let preflight = tokio::select! {
                    () = cancellation.cancelled() => return,
                    result = endpoint_resolves_publicly(endpoint) => result,
                };
                if let Err(message) = preflight {
                    let _ = sender.send(Err(message)).await;
                    return;
                }
            }
            let base = match config.kind {
                AssistantProviderKind::OpenAi => rs_ai::chatgpt(),
                AssistantProviderKind::Anthropic => rs_ai::claude(),
                AssistantProviderKind::Gemini => rs_ai::gemini(),
                AssistantProviderKind::Xai => rs_ai::xai(),
                AssistantProviderKind::Compatible | AssistantProviderKind::Worker => {
                    rs_ai::compatible(config.endpoint.unwrap_or_default())
                }
            }
            .model(config.model);
            let client = base.api_key(config.credential);
            let computer_tools_active =
                should_enable_computer_tools(computer_use_enabled, computer_use_available());
            let client = if computer_tools_active {
                client
                    .with_tools(computer_use_tools())
                    .with_tool_choice(ToolChoice::Auto)
            } else {
                client
            };
            let connected = tokio::select! {
                () = cancellation.cancelled() => return,
                result = tokio::time::timeout(PROVIDER_CONNECT_TIMEOUT, client.stream(text)) => result,
            };
            let stream = match connected {
                Ok(stream) => stream,
                Err(_) => {
                    let _ = sender
                        .send(Err("assistant provider connection timed out".to_owned()))
                        .await;
                    return;
                }
            };
            let mut stream = match stream {
                Ok(stream) => stream,
                Err(_) => {
                    let _ = sender
                        .send(Err("assistant provider connection failed".to_owned()))
                        .await;
                    return;
                }
            };
            let mut tool_names = HashMap::new();
            loop {
                let next = tokio::select! {
                    () = cancellation.cancelled() => return,
                    result = tokio::time::timeout(PROVIDER_EVENT_TIMEOUT, stream.next()) => result,
                };
                let Some(next) = (match next {
                    Ok(next) => next,
                    Err(_) => {
                        let _ = sender
                            .send(Err("assistant provider stream timed out".to_owned()))
                            .await;
                        return;
                    }
                }) else {
                    return;
                };
                let event = match next {
                    Ok(StreamEvent::TextDelta { delta }) => Ok(AssistantProviderEvent::Delta {
                        text: delta,
                        final_segment: false,
                    }),
                    Ok(StreamEvent::ToolCallStart { call_id, tool_name }) => {
                        if !computer_tools_active
                            || !valid_computer_tool_identity(&call_id, &tool_name)
                            || tool_names.insert(call_id, tool_name).is_some()
                        {
                            Err(
                                "assistant provider returned an invalid computer-use tool call"
                                    .to_owned(),
                            )
                        } else {
                            continue;
                        }
                    }
                    Ok(StreamEvent::ToolCallEnd { call_id, arguments }) => {
                        let Some(tool_name) = tool_names.remove(&call_id) else {
                            let _ = sender
                                .send(Err(
                                    "assistant provider returned an invalid computer-use tool call"
                                        .to_owned(),
                                ))
                                .await;
                            return;
                        };
                        computer_use_proposal(&request_id, &call_id, &tool_name, arguments)
                            .map(AssistantProviderEvent::Proposal)
                    }
                    Ok(StreamEvent::MessageEnd { .. }) => {
                        if tool_names.is_empty() {
                            Ok(AssistantProviderEvent::Delta {
                                text: String::new(),
                                final_segment: true,
                            })
                        } else {
                            Err(
                                "assistant provider returned an incomplete computer-use tool call"
                                    .to_owned(),
                            )
                        }
                    }
                    Ok(StreamEvent::Error { .. }) => {
                        Err("assistant provider stream failed".to_owned())
                    }
                    Ok(_) => continue,
                    Err(_) => Err("assistant provider stream failed".to_owned()),
                };
                let terminal = event.is_err()
                    || matches!(
                        &event,
                        Ok(AssistantProviderEvent::Delta {
                            final_segment: true,
                            ..
                        })
                    );
                if sender.send(event).await.is_err() || terminal {
                    return;
                }
            }
        });
        receiver
    }
}

fn production_assistant_provider() -> Arc<dyn AssistantProvider> {
    match configured_assistant_provider(|name| std::env::var(name).ok()) {
        Ok(Some(provider)) => provider,
        Ok(None) => Arc::new(UnavailableAssistantProvider {
            reason: "no model provider is configured".to_owned(),
        }),
        Err(reason) => Arc::new(UnavailableAssistantProvider { reason }),
    }
}

fn configured_assistant_provider(
    value: impl FnMut(&str) -> Option<String>,
) -> Result<Option<Arc<dyn AssistantProvider>>, String> {
    Ok(AssistantProviderConfig::from_values(value)?.map(|config| {
        Arc::new(RsAiAssistantProvider {
            config,
            computer_use_enabled: computer_use_available(),
        }) as Arc<dyn AssistantProvider>
    }))
}

#[derive(Default)]
struct CompletedCaptures {
    entries: HashMap<String, CaptureFingerprint>,
    order: VecDeque<String>,
}

#[derive(Debug, Eq, PartialEq)]
enum ReplayStatus {
    Missing,
    Exact,
    Conflict,
}

#[derive(Debug, Eq, PartialEq)]
enum ActivationError {
    Capacity,
    Duplicate,
    Conflict,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ProposalStatus {
    Pending,
    Approved,
    Rejected,
    Expired,
    Invalidated,
    Executed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProposalFingerprint {
    uid: String,
    authority_generation: u64,
    parent_request_id: String,
    expires_at_ms: Option<i64>,
    risk: ActionRisk,
    title: String,
    summary: String,
    computer_action: Option<ComputerUseAction>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ProposalRecord {
    fingerprint: ProposalFingerprint,
    status: ProposalStatus,
}

#[derive(Default)]
struct ProposalRegistry {
    pending: HashMap<String, ProposalRecord>,
    terminal: HashMap<String, ProposalRecord>,
    terminal_order: VecDeque<String>,
}

#[derive(Debug, Eq, PartialEq)]
enum ProposalRegistration {
    Registered,
    ExactReplay,
}

#[derive(Debug, Eq, PartialEq)]
enum ProposalDecisionError {
    NotFound,
    WrongAuthority,
    Expired,
    AlreadyDecided,
    Capacity,
    Conflict,
    NoAction,
}

impl ProposalRegistry {
    fn register(
        &mut self,
        uid: &str,
        authority_generation: u64,
        proposal: ActionProposal,
    ) -> Result<ProposalRegistration, ProposalDecisionError> {
        let now_ms = unix_time_ms();
        self.purge_expired(now_ms);
        let fingerprint = ProposalFingerprint {
            uid: uid.to_owned(),
            authority_generation,
            parent_request_id: proposal.request_id.clone(),
            expires_at_ms: proposal.expires_at_ms,
            risk: proposal.risk,
            title: proposal.title.clone(),
            summary: proposal.summary.clone(),
            computer_action: proposal.computer_action.clone(),
        };
        if let Some(existing) = self
            .pending
            .get(&proposal.proposal_id)
            .or_else(|| self.terminal.get(&proposal.proposal_id))
        {
            return if existing.fingerprint == fingerprint {
                Ok(ProposalRegistration::ExactReplay)
            } else {
                Err(ProposalDecisionError::Conflict)
            };
        }
        if self.pending.len() >= PENDING_PROPOSAL_CAPACITY {
            return Err(ProposalDecisionError::Capacity);
        }
        self.pending.insert(
            proposal.proposal_id.clone(),
            ProposalRecord {
                fingerprint,
                status: ProposalStatus::Pending,
            },
        );
        if proposal
            .expires_at_ms
            .is_some_and(|expires| expires <= now_ms)
        {
            self.finish(&proposal.proposal_id, ProposalStatus::Expired);
            return Err(ProposalDecisionError::Expired);
        }
        NativeEvent::ActionProposal(proposal).send();
        Ok(ProposalRegistration::Registered)
    }

    fn decide(
        &mut self,
        proposal_id: &str,
        uid: &str,
        authority_generation: u64,
        decision: ApprovalDecision,
        now_ms: i64,
    ) -> Result<ProposalRecord, ProposalDecisionError> {
        self.purge_expired(now_ms);
        if let Some(record) = self.terminal.get(proposal_id) {
            return if record.fingerprint.uid != uid
                || record.fingerprint.authority_generation != authority_generation
            {
                Err(ProposalDecisionError::WrongAuthority)
            } else if record.status == ProposalStatus::Expired {
                Err(ProposalDecisionError::Expired)
            } else {
                Err(ProposalDecisionError::AlreadyDecided)
            };
        }
        let record = self
            .pending
            .get(proposal_id)
            .ok_or(ProposalDecisionError::NotFound)?;
        if record.fingerprint.uid != uid
            || record.fingerprint.authority_generation != authority_generation
        {
            return Err(ProposalDecisionError::WrongAuthority);
        }
        if record
            .fingerprint
            .expires_at_ms
            .is_some_and(|expires| expires <= now_ms)
        {
            self.finish(proposal_id, ProposalStatus::Expired);
            return Err(ProposalDecisionError::Expired);
        }
        let status = match decision {
            ApprovalDecision::ApproveOnce => ProposalStatus::Approved,
            ApprovalDecision::Reject => ProposalStatus::Rejected,
        };
        self.finish(proposal_id, status)
            .ok_or(ProposalDecisionError::NotFound)
    }

    fn invalidate_parent(&mut self, uid: &str, authority_generation: u64, parent: &str) {
        self.purge_expired(unix_time_ms());
        let ids = self
            .pending
            .iter()
            .filter(|(_, record)| {
                record.fingerprint.uid == uid
                    && record.fingerprint.authority_generation == authority_generation
                    && record.fingerprint.parent_request_id == parent
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in ids {
            self.finish(&id, ProposalStatus::Invalidated);
        }
    }

    fn approve_and_take_action(
        &mut self,
        proposal_id: &str,
        uid: &str,
        authority_generation: u64,
        now_ms: i64,
    ) -> Result<ComputerUseAction, ProposalDecisionError> {
        self.purge_expired(now_ms);
        if let Some(record) = self.terminal.get(proposal_id) {
            return if record.fingerprint.uid != uid
                || record.fingerprint.authority_generation != authority_generation
            {
                Err(ProposalDecisionError::WrongAuthority)
            } else if record.status == ProposalStatus::Expired {
                Err(ProposalDecisionError::Expired)
            } else {
                Err(ProposalDecisionError::AlreadyDecided)
            };
        }
        let record = self
            .pending
            .get(proposal_id)
            .ok_or(ProposalDecisionError::NotFound)?;
        if record.fingerprint.uid != uid
            || record.fingerprint.authority_generation != authority_generation
        {
            return Err(ProposalDecisionError::WrongAuthority);
        }
        if record
            .fingerprint
            .expires_at_ms
            .is_some_and(|expires| expires <= now_ms)
        {
            self.finish(proposal_id, ProposalStatus::Expired);
            return Err(ProposalDecisionError::Expired);
        }
        let action = record
            .fingerprint
            .computer_action
            .clone()
            .ok_or(ProposalDecisionError::NoAction)?;
        self.finish(proposal_id, ProposalStatus::Executed)
            .ok_or(ProposalDecisionError::NotFound)?;
        Ok(action)
    }

    fn invalidate_generation(&mut self, uid: &str, authority_generation: u64) {
        let parents = self
            .pending
            .values()
            .filter(|record| {
                record.fingerprint.uid == uid
                    && record.fingerprint.authority_generation == authority_generation
            })
            .map(|record| record.fingerprint.parent_request_id.clone())
            .collect::<Vec<_>>();
        for parent in parents {
            self.invalidate_parent(uid, authority_generation, &parent);
        }
    }

    fn finish(&mut self, proposal_id: &str, status: ProposalStatus) -> Option<ProposalRecord> {
        let mut record = self.pending.remove(proposal_id)?;
        record.status = status;
        self.terminal.insert(proposal_id.to_owned(), record.clone());
        self.terminal_order.push_back(proposal_id.to_owned());
        if self.terminal.len() > TERMINAL_PROPOSAL_CAPACITY
            && let Some(expired) = self.terminal_order.pop_front()
        {
            self.terminal.remove(&expired);
        }
        Some(record)
    }

    fn purge_expired(&mut self, now_ms: i64) {
        let expired = self
            .pending
            .iter()
            .filter(|(_, record)| {
                record
                    .fingerprint
                    .expires_at_ms
                    .is_some_and(|expires| expires <= now_ms)
            })
            .map(|(id, _)| id.clone())
            .collect::<Vec<_>>();
        for id in expired {
            self.finish(&id, ProposalStatus::Expired);
        }
    }
}

fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            duration.as_millis().min(i64::MAX as u128) as i64
        })
}

impl CompletedCaptures {
    fn status(&self, request_id: &str, fingerprint: &CaptureFingerprint) -> ReplayStatus {
        match self.entries.get(request_id) {
            None => ReplayStatus::Missing,
            Some(stored) if stored == fingerprint => ReplayStatus::Exact,
            Some(_) => ReplayStatus::Conflict,
        }
    }

    fn insert(&mut self, request_id: String, fingerprint: CaptureFingerprint) {
        self.entries.insert(request_id.clone(), fingerprint);
        self.order.push_back(request_id);
        if self.entries.len() > COMPLETED_CAPTURE_CAPACITY
            && let Some(expired) = self.order.pop_front()
        {
            self.entries.remove(&expired);
        }
    }

    fn clear(&mut self) {
        self.entries.clear();
        self.order.clear();
    }
}

pub struct AudioDispatcher {
    receiver: mpsc::Receiver<AudioChunk>,
    controls: mpsc::Receiver<TranscriptionControl>,
    sessions: AudioSessions,
}

impl AudioDispatcher {
    pub fn channel() -> (
        mpsc::Sender<AudioChunk>,
        mpsc::Sender<TranscriptionControl>,
        Self,
    ) {
        let (sender, receiver) = mpsc::channel(AUDIO_QUEUE_CAPACITY);
        let (control_sender, controls) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        (
            sender,
            control_sender,
            Self {
                receiver,
                controls,
                sessions: AudioSessions::default(),
            },
        )
    }

    pub async fn run(mut self) {
        loop {
            tokio::select! {
                biased;
                control = self.controls.recv() => match control {
                    Some(TranscriptionControl::Start(start)) => {
                        if let Err(failure) = self.sessions.start(start) {
                            error(Some(failure.request_id), failure.code, &failure.message, false);
                        }
                    }
                    Some(TranscriptionControl::Stop { request_id, stream_id }) => {
                        let (acknowledgement, status) = self.sessions.stop(&request_id, &stream_id);
                        NativeEvent::TranscriptionStopAcknowledged(acknowledgement).send();
                        if let Some(status) = status {
                            NativeEvent::TranscriptionStatus(status).send();
                        }
                    }
                    Some(TranscriptionControl::Fence) => self.sessions.cancel_all(),
                    None if self.receiver.is_closed() => break,
                    None => {}
                },
                chunk = self.receiver.recv() => match chunk {
                    Some(chunk) => match self.sessions.accept(chunk) {
                        Ok(Some(next)) => {
                            progress(&next.request_id, "audio", next.status, Some(&next.detail));
                        }
                        Ok(None) => {}
                        Err(failure) => error(
                            Some(failure.request_id),
                            failure.code,
                            &failure.message,
                            false,
                        ),
                    },
                    None if self.controls.is_closed() => break,
                    None => {}
                }
            }
        }
    }
}

impl AudioSessions {
    #[allow(dead_code)]
    fn provider_disconnected(
        &mut self,
        request_id: &str,
        stream_id: &str,
        gap_start_ms: i64,
        gap_end_ms: i64,
    ) -> Result<TranscriptGap, AudioAcceptError> {
        let session = self.0.get_mut(stream_id).ok_or_else(|| AudioAcceptError {
            request_id: request_id.to_owned(),
            code: "transcription_not_started",
            message: "audio stream was not started".to_owned(),
        })?;
        let previous_epoch = session.epoch;
        session.epoch = session
            .epoch
            .checked_add(1)
            .ok_or_else(|| AudioAcceptError {
                request_id: request_id.to_owned(),
                code: "audio_counter_overflow",
                message: "transcription epoch overflowed".to_owned(),
            })?;
        session.phase = TranscriptionPhase::Reconnecting;
        session.reconnect_buffer.clear();
        session.reconnect_buffer_bytes = 0;
        let gap = TranscriptGap {
            request_id: request_id.to_owned(),
            audio_stream_id: stream_id.to_owned(),
            stt_epoch: previous_epoch,
            start_ms: gap_start_ms,
            end_ms: gap_end_ms,
            reason: "provider connection lost; sent audio was not replayed".to_owned(),
        };
        NativeEvent::TranscriptGap(TranscriptGap {
            request_id: gap.request_id.clone(),
            audio_stream_id: gap.audio_stream_id.clone(),
            stt_epoch: gap.stt_epoch,
            start_ms: gap.start_ms,
            end_ms: gap.end_ms,
            reason: gap.reason.clone(),
        })
        .send();
        NativeEvent::TranscriptionStatus(TranscriptionStatus {
            request_id: request_id.to_owned(),
            audio_stream_id: stream_id.to_owned(),
            state: TranscriptionState::Reconnecting,
            stt_epoch: session.epoch,
        })
        .send();
        Ok(gap)
    }

    #[allow(dead_code)]
    fn provider_reconnected(
        &mut self,
        request_id: &str,
        stream_id: &str,
    ) -> Result<Vec<Vec<u8>>, AudioAcceptError> {
        let session = self.0.get_mut(stream_id).ok_or_else(|| AudioAcceptError {
            request_id: request_id.to_owned(),
            code: "transcription_not_started",
            message: "audio stream was not started".to_owned(),
        })?;
        if session.phase != TranscriptionPhase::Reconnecting {
            return Err(AudioAcceptError {
                request_id: request_id.to_owned(),
                code: "transcription_not_reconnecting",
                message: "audio stream is not reconnecting".to_owned(),
            });
        }
        session.phase = TranscriptionPhase::Streaming;
        session.reconnect_buffer_bytes = 0;
        Ok(session.reconnect_buffer.drain(..).collect())
    }

    #[allow(dead_code)]
    fn transcript(
        &mut self,
        request_id: &str,
        stream_id: &str,
        event: ProviderTranscript,
    ) -> Result<TranscriptDelta, AudioAcceptError> {
        let session = self.0.get_mut(stream_id).ok_or_else(|| AudioAcceptError {
            request_id: request_id.to_owned(),
            code: "transcription_not_started",
            message: "audio stream was not started".to_owned(),
        })?;
        let sequence = session.logical_sequence;
        let delta = TranscriptDelta {
            request_id: request_id.to_owned(),
            audio_stream_id: stream_id.to_owned(),
            segment_id: format!("{stream_id}:segment:{sequence}"),
            segment_sequence: sequence,
            stt_epoch: session.epoch,
            device_id: session.device_id.clone(),
            provider: event.provider,
            start_ms: event.start_ms,
            end_ms: event.end_ms,
            occurred_at_ms: event.end_ms,
            text: event.text,
            final_segment: event.final_segment,
            language: Some(session.language.clone()),
        };
        if event.final_segment {
            session.logical_sequence = session.logical_sequence.saturating_add(1);
        }
        Ok(delta)
    }

    fn start(&mut self, start: StartTranscription) -> Result<(), AudioAcceptError> {
        if matches!(&start.auth, TranscriptionAuth::Local) {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "transcription_local_unavailable",
                message: "local transcription is unavailable".to_owned(),
            });
        }
        if let Some(existing) = self.0.get(&start.audio_stream_id) {
            let exact = existing.device_id == start.device_id
                && existing.route == start.auth.route()
                && existing.language == start.language
                && existing.sample_rate_hz == start.sample_rate_hz
                && existing.channels == start.channels
                && existing.encoding == start.encoding;
            return if exact {
                Ok(())
            } else {
                Err(AudioAcceptError {
                    request_id: start.request_id,
                    code: "transcription_start_conflict",
                    message: "audio stream was already started with different metadata".to_owned(),
                })
            };
        }
        if self.0.len() >= MAX_ACTIVE_AUDIO_SESSIONS {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "audio_capacity_exceeded",
                message: "too many active audio sessions".to_owned(),
            });
        }
        let route = start.auth.route();
        let provider = Some(
            stt::spawn(
                SttConfig {
                    request_id: start.request_id.clone(),
                    audio_stream_id: start.audio_stream_id.clone(),
                    device_id: start.device_id.clone(),
                    language: start.language.clone(),
                    sample_rate_hz: start.sample_rate_hz,
                    channels: start.channels,
                    encoding: start.encoding,
                },
                &start.auth,
                start.trusted_worker_origin.as_deref(),
            )
            .map_err(|failure| AudioAcceptError {
                request_id: start.request_id.clone(),
                code: "transcription_provider_invalid",
                message: failure.to_string(),
            })?,
        );
        let stream_id = start.audio_stream_id.clone();
        self.0.insert(
            stream_id.clone(),
            AudioSession {
                start_request_id: start.request_id,
                next_sequence: 0,
                accepted_bytes: 0,
                sample_rate_hz: start.sample_rate_hz,
                channels: start.channels,
                encoding: start.encoding,
                last_seen: Instant::now(),
                device_id: start.device_id,
                route,
                language: start.language,
                epoch: 0,
                logical_sequence: 0,
                phase: TranscriptionPhase::Streaming,
                reconnect_buffer: VecDeque::new(),
                reconnect_buffer_bytes: 0,
                provider,
            },
        );
        Ok(())
    }

    fn stop(
        &mut self,
        request_id: &str,
        stream_id: &str,
    ) -> (
        TranscriptionStopAcknowledgement,
        Option<TranscriptionStatus>,
    ) {
        if let Some(mut session) = self.0.remove(stream_id) {
            session.phase = TranscriptionPhase::Draining;
            let provider_reports_terminal = session.provider.is_some();
            if let Some(provider) = &session.provider {
                provider.cancel();
            }
            let status = (!provider_reports_terminal).then(|| TranscriptionStatus {
                request_id: session.start_request_id,
                audio_stream_id: stream_id.to_owned(),
                state: TranscriptionState::Cancelled,
                stt_epoch: session.epoch,
            });
            (
                TranscriptionStopAcknowledgement {
                    request_id: request_id.to_owned(),
                    audio_stream_id: stream_id.to_owned(),
                    accepted: true,
                },
                status,
            )
        } else {
            (
                TranscriptionStopAcknowledgement {
                    request_id: request_id.to_owned(),
                    audio_stream_id: stream_id.to_owned(),
                    accepted: false,
                },
                None,
            )
        }
    }

    fn cancel_all(&mut self) {
        for (stream_id, session) in self.0.drain() {
            if let Some(provider) = &session.provider {
                provider.cancel();
            } else {
                NativeEvent::TranscriptionStatus(TranscriptionStatus {
                    request_id: session.start_request_id,
                    audio_stream_id: stream_id,
                    state: TranscriptionState::Cancelled,
                    stt_epoch: session.epoch,
                })
                .send();
            }
        }
    }

    fn accept(&mut self, chunk: AudioChunk) -> Result<Option<AudioProgress>, AudioAcceptError> {
        self.accept_at(chunk, Instant::now())
    }

    fn accept_at(
        &mut self,
        chunk: AudioChunk,
        now: Instant,
    ) -> Result<Option<AudioProgress>, AudioAcceptError> {
        self.0.retain(|_, session| {
            now.saturating_duration_since(session.last_seen) < AUDIO_SESSION_IDLE_TIMEOUT
        });
        if !self.0.contains_key(&chunk.request_id) {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "transcription_not_started",
                message: "audio stream must be started before sending audio".to_owned(),
            });
        }
        let session = self
            .0
            .get_mut(&chunk.request_id)
            .ok_or_else(|| AudioAcceptError {
                request_id: chunk.request_id.clone(),
                code: "transcription_not_started",
                message: "audio stream must be started before sending audio".to_owned(),
            })?;
        if chunk.sequence != session.next_sequence {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "invalid_audio_sequence",
                message: format!(
                    "expected audio sequence {}, received {}",
                    session.next_sequence, chunk.sequence
                ),
            });
        }
        if chunk.sample_rate_hz != session.sample_rate_hz
            || chunk.channels != session.channels
            || chunk.encoding != session.encoding
        {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "audio_format_changed",
                message: "audio format changed during an active session".to_owned(),
            });
        }
        if !chunk.end_of_stream
            && let Some(provider) = &session.provider
        {
            provider
                .send_audio(&chunk.bytes)
                .map_err(|failure| AudioAcceptError {
                    request_id: chunk.request_id.clone(),
                    code: "transcription_provider_unavailable",
                    message: failure.to_string(),
                })?;
        }
        let first_chunk = session.next_sequence == 0;
        let next_sequence =
            session
                .next_sequence
                .checked_add(1)
                .ok_or_else(|| AudioAcceptError {
                    request_id: chunk.request_id.clone(),
                    code: "audio_counter_overflow",
                    message: "audio sequence overflowed".to_owned(),
                })?;
        let accepted_bytes = session
            .accepted_bytes
            .checked_add(chunk.bytes.len() as u64)
            .ok_or_else(|| AudioAcceptError {
                request_id: chunk.request_id.clone(),
                code: "audio_counter_overflow",
                message: "accepted audio byte count overflowed".to_owned(),
            })?;
        let reconnect_buffer_bytes =
            if session.phase == TranscriptionPhase::Reconnecting && !chunk.end_of_stream {
                let buffered = session
                    .reconnect_buffer_bytes
                    .checked_add(chunk.bytes.len())
                    .ok_or_else(|| AudioAcceptError {
                        request_id: chunk.request_id.clone(),
                        code: "audio_counter_overflow",
                        message: "reconnect buffer size overflowed".to_owned(),
                    })?;
                if buffered > MAX_RECONNECT_BUFFER_BYTES {
                    return Err(AudioAcceptError {
                        request_id: chunk.request_id,
                        code: "transcription_reconnect_buffer_full",
                        message: "transcription reconnect buffer is full".to_owned(),
                    });
                }
                Some(buffered)
            } else {
                None
            };
        session.next_sequence = next_sequence;
        session.accepted_bytes = accepted_bytes;
        session.last_seen = now;
        if let Some(buffered) = reconnect_buffer_bytes {
            session.reconnect_buffer.push_back(chunk.bytes.clone());
            session.reconnect_buffer_bytes = buffered;
        }
        let progress = if chunk.end_of_stream {
            let stream_id = chunk.request_id.clone();
            let epoch = session.epoch;
            session.phase = TranscriptionPhase::Draining;
            if let Some(provider) = &session.provider {
                provider.finish();
            }
            NativeEvent::TranscriptionStatus(TranscriptionStatus {
                request_id: stream_id.clone(),
                audio_stream_id: stream_id.clone(),
                state: TranscriptionState::Draining,
                stt_epoch: epoch,
            })
            .send();
            self.0.remove(&stream_id);
            Some((
                ToolStatus::Complete,
                format!("accepted {accepted_bytes} audio bytes"),
            ))
        } else if first_chunk {
            Some((ToolStatus::Running, "audio stream accepted".to_owned()))
        } else {
            None
        };
        Ok(progress.map(|(status, detail)| AudioProgress {
            request_id: chunk.request_id,
            status,
            detail,
        }))
    }
}

pub struct CommandDispatcher {
    receiver: mpsc::Receiver<ClientCommand>,
    state: Arc<Mutex<RuntimeState>>,
    active: Arc<Mutex<HashMap<String, ActiveCommand>>>,
    assistant_provider: Arc<StdMutex<Arc<dyn AssistantProvider>>>,
    transcription: Option<mpsc::Sender<TranscriptionControl>>,
}

impl CommandDispatcher {
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn channel() -> (mpsc::Sender<ClientCommand>, Self) {
        Self::channel_inner(None)
    }

    pub fn channel_with_transcription(
        transcription: mpsc::Sender<TranscriptionControl>,
    ) -> (mpsc::Sender<ClientCommand>, Self) {
        Self::channel_inner(Some(transcription))
    }

    fn channel_inner(
        transcription: Option<mpsc::Sender<TranscriptionControl>>,
    ) -> (mpsc::Sender<ClientCommand>, Self) {
        let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        (
            sender,
            Self {
                receiver,
                state: Arc::new(Mutex::new(RuntimeState::default())),
                active: Arc::new(Mutex::new(HashMap::new())),
                assistant_provider: Arc::new(StdMutex::new(production_assistant_provider())),
                transcription,
            },
        )
    }

    pub async fn run(mut self) {
        let mut tasks = JoinSet::new();
        let mut completed = CompletedCaptures::default();
        let mut authority_generation = 0_u64;
        loop {
            reap_ready(
                &mut tasks,
                &self.active,
                &mut completed,
                authority_generation,
            )
            .await;
            let command = tokio::select! {
                biased;
                joined = tasks.join_next(), if !tasks.is_empty() => {
                    reap_joined(
                        joined,
                        &self.active,
                        &mut completed,
                        authority_generation,
                    ).await;
                    continue;
                }
                command = self.receiver.recv() => match command {
                    Some(command) => command,
                    None => break,
                },
            };
            let request_id = command.request_id.clone();
            if let Command::StartTranscription {
                audio_stream_id,
                device_id,
                auth,
                language,
                sample_rate_hz,
                channels,
                encoding,
            } = &command.command
            {
                if audio_stream_id.trim().is_empty()
                    || device_id.trim().is_empty()
                    || language.trim().is_empty()
                    || !(8_000..=192_000).contains(sample_rate_hz)
                    || !(1..=2).contains(channels)
                {
                    error(
                        Some(request_id),
                        "transcription_start_invalid",
                        "transcription start metadata or credential is invalid",
                        false,
                    );
                    continue;
                }
                let Some(transcription) = &self.transcription else {
                    error(
                        Some(request_id),
                        "transcription_unavailable",
                        "transcription runtime is unavailable",
                        false,
                    );
                    continue;
                };
                let start = StartTranscription {
                    request_id,
                    audio_stream_id: audio_stream_id.clone(),
                    device_id: device_id.clone(),
                    auth: auth.clone(),
                    trusted_worker_origin: self.state.lock().await.managed_worker_origin.clone(),
                    language: language.clone(),
                    sample_rate_hz: *sample_rate_hz,
                    channels: *channels,
                    encoding: *encoding,
                };
                if transcription
                    .send(TranscriptionControl::Start(start))
                    .await
                    .is_err()
                {
                    error(
                        None,
                        "transcription_unavailable",
                        "transcription runtime stopped",
                        false,
                    );
                }
                continue;
            }
            if let Command::StopTranscription { audio_stream_id } = &command.command {
                if let Some(transcription) = &self.transcription {
                    if transcription
                        .send(TranscriptionControl::Stop {
                            request_id: request_id.clone(),
                            stream_id: audio_stream_id.clone(),
                        })
                        .await
                        .is_err()
                    {
                        NativeEvent::TranscriptionStopAcknowledged(
                            TranscriptionStopAcknowledgement {
                                request_id,
                                audio_stream_id: audio_stream_id.clone(),
                                accepted: false,
                            },
                        )
                        .send();
                    }
                } else {
                    NativeEvent::TranscriptionStopAcknowledged(TranscriptionStopAcknowledgement {
                        request_id,
                        audio_stream_id: audio_stream_id.clone(),
                        accepted: false,
                    })
                    .send();
                }
                continue;
            }
            if let Command::ConfigureTrustedAssistant {
                managed_worker_origin,
            } = &command.command
            {
                let trusted = match managed_worker_base(managed_worker_origin) {
                    Ok(_) => managed_worker_origin.trim_end_matches('/').to_owned(),
                    Err(message) => {
                        error(
                            Some(request_id),
                            "trusted_assistant_configuration_invalid",
                            &message,
                            false,
                        );
                        continue;
                    }
                };
                let mut state = self.state.lock().await;
                match state.managed_worker_origin.as_deref() {
                    None => state.managed_worker_origin = Some(trusted),
                    Some(existing) if existing == trusted => {}
                    Some(_) => {
                        error(
                            Some(request_id),
                            "trusted_assistant_configuration_conflict",
                            "managed assistant origin is already configured",
                            false,
                        );
                        continue;
                    }
                }
                continue;
            }
            if let Command::ConfigureAssistant {
                provider,
                model,
                endpoint,
                credential,
            } = &command.command
            {
                cancel_all(&self.active).await;
                let managed_worker_origin = self.state.lock().await.managed_worker_origin.clone();
                match AssistantProviderConfig::from_runtime(
                    *provider,
                    model.clone(),
                    endpoint.clone(),
                    credential.clone(),
                    managed_worker_origin.as_deref(),
                ) {
                    Ok(config) => {
                        *self
                            .assistant_provider
                            .lock()
                            .unwrap_or_else(|failure| failure.into_inner()) =
                            Arc::new(RsAiAssistantProvider {
                                config,
                                computer_use_enabled: computer_use_available(),
                            });
                        progress(
                            &request_id,
                            "assistant_configuration",
                            ToolStatus::Complete,
                            Some("assistant provider configured"),
                        );
                    }
                    Err(message) => error(
                        Some(request_id),
                        "assistant_configuration_invalid",
                        &message,
                        false,
                    ),
                }
                continue;
            }
            if matches!(command.command, Command::ClearAssistant) {
                cancel_all(&self.active).await;
                *self
                    .assistant_provider
                    .lock()
                    .unwrap_or_else(|failure| failure.into_inner()) =
                    Arc::new(UnavailableAssistantProvider {
                        reason: "no model provider is configured".to_owned(),
                    });
                progress(
                    &request_id,
                    "assistant_configuration",
                    ToolStatus::Complete,
                    Some("assistant provider cleared"),
                );
                continue;
            }
            if matches!(command.command, Command::Cancel) {
                let mut state = self.state.lock().await;
                if let Some(uid) = state.authority_uid.clone() {
                    let generation = state.configuration_generation;
                    state
                        .proposals
                        .invalidate_parent(&uid, generation, &request_id);
                }
                drop(state);
                cancel(&self.active, &request_id).await;
                continue;
            }
            if matches!(&command.command, Command::ConfigureMemory { .. }) {
                if let Command::ConfigureMemory {
                    tenant_id,
                    person_id,
                    ..
                } = &command.command
                    && firebase_memory_scope(tenant_id, person_id).is_err()
                {
                    error(
                        Some(request_id),
                        "invalid_memory_configuration",
                        "tenant_id and person_id must match the configured Firebase UID",
                        false,
                    );
                    continue;
                }
                if let Some(transcription) = &self.transcription {
                    let _ = transcription.send(TranscriptionControl::Fence).await;
                }
                let mut state = self.state.lock().await;
                if let Some(uid) = state.authority_uid.clone() {
                    let generation = state.configuration_generation;
                    state.proposals.invalidate_generation(&uid, generation);
                }
                drop(state);
                authority_generation = authority_generation.saturating_add(1);
                completed.clear();
                cancel_all(&self.active).await;
            }
            if let Command::ApprovalDecision {
                proposal_id,
                decision,
            } = &command.command
            {
                let mut state = self.state.lock().await;
                let Some(uid) = state.authority_uid.clone() else {
                    error(
                        Some(request_id),
                        "proposal_not_found",
                        "no action proposal authority is configured",
                        false,
                    );
                    continue;
                };
                let generation = state.configuration_generation;
                match state.proposals.decide(
                    proposal_id,
                    &uid,
                    generation,
                    *decision,
                    unix_time_ms(),
                ) {
                    Ok(record) => {
                        let detail = format!(
                            "{} {:?} proposal for {}",
                            if record.status == ProposalStatus::Approved {
                                "approved"
                            } else {
                                "rejected"
                            },
                            record.fingerprint.risk,
                            record.fingerprint.parent_request_id
                        );
                        progress(&request_id, "approval", ToolStatus::Complete, Some(&detail));
                    }
                    Err(failure) => {
                        let (code, message) = match failure {
                            ProposalDecisionError::NotFound => (
                                "proposal_not_found",
                                "no matching action proposal is active",
                            ),
                            ProposalDecisionError::WrongAuthority => (
                                "proposal_authority_changed",
                                "the proposal belongs to a different authority",
                            ),
                            ProposalDecisionError::Expired => {
                                ("proposal_expired", "the action proposal has expired")
                            }
                            ProposalDecisionError::AlreadyDecided => (
                                "proposal_already_decided",
                                "the action proposal was already decided",
                            ),
                            ProposalDecisionError::Capacity => (
                                "proposal_capacity_exceeded",
                                "too many action proposals are pending",
                            ),
                            ProposalDecisionError::Conflict => (
                                "proposal_id_conflict",
                                "proposal_id was reused with a different payload",
                            ),
                            ProposalDecisionError::NoAction => (
                                "proposal_action_missing",
                                "the proposal has no executable computer action",
                            ),
                        };
                        error(Some(request_id), code, message, false);
                    }
                }
                continue;
            }
            let cancellation = CancellationToken::new();
            let capture = capture_fingerprint(&command.command);
            if let Some(fingerprint) = &capture {
                match completed.status(&request_id, fingerprint) {
                    ReplayStatus::Exact => continue,
                    ReplayStatus::Conflict => {
                        error(
                            Some(request_id),
                            "idempotency_conflict",
                            "request_id completed with a different capture payload",
                            false,
                        );
                        continue;
                    }
                    ReplayStatus::Missing => {}
                }
            }
            {
                let mut active = self.active.lock().await;
                match activate(
                    &mut active,
                    request_id.clone(),
                    cancellation.clone(),
                    capture,
                    authority_generation,
                ) {
                    Ok(true) => {}
                    Ok(false) => continue,
                    Err(ActivationError::Capacity) => {
                        acknowledge_approval_execution_rejection(&command.command, &request_id);
                        error(
                            Some(request_id),
                            "command_capacity_exceeded",
                            "too many active commands",
                            true,
                        );
                        continue;
                    }
                    Err(ActivationError::Duplicate) => {
                        acknowledge_approval_execution_rejection(&command.command, &request_id);
                        error(
                            Some(request_id),
                            "duplicate_request",
                            "request_id is already active",
                            false,
                        );
                        continue;
                    }
                    Err(ActivationError::Conflict) => {
                        acknowledge_approval_execution_rejection(&command.command, &request_id);
                        error(
                            Some(request_id),
                            "idempotency_conflict",
                            "request_id is active with a different capture payload",
                            false,
                        );
                        continue;
                    }
                }
            }

            let configuration_generation =
                if matches!(command.command, Command::ConfigureMemory { .. }) {
                    let mut state = self.state.lock().await;
                    if let Command::ConfigureMemory { person_id, .. } = &command.command {
                        Some(advance_memory_authority(&mut state, person_id))
                    } else {
                        None
                    }
                } else {
                    None
                };
            let state = Arc::clone(&self.state);
            let assistant_provider = self
                .assistant_provider
                .lock()
                .unwrap_or_else(|failure| failure.into_inner())
                .clone();
            let execution_generation = authority_generation;
            tasks.spawn(async move {
                let outcome = tokio::spawn(execute(
                    command,
                    state,
                    assistant_provider,
                    cancellation,
                    configuration_generation,
                    execution_generation,
                ))
                .await;
                (request_id, outcome)
            });
        }
        cancel_all(&self.active).await;
        while let Some(joined) = tasks.join_next().await {
            reap_joined(
                Some(joined),
                &self.active,
                &mut completed,
                authority_generation,
            )
            .await;
        }
    }
}

fn activate(
    active: &mut HashMap<String, ActiveCommand>,
    request_id: String,
    cancellation: CancellationToken,
    capture: Option<CaptureFingerprint>,
    authority_generation: u64,
) -> Result<bool, ActivationError> {
    let at_capacity = active.len() >= MAX_ACTIVE_COMMANDS;
    match active.entry(request_id) {
        Entry::Occupied(entry) => match (&entry.get().capture, &capture) {
            (Some(active), Some(replay)) if active == replay => Ok(false),
            (Some(_), Some(_)) => Err(ActivationError::Conflict),
            _ => Err(ActivationError::Duplicate),
        },
        Entry::Vacant(_) if at_capacity => Err(ActivationError::Capacity),
        Entry::Vacant(entry) => {
            entry.insert(ActiveCommand {
                cancellation,
                capture,
                authority_generation,
            });
            Ok(true)
        }
    }
}

fn capture_fingerprint(command: &Command) -> Option<CaptureFingerprint> {
    match command {
        Command::CaptureEvent {
            ingestion_key,
            source,
            occurred_at_ms,
            recorded_at_ms,
            text,
            application,
            window_title,
            transcript_locator,
        } => Some(CaptureFingerprint {
            ingestion_key: ingestion_key.clone(),
            source: source.clone(),
            occurred_at_ms: *occurred_at_ms,
            recorded_at_ms: *recorded_at_ms,
            text: text.clone(),
            application: application.clone(),
            window_title: window_title.clone(),
            transcript_locator: transcript_locator.clone(),
        }),
        _ => None,
    }
}

type TrackedTaskResult = Result<(String, Result<bool, JoinError>), JoinError>;

async fn reap_ready(
    tasks: &mut JoinSet<(String, Result<bool, JoinError>)>,
    active: &Mutex<HashMap<String, ActiveCommand>>,
    completed: &mut CompletedCaptures,
    authority_generation: u64,
) {
    while let Some(joined) = tasks.try_join_next() {
        reap_joined(Some(joined), active, completed, authority_generation).await;
    }
}

async fn reap_joined(
    result: Option<TrackedTaskResult>,
    active: &Mutex<HashMap<String, ActiveCommand>>,
    completed: &mut CompletedCaptures,
    authority_generation: u64,
) {
    match result {
        Some(Ok((request_id, outcome))) => {
            let command = active.lock().await.remove(&request_id);
            match outcome {
                Ok(true) => {
                    if let Some(ActiveCommand {
                        capture: Some(fingerprint),
                        authority_generation: generation,
                        ..
                    }) = command
                        && generation == authority_generation
                    {
                        completed.insert(request_id, fingerprint);
                    }
                }
                Ok(false) => {}
                Err(error_value) => error(
                    Some(request_id),
                    "native_task_failed",
                    &error_value.to_string(),
                    false,
                ),
            }
        }
        Some(Err(error_value)) => {
            error(None, "native_task_failed", &error_value.to_string(), false);
        }
        None => {}
    }
}

async fn cancel_all(active: &Mutex<HashMap<String, ActiveCommand>>) {
    for command in active.lock().await.values() {
        command.cancellation.cancel();
    }
}

pub fn runtime_status(memory_available: bool) -> RuntimeStatus {
    RuntimeStatus {
        phase: RuntimePhase::Ready,
        detail: Some(format!("rx4 {}", rx4::VERSION)),
        computer_use_available: computer_use_available(),
        local_ai_available: false,
        memory_available,
        agent_harness_available: true,
    }
}

async fn dispatch_assistant(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    provider: Arc<dyn AssistantProvider>,
    text: String,
    cancellation: &CancellationToken,
) {
    let generation = state.lock().await.configuration_generation;
    let mut events = provider.dispatch(request_id.to_owned(), text, cancellation.clone());
    loop {
        let next =
            match receive_provider_event(&mut events, cancellation, PROVIDER_EVENT_TIMEOUT).await {
                ProviderReceive::Event(event) => event,
                ProviderReceive::Closed => return,
                ProviderReceive::Cancelled => {
                    cancelled(request_id);
                    return;
                }
                ProviderReceive::TimedOut => {
                    error(
                        Some(request_id.to_owned()),
                        "assistant_provider_timeout",
                        "assistant provider response timed out",
                        true,
                    );
                    return;
                }
            };
        let mut state = state.lock().await;
        if state.configuration_generation != generation {
            cancelled(request_id);
            return;
        }
        let Some(uid) = state.authority_uid.clone() else {
            error(
                Some(request_id.to_owned()),
                "assistant_unavailable",
                "no assistant authority is configured",
                false,
            );
            return;
        };
        let event = match next {
            Ok(event) => event,
            Err(message) => {
                error(
                    Some(request_id.to_owned()),
                    "assistant_provider_failed",
                    &message,
                    true,
                );
                return;
            }
        };
        match event {
            AssistantProviderEvent::Delta {
                text,
                final_segment,
            } => NativeEvent::AssistantDelta(AssistantDelta {
                request_id: request_id.to_owned(),
                text,
                final_segment,
            })
            .send(),
            AssistantProviderEvent::Proposal(proposal) => {
                if proposal.request_id != request_id {
                    error(
                        Some(request_id.to_owned()),
                        "proposal_parent_mismatch",
                        "action proposal parent does not match the assistant request",
                        false,
                    );
                    continue;
                }
                if let Err(failure) = state.proposals.register(&uid, generation, proposal) {
                    let (code, message) = match failure {
                        ProposalDecisionError::Capacity => (
                            "proposal_capacity_exceeded",
                            "too many action proposals are pending",
                        ),
                        ProposalDecisionError::Conflict => (
                            "proposal_id_conflict",
                            "proposal_id was reused with a different payload",
                        ),
                        ProposalDecisionError::NoAction => (
                            "proposal_action_missing",
                            "the proposal has no executable computer action",
                        ),
                        _ => (
                            "proposal_registration_failed",
                            "action proposal could not be registered",
                        ),
                    };
                    error(Some(request_id.to_owned()), code, message, false);
                }
            }
        }
    }
}

async fn execute(
    command: ClientCommand,
    state: Arc<Mutex<RuntimeState>>,
    assistant_provider: Arc<dyn AssistantProvider>,
    cancellation: CancellationToken,
    configuration_generation: Option<u64>,
    execution_generation: u64,
) -> bool {
    let request_id = command.request_id;
    if cancellation.is_cancelled() {
        cancelled(&request_id);
        return false;
    }

    match command.command {
        Command::ConfigureMemory {
            database_path,
            tenant_id,
            person_id,
        } => {
            configure_memory(
                &request_id,
                &state,
                database_path,
                tenant_id,
                person_id,
                &cancellation,
                configuration_generation.unwrap_or_default(),
            )
            .await;
            false
        }
        Command::CaptureEvent {
            ingestion_key,
            source,
            occurred_at_ms,
            recorded_at_ms,
            text,
            application,
            window_title,
            transcript_locator,
        } => {
            capture(
                &request_id,
                &state,
                ingestion_key,
                source,
                occurred_at_ms,
                recorded_at_ms,
                text,
                application,
                window_title,
                transcript_locator,
                &cancellation,
            )
            .await
        }
        Command::SearchMemory {
            query,
            limit,
            as_of_valid_at_ms,
            as_of_recorded_at_ms,
        } => {
            search(
                &request_id,
                &state,
                query,
                limit,
                as_of_valid_at_ms,
                as_of_recorded_at_ms,
                &cancellation,
            )
            .await;
            false
        }
        Command::ExportMemory {
            after_commit,
            after_event_index,
            high_water_mark,
            limit,
        } => {
            export_memory(
                &request_id,
                &state,
                after_commit,
                after_event_index,
                high_water_mark,
                limit,
                &cancellation,
            )
            .await;
            false
        }
        Command::ListMemoryItems { limit } => {
            list_memory_items(&request_id, &state, limit, &cancellation).await;
            false
        }
        Command::CorrectMemory {
            claim_id,
            text,
            value,
            occurred_at_ms,
            recorded_at_ms,
        } => {
            correct_memory(
                &request_id,
                &state,
                claim_id,
                text,
                value,
                occurred_at_ms,
                recorded_at_ms,
                &cancellation,
            )
            .await;
            false
        }
        Command::DeleteMemorySource {
            source_id,
            deleted_at_ms,
        } => {
            delete_memory_source(&request_id, &state, source_id, deleted_at_ms, &cancellation)
                .await;
            false
        }
        Command::SendMessage { text, .. } => {
            dispatch_assistant(&request_id, &state, assistant_provider, text, &cancellation).await;
            false
        }
        Command::ApproveAndExecuteComputerUse { proposal_id } => {
            approve_and_execute_computer_use(
                &request_id,
                &state,
                &proposal_id,
                execution_generation,
                &cancellation,
            )
            .await;
            false
        }
        Command::ConfigureAssistant { .. }
        | Command::ConfigureTrustedAssistant { .. }
        | Command::ClearAssistant
        | Command::StartTranscription { .. }
        | Command::StopTranscription { .. } => false,
        Command::ApprovalDecision { .. } => {
            error(
                Some(request_id),
                "proposal_not_found",
                "no matching action proposal is active",
                false,
            );
            false
        }
        Command::DeviceState { .. } => {
            progress(
                &request_id,
                "device_state",
                ToolStatus::Complete,
                Some("device state accepted"),
            );
            false
        }
        Command::Cancel => false,
    }
}

async fn configure_memory(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    database_path: String,
    tenant_id: String,
    person_id: String,
    cancellation: &CancellationToken,
    configuration_generation: u64,
) {
    if database_path.trim().is_empty() {
        error(
            Some(request_id.to_owned()),
            "invalid_memory_configuration",
            "database_path must not be empty",
            false,
        );
        return;
    }
    if let Err(message) = firebase_memory_scope(&tenant_id, &person_id) {
        error(
            Some(request_id.to_owned()),
            "invalid_memory_configuration",
            message,
            false,
        );
        return;
    }
    let tenant_id = match TenantId::new(tenant_id) {
        Ok(value) => value,
        Err(error_value) => {
            error(
                Some(request_id.to_owned()),
                "invalid_memory_configuration",
                &error_value.to_string(),
                false,
            );
            return;
        }
    };
    let person_id = match PersonId::new(person_id) {
        Ok(value) => value,
        Err(error_value) => {
            error(
                Some(request_id.to_owned()),
                "invalid_memory_configuration",
                &error_value.to_string(),
                false,
            );
            return;
        }
    };
    let task = spawn_blocking(move || {
        MemoryDb::open(database_path)
            .map(|database| MemoryContext {
                database,
                tenant_id,
                person_id,
            })
            .map_err(|error_value| error_value.to_string())
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(memory) => {
            let mut state = state.lock().await;
            if !configuration_is_current(&state, configuration_generation) {
                error(
                    Some(request_id.to_owned()),
                    "memory_configuration_superseded",
                    "a newer memory configuration replaced this request",
                    false,
                );
                return;
            }
            state.memory = Some(Arc::new(StdMutex::new(memory)));
            drop(state);
            NativeEvent::RuntimeStatus(runtime_status(true)).send();
            progress(
                request_id,
                "memory",
                ToolStatus::Complete,
                Some("memory ready"),
            );
        }
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_open_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn firebase_memory_scope<'a>(tenant_id: &'a str, person_id: &str) -> Result<&'a str, &'static str> {
    if tenant_id.trim().is_empty() || tenant_id != person_id {
        Err("tenant_id and person_id must match the configured Firebase UID")
    } else {
        Ok(tenant_id)
    }
}

fn configuration_is_current(state: &RuntimeState, generation: u64) -> bool {
    state.configuration_generation == generation
}

fn advance_memory_authority(state: &mut RuntimeState, person_id: &str) -> u64 {
    state.configuration_generation = state.configuration_generation.saturating_add(1);
    state.memory = None;
    state.authority_uid = Some(person_id.to_owned());
    state.configuration_generation
}

#[allow(clippy::too_many_arguments)]
async fn capture(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
    transcript_locator: Option<TranscriptLocator>,
    cancellation: &CancellationToken,
) -> bool {
    if ingestion_key.trim().is_empty() {
        error(
            Some(request_id.to_owned()),
            "invalid_capture",
            "ingestion_key must not be empty",
            false,
        );
        return false;
    }
    let Some(text) = capture_text(text, application, window_title) else {
        error(
            Some(request_id.to_owned()),
            "invalid_capture",
            "capture contains no text",
            false,
        );
        return false;
    };
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before capturing events",
            true,
        );
        return false;
    };
    let task = spawn_capture(
        memory,
        ingestion_key,
        source,
        occurred_at_ms,
        recorded_at_ms,
        text,
        transcript_locator,
        cancellation.clone(),
    );
    match await_mutating_blocking(task, cancellation).await {
        BlockingOutcome::Complete(Some(remembered)) => {
            NativeEvent::MemoryCaptured(MemoryCaptured {
                request_id: request_id.to_owned(),
                source_id: remembered.source_id.0,
                evidence_id: remembered.evidence_id.0,
            })
            .send();
            true
        }
        BlockingOutcome::Complete(None) => {
            cancelled(request_id);
            false
        }
        BlockingOutcome::Failed(error_value) => {
            error(
                Some(request_id.to_owned()),
                "memory_capture_failed",
                &error_value,
                false,
            );
            false
        }
        BlockingOutcome::Cancelled => {
            cancelled(request_id);
            false
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn spawn_capture(
    memory: Arc<StdMutex<MemoryContext>>,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    text: String,
    transcript_locator: Option<TranscriptLocator>,
    cancellation: CancellationToken,
) -> JoinHandle<Result<Option<zkr::Remembered>, String>> {
    spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        if cancellation.is_cancelled() {
            return Ok(None);
        }
        remember_capture(
            &mut memory,
            ingestion_key,
            source,
            occurred_at_ms,
            recorded_at_ms,
            text,
            transcript_locator,
        )
        .map(Some)
    })
}

fn remember_capture(
    memory: &mut MemoryContext,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    text: String,
    transcript_locator: Option<TranscriptLocator>,
) -> Result<zkr::Remembered, String> {
    let locator = transcript_locator
        .map(|locator| -> Result<ZkrTranscriptLocator, String> {
            Ok(ZkrTranscriptLocator {
                device_id: locator.device_id,
                provider: locator.provider,
                stream_id: locator.stream_id,
                segment_id: locator.segment_id,
                start_ms: u64::try_from(locator.start_ms)
                    .map_err(|_| "transcript start_ms must not be negative".to_owned())?,
                end_ms: u64::try_from(locator.end_ms)
                    .map_err(|_| "transcript end_ms must not be negative".to_owned())?,
            })
        })
        .transpose()?;
    memory
        .database
        .remember_with_locator(
            RememberInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                ingestion_key: Some(ingestion_key),
                kind: source_kind(source),
                text,
                captured_at: occurred_at_ms,
                recorded_at: recorded_at_ms,
                claim: None,
            },
            locator,
        )
        .map_err(|error_value| error_value.to_string())
}

async fn search(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    query: String,
    limit: u32,
    as_of_valid_at_ms: Option<i64>,
    as_of_recorded_at_ms: Option<i64>,
    cancellation: &CancellationToken,
) {
    let as_of = match temporal_query(as_of_valid_at_ms, as_of_recorded_at_ms) {
        Ok(value) => value,
        Err(message) => {
            error(
                Some(request_id.to_owned()),
                "invalid_memory_search",
                message,
                false,
            );
            return;
        }
    };
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before searching",
            true,
        );
        return;
    };
    let task = spawn_blocking(move || {
        let memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query,
                limit,
                query_embedding: None,
                as_of,
            })
            .map_err(|error_value| error_value.to_string())
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(pack) => NativeEvent::MemorySearchResults(MemorySearchResults {
            request_id: request_id.to_owned(),
            query: pack.query,
            items: pack
                .items
                .into_iter()
                .map(|item| {
                    let (kind, id) = match item.memory {
                        MemoryRef::Source(id) => ("source", id.0),
                        MemoryRef::Evidence(id) => ("evidence", id.0),
                        MemoryRef::Claim(id) => ("claim", id.0),
                        MemoryRef::ProfileEntry(id) => ("profile_entry", id.0),
                        MemoryRef::DailyReview(id) => ("daily_review", id.0),
                    };
                    MemorySearchItem {
                        kind: kind.to_owned(),
                        id,
                        excerpt: item.excerpt,
                        relevance_basis_points: item.relevance_basis_points,
                        evidence_ids: item.evidence_ids.into_iter().map(|id| id.0).collect(),
                    }
                })
                .collect(),
            gaps: pack.gaps,
        })
        .send(),
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_search_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

async fn export_memory(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    after_commit: i64,
    after_event_index: i64,
    high_water_mark: Option<i64>,
    limit: u32,
    cancellation: &CancellationToken,
) {
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before exporting it",
            true,
        );
        return;
    };
    let task = spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        export_configured_memory(
            &mut memory,
            after_commit,
            after_event_index,
            high_water_mark,
            limit,
        )
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(page) => match memory_exported(request_id, page) {
            Ok(event) => NativeEvent::MemoryExported(event).send(),
            Err(error_value) => error(
                Some(request_id.to_owned()),
                "memory_export_failed",
                &error_value,
                false,
            ),
        },
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_export_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn export_configured_memory(
    memory: &mut MemoryContext,
    after_commit: i64,
    after_event_index: i64,
    high_water_mark: Option<i64>,
    limit: u32,
) -> Result<zkr::ExportPage, String> {
    memory
        .database
        .export(ExportInput {
            export_format: EXPORT_FORMAT_VERSION,
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            after_commit,
            after_event_index,
            high_water_mark,
            limit,
        })
        .map_err(|error_value| error_value.to_string())
}

fn memory_exported(request_id: &str, page: zkr::ExportPage) -> Result<MemoryExported, String> {
    Ok(MemoryExported {
        request_id: request_id.to_owned(),
        export_format: page.export_format,
        database_schema_version: page.database_schema_version,
        high_water_mark: page.high_water_mark,
        next_after_commit: page.next_after_commit,
        next_after_event_index: page.next_after_event_index,
        complete: page.complete,
        commits: page
            .commits
            .into_iter()
            .map(|commit| {
                let records_json = commit
                    .records
                    .into_iter()
                    .map(|record| serde_json::to_string(&record).map_err(|error| error.to_string()))
                    .collect::<Result<Vec<_>, _>>()?;
                Ok(MemoryExportCommit {
                    sequence: commit.sequence,
                    recorded_at_ms: commit.recorded_at,
                    event_count: commit.event_count,
                    first_event_index: commit.first_event_index,
                    records_json,
                })
            })
            .collect::<Result<Vec<_>, String>>()?,
    })
}

async fn list_memory_items(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    limit: u32,
    cancellation: &CancellationToken,
) {
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before listing it",
            true,
        );
        return;
    };
    let task = spawn_blocking(move || {
        let memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        list_configured_memory_items(&memory, limit)
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(items) => NativeEvent::MemoryItems(MemoryItems {
            request_id: request_id.to_owned(),
            items,
        })
        .send(),
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_list_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn list_configured_memory_items(
    memory: &MemoryContext,
    limit: u32,
) -> Result<Vec<MemoryItem>, String> {
    let mut items = memory
        .database
        .profiles(ProfilesInput {
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            limit,
        })
        .map_err(|error_value| error_value.to_string())?
        .into_iter()
        .map(|profile| MemoryItem {
            kind: "profile".to_owned(),
            id: profile.id.0,
            title: profile.key,
            body: profile.value,
            recorded_at_ms: profile.recorded_at,
            evidence_ids: Vec::new(),
        })
        .collect::<Vec<_>>();
    items.extend(
        memory
            .database
            .reviews(ReviewsInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                limit,
            })
            .map_err(|error_value| error_value.to_string())?
            .into_iter()
            .map(|review| MemoryItem {
                kind: "daily_review".to_owned(),
                id: review.id.0,
                title: review.day,
                body: review.summary,
                recorded_at_ms: review.recorded_at,
                evidence_ids: review.evidence_ids.into_iter().map(|id| id.0).collect(),
            }),
    );
    items.sort_by(|left, right| {
        right
            .recorded_at_ms
            .cmp(&left.recorded_at_ms)
            .then_with(|| left.id.cmp(&right.id))
    });
    items.truncate(limit.clamp(1, 100) as usize);
    Ok(items)
}

fn temporal_query(
    valid_at: Option<i64>,
    recorded_at: Option<i64>,
) -> Result<Option<zkr::TemporalQuery>, &'static str> {
    match (valid_at, recorded_at) {
        (None, None) => Ok(None),
        (Some(valid_at), Some(recorded_at)) => Ok(Some(zkr::TemporalQuery {
            valid_at,
            recorded_at,
        })),
        _ => Err("historical search requires both valid_at and recorded_at"),
    }
}

#[allow(clippy::too_many_arguments)]
async fn correct_memory(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    claim_id: String,
    text: String,
    value: String,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    cancellation: &CancellationToken,
) {
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before correcting it",
            true,
        );
        return;
    };
    let task = spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        correct_configured_memory(
            &mut memory,
            claim_id,
            text,
            value,
            occurred_at_ms,
            recorded_at_ms,
        )
    });
    match await_mutating_blocking(task, cancellation).await {
        BlockingOutcome::Complete(corrected) => NativeEvent::MemoryCorrected(MemoryCorrected {
            request_id: request_id.to_owned(),
            source_id: corrected.source_id.0,
            evidence_id: corrected.evidence_id.0,
            claim_id: corrected.claim_id.0,
            superseded_claim_id: corrected.superseded_claim_id.0,
        })
        .send(),
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_correction_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

async fn delete_memory_source(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    source_id: String,
    deleted_at_ms: i64,
    cancellation: &CancellationToken,
) {
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before deleting from it",
            true,
        );
        return;
    };
    let task = spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        delete_configured_memory_source(&mut memory, source_id, deleted_at_ms)
    });
    match await_mutating_blocking(task, cancellation).await {
        BlockingOutcome::Complete(deleted) => {
            NativeEvent::MemorySourceDeleted(MemorySourceDeleted {
                request_id: request_id.to_owned(),
                source_id: deleted.source_id.0,
                evidence_count: deleted.evidence_count,
                claim_count: deleted.claim_count,
            })
            .send();
        }
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_deletion_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn correct_configured_memory(
    memory: &mut MemoryContext,
    claim_id: String,
    text: String,
    value: String,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
) -> Result<zkr::Corrected, String> {
    memory
        .database
        .correct(CorrectInput {
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            claim_id: ClaimId(claim_id),
            text,
            value,
            valid_at: occurred_at_ms,
            recorded_at: recorded_at_ms,
        })
        .map_err(|error_value| error_value.to_string())
}

fn delete_configured_memory_source(
    memory: &mut MemoryContext,
    source_id: String,
    deleted_at_ms: i64,
) -> Result<zkr::Deleted, String> {
    memory
        .database
        .delete_source(DeleteInput {
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            source_id: SourceId(source_id),
            deleted_at: deleted_at_ms,
        })
        .map_err(|error_value| error_value.to_string())
}

enum BlockingOutcome<T> {
    Complete(T),
    Failed(String),
    Cancelled,
}

async fn await_blocking<T>(
    mut task: JoinHandle<Result<T, String>>,
    cancellation: &CancellationToken,
) -> BlockingOutcome<T>
where
    T: Send + 'static,
{
    tokio::select! {
        biased;
        () = cancellation.cancelled() => match task.await {
            Ok(_) | Err(_) => BlockingOutcome::Cancelled,
        },
        result = &mut task => match result {
            Ok(Ok(value)) => BlockingOutcome::Complete(value),
            Ok(Err(message)) => BlockingOutcome::Failed(message),
            Err(join_error) => BlockingOutcome::Failed(join_error.to_string()),
        },
    }
}

async fn await_mutating_blocking<T>(
    mut task: JoinHandle<Result<T, String>>,
    cancellation: &CancellationToken,
) -> BlockingOutcome<T>
where
    T: Send + 'static,
{
    tokio::select! {
        biased;
        () = cancellation.cancelled() => match task.await {
            Ok(_) | Err(_) => BlockingOutcome::Cancelled,
        },
        result = &mut task => match result {
            Ok(Ok(value)) => BlockingOutcome::Complete(value),
            Ok(Err(message)) => BlockingOutcome::Failed(message),
            Err(join_error) => BlockingOutcome::Failed(join_error.to_string()),
        },
    }
}

async fn cancel(active: &Mutex<HashMap<String, ActiveCommand>>, request_id: &str) {
    if let Some(command) = active.lock().await.get(request_id) {
        command.cancellation.cancel();
    } else {
        error(
            Some(request_id.to_owned()),
            "request_not_found",
            "no active request matched request_id",
            false,
        );
    }
}

fn capture_text(
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
) -> Option<String> {
    let mut parts = [application, window_title, text]
        .into_iter()
        .flatten()
        .filter_map(|value| {
            let value = value.trim();
            (!value.is_empty()).then(|| value.to_owned())
        });
    let first = parts.next()?;
    Some(parts.fold(first, |mut output, part| {
        output.push_str("\n\n");
        output.push_str(&part);
        output
    }))
}

fn source_kind(source: CaptureSource) -> SourceKind {
    match source {
        CaptureSource::Screen | CaptureSource::Clipboard | CaptureSource::Accessibility => {
            SourceKind::Screen
        }
        CaptureSource::OmiDevice => SourceKind::Audio,
        CaptureSource::Chat => SourceKind::Conversation,
    }
}

fn progress(request_id: &str, tool: &str, status: ToolStatus, detail: Option<&str>) {
    NativeEvent::ToolProgress(ToolProgress {
        request_id: request_id.to_owned(),
        tool: tool.to_owned(),
        status,
        detail: detail.map(str::to_owned),
    })
    .send();
}

fn cancelled(request_id: &str) {
    progress(
        request_id,
        "request",
        ToolStatus::Cancelled,
        Some("request cancelled"),
    );
}

fn error(request_id: Option<String>, code: &str, message: &str, retryable: bool) {
    NativeEvent::Error(NativeError {
        request_id,
        code: code.to_owned(),
        message: message.to_owned(),
        retryable,
    })
    .send();
}

async fn approve_and_execute_computer_use(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    proposal_id: &str,
    generation: u64,
    cancellation: &CancellationToken,
) {
    if cancellation.is_cancelled() {
        approval_execution_acknowledgement(request_id, proposal_id, false);
        cancelled(request_id);
        return;
    }
    if !computer_use_available() {
        approval_execution_acknowledgement(request_id, proposal_id, false);
        error(
            Some(request_id.to_owned()),
            "computer_use_unavailable",
            "computer use permissions or platform support are unavailable",
            true,
        );
        return;
    }
    let action = {
        let mut state = state.lock().await;
        if cancellation.is_cancelled() {
            approval_execution_acknowledgement(request_id, proposal_id, false);
            cancelled(request_id);
            return;
        }
        if state.configuration_generation != generation {
            approval_execution_acknowledgement(request_id, proposal_id, false);
            cancelled(request_id);
            return;
        }
        let Some(uid) = state.authority_uid.clone() else {
            approval_execution_acknowledgement(request_id, proposal_id, false);
            error(
                Some(request_id.to_owned()),
                "proposal_not_found",
                "no action proposal authority is configured",
                false,
            );
            return;
        };
        state
            .proposals
            .approve_and_take_action(proposal_id, &uid, generation, unix_time_ms())
            .map_err(|failure| match failure {
                ProposalDecisionError::NotFound => (
                    "proposal_not_found",
                    "no matching action proposal is active",
                ),
                ProposalDecisionError::WrongAuthority => (
                    "proposal_authority_changed",
                    "the proposal belongs to a different authority",
                ),
                ProposalDecisionError::NoAction => (
                    "proposal_action_missing",
                    "the proposal has no executable computer action",
                ),
                ProposalDecisionError::Expired => {
                    ("proposal_expired", "the action proposal has expired")
                }
                ProposalDecisionError::AlreadyDecided
                | ProposalDecisionError::Capacity
                | ProposalDecisionError::Conflict => (
                    "proposal_not_approved",
                    "the computer action is not approved for execution",
                ),
            })
    };
    let action = match action {
        Ok(action) => action,
        Err((code, message)) => {
            approval_execution_acknowledgement(request_id, proposal_id, false);
            error(Some(request_id.to_owned()), code, message, false);
            return;
        }
    };
    approval_execution_acknowledgement(request_id, proposal_id, true);
    if cancellation.is_cancelled() {
        cancelled(request_id);
        return;
    }
    let worker_cancellation = cancellation.clone();
    let task = spawn_blocking(move || execute_computer_use(action, &worker_cancellation));
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(()) => {
            if state.lock().await.configuration_generation == generation
                && !cancellation.is_cancelled()
            {
                progress(
                    request_id,
                    "computer_use",
                    ToolStatus::Complete,
                    Some("approved computer action completed"),
                );
            } else {
                cancelled(request_id);
            }
        }
        BlockingOutcome::Failed(message) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_failed",
                &message,
                false,
            );
        }
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn approval_execution_acknowledgement(request_id: &str, proposal_id: &str, accepted: bool) {
    NativeEvent::ApprovalExecutionAcknowledged(ApprovalExecutionAcknowledgement {
        request_id: request_id.to_owned(),
        proposal_id: proposal_id.to_owned(),
        accepted,
    })
    .send();
}

fn acknowledge_approval_execution_rejection(command: &Command, request_id: &str) {
    if let Command::ApproveAndExecuteComputerUse { proposal_id } = command {
        approval_execution_acknowledgement(request_id, proposal_id, false);
    }
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn computer_use_available() -> bool {
    let permissions = rs_peekaboo::Peekaboo::new().permissions();
    permissions
        .get("accessibility")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
        && permissions
            .get("screen_recording")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
fn computer_use_available() -> bool {
    false
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn execute_computer_use(
    action: ComputerUseAction,
    cancellation: &CancellationToken,
) -> Result<(), String> {
    if cancellation.is_cancelled() {
        return Err("computer action was cancelled".to_owned());
    }
    let peekaboo = rs_peekaboo::Peekaboo::new();
    let result = match action {
        ComputerUseAction::Click {
            x,
            y,
            button,
            count,
        } => {
            if !(1..=3).contains(&count) {
                return Err("click count must be between 1 and 3".to_owned());
            }
            let button = match button {
                crate::signals::MouseButton::Left => "left",
                crate::signals::MouseButton::Right => "right",
                crate::signals::MouseButton::Middle => "middle",
            };
            peekaboo.click(
                rs_peekaboo::automation::Target::Point(rs_peekaboo::Point { x, y }),
                button,
                count,
            )
        }
        ComputerUseAction::TypeText {
            text,
            clear,
            press_return,
            delay_ms,
        } => {
            if !valid_computer_type(&text, delay_ms) {
                return Err("type action parameters are invalid".to_owned());
            }
            let deadline = Instant::now() + Duration::from_millis(MAX_COMPUTER_TYPE_DURATION_MS);
            if clear {
                peekaboo
                    .type_text("", true, false, None, None)
                    .map_err(|failure| failure.to_string())?;
            }
            let chunk_chars = if delay_ms.is_some() { 1 } else { 64 };
            let mut chunk = String::new();
            for character in text.chars() {
                if cancellation.is_cancelled() || Instant::now() >= deadline {
                    return Err("computer action was cancelled".to_owned());
                }
                chunk.push(character);
                if chunk.chars().count() == chunk_chars {
                    peekaboo
                        .type_text(&chunk, false, false, delay_ms, None)
                        .map_err(|failure| failure.to_string())?;
                    chunk.clear();
                }
            }
            if !chunk.is_empty() {
                peekaboo
                    .type_text(&chunk, false, false, delay_ms, None)
                    .map_err(|failure| failure.to_string())?;
            }
            if cancellation.is_cancelled() || Instant::now() >= deadline {
                return Err("computer action was cancelled".to_owned());
            }
            if press_return {
                peekaboo.type_text("", false, true, None, None)
            } else {
                Ok(serde_json::Value::Null)
            }
        }
    };
    result.map(|_| ()).map_err(|failure| failure.to_string())
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
fn execute_computer_use(
    _action: ComputerUseAction,
    _cancellation: &CancellationToken,
) -> Result<(), String> {
    Err("computer use is unavailable on this platform".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::AudioEncoding;
    use std::sync::atomic::{AtomicBool, Ordering};

    fn lifecycle_memory(label: &str) -> (std::path::PathBuf, MemoryContext, zkr::Remembered) {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-{label}-{}-{}.sqlite3",
            std::process::id(),
            unix_time_ms()
        ));
        let mut memory = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        let remembered = memory
            .database
            .remember(RememberInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                ingestion_key: Some(format!("{label}-capture")),
                kind: SourceKind::Conversation,
                text: "I work at Acme".to_owned(),
                captured_at: 10,
                recorded_at: 10,
                claim: Some(zkr::ClaimInput {
                    subject: "person-1".to_owned(),
                    predicate: "employer".to_owned(),
                    value: "Acme".to_owned(),
                    kind: zkr::ClaimKind::Fact,
                    valid_from: 10,
                }),
            })
            .unwrap_or_else(|error_value| panic!("memory is seeded: {error_value}"));
        (path, memory, remembered)
    }

    #[test]
    fn firebase_uid_is_the_only_configured_memory_scope() {
        assert_eq!(firebase_memory_scope("user-a", "user-a"), Ok("user-a"));
        assert!(firebase_memory_scope("tenant-a", "person-a").is_err());
        assert!(firebase_memory_scope("", "").is_err());
    }

    #[test]
    fn configured_memory_exports_and_lists_native_items_without_reimplementing_zkr() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-export-{}-{}.sqlite3",
            std::process::id(),
            unix_time_ms()
        ));
        let uid = "firebase-user";
        let mut memory = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new(uid)
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new(uid)
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        let remembered = memory
            .database
            .remember(RememberInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                ingestion_key: Some("profile-capture".to_owned()),
                kind: SourceKind::Conversation,
                text: "I work at Acme".to_owned(),
                captured_at: 10,
                recorded_at: 10,
                claim: Some(zkr::ClaimInput {
                    subject: uid.to_owned(),
                    predicate: "employer".to_owned(),
                    value: "Acme".to_owned(),
                    kind: zkr::ClaimKind::ProfileFact,
                    valid_from: 10,
                }),
            })
            .unwrap_or_else(|error_value| panic!("memory seeds: {error_value}"));
        memory
            .database
            .store_profile(zkr::ProfileInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                stability: zkr::ProfileStability::Current,
                claim_id: remembered
                    .claim_id
                    .clone()
                    .unwrap_or_else(|| panic!("claim exists")),
                recorded_at: 11,
            })
            .unwrap_or_else(|error_value| panic!("profile stores: {error_value}"));
        memory
            .database
            .store_review(zkr::ReviewInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                day: "2026-07-21".to_owned(),
                summary: "Worked at Acme".to_owned(),
                evidence_ids: vec![remembered.evidence_id],
                recorded_at: 12,
            })
            .unwrap_or_else(|error_value| panic!("review stores: {error_value}"));

        let page = export_configured_memory(&mut memory, 0, -1, None, 100)
            .unwrap_or_else(|error_value| panic!("memory exports: {error_value}"));
        assert!(page.complete);
        assert_eq!(page.export_format, EXPORT_FORMAT_VERSION);
        let event = memory_exported("export-1", page)
            .unwrap_or_else(|error_value| panic!("event maps: {error_value}"));
        assert!(
            event
                .commits
                .iter()
                .all(|commit| !commit.records_json.is_empty())
        );
        assert!(
            event
                .commits
                .iter()
                .flat_map(|commit| &commit.records_json)
                .all(|record| {
                    serde_json::from_str::<serde_json::Value>(record).is_ok_and(|value| {
                        let serialized = value.to_string();
                        serialized.contains(uid) && !serialized.contains("firebase_token")
                    })
                })
        );
        let items = list_configured_memory_items(&memory, 10)
            .unwrap_or_else(|error_value| panic!("memory lists: {error_value}"));
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].kind, "daily_review");
        assert_eq!(items[1].kind, "profile");

        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[test]
    fn memory_search_defaults_current_and_requires_a_complete_historical_point() {
        assert!(temporal_query(None, None).is_ok_and(|query| query.is_none()));
        assert!(temporal_query(Some(10), None).is_err());
        assert!(temporal_query(None, Some(11)).is_err());
        assert!(temporal_query(Some(10), Some(11)).is_ok_and(|query| {
            query.is_some_and(|point| point.valid_at == 10 && point.recorded_at == 11)
        }));
    }

    #[test]
    fn lifecycle_commands_cannot_cross_configured_tenant_or_person() {
        let (path, mut memory, _) = lifecycle_memory("lifecycle-scope");
        for (tenant_id, person_id) in [("tenant-2", "person-1"), ("tenant-1", "person-2")] {
            let outside = memory
                .database
                .remember(RememberInput {
                    tenant_id: TenantId::new(tenant_id)
                        .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
                    person_id: PersonId::new(person_id)
                        .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
                    ingestion_key: Some(format!("outside-{tenant_id}-{person_id}")),
                    kind: SourceKind::Conversation,
                    text: "I work at Outside".to_owned(),
                    captured_at: 10,
                    recorded_at: 10,
                    claim: Some(zkr::ClaimInput {
                        subject: person_id.to_owned(),
                        predicate: "employer".to_owned(),
                        value: "Outside".to_owned(),
                        kind: zkr::ClaimKind::Fact,
                        valid_from: 10,
                    }),
                })
                .unwrap_or_else(|error_value| panic!("outside memory is seeded: {error_value}"));
            assert!(
                correct_configured_memory(
                    &mut memory,
                    outside.claim_id.unwrap_or_else(|| panic!("claim exists")).0,
                    "Correction".to_owned(),
                    "Changed".to_owned(),
                    20,
                    21,
                )
                .is_err()
            );
            assert!(delete_configured_memory_source(&mut memory, outside.source_id.0, 20).is_err());
        }
        drop(memory);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[test]
    fn correction_result_keeps_cited_provenance() {
        let (path, mut memory, remembered) = lifecycle_memory("lifecycle-citation");
        let corrected = correct_configured_memory(
            &mut memory,
            remembered
                .claim_id
                .unwrap_or_else(|| panic!("claim exists"))
                .0,
            "I moved to Beta".to_owned(),
            "Beta".to_owned(),
            20,
            21,
        )
        .unwrap_or_else(|error_value| panic!("correction succeeds: {error_value}"));
        let results = memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query: "Beta".to_owned(),
                limit: 5,
                query_embedding: None,
                as_of: None,
            })
            .unwrap_or_else(|error_value| panic!("search succeeds: {error_value}"));
        assert!(!results.items.is_empty());
        assert!(
            results
                .items
                .iter()
                .all(|item| item.evidence_ids == vec![corrected.evidence_id.clone()])
        );
        let stale = memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query: "Acme".to_owned(),
                limit: 5,
                query_embedding: None,
                as_of: None,
            })
            .unwrap_or_else(|error_value| panic!("search succeeds: {error_value}"));
        assert!(stale.items.is_empty());
        drop(memory);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[test]
    fn correction_rejects_stale_evidence_time() {
        let (path, mut memory, remembered) = lifecycle_memory("lifecycle-stale");
        assert!(
            correct_configured_memory(
                &mut memory,
                remembered
                    .claim_id
                    .unwrap_or_else(|| panic!("claim exists"))
                    .0,
                "Stale correction".to_owned(),
                "Beta".to_owned(),
                10,
                11,
            )
            .is_err()
        );
        drop(memory);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[test]
    fn source_deletion_propagates_to_evidence_claims_and_search() {
        let (path, mut memory, remembered) = lifecycle_memory("lifecycle-delete");
        let deleted = delete_configured_memory_source(&mut memory, remembered.source_id.0, 20)
            .unwrap_or_else(|error_value| panic!("deletion succeeds: {error_value}"));
        assert_eq!((deleted.evidence_count, deleted.claim_count), (1, 1));
        let results = memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query: "Acme".to_owned(),
                limit: 5,
                query_embedding: None,
                as_of: None,
            })
            .unwrap_or_else(|error_value| panic!("search succeeds: {error_value}"));
        assert!(results.items.is_empty());
        drop(memory);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[test]
    fn transcript_capture_persists_scoped_evidence_locator() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-locator-{}-{}.sqlite3",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |duration| duration.as_nanos())
        ));
        let mut memory = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        let remembered = remember_capture(
            &mut memory,
            "stream-1-segment-2".to_owned(),
            CaptureSource::OmiDevice,
            2_000,
            2_001,
            "Remember this".to_owned(),
            Some(TranscriptLocator {
                device_id: "omi-1".to_owned(),
                provider: "deepgram".to_owned(),
                stream_id: "stream-1".to_owned(),
                segment_id: "segment-2".to_owned(),
                start_ms: 1_000,
                end_ms: 2_000,
            }),
        )
        .unwrap_or_else(|error_value| panic!("capture succeeds: {error_value}"));
        assert!(
            remember_capture(
                &mut memory,
                "stream-1-segment-2".to_owned(),
                CaptureSource::OmiDevice,
                2_000,
                2_001,
                "Remember this".to_owned(),
                Some(TranscriptLocator {
                    device_id: "omi-1".to_owned(),
                    provider: "deepgram".to_owned(),
                    stream_id: "stream-1".to_owned(),
                    segment_id: "changed-segment".to_owned(),
                    start_ms: 1_000,
                    end_ms: 2_000,
                }),
            )
            .is_err()
        );
        let locator = memory
            .database
            .evidence_locator(zkr::EvidenceLocatorInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                evidence_id: remembered.evidence_id.clone(),
            })
            .unwrap_or_else(|error_value| panic!("locator reads: {error_value}"))
            .unwrap_or_else(|| panic!("locator exists"));
        assert_eq!(locator.device_id, "omi-1");
        assert_eq!(locator.provider, "deepgram");
        assert_eq!(locator.stream_id, "stream-1");
        assert_eq!(locator.segment_id, "segment-2");
        assert_eq!((locator.start_ms, locator.end_ms), (1_000, 2_000));
        let before_recording = memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query: "Remember this".to_owned(),
                limit: 5,
                query_embedding: None,
                as_of: Some(zkr::TemporalQuery {
                    valid_at: 2_000,
                    recorded_at: 2_000,
                }),
            })
            .unwrap_or_else(|error_value| panic!("historical search succeeds: {error_value}"));
        assert!(before_recording.items.is_empty());
        let after_recording = memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query: "Remember this".to_owned(),
                limit: 5,
                query_embedding: None,
                as_of: Some(zkr::TemporalQuery {
                    valid_at: 2_000,
                    recorded_at: 2_001,
                }),
            })
            .unwrap_or_else(|error_value| panic!("historical search succeeds: {error_value}"));
        assert_eq!(after_recording.items.len(), 1);
        let point = remember_capture(
            &mut memory,
            "stream-1-segment-3".to_owned(),
            CaptureSource::OmiDevice,
            3_000,
            3_001,
            "Point transcript".to_owned(),
            Some(TranscriptLocator {
                device_id: "omi-1".to_owned(),
                provider: "deepgram".to_owned(),
                stream_id: "stream-1".to_owned(),
                segment_id: "segment-3".to_owned(),
                start_ms: 3_000,
                end_ms: 3_000,
            }),
        )
        .unwrap_or_else(|error_value| panic!("point capture succeeds: {error_value}"));
        let point_locator = memory
            .database
            .evidence_locator(zkr::EvidenceLocatorInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                evidence_id: point.evidence_id,
            })
            .unwrap_or_else(|error_value| panic!("point locator reads: {error_value}"))
            .unwrap_or_else(|| panic!("point locator exists"));
        assert_eq!(
            (point_locator.start_ms, point_locator.end_ms),
            (3_000, 3_000)
        );
        let leaked = memory
            .database
            .evidence_locator(zkr::EvidenceLocatorInput {
                tenant_id: TenantId::new("tenant-2")
                    .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
                person_id: memory.person_id.clone(),
                evidence_id: remembered.evidence_id,
            })
            .unwrap_or_else(|error_value| panic!("scoped locator reads: {error_value}"));
        assert!(leaked.is_none());
        drop(memory);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    struct FakeAssistantProvider {
        events: StdMutex<Option<Vec<AssistantProviderEvent>>>,
    }

    impl AssistantProvider for FakeAssistantProvider {
        fn dispatch(
            &self,
            _request_id: String,
            _text: String,
            _cancellation: CancellationToken,
        ) -> mpsc::Receiver<Result<AssistantProviderEvent, String>> {
            let events = self
                .events
                .lock()
                .unwrap_or_else(|failure| failure.into_inner())
                .take()
                .unwrap_or_default();
            let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
            tokio::spawn(async move {
                for event in events {
                    if sender.send(Ok(event)).await.is_err() {
                        return;
                    }
                }
            });
            receiver
        }
    }

    struct ReconfiguringAssistantProvider {
        state: Arc<Mutex<RuntimeState>>,
        proposal: StdMutex<Option<ActionProposal>>,
    }

    impl AssistantProvider for ReconfiguringAssistantProvider {
        fn dispatch(
            &self,
            _request_id: String,
            _text: String,
            _cancellation: CancellationToken,
        ) -> mpsc::Receiver<Result<AssistantProviderEvent, String>> {
            let state = Arc::clone(&self.state);
            let proposal = self
                .proposal
                .lock()
                .unwrap_or_else(|failure| failure.into_inner())
                .take()
                .unwrap_or_else(|| panic!("fake proposal exists"));
            let (sender, receiver) = mpsc::channel(1);
            tokio::spawn(async move {
                state.lock().await.configuration_generation += 1;
                let _ = sender
                    .send(Ok(AssistantProviderEvent::Proposal(proposal)))
                    .await;
            });
            receiver
        }
    }

    fn action_proposal(id: &str, parent: &str, expires_at_ms: i64) -> ActionProposal {
        ActionProposal {
            proposal_id: id.to_owned(),
            request_id: parent.to_owned(),
            title: "Create task".to_owned(),
            summary: "Add a task".to_owned(),
            risk: ActionRisk::External,
            computer_action: None,
            expires_at_ms: Some(expires_at_ms),
        }
    }

    #[test]
    fn computer_use_tool_calls_are_strict_and_proposal_bound() {
        let proposal = computer_use_proposal(
            "chat-1",
            "call_1",
            COMPUTER_CLICK_TOOL,
            serde_json::json!({
                "x": -20,
                "y": 40,
                "button": "left",
                "count": 2
            }),
        )
        .unwrap_or_else(|failure| panic!("valid click proposal: {failure}"));

        assert_eq!(proposal.proposal_id, "chat-1:tool:call_1");
        assert_eq!(proposal.request_id, "chat-1");
        assert_eq!(proposal.risk, ActionRisk::External);
        assert_eq!(
            proposal.computer_action,
            Some(ComputerUseAction::Click {
                x: -20,
                y: 40,
                button: crate::signals::MouseButton::Left,
                count: 2,
            })
        );
        assert!(proposal.expires_at_ms.is_some());
    }

    #[test]
    fn computer_use_tool_calls_reject_unknown_or_unsafe_arguments() {
        for arguments in [
            serde_json::json!({
                "text": "hello",
                "clear": false,
                "press_return": false,
                "unexpected": true
            }),
            serde_json::json!({
                "text": "",
                "clear": false,
                "press_return": false
            }),
            serde_json::json!({
                "text": "hello",
                "clear": false,
                "press_return": false,
                "delay_ms": 1001
            }),
        ] {
            assert!(
                computer_use_proposal("chat-1", "call_1", COMPUTER_TYPE_TOOL, arguments).is_err()
            );
        }
        assert!(
            computer_use_proposal(
                "chat-1",
                "call/1",
                COMPUTER_CLICK_TOOL,
                serde_json::json!({
                    "x": 1,
                    "y": 2,
                    "button": "left",
                    "count": 1
                }),
            )
            .is_err()
        );
    }

    #[test]
    fn production_provider_constructor_accepts_byok_and_authenticated_worker_config() {
        let byok = HashMap::from([
            ("OMI_AI_PROVIDER", "xai"),
            ("OMI_AI_MODEL", "grok-4"),
            ("OMI_AI_API_KEY", "secret-byok"),
        ]);
        assert!(
            configured_assistant_provider(|name| byok.get(name).map(ToString::to_string))
                .unwrap_or_else(|failure| panic!("BYOK provider configures: {failure}"))
                .is_some()
        );

        let worker = HashMap::from([
            ("OMI_AI_PROVIDER", "worker"),
            ("OMI_AI_MODEL", "managed-chat"),
            ("OMI_AI_AUTH_TOKEN", "firebase-session-token"),
            ("OMI_AI_ENDPOINT", "https://assistant.example.test/v1"),
            ("OMI_MANAGED_AI_ORIGINS", "https://assistant.example.test"),
        ]);
        assert!(
            configured_assistant_provider(|name| worker.get(name).map(ToString::to_string))
                .unwrap_or_else(|failure| panic!("Worker provider configures: {failure}"))
                .is_some()
        );

        let insecure = AssistantProviderConfig::from_runtime(
            ProviderKind::Worker,
            "managed-chat".to_owned(),
            Some("http://assistant.example.test/v1".to_owned()),
            "must-not-appear-in-errors".to_owned(),
            Some("https://assistant.example.test"),
        );
        let failure = insecure
            .err()
            .unwrap_or_else(|| panic!("insecure Worker endpoint is rejected"));
        assert!(!failure.contains("must-not-appear-in-errors"));
        assert!(failure.contains("HTTPS"));
    }

    #[test]
    fn assistant_endpoint_policy_rejects_unsafe_urls_and_separates_managed_origins() {
        for endpoint in [
            "https://user:pass@example.com/v1",
            "https://example.com/v1?target=internal",
            "https://example.com/v1#fragment",
            "https://127.0.0.1/v1",
            "https://[::1]/v1",
            "https://service.local/v1",
        ] {
            assert!(validate_endpoint(endpoint, false, None).is_err());
        }
        assert!(validate_endpoint("https://api.example.com/v1", false, None).is_ok());
        assert!(
            validate_endpoint(
                "https://managed.example.com/v1",
                true,
                Some("https://other.example.com"),
            )
            .is_err()
        );
        assert!(
            validate_endpoint(
                "https://managed.example.com/v1",
                true,
                Some("https://managed.example.com"),
            )
            .is_ok()
        );
        assert!(!public_ip(IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1))));
        assert!(!public_ip(IpAddr::V4(Ipv4Addr::new(169, 254, 1, 1))));
        assert!(!public_ip(IpAddr::V6(Ipv6Addr::LOCALHOST)));
        assert!(public_ip(IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1))));
        assert_eq!(
            managed_worker_base("https://managed.example.com").as_deref(),
            Ok("https://managed.example.com/v1")
        );
        assert!(
            AssistantProviderConfig::from_runtime(
                ProviderKind::Worker,
                "managed-chat".to_owned(),
                Some("https://managed.example.com/v1".to_owned()),
                "session-token".to_owned(),
                Some("https://managed.example.com"),
            )
            .is_ok()
        );
        assert!(
            AssistantProviderConfig::from_runtime(
                ProviderKind::Worker,
                "managed-chat".to_owned(),
                Some("https://attacker.example.com/v1".to_owned()),
                "session-token".to_owned(),
                Some("https://managed.example.com"),
            )
            .is_err()
        );
    }

    #[tokio::test]
    async fn stalled_provider_receive_times_out_and_cancellation_wins() {
        let (_sender, mut receiver) = mpsc::channel(1);
        assert!(matches!(
            receive_provider_event(
                &mut receiver,
                &CancellationToken::new(),
                Duration::from_millis(5),
            )
            .await,
            ProviderReceive::TimedOut
        ));
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        assert!(matches!(
            receive_provider_event(&mut receiver, &cancellation, Duration::from_secs(1)).await,
            ProviderReceive::Cancelled
        ));
    }

    fn fingerprint(text: &str, occurred_at_ms: i64) -> CaptureFingerprint {
        CaptureFingerprint {
            ingestion_key: "transcript-1".to_owned(),
            source: CaptureSource::OmiDevice,
            occurred_at_ms,
            recorded_at_ms: occurred_at_ms + 1,
            text: Some(text.to_owned()),
            application: None,
            window_title: None,
            transcript_locator: None,
        }
    }

    fn active_command() -> ActiveCommand {
        ActiveCommand {
            cancellation: CancellationToken::new(),
            capture: None,
            authority_generation: 0,
        }
    }

    #[test]
    fn capture_preserves_available_context() {
        assert_eq!(
            capture_text(
                Some("selected text".to_owned()),
                Some("Browser".to_owned()),
                Some("Memory".to_owned())
            ),
            Some("Browser\n\nMemory\n\nselected text".to_owned())
        );
        assert_eq!(capture_text(None, None, None), None);
    }

    #[test]
    fn capture_retry_reuses_one_durable_source_and_evidence() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-capture-retry-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |duration| duration.as_nanos())
        ));
        let open = || {
            MemoryDb::open(&path)
                .map(|database| MemoryContext {
                    database,
                    tenant_id: TenantId::new("tenant-1")
                        .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
                    person_id: PersonId::new("person-1")
                        .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
                })
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}"))
        };
        let mut first_database = open();
        let first = remember_capture(
            &mut first_database,
            "capture-1".to_owned(),
            CaptureSource::Screen,
            1,
            2,
            "first capture".to_owned(),
            None,
        )
        .unwrap_or_else(|error_value| panic!("first capture succeeds: {error_value}"));
        drop(first_database);

        let mut reopened_database = open();
        let replay = remember_capture(
            &mut reopened_database,
            "capture-1".to_owned(),
            CaptureSource::Screen,
            1,
            2,
            "first capture".to_owned(),
            None,
        )
        .unwrap_or_else(|error_value| panic!("capture replay succeeds: {error_value}"));
        assert_eq!(replay.source_id, first.source_id);
        assert_eq!(replay.evidence_id, first.evidence_id);
        drop(reopened_database);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("test database is removed: {error_value}"));
    }

    #[tokio::test]
    async fn cancellation_targets_active_request() {
        let active = Mutex::new(HashMap::from([(
            "request-1".to_owned(),
            ActiveCommand {
                cancellation: CancellationToken::new(),
                capture: None,
                authority_generation: 0,
            },
        )]));
        cancel(&active, "request-1").await;
        assert!(active.lock().await["request-1"].cancellation.is_cancelled());
    }

    #[tokio::test]
    async fn cancellation_wins_before_a_blocking_result_is_published() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        let task = spawn_blocking(|| Ok::<_, String>("late result"));

        assert!(matches!(
            await_blocking(task, &cancellation).await,
            BlockingOutcome::Cancelled
        ));
    }

    #[tokio::test]
    async fn mutating_cancellation_waits_for_the_side_effect() {
        let cancellation = CancellationToken::new();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_in_task = Arc::clone(&completed);
        let task = spawn_blocking(move || {
            std::thread::sleep(Duration::from_millis(10));
            completed_in_task.store(true, Ordering::SeqCst);
            Ok::<_, String>(())
        });
        cancellation.cancel();

        assert!(matches!(
            await_mutating_blocking(task, &cancellation).await,
            BlockingOutcome::Cancelled
        ));
        assert!(completed.load(Ordering::SeqCst));
    }

    #[test]
    fn active_commands_are_bounded_and_duplicates_are_distinct() {
        let mut active = HashMap::new();
        for index in 0..MAX_ACTIVE_COMMANDS {
            assert_eq!(
                activate(
                    &mut active,
                    format!("request-{index}"),
                    CancellationToken::new(),
                    None,
                    0,
                ),
                Ok(true)
            );
        }
        assert_eq!(
            activate(
                &mut active,
                "request-0".to_owned(),
                CancellationToken::new(),
                None,
                0,
            ),
            Err(ActivationError::Duplicate)
        );
        assert_eq!(
            activate(
                &mut active,
                "request-overflow".to_owned(),
                CancellationToken::new(),
                None,
                0,
            ),
            Err(ActivationError::Capacity)
        );
    }

    #[test]
    fn duplicate_capture_requests_coalesce_while_active() {
        let mut active = HashMap::new();
        assert_eq!(
            activate(
                &mut active,
                "capture-1".to_owned(),
                CancellationToken::new(),
                Some(fingerprint("remember this", 1)),
                0,
            ),
            Ok(true)
        );
        assert_eq!(
            activate(
                &mut active,
                "capture-1".to_owned(),
                CancellationToken::new(),
                Some(fingerprint("remember this", 1)),
                0,
            ),
            Ok(false)
        );
        assert_eq!(
            activate(
                &mut active,
                "capture-1".to_owned(),
                CancellationToken::new(),
                Some(fingerprint("changed", 1)),
                0,
            ),
            Err(ActivationError::Conflict)
        );
        assert_eq!(
            activate(
                &mut active,
                "capture-1".to_owned(),
                CancellationToken::new(),
                Some(fingerprint("remember this", 2)),
                0,
            ),
            Err(ActivationError::Conflict)
        );
        let mut changed_source = fingerprint("remember this", 1);
        changed_source.source = CaptureSource::Screen;
        assert_eq!(
            activate(
                &mut active,
                "capture-1".to_owned(),
                CancellationToken::new(),
                Some(changed_source),
                0,
            ),
            Err(ActivationError::Conflict)
        );
    }

    #[tokio::test]
    async fn dispatcher_rejects_changed_payload_while_first_capture_holds_database_lock() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-dispatcher-replay-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |duration| duration.as_nanos())
        ));
        let memory = Arc::new(StdMutex::new(MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        }));
        let lock_ready = Arc::new(std::sync::Barrier::new(2));
        let lock_release = Arc::new(std::sync::Barrier::new(2));
        let held_memory = Arc::clone(&memory);
        let holder_ready = Arc::clone(&lock_ready);
        let holder_release = Arc::clone(&lock_release);
        let holder = std::thread::spawn(move || {
            let _held = held_memory
                .lock()
                .unwrap_or_else(|error_value| panic!("memory lock: {error_value}"));
            holder_ready.wait();
            holder_release.wait();
        });
        lock_ready.wait();
        let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        let active = Arc::new(Mutex::new(HashMap::new()));
        let dispatcher = CommandDispatcher {
            receiver,
            state: Arc::new(Mutex::new(RuntimeState {
                memory: Some(Arc::clone(&memory)),
                configuration_generation: 1,
                ..RuntimeState::default()
            })),
            active: Arc::clone(&active),
            assistant_provider: Arc::new(StdMutex::new(Arc::new(UnavailableAssistantProvider {
                reason: "test provider unavailable".to_owned(),
            }))),
            transcription: None,
        };
        let running = tokio::spawn(dispatcher.run());
        let capture = |request_id: &str, text: &str, occurred_at_ms| ClientCommand {
            request_id: request_id.to_owned(),
            command: Command::CaptureEvent {
                ingestion_key: "stable-transcript-1".to_owned(),
                source: CaptureSource::OmiDevice,
                occurred_at_ms,
                recorded_at_ms: occurred_at_ms + 1,
                text: Some(text.to_owned()),
                application: None,
                window_title: None,
                transcript_locator: None,
            },
        };
        sender
            .send(capture("transcript-1", "remember this", 1))
            .await
            .unwrap_or_else(|_| panic!("dispatcher accepts first capture"));
        while !active.lock().await.contains_key("transcript-1") {
            tokio::task::yield_now().await;
        }
        sender
            .send(capture("transcript-1", "remember this", 1))
            .await
            .unwrap_or_else(|_| panic!("dispatcher accepts duplicate capture"));
        sender
            .send(capture("transcript-1", "changed payload", 2))
            .await
            .unwrap_or_else(|_| panic!("dispatcher accepts conflicting capture"));
        tokio::task::yield_now().await;
        assert_eq!(active.lock().await.len(), 1);
        lock_release.wait();
        holder
            .join()
            .unwrap_or_else(|_| panic!("memory lock holder exits"));
        while active.lock().await.contains_key("transcript-1") {
            tokio::task::yield_now().await;
        }
        sender
            .send(capture("transcript-1", "remember this", 1))
            .await
            .unwrap_or_else(|_| panic!("dispatcher accepts completed replay"));
        sender
            .send(capture("transcript-1", "changed after completion", 1))
            .await
            .unwrap_or_else(|_| panic!("dispatcher accepts completed conflict"));
        tokio::task::yield_now().await;
        assert!(active.lock().await.is_empty());
        sender
            .send(capture("transcript-2", "remember this", 1))
            .await
            .unwrap_or_else(|_| panic!("dispatcher accepts stable ingestion replay"));
        while active.lock().await.contains_key("transcript-2") {
            tokio::task::yield_now().await;
        }
        drop(sender);
        running
            .await
            .unwrap_or_else(|error_value| panic!("dispatcher exits: {error_value}"));
        drop(memory);

        let mut reopened = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory reopens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        assert!(
            remember_capture(
                &mut reopened,
                "stable-transcript-1".to_owned(),
                CaptureSource::OmiDevice,
                1,
                2,
                "changed payload".to_owned(),
                None,
            )
            .is_err()
        );
        drop(reopened);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("test database is removed: {error_value}"));
    }

    #[test]
    fn completed_capture_ledger_is_bounded_and_clears_with_authority() {
        let mut completed = CompletedCaptures::default();
        for index in 0..=COMPLETED_CAPTURE_CAPACITY {
            completed.insert(
                format!("capture-{index}"),
                fingerprint("payload", index as i64),
            );
        }
        assert_eq!(
            completed.status("capture-0", &fingerprint("payload", 0)),
            ReplayStatus::Missing
        );
        assert_eq!(
            completed.status("capture-1", &fingerprint("payload", 1)),
            ReplayStatus::Exact
        );
        assert_eq!(
            completed.status("capture-1", &fingerprint("changed", 1)),
            ReplayStatus::Conflict
        );
        let mut changed_recording = fingerprint("payload", 1);
        changed_recording.recorded_at_ms += 1;
        assert_eq!(
            completed.status("capture-1", &changed_recording),
            ReplayStatus::Conflict
        );
        completed.clear();
        assert!(completed.entries.is_empty());
        assert!(completed.order.is_empty());
    }

    #[tokio::test]
    async fn cancelled_capture_waiting_for_memory_never_writes() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-cancelled-capture-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |duration| duration.as_nanos())
        ));
        let memory = Arc::new(StdMutex::new(MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        }));
        let held = memory
            .lock()
            .unwrap_or_else(|error_value| panic!("memory lock: {error_value}"));
        let cancellation = CancellationToken::new();
        let task = spawn_capture(
            Arc::clone(&memory),
            "transcript-1".to_owned(),
            CaptureSource::OmiDevice,
            1,
            2,
            "remember this".to_owned(),
            None,
            cancellation.clone(),
        );
        cancellation.cancel();
        drop(held);
        assert!(matches!(
            await_mutating_blocking(task, &cancellation).await,
            BlockingOutcome::Cancelled
        ));
        drop(memory);

        let mut reopened = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory reopens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        assert!(
            remember_capture(
                &mut reopened,
                "transcript-1".to_owned(),
                CaptureSource::OmiDevice,
                1,
                2,
                "different payload".to_owned(),
                None,
            )
            .is_ok()
        );
        drop(reopened);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("test database is removed: {error_value}"));
    }

    #[tokio::test]
    async fn completed_tasks_are_reaped_before_more_work() {
        let active = Mutex::new(HashMap::from([("request-1".to_owned(), active_command())]));
        let mut tasks = JoinSet::new();
        tasks.spawn(async {
            let outcome = tokio::spawn(async { false }).await;
            ("request-1".to_owned(), outcome)
        });
        tokio::task::yield_now().await;
        reap_ready(&mut tasks, &active, &mut CompletedCaptures::default(), 0).await;
        assert!(tasks.is_empty());
        assert!(active.lock().await.is_empty());
    }

    #[tokio::test]
    async fn panicked_tasks_release_their_active_slot() {
        let active = Mutex::new(HashMap::from([("request-1".to_owned(), active_command())]));
        let mut tasks = JoinSet::new();
        tasks.spawn(async {
            let outcome = tokio::spawn(async { panic!("boom") }).await;
            ("request-1".to_owned(), outcome)
        });
        let joined = tasks.join_next().await;
        reap_joined(joined, &active, &mut CompletedCaptures::default(), 0).await;
        assert!(active.lock().await.is_empty());
    }

    #[tokio::test]
    async fn closed_dispatcher_drains_accepted_commands() {
        let (sender, dispatcher) = CommandDispatcher::channel();
        sender
            .send(ClientCommand {
                request_id: "device-1".to_owned(),
                command: Command::DeviceState {
                    device_id: "omi-1".to_owned(),
                    connected: true,
                    battery_percent: Some(80),
                    firmware_version: None,
                },
            })
            .await
            .unwrap_or_else(|_| panic!("dispatcher must accept a command"));
        drop(sender);
        dispatcher.run().await;
    }

    #[test]
    fn newest_memory_configuration_wins() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-authority-{}-{}.sqlite3",
            std::process::id(),
            unix_time_ms()
        ));
        let memory = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new("old-user")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("old-user")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        let mut state = RuntimeState {
            memory: Some(Arc::new(StdMutex::new(memory))),
            configuration_generation: 2,
            ..RuntimeState::default()
        };
        assert!(!configuration_is_current(&state, 1));
        assert!(configuration_is_current(&state, 2));
        assert_eq!(advance_memory_authority(&mut state, "new-user"), 3);
        assert!(state.memory.is_none());
        assert_eq!(state.authority_uid.as_deref(), Some("new-user"));
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    fn start_audio(sessions: &mut AudioSessions, stream_id: &str) {
        sessions
            .start(StartTranscription {
                request_id: format!("start-{stream_id}"),
                audio_stream_id: stream_id.to_owned(),
                device_id: "omi-1".to_owned(),
                auth: TranscriptionAuth::Byok {
                    endpoint: "wss://api.deepgram.com/v1/listen".to_owned(),
                    api_key: "test-key".to_owned(),
                },
                trusted_worker_origin: None,
                language: "en".to_owned(),
                sample_rate_hz: 16_000,
                channels: 1,
                encoding: AudioEncoding::Opus,
            })
            .unwrap_or_else(|failure| panic!("start failed: {}", failure.message));
    }

    #[test]
    fn local_transcription_fails_before_accepting_audio() {
        let mut sessions = AudioSessions::default();
        let failure = sessions.start(StartTranscription {
            request_id: "start-local".to_owned(),
            audio_stream_id: "local-stream".to_owned(),
            device_id: "omi-1".to_owned(),
            auth: TranscriptionAuth::Local,
            trusted_worker_origin: None,
            language: "en".to_owned(),
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
        });
        assert!(matches!(
            failure,
            Err(AudioAcceptError {
                code: "transcription_local_unavailable",
                ..
            })
        ));
        assert!(matches!(
            sessions.accept(AudioChunk {
                request_id: "local-stream".to_owned(),
                sequence: 0,
                sample_rate_hz: 16_000,
                channels: 1,
                encoding: AudioEncoding::Opus,
                end_of_stream: true,
                bytes: vec![1, 2, 3],
            }),
            Err(AudioAcceptError {
                code: "transcription_not_started",
                ..
            })
        ));
        assert!(sessions.0.is_empty());
    }

    #[test]
    fn audio_consumer_enforces_sequence_and_resets_after_end() {
        let mut sessions = AudioSessions::default();
        start_audio(&mut sessions, "voice-1");
        let chunk = |sequence, end_of_stream| AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream,
            bytes: vec![1, 2, 3],
        };

        let first = sessions.accept(chunk(0, false));
        assert!(matches!(
            first,
            Ok(Some(AudioProgress {
                status: ToolStatus::Running,
                ..
            }))
        ));
        assert!(sessions.accept(chunk(2, false)).is_err());
        let last = sessions.accept(chunk(1, true));
        assert!(matches!(
            last,
            Ok(Some(AudioProgress {
                status: ToolStatus::Complete,
                ..
            }))
        ));
        assert!(matches!(
            sessions.accept(chunk(0, false)),
            Err(AudioAcceptError {
                code: "transcription_not_started",
                ..
            })
        ));
    }

    #[test]
    fn audio_consumer_bounds_active_sessions() {
        let mut sessions = AudioSessions::default();
        for index in 0..MAX_ACTIVE_AUDIO_SESSIONS {
            start_audio(&mut sessions, &format!("voice-{index}"));
            assert!(
                sessions
                    .accept(AudioChunk {
                        request_id: format!("voice-{index}"),
                        sequence: 0,
                        sample_rate_hz: 16_000,
                        channels: 1,
                        encoding: AudioEncoding::Opus,
                        end_of_stream: false,
                        bytes: vec![1],
                    })
                    .is_ok()
            );
        }
        let failure = sessions.start(StartTranscription {
            request_id: "start-overflow".to_owned(),
            audio_stream_id: "one-too-many".to_owned(),
            device_id: "omi-1".to_owned(),
            auth: TranscriptionAuth::Byok {
                endpoint: "wss://api.deepgram.com/v1/listen".to_owned(),
                api_key: "test-key".to_owned(),
            },
            trusted_worker_origin: None,
            language: "en".to_owned(),
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
        });
        assert!(matches!(
            failure,
            Err(AudioAcceptError {
                code: "audio_capacity_exceeded",
                ..
            })
        ));
    }

    #[test]
    fn audio_consumer_rejects_format_drift() {
        let mut sessions = AudioSessions::default();
        start_audio(&mut sessions, "voice-1");
        let started = AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: 0,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![1],
        };
        assert!(sessions.accept(started).is_ok());
        let changed = AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: 1,
            sample_rate_hz: 48_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![1],
        };
        let Err(failure) = sessions.accept(changed) else {
            panic!("format drift must fail");
        };
        assert_eq!(failure.code, "audio_format_changed");
    }

    #[test]
    fn abandoned_audio_sessions_expire() {
        let mut sessions = AudioSessions::default();
        let started_at = Instant::now();
        for index in 0..MAX_ACTIVE_AUDIO_SESSIONS {
            start_audio(&mut sessions, &format!("voice-{index}"));
            assert!(
                sessions
                    .accept_at(
                        AudioChunk {
                            request_id: format!("voice-{index}"),
                            sequence: 0,
                            sample_rate_hz: 16_000,
                            channels: 1,
                            encoding: AudioEncoding::Opus,
                            end_of_stream: false,
                            bytes: vec![1],
                        },
                        started_at,
                    )
                    .is_ok()
            );
        }
        let expired = sessions.accept_at(
            AudioChunk {
                request_id: "voice-0".to_owned(),
                sequence: 1,
                sample_rate_hz: 16_000,
                channels: 1,
                encoding: AudioEncoding::Opus,
                end_of_stream: false,
                bytes: vec![1],
            },
            started_at + AUDIO_SESSION_IDLE_TIMEOUT,
        );
        assert!(matches!(
            expired,
            Err(AudioAcceptError {
                code: "transcription_not_started",
                ..
            })
        ));
        assert!(sessions.0.is_empty());
    }

    #[test]
    fn audio_overflow_does_not_partially_advance_a_session() {
        let mut sessions = AudioSessions(HashMap::from([(
            "voice-1".to_owned(),
            AudioSession {
                start_request_id: "start-voice-1".to_owned(),
                next_sequence: u64::MAX,
                accepted_bytes: 7,
                sample_rate_hz: 16_000,
                channels: 1,
                encoding: AudioEncoding::Opus,
                last_seen: Instant::now(),
                device_id: "omi-1".to_owned(),
                route: TranscriptionRoute::Byok,
                language: "en".to_owned(),
                epoch: 0,
                logical_sequence: 0,
                phase: TranscriptionPhase::Streaming,
                reconnect_buffer: VecDeque::new(),
                reconnect_buffer_bytes: 0,
                provider: None,
            },
        )]));
        let previous_seen = sessions.0["voice-1"].last_seen;
        let failure = sessions.accept(AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: u64::MAX,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![1],
        });
        assert!(matches!(
            failure,
            Err(AudioAcceptError {
                code: "audio_counter_overflow",
                ..
            })
        ));
        let session = &sessions.0["voice-1"];
        assert_eq!(session.next_sequence, u64::MAX);
        assert_eq!(session.accepted_bytes, 7);
        assert_eq!(session.last_seen, previous_seen);
    }

    #[test]
    fn transcript_revisions_keep_identity_and_finals_advance_sequence() {
        let mut sessions = AudioSessions::default();
        start_audio(&mut sessions, "voice-1");
        let interim = sessions
            .transcript(
                "voice-1",
                "voice-1",
                ProviderTranscript {
                    provider: "fake".to_owned(),
                    start_ms: 0,
                    end_ms: 100,
                    text: "hel".to_owned(),
                    final_segment: false,
                },
            )
            .unwrap_or_else(|failure| panic!("interim failed: {}", failure.message));
        let revision = sessions
            .transcript(
                "voice-1",
                "voice-1",
                ProviderTranscript {
                    provider: "fake".to_owned(),
                    start_ms: 0,
                    end_ms: 120,
                    text: "hello".to_owned(),
                    final_segment: true,
                },
            )
            .unwrap_or_else(|failure| panic!("final failed: {}", failure.message));
        let next = sessions
            .transcript(
                "voice-1",
                "voice-1",
                ProviderTranscript {
                    provider: "fake".to_owned(),
                    start_ms: 120,
                    end_ms: 200,
                    text: "next".to_owned(),
                    final_segment: false,
                },
            )
            .unwrap_or_else(|failure| panic!("next failed: {}", failure.message));
        assert_eq!(interim.segment_id, revision.segment_id);
        assert_eq!(interim.segment_sequence, revision.segment_sequence);
        assert_ne!(revision.segment_id, next.segment_id);
        assert_eq!(next.segment_sequence, 1);
    }

    #[test]
    fn reconnect_never_replays_sent_audio_and_bounds_new_audio() {
        let mut sessions = AudioSessions::default();
        start_audio(&mut sessions, "voice-1");
        assert!(
            sessions
                .accept(AudioChunk {
                    request_id: "voice-1".to_owned(),
                    sequence: 0,
                    sample_rate_hz: 16_000,
                    channels: 1,
                    encoding: AudioEncoding::Opus,
                    end_of_stream: false,
                    bytes: vec![1, 2, 3],
                })
                .is_ok()
        );
        let gap = sessions
            .provider_disconnected("reconnect-1", "voice-1", 0, 20)
            .unwrap_or_else(|failure| panic!("disconnect failed: {}", failure.message));
        assert_eq!(gap.stt_epoch, 0);
        assert_eq!(sessions.0["voice-1"].epoch, 1);
        assert!(
            sessions
                .accept(AudioChunk {
                    request_id: "voice-1".to_owned(),
                    sequence: 1,
                    sample_rate_hz: 16_000,
                    channels: 1,
                    encoding: AudioEncoding::Opus,
                    end_of_stream: false,
                    bytes: vec![4, 5],
                })
                .is_ok()
        );
        let replay = sessions
            .provider_reconnected("reconnect-1", "voice-1")
            .unwrap_or_else(|failure| panic!("reconnect failed: {}", failure.message));
        assert_eq!(replay, vec![vec![4, 5]]);
        assert!(!replay.iter().any(|bytes| bytes == &[1, 2, 3]));

        sessions
            .provider_disconnected("reconnect-2", "voice-1", 20, 40)
            .unwrap_or_else(|failure| panic!("disconnect failed: {}", failure.message));
        let overflow = sessions.accept(AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: 2,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![0; MAX_RECONNECT_BUFFER_BYTES + 1],
        });
        assert!(matches!(
            overflow,
            Err(AudioAcceptError {
                code: "transcription_reconnect_buffer_full",
                ..
            })
        ));
        assert_eq!(sessions.0["voice-1"].next_sequence, 2);
    }

    #[test]
    fn eos_drains_once_and_authority_fence_cancels_sessions() {
        let mut sessions = AudioSessions::default();
        start_audio(&mut sessions, "voice-1");
        let eos = sessions.accept(AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: 0,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: true,
            bytes: Vec::new(),
        });
        assert!(matches!(
            eos,
            Ok(Some(AudioProgress {
                status: ToolStatus::Complete,
                ..
            }))
        ));
        assert!(!sessions.0.contains_key("voice-1"));
        start_audio(&mut sessions, "voice-2");
        sessions.cancel_all();
        assert!(sessions.0.is_empty());
    }

    #[test]
    fn explicit_transcription_stop_is_cancelled() {
        let mut sessions = AudioSessions::default();
        start_audio(&mut sessions, "voice-1");

        let (acknowledgement, status) = sessions.stop("stop-1", "voice-1");

        assert_eq!(acknowledgement.request_id, "stop-1");
        assert!(acknowledgement.accepted);
        assert!(status.is_none());
        assert!(sessions.0.is_empty());
        let (duplicate, status) = sessions.stop("stop-2", "voice-1");
        assert!(!duplicate.accepted);
        assert!(status.is_none());
    }

    #[test]
    fn computer_typing_duration_is_bounded() {
        assert!(valid_computer_type("hello", Some(10)));
        assert!(valid_computer_type("hello", None));
        assert!(!valid_computer_type("", None));
        assert!(!valid_computer_type(&"x".repeat(31), Some(1_000)));
        assert!(!valid_computer_type("x", Some(1_001)));
    }

    #[test]
    fn computer_tools_require_configuration_and_runtime_availability() {
        assert!(should_enable_computer_tools(true, true));
        assert!(!should_enable_computer_tools(true, false));
        assert!(!should_enable_computer_tools(false, true));
        assert!(!should_enable_computer_tools(false, false));
    }

    struct ScriptedProvider {
        calls: Vec<&'static str>,
    }

    impl LiveSttProvider for ScriptedProvider {
        fn start(&mut self, _stream_id: &str) -> Result<(), String> {
            self.calls.push("start");
            Ok(())
        }

        fn send_audio(&mut self, _bytes: &[u8]) -> Result<(), String> {
            self.calls.push("audio");
            Ok(())
        }

        fn finish(&mut self) -> Result<(), String> {
            self.calls.push("finish");
            Ok(())
        }

        fn cancel(&mut self) {
            self.calls.push("cancel");
        }
    }

    #[test]
    fn scripted_provider_observes_start_audio_finish_order() {
        let mut provider = ScriptedProvider { calls: Vec::new() };
        assert!(provider.start("voice-1").is_ok());
        assert!(provider.send_audio(&[1]).is_ok());
        assert!(provider.finish().is_ok());
        assert_eq!(provider.calls, ["start", "audio", "finish"]);
    }

    #[test]
    fn proposal_decisions_are_authority_scoped_expiring_and_one_shot() {
        let mut registry = ProposalRegistry::default();
        registry
            .register(
                "user-a",
                4,
                ActionProposal {
                    proposal_id: "proposal-1".to_owned(),
                    request_id: "chat-g4-1".to_owned(),
                    title: "Create task".to_owned(),
                    summary: "Add a task".to_owned(),
                    risk: ActionRisk::External,
                    computer_action: None,
                    expires_at_ms: Some(i64::MAX),
                },
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        assert_eq!(
            registry.decide(
                "proposal-1",
                "user-b",
                4,
                ApprovalDecision::ApproveOnce,
                100,
            ),
            Err(ProposalDecisionError::WrongAuthority)
        );
        let decided = registry
            .decide(
                "proposal-1",
                "user-a",
                4,
                ApprovalDecision::ApproveOnce,
                100,
            )
            .unwrap_or_else(|failure| panic!("proposal is approved: {failure:?}"));
        assert_eq!(decided.status, ProposalStatus::Approved);
        assert_eq!(decided.fingerprint.parent_request_id, "chat-g4-1");
        assert_eq!(decided.fingerprint.risk, ActionRisk::External);
        assert_eq!(
            registry.register(
                "user-a",
                4,
                action_proposal("proposal-1", "chat-g4-1", i64::MAX)
            ),
            Ok(ProposalRegistration::ExactReplay)
        );
        let mut conflicting = action_proposal("proposal-1", "chat-g4-1", i64::MAX);
        conflicting.summary = "Changed payload".to_owned();
        assert_eq!(
            registry.register("user-a", 4, conflicting),
            Err(ProposalDecisionError::Conflict)
        );
        assert_eq!(
            registry.decide("proposal-1", "user-a", 4, ApprovalDecision::Reject, 100,),
            Err(ProposalDecisionError::AlreadyDecided)
        );

        registry
            .register(
                "user-a",
                4,
                ActionProposal {
                    proposal_id: "proposal-2".to_owned(),
                    request_id: "chat-g4-2".to_owned(),
                    title: "Expired".to_owned(),
                    summary: "Expired proposal".to_owned(),
                    risk: ActionRisk::Reversible,
                    computer_action: None,
                    expires_at_ms: Some(unix_time_ms() + 100),
                },
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        assert_eq!(
            registry.decide(
                "proposal-2",
                "user-a",
                4,
                ApprovalDecision::ApproveOnce,
                i64::MAX,
            ),
            Err(ProposalDecisionError::Expired)
        );
        assert_eq!(
            registry.terminal["proposal-2"].status,
            ProposalStatus::Expired
        );
        registry.invalidate_generation("user-a", 4);
        assert!(registry.pending.is_empty());
        assert!(!registry.terminal.is_empty());
    }

    #[test]
    fn computer_action_is_approved_and_consumed_in_one_transition() {
        let mut registry = ProposalRegistry::default();
        let action = ComputerUseAction::TypeText {
            text: "approved text".to_owned(),
            clear: true,
            press_return: false,
            delay_ms: Some(5),
        };
        registry
            .register(
                "user-a",
                7,
                ActionProposal {
                    proposal_id: "computer-1".to_owned(),
                    request_id: "chat-g7-1".to_owned(),
                    title: "Type approved text".to_owned(),
                    summary: "Replace the focused field".to_owned(),
                    risk: ActionRisk::External,
                    computer_action: Some(action.clone()),
                    expires_at_ms: Some(i64::MAX),
                },
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        assert_eq!(
            registry.approve_and_take_action("computer-1", "user-a", 7, 100),
            Ok(action)
        );
        assert_eq!(
            registry.approve_and_take_action("computer-1", "user-a", 7, 100),
            Err(ProposalDecisionError::AlreadyDecided)
        );
        assert_eq!(
            registry.terminal["computer-1"].status,
            ProposalStatus::Executed
        );
        registry
            .register(
                "user-a",
                7,
                ActionProposal {
                    proposal_id: "non-computer".to_owned(),
                    request_id: "chat-g7-1".to_owned(),
                    title: "Review".to_owned(),
                    summary: "No side effect".to_owned(),
                    risk: ActionRisk::Reversible,
                    computer_action: None,
                    expires_at_ms: Some(i64::MAX),
                },
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        assert_eq!(
            registry.approve_and_take_action("non-computer", "user-a", 7, 100),
            Err(ProposalDecisionError::NoAction)
        );
        assert!(registry.pending.contains_key("non-computer"));
    }

    #[tokio::test]
    async fn cancellation_before_acceptance_preserves_the_pending_proposal() {
        let action = ComputerUseAction::Click {
            x: 10,
            y: 20,
            button: crate::signals::MouseButton::Left,
            count: 1,
        };
        let mut runtime = RuntimeState {
            configuration_generation: 3,
            authority_uid: Some("user-a".to_owned()),
            ..RuntimeState::default()
        };
        runtime
            .proposals
            .register(
                "user-a",
                3,
                ActionProposal {
                    proposal_id: "cancel-before-accept".to_owned(),
                    request_id: "chat-g3-1".to_owned(),
                    title: "Click".to_owned(),
                    summary: "Click once".to_owned(),
                    risk: ActionRisk::Reversible,
                    computer_action: Some(action),
                    expires_at_ms: Some(i64::MAX),
                },
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        let state = Mutex::new(runtime);
        let cancellation = CancellationToken::new();
        cancellation.cancel();

        approve_and_execute_computer_use(
            "approval-1",
            &state,
            "cancel-before-accept",
            3,
            &cancellation,
        )
        .await;

        let runtime = state.lock().await;
        assert!(
            runtime
                .proposals
                .pending
                .contains_key("cancel-before-accept")
        );
        assert!(
            !runtime
                .proposals
                .terminal
                .contains_key("cancel-before-accept")
        );
    }

    #[test]
    fn proposal_pending_and_terminal_ledgers_are_bounded() {
        let mut registry = ProposalRegistry::default();
        for index in 0..PENDING_PROPOSAL_CAPACITY {
            registry
                .register(
                    "user-a",
                    1,
                    action_proposal(&format!("pending-{index}"), "chat-1", i64::MAX),
                )
                .unwrap_or_else(|failure| panic!("pending proposal registers: {failure:?}"));
        }
        assert_eq!(
            registry.register(
                "user-a",
                1,
                action_proposal("pending-overflow", "chat-1", i64::MAX),
            ),
            Err(ProposalDecisionError::Capacity)
        );
        for index in 0..PENDING_PROPOSAL_CAPACITY {
            registry
                .decide(
                    &format!("pending-{index}"),
                    "user-a",
                    1,
                    ApprovalDecision::Reject,
                    0,
                )
                .unwrap_or_else(|failure| panic!("pending proposal rejects: {failure:?}"));
        }
        for index in 0..=TERMINAL_PROPOSAL_CAPACITY {
            let id = format!("terminal-{index}");
            registry
                .register("user-a", 1, action_proposal(&id, "chat-2", i64::MAX))
                .unwrap_or_else(|failure| panic!("terminal proposal registers: {failure:?}"));
            registry
                .decide(&id, "user-a", 1, ApprovalDecision::Reject, 0)
                .unwrap_or_else(|failure| panic!("terminal proposal rejects: {failure:?}"));
        }
        assert_eq!(registry.terminal.len(), TERMINAL_PROPOSAL_CAPACITY);
        assert!(!registry.terminal.contains_key("terminal-0"));
        assert!(registry.terminal.contains_key("terminal-256"));
    }

    #[tokio::test]
    async fn assistant_dispatch_registers_proposals_and_suppresses_cancelled_output() {
        let state = Arc::new(Mutex::new(RuntimeState {
            configuration_generation: 7,
            authority_uid: Some("user-a".to_owned()),
            ..RuntimeState::default()
        }));
        let request_id = "chat-g7-1";
        let provider: Arc<dyn AssistantProvider> = Arc::new(FakeAssistantProvider {
            events: StdMutex::new(Some(vec![
                AssistantProviderEvent::Delta {
                    text: "ready".to_owned(),
                    final_segment: false,
                },
                AssistantProviderEvent::Proposal(action_proposal(
                    "proposal-live",
                    request_id,
                    i64::MAX,
                )),
                AssistantProviderEvent::Delta {
                    text: "done".to_owned(),
                    final_segment: true,
                },
            ])),
        });
        dispatch_assistant(
            request_id,
            state.as_ref(),
            provider,
            "plan".to_owned(),
            &CancellationToken::new(),
        )
        .await;
        assert!(
            state
                .lock()
                .await
                .proposals
                .pending
                .contains_key("proposal-live")
        );

        let cancellation = CancellationToken::new();
        cancellation.cancel();
        let cancelled_provider: Arc<dyn AssistantProvider> = Arc::new(FakeAssistantProvider {
            events: StdMutex::new(Some(vec![AssistantProviderEvent::Proposal(
                action_proposal("proposal-cancelled", "chat-g7-2", i64::MAX),
            )])),
        });
        dispatch_assistant(
            "chat-g7-2",
            state.as_ref(),
            cancelled_provider,
            "cancel".to_owned(),
            &cancellation,
        )
        .await;
        assert!(
            !state
                .lock()
                .await
                .proposals
                .pending
                .contains_key("proposal-cancelled")
        );

        let reconfiguring_provider: Arc<dyn AssistantProvider> =
            Arc::new(ReconfiguringAssistantProvider {
                state: Arc::clone(&state),
                proposal: StdMutex::new(Some(action_proposal(
                    "proposal-old-generation",
                    "chat-g7-3",
                    i64::MAX,
                ))),
            });
        dispatch_assistant(
            "chat-g7-3",
            state.as_ref(),
            reconfiguring_provider,
            "reconfigure".to_owned(),
            &CancellationToken::new(),
        )
        .await;
        assert!(
            !state
                .lock()
                .await
                .proposals
                .pending
                .contains_key("proposal-old-generation")
        );
    }
}
