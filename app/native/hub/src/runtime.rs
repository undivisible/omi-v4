#[cfg(test)]
use crate::approval::{
    PENDING_PROPOSAL_CAPACITY, ProposalRegistration, TERMINAL_PROPOSAL_CAPACITY,
};
use crate::approval::{ProposalDecisionError, ProposalRegistry, ProposalStatus, unix_time_ms};
use crate::computer_use::{
    BoundComputerUseAction, ComputerUseError, ExecutionOutcome, PreparedComputerUseAction,
    available as computer_use_available, capabilities as computer_use_capabilities,
};
use crate::signals::{
    ActionProposal, ActionRisk, ApprovalDecision, ApprovalDecisionAcknowledgement, AssistantDelta,
    AssistantProvider as ProviderKind, CaptureSource, ClientCommand, Command, ComputerUseAction,
    ComputerUseAuthorityReceipt, MemoryCaptured, MemoryCorrected, MemoryExportCommit,
    MemoryExported, MemoryItem, MemoryItems, MemorySearchItem, MemorySearchResults,
    MemorySourceDeleted, NativeError, NativeEvent, OnboardingScanCompleted, OnboardingScanSource,
    OnboardingScanState, RuntimePhase, RuntimeStatus, ToolProgress, ToolStatus, TranscriptLocator,
    TranscriptionStopAcknowledgement,
};
#[cfg(test)]
use crate::signals::{AudioChunk, TranscriptionAuth, TranscriptionRoute};
#[cfg(test)]
use crate::transcription::{
    AudioAcceptError, AudioProgress, AudioSession, AudioSessions, LiveSttProvider,
    ProviderTranscript, TranscriptionPhase,
};
use crate::transcription::{StartTranscription, TranscriptionControl};
use futures::StreamExt;
use rs_ai_core::{StreamEvent, ToolChoice, ToolDefinition};
use std::collections::{HashMap, VecDeque, hash_map::Entry};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;
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
const PROVIDER_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const PROVIDER_EVENT_TIMEOUT: Duration = Duration::from_secs(45);
const COMPUTER_USE_PROPOSAL_TTL_MS: i64 = 5 * 60 * 1_000;
const COMPUTER_INVOKE_TOOL: &str = "computer_invoke";
const COMPUTER_SET_VALUE_TOOL: &str = "computer_set_value";
const COMPUTER_USE_RECEIPT_VERSION: &str = "omi-current-authority-v1";
const MAX_APPROVAL_RESPONSE_BYTES: usize = 32 * 1024;
#[cfg(test)]
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
#[cfg(test)]
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
#[cfg(test)]
const MAX_RECONNECT_BUFFER_BYTES: usize = 64 * 1024;

pub(crate) struct MemoryContext {
    pub(crate) database: MemoryDb,
    pub(crate) tenant_id: TenantId,
    pub(crate) person_id: PersonId,
}

#[derive(Default)]
struct RuntimeState {
    memory: Option<Arc<StdMutex<MemoryContext>>>,
    configuration_generation: u64,
    authority_uid: Option<String>,
    proposals: ProposalRegistry,
    managed_worker_origin: Option<String>,
    computer_use_ledger_path: Option<PathBuf>,
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
    Proposal(Box<BoundActionProposal>),
}

