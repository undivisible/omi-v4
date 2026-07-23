use crate::signals::{
    ActionRisk, ComputerUseAction, ComputerUseCapabilities, ComputerUseTargetProvenance,
};

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use crate::signals::{
    ComputerUseActionCapability, ComputerUseBackgroundSupport, ComputerUseDeliveryRoute,
    ComputerUsePermission, ComputerUseSessionIsolation,
};

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use ed25519_dalek::{Signer, SigningKey};
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use praefectus::semantic::{self, SemanticTargetRef};
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use praefectus::{
    AckState, Action, ActionRequest, AuthorityGrant, BackgroundSupport, CancellationToken,
    DeliveryRoute, Ed25519AuthorityVerifier, Engine, Executor, InteractionMode, NativeExecutor,
    PROTOCOL_VERSION, SafetyClass, SessionIsolation, SignedAuthority, TargetRef, Terminal,
    VerificationPolicy, canonical_authority_bytes, normalized_action_hash,
};
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use sha2::{Digest, Sha256};
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use std::path::Path;
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use std::sync::OnceLock;
#[cfg(all(
    test,
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use std::sync::atomic::{AtomicUsize, Ordering};
#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_COMPUTER_VALUE_BYTES: usize = 16 * 1024;
const MAX_TARGET_NAME_BYTES: usize = 1_024;
#[cfg(all(
    test,
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
static AUTHORITY_MINT_ATTEMPTS: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct BoundComputerUseAction {
    pub(crate) display: ComputerUseAction,
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    target: SemanticTargetRef,
    pub(crate) provenance: ComputerUseTargetProvenance,
    pub(crate) expires_at_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PreparedComputerUseAction {
    pub(crate) bound: BoundComputerUseAction,
    pub(crate) operation_id: String,
    subject: String,
    session_id: String,
    action_hash: String,
    #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
    safety: SafetyClass,
}

impl PreparedComputerUseAction {
    pub(crate) fn action_hash(&self) -> &str {
        &self.action_hash
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(
    not(any(target_os = "macos", target_os = "windows", target_os = "linux")),
    allow(dead_code)
)]
pub(crate) enum ExecutionOutcome {
    Succeeded,
    Rejected,
    Failed,
    CancelledBeforeEffect,
    ExpiredBeforeEffect,
    OutcomeUnknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(
    not(any(target_os = "macos", target_os = "windows", target_os = "linux")),
    allow(dead_code)
)]
pub(crate) enum ComputerUseError {
    AuthorityUnavailable,
    Protocol,
    TargetUnavailable,
}

pub(crate) fn valid_action(action: &ComputerUseAction) -> bool {
    match action {
        ComputerUseAction::Invoke {
            target_name,
            background_only: _,
        } => valid_target_name(target_name),
        ComputerUseAction::SetValue {
            target_name,
            value,
            background_only: _,
        } => valid_target_name(target_name) && value.len() <= MAX_COMPUTER_VALUE_BYTES,
    }
}

fn valid_target_name(target_name: &str) -> bool {
    !target_name.trim().is_empty() && target_name.len() <= MAX_TARGET_NAME_BYTES
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn available() -> bool {
    capabilities()
        .is_some_and(|capabilities| capabilities.actions.iter().any(|action| action.available))
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn capabilities() -> Option<ComputerUseCapabilities> {
    let native = NativeExecutor::default().capabilities().ok()?;
    let supported_actions = &native.supported_actions;
    Some(ComputerUseCapabilities {
        platform: native.platform,
        backend: native.backend,
        session_isolation: match native.session_isolation {
            SessionIsolation::SharedDesktop => ComputerUseSessionIsolation::SharedDesktop,
            SessionIsolation::HostIsolated => ComputerUseSessionIsolation::HostIsolated,
            SessionIsolation::Unknown => ComputerUseSessionIsolation::Unknown,
        },
        permissions: native
            .permissions
            .into_iter()
            .map(|(name, granted)| ComputerUsePermission { name, granted })
            .collect(),
        actions: native
            .action_capabilities
            .into_iter()
            .map(|capability| ComputerUseActionCapability {
                available: supported_actions
                    .iter()
                    .any(|action| action == &capability.action),
                name: capability.action,
                delivery_route: match capability.delivery_route {
                    DeliveryRoute::TargetAddressed => ComputerUseDeliveryRoute::TargetAddressed,
                    DeliveryRoute::Pointer => ComputerUseDeliveryRoute::Pointer,
                    DeliveryRoute::Unknown => ComputerUseDeliveryRoute::Unknown,
                },
                background_support: match capability.background_support {
                    BackgroundSupport::Guarded => ComputerUseBackgroundSupport::Guarded,
                    BackgroundSupport::HostIsolatedOnly => {
                        ComputerUseBackgroundSupport::HostIsolatedOnly
                    }
                    BackgroundSupport::Unavailable => ComputerUseBackgroundSupport::Unavailable,
                },
            })
            .collect(),
    })
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
pub(crate) fn available() -> bool {
    false
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
pub(crate) fn capabilities() -> Option<ComputerUseCapabilities> {
    None
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn bind(
    display: ComputerUseAction,
    cancellation: &CancellationToken,
) -> Result<BoundComputerUseAction, ComputerUseError> {
    if !valid_action(&display) {
        return Err(ComputerUseError::TargetUnavailable);
    }
    let deadline_at_ms = now_ms().saturating_add(30_000);
    let executor = NativeExecutor::default();
    let capabilities = executor
        .capabilities()
        .map_err(|_| ComputerUseError::TargetUnavailable)?;
    let action_name = match &display {
        ComputerUseAction::Invoke { .. } => "invoke",
        ComputerUseAction::SetValue { .. } => "set_value",
    };
    let mut action_capabilities = capabilities
        .action_capabilities
        .iter()
        .filter(|capability| capability.action == action_name);
    let capability = action_capabilities
        .next()
        .ok_or(ComputerUseError::TargetUnavailable)?;
    if action_capabilities.next().is_some()
        || !capabilities
            .supported_actions
            .iter()
            .any(|supported| supported == action_name)
        || matches!(
            &display,
            ComputerUseAction::Invoke {
                background_only: true,
                ..
            } | ComputerUseAction::SetValue {
                background_only: true,
                ..
            }
        ) && (capability.delivery_route != DeliveryRoute::TargetAddressed
            || capability.background_support != BackgroundSupport::Guarded)
    {
        return Err(ComputerUseError::TargetUnavailable);
    }
    let observation = executor
        .observe_semantic(cancellation, deadline_at_ms)
        .map_err(|_| ComputerUseError::TargetUnavailable)?;
    observation
        .validate(now_ms())
        .map_err(|_| ComputerUseError::TargetUnavailable)?;
    let target_name = match &display {
        ComputerUseAction::Invoke { target_name, .. }
        | ComputerUseAction::SetValue { target_name, .. } => target_name,
    };
    let mut matches = observation
        .elements
        .iter()
        .filter(|element| element.name.as_deref() == Some(target_name.as_str()));
    let element = matches.next().ok_or(ComputerUseError::TargetUnavailable)?;
    if matches.next().is_some() {
        return Err(ComputerUseError::TargetUnavailable);
    }
    let target = observation
        .target(&element.tag)
        .map_err(|_| ComputerUseError::TargetUnavailable)?;
    let provenance = ComputerUseTargetProvenance {
        process_id: observation.provenance.process_id,
        process_generation: observation.provenance.process_generation.clone(),
        window_id: observation.provenance.window_id.clone(),
        role: element.role.clone(),
        observation_generation: observation.generation,
    };
    let action = match &display {
        ComputerUseAction::Invoke { .. } => Action::Invoke,
        ComputerUseAction::SetValue { value, .. } => Action::SetValue {
            value: value.clone(),
        },
    };
    semantic::route_action(&action, &observation, &target, now_ms())
        .map_err(|_| ComputerUseError::TargetUnavailable)?;
    Ok(BoundComputerUseAction {
        display,
        target,
        provenance,
        expires_at_ms: observation.expires_at_ms,
    })
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn cancellation_token() -> CancellationToken {
    CancellationToken::default()
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn cancel(token: &CancellationToken) {
    token.cancel();
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn prepare(
    bound: BoundComputerUseAction,
    operation_source: &str,
    uid: &str,
    risk: ActionRisk,
) -> Result<PreparedComputerUseAction, ComputerUseError> {
    let session_id = host_session_id()?;
    let operation_id = hashed_identifier("omi-op", operation_source);
    let subject = hashed_identifier("omi-user", uid);
    let safety = safety_class(risk);
    let request = unsigned_request(
        &bound,
        &operation_id,
        &subject,
        session_id,
        safety,
        bound.expires_at_ms,
        "unissued",
    );
    let action_hash = normalized_action_hash(&request).map_err(|_| ComputerUseError::Protocol)?;
    Ok(PreparedComputerUseAction {
        bound,
        operation_id,
        subject,
        session_id: session_id.to_owned(),
        action_hash,
        safety,
    })
}

#[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
pub(crate) fn prepare(
    _bound: BoundComputerUseAction,
    _operation_source: &str,
    _uid: &str,
    _risk: ActionRisk,
) -> Result<PreparedComputerUseAction, ComputerUseError> {
    Err(ComputerUseError::TargetUnavailable)
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn safety_class(risk: ActionRisk) -> SafetyClass {
    match risk {
        ActionRisk::Reversible => SafetyClass::Reversible,
        ActionRisk::External => SafetyClass::External,
        ActionRisk::Destructive => SafetyClass::Destructive,
    }
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn unsigned_request(
    bound: &BoundComputerUseAction,
    operation_id: &str,
    subject: &str,
    session_id: &str,
    safety: SafetyClass,
    authority_expires_at_ms: i64,
    policy_generation: &str,
) -> ActionRequest {
    let interaction_mode = match &bound.display {
        ComputerUseAction::Invoke {
            background_only, ..
        }
        | ComputerUseAction::SetValue {
            background_only, ..
        } if *background_only => InteractionMode::BackgroundOnly,
        _ => InteractionMode::Interactive,
    };
    let action = match &bound.display {
        ComputerUseAction::Invoke { .. } => Action::Invoke,
        ComputerUseAction::SetValue { value, .. } => Action::SetValue {
            value: value.clone(),
        },
    };
    let verification = match &action {
        Action::SetValue { value } => VerificationPolicy::TargetValueHash {
            sha256: lower_hex(&Sha256::digest(value.as_bytes())),
        },
        _ => VerificationPolicy::None,
    };
    ActionRequest {
        protocol_version: PROTOCOL_VERSION,
        action_version: PROTOCOL_VERSION,
        target_version: PROTOCOL_VERSION,
        verification_version: PROTOCOL_VERSION,
        operation_id: operation_id.to_owned(),
        subject: subject.to_owned(),
        session_id: session_id.to_owned(),
        authority: SignedAuthority {
            grant: AuthorityGrant {
                protocol_version: PROTOCOL_VERSION,
                issuer: "omi-v4".to_owned(),
                key_id: "process-key".to_owned(),
                operation_id: operation_id.to_owned(),
                subject: subject.to_owned(),
                session_id: session_id.to_owned(),
                risk: safety,
                expires_at_ms: authority_expires_at_ms,
                policy_generation: policy_generation.to_owned(),
                action_hash: String::new(),
            },
            signature: String::new(),
        },
        action,
        target: TargetRef::Element {
            target: bound.target.clone(),
        },
        interaction_mode,
        deadline_at_ms: bound.expires_at_ms,
        verification,
        safety,
    }
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
pub(crate) fn execute(
    prepared: PreparedComputerUseAction,
    policy_generation: u64,
    authority_expires_at_ms: i64,
    ledger_path: &Path,
    cancellation: &CancellationToken,
) -> Result<ExecutionOutcome, ComputerUseError> {
    #[cfg(test)]
    AUTHORITY_MINT_ATTEMPTS.fetch_add(1, Ordering::SeqCst);
    let authority = host_authority()?;
    if host_session_id()? != prepared.session_id
        || now_ms() >= authority_expires_at_ms
        || authority_expires_at_ms > prepared.bound.expires_at_ms
    {
        return Err(ComputerUseError::Protocol);
    }
    let policy_generation = format!("omi-policy:{policy_generation}");
    let mut request = unsigned_request(
        &prepared.bound,
        &prepared.operation_id,
        &prepared.subject,
        &prepared.session_id,
        prepared.safety,
        authority_expires_at_ms,
        &policy_generation,
    );
    if normalized_action_hash(&request).map_err(|_| ComputerUseError::Protocol)?
        != prepared.action_hash
    {
        return Err(ComputerUseError::Protocol);
    }
    request.authority.grant.action_hash = prepared.action_hash;
    request.authority.signature = lower_hex(
        &authority
            .signing_key
            .sign(
                &canonical_authority_bytes(&request.authority.grant)
                    .map_err(|_| ComputerUseError::Protocol)?,
            )
            .to_bytes(),
    );
    let verifier = Ed25519AuthorityVerifier::new([(
        request.authority.grant.issuer.clone(),
        request.authority.grant.key_id.clone(),
        policy_generation,
        authority.signing_key.verifying_key(),
    )])
    .map_err(|_| ComputerUseError::Protocol)?;
    let report = Engine::new(NativeExecutor::default(), ledger_path, verifier)
        .execute(&request, cancellation)
        .map_err(|_| ComputerUseError::Protocol)?;
    report
        .acknowledgements
        .iter()
        .rev()
        .find_map(|acknowledgement| match &acknowledgement.state {
            AckState::Terminal { terminal } => Some(match &**terminal {
                Terminal::Succeeded { .. } => ExecutionOutcome::Succeeded,
                Terminal::Rejected { .. } => ExecutionOutcome::Rejected,
                Terminal::Failed { .. } => ExecutionOutcome::Failed,
                Terminal::CancelledBeforeEffect => ExecutionOutcome::CancelledBeforeEffect,
                Terminal::ExpiredBeforeEffect => ExecutionOutcome::ExpiredBeforeEffect,
                Terminal::OutcomeUnknown { .. } => ExecutionOutcome::OutcomeUnknown,
            }),
            _ => None,
        })
        .ok_or(ComputerUseError::Protocol)
}

#[cfg(all(
    test,
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn authority_mint_attempts() -> usize {
    AUTHORITY_MINT_ATTEMPTS.load(Ordering::SeqCst)
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
struct HostAuthority {
    signing_key: SigningKey,
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn host_authority() -> Result<&'static HostAuthority, ComputerUseError> {
    static HOST_AUTHORITY: OnceLock<HostAuthority> = OnceLock::new();
    if let Some(authority) = HOST_AUTHORITY.get() {
        return Ok(authority);
    }
    let mut key_bytes = [0_u8; 32];
    getrandom::fill(&mut key_bytes).map_err(|_| ComputerUseError::AuthorityUnavailable)?;
    let _ = HOST_AUTHORITY.set(HostAuthority {
        signing_key: SigningKey::from_bytes(&key_bytes),
    });
    HOST_AUTHORITY
        .get()
        .ok_or(ComputerUseError::AuthorityUnavailable)
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn host_session_id() -> Result<&'static str, ComputerUseError> {
    static HOST_SESSION_ID: OnceLock<String> = OnceLock::new();
    if let Some(session_id) = HOST_SESSION_ID.get() {
        return Ok(session_id);
    }
    let mut session_bytes = [0_u8; 16];
    getrandom::fill(&mut session_bytes).map_err(|_| ComputerUseError::AuthorityUnavailable)?;
    let _ = HOST_SESSION_ID.set(format!("omi-session:{}", lower_hex(&session_bytes)));
    HOST_SESSION_ID
        .get()
        .map(String::as_str)
        .ok_or(ComputerUseError::AuthorityUnavailable)
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn hashed_identifier(prefix: &str, value: &str) -> String {
    format!("{prefix}:{}", lower_hex(&Sha256::digest(value.as_bytes())))
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn lower_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            duration.as_millis().min(i64::MAX as u128) as i64
        })
}

#[cfg(test)]
pub(crate) fn test_bound(
    display: ComputerUseAction,
    risk: ActionRisk,
) -> PreparedComputerUseAction {
    #[cfg(not(any(target_os = "macos", target_os = "windows", target_os = "linux")))]
    let _ = risk;
    PreparedComputerUseAction {
        bound: BoundComputerUseAction {
            display,
            #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
            target: SemanticTargetRef {
                observation_id: "1".repeat(64),
                generation: 1,
                provenance_hash: "2".repeat(64),
                element_id: "3".repeat(64),
                fingerprint_hash: "4".repeat(64),
            },
            provenance: ComputerUseTargetProvenance {
                process_id: 1,
                process_generation: "test-process".to_owned(),
                window_id: "test-window".to_owned(),
                role: "button".to_owned(),
                observation_generation: 1,
            },
            expires_at_ms: i64::MAX,
        },
        operation_id: "omi-op:test".to_owned(),
        subject: "omi-user:test".to_owned(),
        session_id: "omi-session:test".to_owned(),
        action_hash: "5".repeat(64),
        #[cfg(any(target_os = "macos", target_os = "windows", target_os = "linux"))]
        safety: safety_class(risk),
    }
}

#[cfg(test)]
mod tests {
    use super::valid_action;
    use crate::signals::ComputerUseAction;

    #[test]
    fn semantic_actions_are_bounded() {
        assert!(valid_action(&ComputerUseAction::Invoke {
            target_name: "Save".to_owned(),
            background_only: false,
        }));
        assert!(valid_action(&ComputerUseAction::SetValue {
            target_name: "Email".to_owned(),
            value: String::new(),
            background_only: true,
        }));
        assert!(!valid_action(&ComputerUseAction::Invoke {
            target_name: " ".to_owned(),
            background_only: false,
        }));
        assert!(!valid_action(&ComputerUseAction::SetValue {
            target_name: "Email".to_owned(),
            value: "x".repeat(16 * 1024 + 1),
            background_only: false,
        }));
    }
}
