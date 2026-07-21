use crate::signals::{
    ActionProposal, ActionRisk, ApprovalDecision, AssistantDelta,
    AssistantProvider as ProviderKind, AudioChunk, CaptureSource, ClientCommand, Command,
    MemoryCaptured, MemorySearchItem, MemorySearchResults, NativeError, NativeEvent, RuntimePhase,
    RuntimeStatus, ToolProgress, ToolStatus,
};
use futures::StreamExt;
use rs_ai_core::StreamEvent;
use std::collections::{HashMap, VecDeque, hash_map::Entry};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::{Mutex, mpsc};
use tokio::task::{JoinError, JoinHandle, JoinSet, spawn_blocking};
use tokio_util::sync::CancellationToken;
use url::{Host, Url};
use zkr::{MemoryDb, MemoryRef, PersonId, RememberInput, SearchInput, SourceKind, TenantId};

const COMMAND_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_COMMANDS: usize = 32;
const COMPLETED_CAPTURE_CAPACITY: usize = 256;
const PENDING_PROPOSAL_CAPACITY: usize = 64;
const TERMINAL_PROPOSAL_CAPACITY: usize = 256;
const PROVIDER_CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const PROVIDER_EVENT_TIMEOUT: Duration = Duration::from_secs(45);
const AUDIO_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

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
    next_sequence: u64,
    accepted_bytes: u64,
    sample_rate_hz: u32,
    channels: u8,
    encoding: crate::signals::AudioEncoding,
    last_seen: Instant,
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
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
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
}

impl AssistantProvider for RsAiAssistantProvider {
    fn dispatch(
        &self,
        _request_id: String,
        text: String,
        cancellation: CancellationToken,
    ) -> mpsc::Receiver<Result<AssistantProviderEvent, String>> {
        let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        let config = self.config.clone();
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
                    Ok(StreamEvent::MessageEnd { .. }) => Ok(AssistantProviderEvent::Delta {
                        text: String::new(),
                        final_segment: true,
                    }),
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
    Ok(AssistantProviderConfig::from_values(value)?
        .map(|config| Arc::new(RsAiAssistantProvider { config }) as Arc<dyn AssistantProvider>))
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
    sessions: AudioSessions,
}

impl AudioDispatcher {
    pub fn channel() -> (mpsc::Sender<AudioChunk>, Self) {
        let (sender, receiver) = mpsc::channel(AUDIO_QUEUE_CAPACITY);
        (
            sender,
            Self {
                receiver,
                sessions: AudioSessions::default(),
            },
        )
    }

    pub async fn run(mut self) {
        while let Some(chunk) = self.receiver.recv().await {
            match self.sessions.accept(chunk) {
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
            }
        }
    }
}

impl AudioSessions {
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
        if !self.0.contains_key(&chunk.request_id) && self.0.len() >= MAX_ACTIVE_AUDIO_SESSIONS {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "audio_capacity_exceeded",
                message: "too many active audio sessions".to_owned(),
            });
        }
        let session = self
            .0
            .entry(chunk.request_id.clone())
            .or_insert_with(|| AudioSession {
                next_sequence: 0,
                accepted_bytes: 0,
                sample_rate_hz: chunk.sample_rate_hz,
                channels: chunk.channels,
                encoding: chunk.encoding,
                last_seen: now,
            });
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
        session.next_sequence = next_sequence;
        session.accepted_bytes = accepted_bytes;
        session.last_seen = now;
        let progress = if chunk.end_of_stream {
            self.0.remove(&chunk.request_id);
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
}

