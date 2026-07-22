use crate::signals::ComputerUseAction;

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use crate::signals::ActionRisk;

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use ed25519_dalek::{Signer, SigningKey};
#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use praefectus::semantic::{self, SemanticTargetRef};
#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use praefectus::{
    AckState, Action, ActionRequest, AuthorityGrant, BackgroundSupport, CancellationToken,
    DeliveryRoute, Ed25519AuthorityVerifier, Engine, Executor, InteractionMode, NativeExecutor,
    PROTOCOL_VERSION, SafetyClass, SignedAuthority, TargetRef, Terminal, VerificationPolicy,
    canonical_authority_bytes, normalized_action_hash,
};
#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use sha2::{Digest, Sha256};
#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use std::path::Path;
#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use std::sync::OnceLock;
#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_COMPUTER_VALUE_BYTES: usize = 16 * 1024;
const MAX_TARGET_NAME_BYTES: usize = 1_024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct BoundComputerUseAction {
    pub(crate) display: ComputerUseAction,
    #[cfg(all(
        feature = "computer-use",
        any(target_os = "macos", target_os = "windows", target_os = "linux")
    ))]
    target: SemanticTargetRef,
    pub(crate) expires_at_ms: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(
    not(all(
        feature = "computer-use",
        any(target_os = "macos", target_os = "windows", target_os = "linux")
    )),
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
    not(all(
        feature = "computer-use",
        any(target_os = "macos", target_os = "windows", target_os = "linux")
    )),
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

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn available() -> bool {
    NativeExecutor::default()
        .capabilities()
        .is_ok_and(|capabilities| {
            capabilities
                .supported_actions
                .iter()
                .any(|action| action == "invoke" || action == "set_value")
        })
}

#[cfg(not(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
)))]
pub(crate) fn available() -> bool {
    false
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
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
        expires_at_ms: observation.expires_at_ms,
    })
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn cancellation_token() -> CancellationToken {
    CancellationToken::default()
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn cancel(token: &CancellationToken) {
    token.cancel();
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn execute(
    bound: BoundComputerUseAction,
    operation_source: &str,
    uid: &str,
    policy_generation: u64,
    risk: ActionRisk,
    ledger_path: &Path,
    cancellation: &CancellationToken,
) -> Result<ExecutionOutcome, ComputerUseError> {
    let authority = host_authority()?;
    let operation_id = hashed_identifier("omi-op", operation_source);
    let subject = hashed_identifier("omi-user", uid);
    let policy_generation = format!("omi-policy:{policy_generation}");
    let safety = match risk {
        ActionRisk::Reversible => SafetyClass::Reversible,
        ActionRisk::External => SafetyClass::External,
        ActionRisk::Destructive => SafetyClass::Destructive,
    };
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
    let mut request = ActionRequest {
        protocol_version: PROTOCOL_VERSION,
        action_version: PROTOCOL_VERSION,
        target_version: PROTOCOL_VERSION,
        verification_version: PROTOCOL_VERSION,
        operation_id: operation_id.clone(),
        subject: subject.clone(),
        session_id: authority.session_id.clone(),
        authority: SignedAuthority {
            grant: AuthorityGrant {
                protocol_version: PROTOCOL_VERSION,
                issuer: "omi-v4".to_owned(),
                key_id: "process-key".to_owned(),
                operation_id,
                subject,
                session_id: authority.session_id.clone(),
                risk: safety,
                expires_at_ms: bound.expires_at_ms,
                policy_generation: policy_generation.clone(),
                action_hash: String::new(),
            },
            signature: String::new(),
        },
        action,
        target: TargetRef::Element {
            target: bound.target,
        },
        interaction_mode,
        deadline_at_ms: bound.expires_at_ms,
        verification,
        safety,
    };
    request.authority.grant.action_hash =
        normalized_action_hash(&request).map_err(|_| ComputerUseError::Protocol)?;
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
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
struct HostAuthority {
    signing_key: SigningKey,
    session_id: String,
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn host_authority() -> Result<&'static HostAuthority, ComputerUseError> {
    static HOST_AUTHORITY: OnceLock<HostAuthority> = OnceLock::new();
    if let Some(authority) = HOST_AUTHORITY.get() {
        return Ok(authority);
    }
    let mut key_bytes = [0_u8; 32];
    let mut session_bytes = [0_u8; 16];
    getrandom::fill(&mut key_bytes).map_err(|_| ComputerUseError::AuthorityUnavailable)?;
    getrandom::fill(&mut session_bytes).map_err(|_| ComputerUseError::AuthorityUnavailable)?;
    let _ = HOST_AUTHORITY.set(HostAuthority {
        signing_key: SigningKey::from_bytes(&key_bytes),
        session_id: format!("omi-session:{}", lower_hex(&session_bytes)),
    });
    HOST_AUTHORITY
        .get()
        .ok_or(ComputerUseError::AuthorityUnavailable)
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn hashed_identifier(prefix: &str, value: &str) -> String {
    format!("{prefix}:{}", lower_hex(&Sha256::digest(value.as_bytes())))
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn lower_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(all(
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            duration.as_millis().min(i64::MAX as u128) as i64
        })
}

#[cfg(all(
    test,
    feature = "computer-use",
    any(target_os = "macos", target_os = "windows", target_os = "linux")
))]
pub(crate) fn test_bound(display: ComputerUseAction) -> BoundComputerUseAction {
    BoundComputerUseAction {
        display,
        target: SemanticTargetRef {
            observation_id: "1".repeat(64),
            generation: 1,
            provenance_hash: "2".repeat(64),
            element_id: "3".repeat(64),
            fingerprint_hash: "4".repeat(64),
        },
        expires_at_ms: i64::MAX,
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