struct BoundActionProposal {
    proposal: ActionProposal,
    bound_computer_action: Option<BoundComputerUseAction>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ApprovalReceiptClaim<'a> {
    receipt_token: &'a str,
    subject: &'a str,
    policy_generation: u64,
    proposal_id: &'a str,
    operation_id: &'a str,
    action_hash: &'a str,
    risk: &'a str,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ApprovalReceiptClaimResponse {
    execution_id: String,
    state: String,
    receipt: ClaimedApprovalReceipt,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ClaimedApprovalReceipt {
    version: String,
    receipt_id: String,
    subject: String,
    policy_generation: u64,
    proposal_id: String,
    operation_id: String,
    action_hash: String,
    risk: String,
    issued_at_ms: i64,
    expires_at_ms: i64,
    claimed_at_ms: i64,
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
struct ComputerInvokeArgs {
    target_name: String,
    background_only: bool,
}

#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct ComputerSetValueArgs {
    target_name: String,
    value: String,
    background_only: bool,
}

fn computer_use_tools() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: COMPUTER_INVOKE_TOOL.to_owned(),
            description: "Propose invoking the unique accessible element with this exact name after user approval".to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "target_name": {"type": "string", "minLength": 1, "maxLength": 1024},
                    "background_only": {"type": "boolean"}
                },
                "required": ["target_name", "background_only"]
            }),
            examples: None,
        },
        ToolDefinition {
            name: COMPUTER_SET_VALUE_TOOL.to_owned(),
            description: "Propose setting the value of the unique editable accessible element with this exact name after user approval".to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "additionalProperties": false,
                "properties": {
                    "target_name": {"type": "string", "minLength": 1, "maxLength": 1024},
                    "value": {"type": "string", "maxLength": 16384},
                    "background_only": {"type": "boolean"}
                },
                "required": ["target_name", "value", "background_only"]
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
        && matches!(tool_name, COMPUTER_INVOKE_TOOL | COMPUTER_SET_VALUE_TOOL)
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
        COMPUTER_INVOKE_TOOL => {
            let args: ComputerInvokeArgs = serde_json::from_value(arguments).map_err(|_| {
                "assistant provider returned an invalid computer-use tool call".to_owned()
            })?;
            let summary = format!(
                "Invoke {}{}",
                args.target_name,
                if args.background_only {
                    " in the background"
                } else {
                    ""
                }
            );
            let action = ComputerUseAction::Invoke {
                target_name: args.target_name,
                background_only: args.background_only,
            };
            if !crate::computer_use::valid_action(&action) {
                return Err(
                    "assistant provider returned an invalid computer-use tool call".to_owned(),
                );
            }
            ("Invoke interface element".to_owned(), summary, action)
        }
        COMPUTER_SET_VALUE_TOOL => {
            let args: ComputerSetValueArgs = serde_json::from_value(arguments).map_err(|_| {
                "assistant provider returned an invalid computer-use tool call".to_owned()
            })?;
            let summary = format!(
                "Set {} to {} bytes{}",
                args.target_name,
                args.value.len(),
                if args.background_only {
                    " in the background"
                } else {
                    ""
                }
            );
            let action = ComputerUseAction::SetValue {
                target_name: args.target_name,
                value: args.value,
                background_only: args.background_only,
            };
            if !crate::computer_use::valid_action(&action) {
                return Err(
                    "assistant provider returned an invalid computer-use tool call".to_owned(),
                );
            }
            ("Set interface value".to_owned(), summary, action)
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
        risk: ActionRisk::Destructive,
        computer_action: Some(action),
        operation_id: None,
        action_hash: None,
        target_provenance: None,
        expires_at_ms: Some(unix_time_ms().saturating_add(COMPUTER_USE_PROPOSAL_TTL_MS)),
    })
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
async fn bind_computer_use_action(
    action: ComputerUseAction,
    cancellation: &CancellationToken,
) -> Result<BoundComputerUseAction, String> {
    let protocol_cancellation = crate::computer_use::cancellation_token();
    if cancellation.is_cancelled() {
        crate::computer_use::cancel(&protocol_cancellation);
    }
    let watcher_source = cancellation.clone();
    let watcher_target = protocol_cancellation.clone();
    let watcher = tokio::spawn(async move {
        watcher_source.cancelled().await;
        crate::computer_use::cancel(&watcher_target);
    });
    let task = spawn_blocking(move || crate::computer_use::bind(action, &protocol_cancellation));
    let result = task
        .await
        .map_err(|_| "semantic computer target observation failed".to_owned())?
        .map_err(|_| "semantic computer target is unavailable or ambiguous".to_owned());
    watcher.abort();
    result
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
async fn bind_computer_use_action(
    _action: ComputerUseAction,
    _cancellation: &CancellationToken,
) -> Result<BoundComputerUseAction, String> {
    Err("computer use is unavailable on this platform".to_owned())
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
                        match computer_use_proposal(&request_id, &call_id, &tool_name, arguments) {
                            Ok(mut proposal) => match proposal.computer_action.clone() {
                                Some(action) => {
                                    match bind_computer_use_action(action, &cancellation).await {
                                        Ok(bound_computer_action) => {
                                            proposal.expires_at_ms = Some(
                                                proposal
                                                    .expires_at_ms
                                                    .unwrap_or(i64::MAX)
                                                    .min(bound_computer_action.expires_at_ms),
                                            );
                                            Ok(AssistantProviderEvent::Proposal(Box::new(
                                                BoundActionProposal {
                                                    proposal,
                                                    bound_computer_action: Some(
                                                        bound_computer_action,
                                                    ),
                                                },
                                            )))
                                        }
                                        Err(message) => Err(message),
                                    }
                                }
                                None => Err(
                                    "assistant provider returned an invalid computer-use tool call"
                                        .to_owned(),
                                ),
                            },
                            Err(message) => Err(message),
                        }
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
        Ok(None) => match crate::dev_gemini::api_key() {
            Some(key) => Arc::new(RsAiAssistantProvider {
                config: AssistantProviderConfig {
                    kind: AssistantProviderKind::Gemini,
                    model: crate::dev_gemini::DEV_GEMINI_MODEL.to_owned(),
                    credential: key.0,
                    endpoint: None,
                },
                computer_use_enabled: computer_use_available(),
            }),
            None => Arc::new(UnavailableAssistantProvider {
                reason: "no model provider is configured".to_owned(),
            }),
        },
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
            if let Command::StartLiveVoice {
                live_stream_id,
                ephemeral_token,
                model,
            } = &command.command
            {
                let Some(transcription) = &self.transcription else {
                    error(
                        Some(request_id),
                        "live_voice_unavailable",
                        "live voice runtime is unavailable",
                        false,
                    );
                    continue;
                };
                let start = crate::transcription::StartLiveVoice {
                    request_id,
                    live_stream_id: live_stream_id.clone(),
                    ephemeral_token: ephemeral_token.clone(),
                    model: model.clone(),
                };
                if transcription
                    .send(TranscriptionControl::StartLive(start))
                    .await
                    .is_err()
                {
                    error(
                        None,
                        "live_voice_unavailable",
                        "live voice runtime stopped",
                        false,
                    );
                }
                continue;
            }
            if let Command::StopLiveVoice { live_stream_id } = &command.command {
                let Some(transcription) = &self.transcription else {
                    error(
                        Some(request_id),
                        "live_voice_unavailable",
                        "live voice runtime is unavailable",
                        false,
                    );
                    continue;
                };
                if transcription
                    .send(TranscriptionControl::StopLive {
                        request_id,
                        stream_id: live_stream_id.clone(),
                    })
                    .await
                    .is_err()
                {
                    error(
                        None,
                        "live_voice_unavailable",
                        "live voice runtime stopped",
                        false,
                    );
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
                        acknowledge_approval_rejection(&command.command, &request_id);
                        error(
                            Some(request_id),
                            "command_capacity_exceeded",
                            "too many active commands",
                            true,
                        );
                        continue;
                    }
                    Err(ActivationError::Duplicate) => {
                        acknowledge_approval_rejection(&command.command, &request_id);
                        error(
                            Some(request_id),
                            "duplicate_request",
                            "request_id is already active",
                            false,
                        );
                        continue;
                    }
                    Err(ActivationError::Conflict) => {
                        acknowledge_approval_rejection(&command.command, &request_id);
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
        computer_use_capabilities: computer_use_capabilities(),
        local_ai_available: crate::local_ai::is_available(),
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
            AssistantProviderEvent::Proposal(bound) => {
                let BoundActionProposal {
                    mut proposal,
                    bound_computer_action,
                } = *bound;
                if proposal.request_id != request_id {
                    error(
                        Some(request_id.to_owned()),
                        "proposal_parent_mismatch",
                        "action proposal parent does not match the assistant request",
                        false,
                    );
                    continue;
                }
                let prepared_computer_action = match bound_computer_action {
                    Some(bound) => match crate::computer_use::prepare(
                        bound,
                        &proposal.proposal_id,
                        &uid,
                        proposal.risk,
                    ) {
                        Ok(prepared) => {
                            proposal.operation_id = Some(prepared.operation_id.clone());
                            proposal.action_hash = Some(prepared.action_hash().to_owned());
                            proposal.target_provenance = Some(prepared.bound.provenance.clone());
                            Some(prepared)
                        }
                        Err(_) => {
                            error(
                                Some(request_id.to_owned()),
                                "computer_use_binding_failed",
                                "the semantic computer action could not be bound safely",
                                false,
                            );
                            continue;
                        }
                    },
                    None => None,
                };
                if let Err(failure) = state.proposals.register_bound(
                    &uid,
                    generation,
                    proposal,
                    prepared_computer_action,
                ) {
                    let (code, message) = match failure {
                        ProposalDecisionError::Capacity => (
                            "proposal_capacity_exceeded",
                            "too many action proposals are pending",
                        ),
                        ProposalDecisionError::Conflict => (
                            "proposal_id_conflict",
                            "proposal_id was reused with a different payload",
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
        Command::ScanOnboarding {
            roots,
            include_apple_notes,
            include_apple_mail,
            recorded_at_ms,
        } => {
            scan_onboarding(
                &request_id,
                &state,
                roots,
                include_apple_notes,
                include_apple_mail,
                recorded_at_ms,
                &cancellation,
            )
            .await;
            false
        }
        Command::SendMessage { text, .. } => {
            dispatch_assistant(&request_id, &state, assistant_provider, text, &cancellation).await;
            false
        }
        Command::ApprovalDecision {
            proposal_id,
            decision,
            authority_receipt,
        } => {
            decide_approval(
                &request_id,
                &state,
                &proposal_id,
                decision,
                authority_receipt,
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
        | Command::StopTranscription { .. }
        | Command::StartLiveVoice { .. }
        | Command::StopLiveVoice { .. } => false,
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
        Command::StartMeeting { title } => {
            if crate::meeting::request_start(title) {
                progress(
                    &request_id,
                    "meeting",
                    ToolStatus::Complete,
                    Some("meeting start requested"),
                );
            } else {
                progress(
                    &request_id,
                    "meeting",
                    ToolStatus::Failed,
                    Some("meeting runtime is unavailable"),
                );
            }
            false
        }
        Command::StopMeeting => {
            if crate::meeting::request_stop() {
                progress(
                    &request_id,
                    "meeting",
                    ToolStatus::Complete,
                    Some("meeting stop requested"),
                );
            } else {
                progress(
                    &request_id,
                    "meeting",
                    ToolStatus::Failed,
                    Some("meeting runtime is unavailable"),
                );
            }
            false
        }
        Command::ProvideMeetingAuth {
            auth,
            trusted_worker_origin,
        } => {
            crate::meeting::provide_auth(auth, trusted_worker_origin);
            progress(
                &request_id,
                "meeting",
                ToolStatus::Complete,
                Some("meeting capture auth accepted"),
            );
            false
        }
        Command::SetSystemAudioCaptureMode { mode } => {
            crate::meeting::set_mode(mode);
            progress(
                &request_id,
                "meeting",
                ToolStatus::Complete,
                Some("system audio capture mode updated"),
            );
            false
        }
    }
}

async fn scan_onboarding(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    roots: Vec<String>,
    notes: bool,
    mail: bool,
    recorded_at_ms: i64,
    cancellation: &CancellationToken,
) {
    if recorded_at_ms <= 0 {
        error(
            Some(request_id.to_owned()),
            "invalid_onboarding_scan",
            "recorded_at_ms must be positive",
            false,
        );
        return;
    }
    let memory = state.lock().await.memory.clone();
    let scan_cancellation = cancellation.clone();
    let task = spawn_blocking(move || {
        let scans = crate::scan::scan_sources(&roots, notes, mail);
        if scan_cancellation.is_cancelled() {
            return Ok(None);
        }
        let summary_prompts = crate::scan::summary_prompts(&scans, recorded_at_ms);
        let detected_name = crate::scan::detected_name();
        let detected_languages = crate::scan::detected_languages(&scans);
        let mut sources = Vec::with_capacity(scans.len());
        for scan in scans {
            let mut memory_source_id = None;
            if let Some(memory) = &memory {
                for item in &scan.memories {
                    if scan_cancellation.is_cancelled() {
                        return Ok(None);
                    }
                    let mut memory = memory
                        .lock()
                        .map_err(|_| "memory database lock was poisoned".to_owned())?;
                    let tenant_id = memory.tenant_id.clone();
                    let person_id = memory.person_id.clone();
                    let remembered = memory
                        .database
                        .remember(RememberInput {
                            tenant_id,
                            person_id,
                            ingestion_key: Some(format!(
                                "onboarding-scan:{}:{}:{recorded_at_ms}",
                                scan.source, item.stable_id
                            )),
                            kind: if scan.source == "workspace" {
                                SourceKind::Document
                            } else {
                                SourceKind::Integration
                            },
                            text: item.text.clone(),
                            captured_at: item.captured_at_ms.unwrap_or(recorded_at_ms),
                            recorded_at: recorded_at_ms,
                            claim: None,
                        })
                        .map_err(|error| error.to_string())?;
                    if memory_source_id.is_none() {
                        memory_source_id = Some(remembered.source_id.0);
                    }
                }
            }
            sources.push(OnboardingScanSource {
                source: scan.source,
                state: match scan.state {
                    crate::scan::ScanState::Complete => OnboardingScanState::Complete,
                    crate::scan::ScanState::Denied => OnboardingScanState::Denied,
                    crate::scan::ScanState::Unavailable => OnboardingScanState::Unavailable,
                    crate::scan::ScanState::Failed => OnboardingScanState::Failed,
                },
                items_found: scan.items_found,
                detail: scan.detail,
                memory_source_id,
            });
        }
        Ok(Some((
            sources,
            summary_prompts,
            detected_name,
            detected_languages,
        )))
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(Some((
            sources,
            summary_prompts,
            detected_name,
            detected_languages,
        ))) => {
            let summary = if let Some(prompts) = summary_prompts {
                tokio::select! {
                    () = cancellation.cancelled() => {
                        cancelled(request_id);
                        return;
                    }
                    value = crate::local_ai::summarize_with_dev_fallback(&prompts.local, &prompts.fallback) => value.map(|summary| {
                        crate::scan::ensure_summary_emphasis(
                            &summary,
                            &prompts.emphasis_candidates,
                        )
                    }),
                }
            } else {
                None
            };
            NativeEvent::OnboardingScanCompleted(OnboardingScanCompleted {
                request_id: request_id.to_owned(),
                sources,
                summary,
                detected_name,
                detected_languages,
            })
            .send()
        }
        BlockingOutcome::Complete(None) | BlockingOutcome::Cancelled => cancelled(request_id),
        BlockingOutcome::Failed(message) => error(
            Some(request_id.to_owned()),
            "onboarding_scan_failed",
            &message,
            false,
        ),
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
    let computer_use_ledger_path = computer_use_ledger_path(&database_path);
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
            let memory = Arc::new(StdMutex::new(memory));
            state.memory = Some(Arc::clone(&memory));
            state.computer_use_ledger_path = computer_use_ledger_path;
            drop(state);
            NativeEvent::RuntimeStatus(runtime_status(true)).send();
            let review_cancellation = cancellation.clone();
            tokio::spawn(async move {
                tokio::select! {
                    () = review_cancellation.cancelled() => {}
                    _ = crate::daily_review::ensure_daily_review(
                        memory,
                        chrono::Local::now().fixed_offset(),
                    ) => {}
                }
            });
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

fn computer_use_ledger_path(database_path: &str) -> Option<PathBuf> {
    let database_path = Path::new(database_path);
    database_path.is_absolute().then(|| {
        database_path
            .parent()
            .unwrap_or(database_path)
            .join("praefectus")
            .join("operations.jsonl")
    })
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
    let extraction_input = (crate::local_ai::is_available()
        && matches!(source, CaptureSource::OmiDevice | CaptureSource::Chat))
    .then(|| (Arc::clone(&memory), ingestion_key.clone(), text.clone()));
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
            if let Some((memory, ingestion_key, text)) = extraction_input {
                spawn_transcript_extraction(
                    memory,
                    ingestion_key,
                    occurred_at_ms,
                    recorded_at_ms,
                    text,
                    cancellation.clone(),
                );
            }
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

fn spawn_transcript_extraction(
    memory: Arc<StdMutex<MemoryContext>>,
    ingestion_key: String,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    text: String,
    cancellation: CancellationToken,
) {
    let Some(prompt) = crate::extraction::extraction_prompt(&text) else {
        return;
    };
    tokio::spawn(async move {
        let output = tokio::select! {
            () = cancellation.cancelled() => return,
            value = crate::local_ai::summarize(&prompt) => value,
        };
        let Some(output) = output else {
            return;
        };
        let claims = crate::extraction::candidate_claims(&output, occurred_at_ms);
        if claims.is_empty() {
            return;
        }
        let _ = spawn_blocking(move || {
            if cancellation.is_cancelled() {
                return Ok(0);
            }
            let mut memory = memory
                .lock()
                .map_err(|_| "memory database lock was poisoned".to_owned())?;
            store_candidate_claims(
                &mut memory,
                &ingestion_key,
                occurred_at_ms,
                recorded_at_ms,
                claims,
            )
        })
        .await;
    });
}

fn store_candidate_claims(
    memory: &mut MemoryContext,
    ingestion_key: &str,
    occurred_at_ms: i64,
    recorded_at_ms: i64,
    claims: Vec<zkr::ClaimInput>,
) -> Result<usize, String> {
    let mut stored = 0;
    for (index, claim) in claims.into_iter().enumerate() {
        let text = format!("{} {} {}", claim.subject, claim.predicate, claim.value);
        let remembered = memory
            .database
            .remember(RememberInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                ingestion_key: Some(format!("{ingestion_key}:extract:{index}")),
                kind: SourceKind::Conversation,
                text,
                captured_at: occurred_at_ms,
                recorded_at: recorded_at_ms,
                claim: Some(claim),
            })
            .map_err(|error_value| error_value.to_string())?;
        if remembered.claim_id.is_some() {
            stored += 1;
        }
    }
    Ok(stored)
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
        CaptureSource::Workspace => SourceKind::Document,
        CaptureSource::AppleNotes
        | CaptureSource::AppleMail
        | CaptureSource::AppleCalendar
        | CaptureSource::AppleReminders => SourceKind::Integration,
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

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
async fn execute_bound_computer_use(
    action: PreparedComputerUseAction,
    policy_generation: u64,
    authority_expires_at_ms: i64,
    ledger_path: PathBuf,
    cancellation: &CancellationToken,
) -> Result<ExecutionOutcome, ComputerUseError> {
    let protocol_cancellation = crate::computer_use::cancellation_token();
    if cancellation.is_cancelled() {
        crate::computer_use::cancel(&protocol_cancellation);
    }
    let watcher_source = cancellation.clone();
    let watcher_target = protocol_cancellation.clone();
    let watcher = tokio::spawn(async move {
        watcher_source.cancelled().await;
        crate::computer_use::cancel(&watcher_target);
    });
    let task = spawn_blocking(move || {
        crate::computer_use::execute(
            action,
            policy_generation,
            authority_expires_at_ms,
            &ledger_path,
            &protocol_cancellation,
        )
    });
    let result = task.await.map_err(|_| ComputerUseError::Protocol)?;
    watcher.abort();
    result
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
async fn execute_bound_computer_use(
    _action: PreparedComputerUseAction,
    _policy_generation: u64,
    _authority_expires_at_ms: i64,
    _ledger_path: PathBuf,
    _cancellation: &CancellationToken,
) -> Result<ExecutionOutcome, ComputerUseError> {
    Err(ComputerUseError::TargetUnavailable)
}

fn computer_use_risk_name(risk: ActionRisk) -> &'static str {
    match risk {
        ActionRisk::Reversible => "reversible",
        ActionRisk::External => "external",
        ActionRisk::Destructive => "destructive",
    }
}

fn valid_receipt_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 256
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn valid_receipt_hash(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn validate_computer_use_receipt(
    receipt: &ComputerUseAuthorityReceipt,
    proposal_id: &str,
    uid: &str,
    risk: ActionRisk,
    action: &PreparedComputerUseAction,
) -> bool {
    receipt.version == COMPUTER_USE_RECEIPT_VERSION
        && receipt.subject == uid
        && receipt.proposal_id == proposal_id
        && receipt.operation_id == action.operation_id
        && receipt.action_hash == action.action_hash()
        && receipt.risk == risk
        && receipt.issued_at_ms > 0
        && receipt.expires_at_ms > receipt.issued_at_ms
        && receipt.expires_at_ms.saturating_sub(receipt.issued_at_ms) <= 60_000
        && unix_time_ms() < receipt.expires_at_ms
        && unix_time_ms() < action.bound.expires_at_ms
        && valid_receipt_identifier(&receipt.execution_id)
        && valid_receipt_identifier(&receipt.receipt_id)
        && valid_receipt_hash(&receipt.action_hash)
        && receipt.receipt_token.len() >= 32
        && receipt.receipt_token.len() <= 512
        && receipt
            .receipt_token
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        && !receipt.firebase_token.trim().is_empty()
        && receipt.firebase_token.len() <= 16 * 1024
}

async fn claim_computer_use_receipt(
    managed_worker_origin: &str,
    receipt: &ComputerUseAuthorityReceipt,
    cancellation: &CancellationToken,
) -> Result<(), ComputerUseError> {
    let endpoint = Url::parse(managed_worker_origin)
        .and_then(|origin| {
            origin.join(&format!(
                "/v1/currents/executions/{}/receipts/{}/claim",
                receipt.execution_id, receipt.receipt_id
            ))
        })
        .map_err(|_| ComputerUseError::Protocol)?;
    let endpoint_value = endpoint.to_string();
    tokio::select! {
        () = cancellation.cancelled() => return Err(ComputerUseError::Protocol),
        result = endpoint_resolves_publicly(&endpoint_value) => {
            result.map_err(|_| ComputerUseError::Protocol)?;
        }
    }
    let risk = computer_use_risk_name(receipt.risk);
    let request = reqwest::Client::new()
        .post(endpoint)
        .bearer_auth(&receipt.firebase_token)
        .json(&ApprovalReceiptClaim {
            receipt_token: &receipt.receipt_token,
            subject: &receipt.subject,
            policy_generation: receipt.policy_generation,
            proposal_id: &receipt.proposal_id,
            operation_id: &receipt.operation_id,
            action_hash: &receipt.action_hash,
            risk,
        });
    let response = tokio::select! {
        () = cancellation.cancelled() => return Err(ComputerUseError::Protocol),
        result = tokio::time::timeout(Duration::from_secs(10), request.send()) => {
            result.map_err(|_| ComputerUseError::Protocol)?
                .map_err(|_| ComputerUseError::Protocol)?
        }
    };
    if !response.status().is_success()
        || response
            .content_length()
            .is_some_and(|length| length > MAX_APPROVAL_RESPONSE_BYTES as u64)
    {
        return Err(ComputerUseError::Protocol);
    }
    let bytes = tokio::select! {
        () = cancellation.cancelled() => return Err(ComputerUseError::Protocol),
        result = response.bytes() => result.map_err(|_| ComputerUseError::Protocol)?,
    };
    if bytes.len() > MAX_APPROVAL_RESPONSE_BYTES {
        return Err(ComputerUseError::Protocol);
    }
    let claimed: ApprovalReceiptClaimResponse =
        serde_json::from_slice(&bytes).map_err(|_| ComputerUseError::Protocol)?;
    let claimed_receipt = claimed.receipt;
    if claimed.execution_id != receipt.execution_id
        || claimed.state != "claimed"
        || claimed_receipt.version != receipt.version
        || claimed_receipt.receipt_id != receipt.receipt_id
        || claimed_receipt.subject != receipt.subject
        || claimed_receipt.policy_generation != receipt.policy_generation
        || claimed_receipt.proposal_id != receipt.proposal_id
        || claimed_receipt.operation_id != receipt.operation_id
        || claimed_receipt.action_hash != receipt.action_hash
        || claimed_receipt.risk != risk
        || claimed_receipt.issued_at_ms != receipt.issued_at_ms
        || claimed_receipt.expires_at_ms != receipt.expires_at_ms
        || claimed_receipt.claimed_at_ms < claimed_receipt.issued_at_ms
        || claimed_receipt.claimed_at_ms >= claimed_receipt.expires_at_ms
    {
        return Err(ComputerUseError::Protocol);
    }
    Ok(())
}

async fn decide_approval(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    proposal_id: &str,
    decision: ApprovalDecision,
    authority_receipt: Option<ComputerUseAuthorityReceipt>,
    generation: u64,
    cancellation: &CancellationToken,
) {
    decide_approval_with_availability(
        request_id,
        state,
        proposal_id,
        decision,
        authority_receipt,
        ApprovalExecutionContext {
            generation,
            computer_use_is_available: computer_use_available(),
        },
        cancellation,
    )
    .await;
}

#[derive(Clone, Copy)]
struct ApprovalExecutionContext {
    generation: u64,
    computer_use_is_available: bool,
}

async fn decide_approval_with_availability(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    proposal_id: &str,
    decision: ApprovalDecision,
    authority_receipt: Option<ComputerUseAuthorityReceipt>,
    execution: ApprovalExecutionContext,
    cancellation: &CancellationToken,
) {
    let generation = execution.generation;
    let computer_use_is_available = execution.computer_use_is_available;
    if cancellation.is_cancelled() {
        approval_decision_acknowledgement(request_id, proposal_id, decision, false, false);
        cancelled(request_id);
        return;
    }
    let result = {
        let mut state = state.lock().await;
        if cancellation.is_cancelled() {
            approval_decision_acknowledgement(request_id, proposal_id, decision, false, false);
            cancelled(request_id);
            return;
        }
        if state.configuration_generation != generation {
            approval_decision_acknowledgement(request_id, proposal_id, decision, false, false);
            cancelled(request_id);
            return;
        }
        let Some(uid) = state.authority_uid.clone() else {
            approval_decision_acknowledgement(request_id, proposal_id, decision, false, false);
            error(
                Some(request_id.to_owned()),
                "proposal_not_found",
                "no action proposal authority is configured",
                false,
            );
            return;
        };
        let ledger_path = state.computer_use_ledger_path.clone();
        let managed_worker_origin = state.managed_worker_origin.clone();
        state
            .proposals
            .decide(
                proposal_id,
                &uid,
                generation,
                decision,
                unix_time_ms(),
                computer_use_is_available && ledger_path.is_some(),
            )
            .map(|(record, action)| (record, action, uid, ledger_path, managed_worker_origin))
            .map_err(|failure| match failure {
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
                ProposalDecisionError::ExecutionUnavailable => (
                    "computer_use_unavailable",
                    "computer use permissions or platform support are unavailable",
                ),
                ProposalDecisionError::AlreadyDecided
                | ProposalDecisionError::Capacity
                | ProposalDecisionError::Conflict => (
                    "proposal_not_approved",
                    "the action proposal cannot be decided",
                ),
            })
    };
    let (record, action, uid, ledger_path, managed_worker_origin) = match result {
        Ok(result) => result,
        Err((code, message)) => {
            approval_decision_acknowledgement(request_id, proposal_id, decision, false, false);
            error(
                Some(request_id.to_owned()),
                code,
                message,
                code == "computer_use_unavailable",
            );
            return;
        }
    };
    approval_decision_acknowledgement(request_id, proposal_id, decision, true, action.is_some());
    let Some(action) = action else {
        if authority_receipt.is_some() {
            error(
                Some(request_id.to_owned()),
                "computer_use_authority_invalid",
                "computer-use authority was supplied for a non-computer decision",
                false,
            );
            return;
        }
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
        progress(request_id, "approval", ToolStatus::Complete, Some(&detail));
        return;
    };
    let Some(authority_receipt) = authority_receipt else {
        state
            .lock()
            .await
            .proposals
            .finish_execution(proposal_id, ProposalStatus::Failed);
        error(
            Some(request_id.to_owned()),
            "computer_use_authority_required",
            "server-consumed computer-use approval is required",
            false,
        );
        return;
    };
    if !validate_computer_use_receipt(
        &authority_receipt,
        proposal_id,
        &uid,
        record.fingerprint.risk,
        &action,
    ) {
        state
            .lock()
            .await
            .proposals
            .finish_execution(proposal_id, ProposalStatus::Failed);
        error(
            Some(request_id.to_owned()),
            "computer_use_authority_invalid",
            "server-consumed computer-use approval does not match the action",
            false,
        );
        return;
    }
    let Some(managed_worker_origin) = managed_worker_origin else {
        state
            .lock()
            .await
            .proposals
            .finish_execution(proposal_id, ProposalStatus::Failed);
        error(
            Some(request_id.to_owned()),
            "computer_use_authority_unavailable",
            "trusted computer-use approval service is unavailable",
            false,
        );
        return;
    };
    if claim_computer_use_receipt(&managed_worker_origin, &authority_receipt, cancellation)
        .await
        .is_err()
    {
        let cancelled_before_effect = cancellation.is_cancelled();
        let expired_before_effect = !cancelled_before_effect
            && (unix_time_ms() >= authority_receipt.expires_at_ms
                || unix_time_ms() >= action.bound.expires_at_ms);
        state.lock().await.proposals.finish_execution(
            proposal_id,
            if cancelled_before_effect {
                ProposalStatus::CancelledBeforeEffect
            } else if expired_before_effect {
                ProposalStatus::ExpiredBeforeEffect
            } else {
                ProposalStatus::Failed
            },
        );
        if cancelled_before_effect {
            cancelled(request_id);
        } else if expired_before_effect {
            error(
                Some(request_id.to_owned()),
                "computer_use_expired",
                "the approved computer action expired before an effect",
                false,
            );
        } else {
            error(
                Some(request_id.to_owned()),
                "computer_use_authority_rejected",
                "server-consumed computer-use approval could not be claimed",
                false,
            );
        }
        return;
    }
    let Some(ledger_path) = ledger_path else {
        state
            .lock()
            .await
            .proposals
            .finish_execution(proposal_id, ProposalStatus::Failed);
        error(
            Some(request_id.to_owned()),
            "computer_use_unavailable",
            "computer use host state is unavailable",
            false,
        );
        return;
    };
    let authority_expires_at_ms = authority_receipt
        .expires_at_ms
        .min(action.bound.expires_at_ms);
    let outcome = execute_bound_computer_use(
        action,
        authority_receipt.policy_generation,
        authority_expires_at_ms,
        ledger_path,
        cancellation,
    )
    .await;
    let status = match outcome {
        Ok(ExecutionOutcome::Succeeded) => {
            progress(
                request_id,
                "computer_use",
                ToolStatus::Complete,
                Some("approved computer action completed"),
            );
            ProposalStatus::Succeeded
        }
        Ok(ExecutionOutcome::OutcomeUnknown) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_outcome_unknown",
                "the approved computer action outcome is unknown and must not be retried automatically",
                false,
            );
            ProposalStatus::OutcomeUnknown
        }
        Ok(ExecutionOutcome::Rejected) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_rejected",
                "the semantic computer action was rejected before an effect",
                false,
            );
            ProposalStatus::Failed
        }
        Ok(ExecutionOutcome::Failed) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_failed",
                "the approved computer action failed verification",
                false,
            );
            ProposalStatus::Failed
        }
        Ok(ExecutionOutcome::CancelledBeforeEffect) => {
            cancelled(request_id);
            ProposalStatus::CancelledBeforeEffect
        }
        Ok(ExecutionOutcome::ExpiredBeforeEffect) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_expired",
                "the approved computer action expired before an effect",
                false,
            );
            ProposalStatus::ExpiredBeforeEffect
        }
        Err(ComputerUseError::AuthorityUnavailable) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_authority_unavailable",
                "host computer-use authority is unavailable",
                false,
            );
            ProposalStatus::Failed
        }
        Err(ComputerUseError::Protocol | ComputerUseError::TargetUnavailable) => {
            error(
                Some(request_id.to_owned()),
                "computer_use_failed",
                "the approved computer action could not be executed safely",
                false,
            );
            ProposalStatus::Failed
        }
    };
    state
        .lock()
        .await
        .proposals
        .finish_execution(proposal_id, status);
}

fn approval_decision_acknowledgement(
    request_id: &str,
    proposal_id: &str,
    decision: ApprovalDecision,
    accepted: bool,
    execution_pending: bool,
) {
    NativeEvent::ApprovalDecisionAcknowledged(ApprovalDecisionAcknowledgement {
        request_id: request_id.to_owned(),
        proposal_id: proposal_id.to_owned(),
        decision,
        accepted,
        execution_pending,
    })
    .send();
}

fn acknowledge_approval_rejection(command: &Command, request_id: &str) {
    if let Command::ApprovalDecision {
        proposal_id,
        decision,
        ..
    } = command
    {
        approval_decision_acknowledgement(request_id, proposal_id, *decision, false, false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::AudioEncoding;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Instant;

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
                    tier: zkr::MemoryTier::LongTerm,
                    processing_state: zkr::MemoryProcessingState::Processed,
                }),
            })
            .unwrap_or_else(|error_value| panic!("memory is seeded: {error_value}"));
        (path, memory, remembered)
    }

    #[test]
    fn extracted_candidate_claims_are_stored_with_derived_ingestion_keys() {
        let (path, mut memory, _) = lifecycle_memory("extraction");
        let output = r#"[
            {"title":"book flight","description":"to Berlin","priority":8,"action":"open airline site"},
            {"title":"email Sam","description":"about the review","priority":3,"action":"send draft"}
        ]"#;
        let claims = crate::extraction::candidate_claims(output, 10);
        assert_eq!(claims.len(), 2);
        let stored = store_candidate_claims(&mut memory, "transcript-1", 10, 11, claims)
            .unwrap_or_else(|error_value| panic!("claims store: {error_value}"));
        assert_eq!(stored, 2);
        let replayed = crate::extraction::candidate_claims(output, 10);
        store_candidate_claims(&mut memory, "transcript-1", 10, 11, replayed)
            .unwrap_or_else(|error_value| panic!("claims replay: {error_value}"));
        drop(memory);
        let _ = std::fs::remove_file(path);
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
                    tier: zkr::MemoryTier::LongTerm,
                    processing_state: zkr::MemoryProcessingState::Processed,
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
                        tier: zkr::MemoryTier::LongTerm,
                        processing_state: zkr::MemoryProcessingState::Processed,
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
                    .send(Ok(AssistantProviderEvent::Proposal(Box::new(
                        BoundActionProposal {
                            proposal,
                            bound_computer_action: None,
                        },
                    ))))
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
            operation_id: None,
            action_hash: None,
            target_provenance: None,
            expires_at_ms: Some(expires_at_ms),
        }
    }

    #[test]
    fn computer_use_tool_calls_are_strict_and_proposal_bound() {
        let proposal = computer_use_proposal(
            "chat-1",
            "call_1",
            COMPUTER_INVOKE_TOOL,
            serde_json::json!({
                "target_name": "Save",
                "background_only": true
            }),
        )
        .unwrap_or_else(|failure| panic!("valid click proposal: {failure}"));

        assert_eq!(proposal.proposal_id, "chat-1:tool:call_1");
        assert_eq!(proposal.request_id, "chat-1");
        assert_eq!(proposal.risk, ActionRisk::Destructive);
        assert_eq!(
            proposal.computer_action,
            Some(ComputerUseAction::Invoke {
                target_name: "Save".to_owned(),
                background_only: true,
            })
        );
        assert!(proposal.expires_at_ms.is_some());
    }

    #[test]
    fn computer_use_tool_calls_reject_unknown_or_unsafe_arguments() {
        for arguments in [
            serde_json::json!({
                "target_name": "Email",
                "value": "hello",
                "background_only": false,
                "unexpected": true
            }),
            serde_json::json!({
                "target_name": "",
                "value": "hello",
                "background_only": false
            }),
            serde_json::json!({
                "target_name": "Email",
                "value": "x".repeat(16 * 1024 + 1),
                "background_only": false
            }),
        ] {
            assert!(
                computer_use_proposal("chat-1", "call_1", COMPUTER_SET_VALUE_TOOL, arguments)
                    .is_err()
            );
        }
        assert!(
            computer_use_proposal(
                "chat-1",
                "call/1",
                COMPUTER_INVOKE_TOOL,
                serde_json::json!({
                    "target_name": "Save",
                    "background_only": false
                }),
            )
            .is_err()
        );
    }

    #[test]
    fn computer_use_receipt_must_match_the_prepared_action() {
        let action = crate::computer_use::test_bound(
            ComputerUseAction::Invoke {
                target_name: "Save".to_owned(),
                background_only: false,
            },
            ActionRisk::Destructive,
        );
        let now = unix_time_ms();
        let mut receipt = ComputerUseAuthorityReceipt {
            version: COMPUTER_USE_RECEIPT_VERSION.to_owned(),
            execution_id: "11111111-1111-1111-1111-111111111111".to_owned(),
            receipt_id: "22222222-2222-2222-2222-222222222222".to_owned(),
            receipt_token: "a".repeat(43),
            firebase_token: "firebase-token".to_owned(),
            subject: "user-a".to_owned(),
            policy_generation: 7,
            operation_id: action.operation_id.clone(),
            proposal_id: "proposal-1".to_owned(),
            action_hash: action.action_hash().to_owned(),
            risk: ActionRisk::Destructive,
            issued_at_ms: now,
            expires_at_ms: now.saturating_add(30_000),
        };

        assert!(validate_computer_use_receipt(
            &receipt,
            "proposal-1",
            "user-a",
            ActionRisk::Destructive,
            &action,
        ));
        receipt.operation_id = "different-operation".to_owned();
        assert!(!validate_computer_use_receipt(
            &receipt,
            "proposal-1",
            "user-a",
            ActionRisk::Destructive,
            &action,
        ));
    }

    #[cfg(all(
        feature = "computer-use",
        any(target_os = "macos", target_os = "windows", target_os = "linux")
    ))]
    #[tokio::test]
    async fn failed_receipt_claim_cannot_reach_authority_mint() {
        let action = ComputerUseAction::Invoke {
            target_name: "Save".to_owned(),
            background_only: false,
        };
        let bound = crate::computer_use::test_bound(action.clone(), ActionRisk::Destructive);
        let now = unix_time_ms();
        let receipt = ComputerUseAuthorityReceipt {
            version: COMPUTER_USE_RECEIPT_VERSION.to_owned(),
            execution_id: "execution-1".to_owned(),
            receipt_id: "receipt-1".to_owned(),
            receipt_token: "a".repeat(43),
            firebase_token: "firebase-token".to_owned(),
            subject: "user-a".to_owned(),
            policy_generation: 7,
            operation_id: bound.operation_id.clone(),
            proposal_id: "claim-failure".to_owned(),
            action_hash: bound.action_hash().to_owned(),
            risk: ActionRisk::Destructive,
            issued_at_ms: now,
            expires_at_ms: now.saturating_add(30_000),
        };
        let mut runtime = RuntimeState {
            configuration_generation: 7,
            authority_uid: Some("user-a".to_owned()),
            managed_worker_origin: Some("https://localhost".to_owned()),
            computer_use_ledger_path: Some(PathBuf::from("unused-ledger.jsonl")),
            ..RuntimeState::default()
        };
        runtime
            .proposals
            .register_bound(
                "user-a",
                7,
                ActionProposal {
                    proposal_id: "claim-failure".to_owned(),
                    request_id: "chat-g7-1".to_owned(),
                    title: "Invoke interface element".to_owned(),
                    summary: "Invoke Save".to_owned(),
                    risk: ActionRisk::Destructive,
                    computer_action: Some(action),
                    operation_id: Some(bound.operation_id.clone()),
                    action_hash: Some(bound.action_hash().to_owned()),
                    target_provenance: Some(bound.bound.provenance.clone()),
                    expires_at_ms: Some(bound.bound.expires_at_ms),
                },
                Some(bound),
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        let state = Mutex::new(runtime);
        let attempts = crate::computer_use::authority_mint_attempts();

        decide_approval_with_availability(
            "approval-claim-failure",
            &state,
            "claim-failure",
            ApprovalDecision::ApproveOnce,
            Some(receipt),
            ApprovalExecutionContext {
                generation: 7,
                computer_use_is_available: true,
            },
            &CancellationToken::new(),
        )
        .await;

        assert_eq!(crate::computer_use::authority_mint_attempts(), attempts);
        assert_eq!(
            state.lock().await.proposals.terminal["claim-failure"].status,
            ProposalStatus::Failed
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
    fn computer_tools_require_configuration_and_runtime_availability() {
        assert!(should_enable_computer_tools(true, true));
        assert!(!should_enable_computer_tools(true, false));
        assert!(!should_enable_computer_tools(false, true));
        assert!(!should_enable_computer_tools(false, false));
    }

    #[test]
    fn runtime_computer_use_availability_matches_structured_capabilities() {
        let status = runtime_status(false);
        assert_eq!(
            status.computer_use_available,
            status
                .computer_use_capabilities
                .as_ref()
                .is_some_and(|capabilities| capabilities
                    .actions
                    .iter()
                    .any(|action| action.available)),
        );
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
                    operation_id: None,
                    action_hash: None,
                    target_provenance: None,
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
                true,
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
                true,
            )
            .unwrap_or_else(|failure| panic!("proposal is approved: {failure:?}"));
        let (decided, action) = decided;
        assert_eq!(action, None);
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
            registry.decide(
                "proposal-1",
                "user-a",
                4,
                ApprovalDecision::Reject,
                100,
                true,
            ),
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
                    operation_id: None,
                    action_hash: None,
                    target_provenance: None,
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
                true,
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
        let action = ComputerUseAction::SetValue {
            target_name: "Message".to_owned(),
            value: "approved text".to_owned(),
            background_only: false,
        };
        let bound = crate::computer_use::test_bound(action.clone(), ActionRisk::External);
        registry
            .register_bound(
                "user-a",
                7,
                ActionProposal {
                    proposal_id: "computer-1".to_owned(),
                    request_id: "chat-g7-1".to_owned(),
                    title: "Type approved text".to_owned(),
                    summary: "Replace the focused field".to_owned(),
                    risk: ActionRisk::External,
                    computer_action: Some(action.clone()),
                    operation_id: Some(bound.operation_id.clone()),
                    action_hash: Some(bound.action_hash().to_owned()),
                    target_provenance: Some(bound.bound.provenance.clone()),
                    expires_at_ms: Some(i64::MAX),
                },
                Some(bound.clone()),
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        assert_eq!(
            registry.decide(
                "computer-1",
                "user-a",
                7,
                ApprovalDecision::ApproveOnce,
                100,
                false,
            ),
            Err(ProposalDecisionError::ExecutionUnavailable)
        );
        assert!(registry.pending.contains_key("computer-1"));
        assert_eq!(
            registry.decide(
                "computer-1",
                "user-a",
                7,
                ApprovalDecision::ApproveOnce,
                100,
                true,
            ),
            Ok((registry.terminal["computer-1"].clone(), Some(bound)))
        );
        assert_eq!(
            registry.decide(
                "computer-1",
                "user-a",
                7,
                ApprovalDecision::ApproveOnce,
                100,
                true,
            ),
            Err(ProposalDecisionError::AlreadyDecided)
        );
        assert_eq!(
            registry.terminal["computer-1"].status,
            ProposalStatus::Approved
        );
        registry.finish_execution("computer-1", ProposalStatus::Succeeded);
        assert_eq!(
            registry.terminal["computer-1"].status,
            ProposalStatus::Succeeded
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
                    operation_id: None,
                    action_hash: None,
                    target_provenance: None,
                    expires_at_ms: Some(i64::MAX),
                },
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        assert_eq!(
            registry
                .decide(
                    "non-computer",
                    "user-a",
                    7,
                    ApprovalDecision::ApproveOnce,
                    100,
                    true,
                )
                .map(|(record, action)| (record.status, action)),
            Ok((ProposalStatus::Approved, None))
        );
        assert!(!registry.pending.contains_key("non-computer"));
    }

    #[tokio::test]
    async fn cancellation_before_acceptance_preserves_the_pending_proposal() {
        let action = ComputerUseAction::Invoke {
            target_name: "Save".to_owned(),
            background_only: false,
        };
        let bound = crate::computer_use::test_bound(action.clone(), ActionRisk::Reversible);
        let mut runtime = RuntimeState {
            configuration_generation: 3,
            authority_uid: Some("user-a".to_owned()),
            ..RuntimeState::default()
        };
        runtime
            .proposals
            .register_bound(
                "user-a",
                3,
                ActionProposal {
                    proposal_id: "cancel-before-accept".to_owned(),
                    request_id: "chat-g3-1".to_owned(),
                    title: "Click".to_owned(),
                    summary: "Click once".to_owned(),
                    risk: ActionRisk::Reversible,
                    computer_action: Some(action),
                    operation_id: Some(bound.operation_id.clone()),
                    action_hash: Some(bound.action_hash().to_owned()),
                    target_provenance: Some(bound.bound.provenance.clone()),
                    expires_at_ms: Some(i64::MAX),
                },
                Some(bound),
            )
            .unwrap_or_else(|failure| panic!("proposal registers: {failure:?}"));
        let state = Mutex::new(runtime);
        let cancellation = CancellationToken::new();
        cancellation.cancel();

        decide_approval(
            "approval-1",
            &state,
            "cancel-before-accept",
            ApprovalDecision::ApproveOnce,
            None,
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
                    true,
                )
                .unwrap_or_else(|failure| panic!("pending proposal rejects: {failure:?}"));
        }
        for index in 0..=TERMINAL_PROPOSAL_CAPACITY {
            let id = format!("terminal-{index}");
            registry
                .register("user-a", 1, action_proposal(&id, "chat-2", i64::MAX))
                .unwrap_or_else(|failure| panic!("terminal proposal registers: {failure:?}"));
            registry
                .decide(&id, "user-a", 1, ApprovalDecision::Reject, 0, true)
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
                AssistantProviderEvent::Proposal(Box::new(BoundActionProposal {
                    proposal: action_proposal("proposal-live", request_id, i64::MAX),
                    bound_computer_action: None,
                })),
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
            events: StdMutex::new(Some(vec![AssistantProviderEvent::Proposal(Box::new(
                BoundActionProposal {
                    proposal: action_proposal("proposal-cancelled", "chat-g7-2", i64::MAX),
                    bound_computer_action: None,
                },
            ))])),
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