impl CommandDispatcher {
    pub fn channel() -> (mpsc::Sender<ClientCommand>, Self) {
        let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        (
            sender,
            Self {
                receiver,
                state: Arc::new(Mutex::new(RuntimeState::default())),
                active: Arc::new(Mutex::new(HashMap::new())),
                assistant_provider: Arc::new(StdMutex::new(production_assistant_provider())),
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
                            Arc::new(RsAiAssistantProvider { config });
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
                        error(
                            Some(request_id),
                            "command_capacity_exceeded",
                            "too many active commands",
                            true,
                        );
                        continue;
                    }
                    Err(ActivationError::Duplicate) => {
                        error(
                            Some(request_id),
                            "duplicate_request",
                            "request_id is already active",
                            false,
                        );
                        continue;
                    }
                    Err(ActivationError::Conflict) => {
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
                    state.configuration_generation =
                        state.configuration_generation.saturating_add(1);
                    if let Command::ConfigureMemory { person_id, .. } = &command.command {
                        state.authority_uid = Some(person_id.clone());
                    }
                    Some(state.configuration_generation)
                } else {
                    None
                };
            let state = Arc::clone(&self.state);
            let assistant_provider = self
                .assistant_provider
                .lock()
                .unwrap_or_else(|failure| failure.into_inner())
                .clone();
            tasks.spawn(async move {
                let outcome = tokio::spawn(execute(
                    command,
                    state,
                    assistant_provider,
                    cancellation,
                    configuration_generation,
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
            text,
            application,
            window_title,
        } => Some(CaptureFingerprint {
            ingestion_key: ingestion_key.clone(),
            source: source.clone(),
            occurred_at_ms: *occurred_at_ms,
            text: text.clone(),
            application: application.clone(),
            window_title: window_title.clone(),
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
            text,
            application,
            window_title,
        } => {
            capture(
                &request_id,
                &state,
                ingestion_key,
                source,
                occurred_at_ms,
                text,
                application,
                window_title,
                &cancellation,
            )
            .await
        }
        Command::SearchMemory { query, limit } => {
            search(&request_id, &state, query, limit, &cancellation).await;
            false
        }
        Command::SendMessage { text, .. } => {
            dispatch_assistant(&request_id, &state, assistant_provider, text, &cancellation).await;
            false
        }
        Command::ConfigureAssistant { .. }
        | Command::ConfigureTrustedAssistant { .. }
        | Command::ClearAssistant => false,
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

fn configuration_is_current(state: &RuntimeState, generation: u64) -> bool {
    state.configuration_generation == generation
}

#[allow(clippy::too_many_arguments)]
async fn capture(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
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
        text,
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

fn spawn_capture(
    memory: Arc<StdMutex<MemoryContext>>,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    text: String,
    cancellation: CancellationToken,
) -> JoinHandle<Result<Option<zkr::Remembered>, String>> {
    spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        if cancellation.is_cancelled() {
            return Ok(None);
        }
        remember_capture(&mut memory, ingestion_key, source, occurred_at_ms, text).map(Some)
    })
}

fn remember_capture(
    memory: &mut MemoryContext,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    text: String,
) -> Result<zkr::Remembered, String> {
    memory
        .database
        .remember(RememberInput {
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            ingestion_key: Some(ingestion_key),
            kind: source_kind(source),
            text,
            captured_at: occurred_at_ms,
            claim: None,
        })
        .map_err(|error_value| error_value.to_string())
}

async fn search(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    query: String,
    limit: u32,
    cancellation: &CancellationToken,
) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::AudioEncoding;
    use std::sync::atomic::{AtomicBool, Ordering};

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
            expires_at_ms: Some(expires_at_ms),
        }
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
            text: Some(text.to_owned()),
            application: None,
            window_title: None,
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
            "first capture".to_owned(),
        )
        .unwrap_or_else(|error_value| panic!("first capture succeeds: {error_value}"));
        drop(first_database);

        let mut reopened_database = open();
        let replay = remember_capture(
            &mut reopened_database,
            "capture-1".to_owned(),
            CaptureSource::Screen,
            1,
            "first capture".to_owned(),
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
        };
        let running = tokio::spawn(dispatcher.run());
        let capture = |request_id: &str, text: &str, occurred_at_ms| ClientCommand {
            request_id: request_id.to_owned(),
            command: Command::CaptureEvent {
                ingestion_key: "stable-transcript-1".to_owned(),
                source: CaptureSource::OmiDevice,
                occurred_at_ms,
                text: Some(text.to_owned()),
                application: None,
                window_title: None,
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
                "changed payload".to_owned(),
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
            "remember this".to_owned(),
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
                "different payload".to_owned(),
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
        let state = RuntimeState {
            memory: None,
            configuration_generation: 2,
            ..RuntimeState::default()
        };
        assert!(!configuration_is_current(&state, 1));
        assert!(configuration_is_current(&state, 2));
    }

    #[test]
    fn audio_consumer_enforces_sequence_and_resets_after_end() {
        let mut sessions = AudioSessions::default();
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
        assert!(sessions.accept(chunk(0, false)).is_ok());
    }

    #[test]
    fn audio_consumer_bounds_active_sessions() {
        let mut sessions = AudioSessions::default();
        for index in 0..MAX_ACTIVE_AUDIO_SESSIONS {
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
        assert!(
            sessions
                .accept(AudioChunk {
                    request_id: "one-too-many".to_owned(),
                    sequence: 0,
                    sample_rate_hz: 16_000,
                    channels: 1,
                    encoding: AudioEncoding::Opus,
                    end_of_stream: false,
                    bytes: vec![1],
                })
                .is_err()
        );
    }

    #[test]
    fn audio_consumer_rejects_format_drift() {
        let mut sessions = AudioSessions::default();
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
        assert!(
            sessions
                .accept_at(
                    AudioChunk {
                        request_id: "replacement".to_owned(),
                        sequence: 0,
                        sample_rate_hz: 16_000,
                        channels: 1,
                        encoding: AudioEncoding::Opus,
                        end_of_stream: false,
                        bytes: vec![1],
                    },
                    started_at + AUDIO_SESSION_IDLE_TIMEOUT,
                )
                .is_ok()
        );
        assert_eq!(sessions.0.len(), 1);
    }

    #[test]
    fn audio_overflow_does_not_partially_advance_a_session() {
        let mut sessions = AudioSessions(HashMap::from([(
            "voice-1".to_owned(),
            AudioSession {
                next_sequence: u64::MAX,
                accepted_bytes: 7,
                sample_rate_hz: 16_000,
                channels: 1,
                encoding: AudioEncoding::Opus,
                last_seen: Instant::now(),
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
