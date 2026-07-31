use crate::signals::{
    ActionRisk, ComputerUseAction, ComputerUseCapabilities, ComputerUseTargetProvenance,
};

#[cfg(target_os = "macos")]
use crate::signals::{
    ComputerUseActionCapability, ComputerUseBackgroundSupport, ComputerUseDeliveryRoute,
    ComputerUsePermission, ComputerUseSessionIsolation,
};

#[cfg(target_os = "macos")]
use ed25519_dalek::{Signer, SigningKey};
#[cfg(target_os = "macos")]
use praefectus::semantic::{self, SemanticTargetRef};
#[cfg(target_os = "macos")]
use praefectus::{
    AckState, Action, ActionRequest, AuthorityGrant, BackgroundSupport, CancellationToken,
    DeliveryRoute, Ed25519AuthorityVerifier, Engine, Executor, InteractionMode, NativeExecutor,
    PROTOCOL_VERSION, SafetyClass, SessionIsolation, SignedAuthority, TargetRef, Terminal,
    VerificationPolicy, canonical_authority_bytes, normalized_action_hash,
};
#[cfg(target_os = "macos")]
use sha2::{Digest, Sha256};
#[cfg(target_os = "macos")]
use std::path::Path;
#[cfg(target_os = "macos")]
use std::sync::OnceLock;
#[cfg(all(test, target_os = "macos"))]
use std::sync::atomic::{AtomicUsize, Ordering};
#[cfg(target_os = "macos")]
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_COMPUTER_VALUE_BYTES: usize = 16 * 1024;
const MAX_TARGET_NAME_BYTES: usize = 1_024;
#[cfg(all(test, target_os = "macos"))]
static AUTHORITY_MINT_ATTEMPTS: AtomicUsize = AtomicUsize::new(0);

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct BoundComputerUseAction {
    pub(crate) display: ComputerUseAction,
    #[cfg(target_os = "macos")]
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
    #[cfg(target_os = "macos")]
    safety: SafetyClass,
}

impl PreparedComputerUseAction {
    pub(crate) fn action_hash(&self) -> &str {
        &self.action_hash
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(crate) enum ExecutionOutcome {
    Succeeded,
    Rejected,
    Failed,
    CancelledBeforeEffect,
    ExpiredBeforeEffect,
    OutcomeUnknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
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

#[cfg(target_os = "macos")]
pub(crate) fn available() -> bool {
    capabilities()
        .is_some_and(|capabilities| capabilities.actions.iter().any(|action| action.available))
}

#[cfg(target_os = "macos")]
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
                    DeliveryRoute::PerProcessEvent => ComputerUseDeliveryRoute::PerProcessEvent,
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

#[cfg(not(target_os = "macos"))]
pub(crate) fn available() -> bool {
    false
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn capabilities() -> Option<ComputerUseCapabilities> {
    None
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
pub(crate) fn cancellation_token() -> CancellationToken {
    CancellationToken::default()
}

#[cfg(target_os = "macos")]
pub(crate) fn cancel(token: &CancellationToken) {
    token.cancel();
}

#[cfg(target_os = "macos")]
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

#[cfg(not(target_os = "macos"))]
pub(crate) fn prepare(
    _bound: BoundComputerUseAction,
    _operation_source: &str,
    _uid: &str,
    _risk: ActionRisk,
) -> Result<PreparedComputerUseAction, ComputerUseError> {
    Err(ComputerUseError::TargetUnavailable)
}

#[cfg(target_os = "macos")]
fn safety_class(risk: ActionRisk) -> SafetyClass {
    match risk {
        ActionRisk::Reversible => SafetyClass::Reversible,
        ActionRisk::External => SafetyClass::External,
        ActionRisk::Destructive => SafetyClass::Destructive,
    }
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(all(test, target_os = "macos"))]
pub(crate) fn authority_mint_attempts() -> usize {
    AUTHORITY_MINT_ATTEMPTS.load(Ordering::SeqCst)
}

#[cfg(target_os = "macos")]
struct HostAuthority {
    signing_key: SigningKey,
}

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
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

#[cfg(target_os = "macos")]
fn hashed_identifier(prefix: &str, value: &str) -> String {
    format!("{prefix}:{}", lower_hex(&Sha256::digest(value.as_bytes())))
}

#[cfg(target_os = "macos")]
fn lower_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(target_os = "macos")]
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
    #[cfg(not(target_os = "macos"))]
    let _ = risk;
    PreparedComputerUseAction {
        bound: BoundComputerUseAction {
            display,
            #[cfg(target_os = "macos")]
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
        #[cfg(target_os = "macos")]
        safety: safety_class(risk),
    }
}

#[cfg(test)]
mod tests {
    use super::valid_action;
    #[cfg(target_os = "macos")]
    use super::{ComputerUseError, available, bind, capabilities, prepare};
    #[cfg(target_os = "macos")]
    use crate::signals::ActionRisk;
    use crate::signals::ComputerUseAction;
    #[cfg(target_os = "macos")]
    use praefectus::CancellationToken;

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

    #[cfg(target_os = "macos")]
    #[test]
    fn native_praefectus_capabilities_probe_is_internally_consistent() {
        let status = capabilities();
        assert_eq!(
            available(),
            status
                .as_ref()
                .is_some_and(|caps| caps.actions.iter().any(|action| action.available))
        );
        let Some(caps) = status else {
            eprintln!("computer-use capabilities unavailable (permissions/backend)");
            return;
        };
        eprintln!(
            "computer-use probe: platform={} backend={} isolation={:?} permissions={} actions={}",
            caps.platform,
            caps.backend,
            caps.session_isolation,
            caps.permissions.len(),
            caps.actions.len()
        );
        for permission in &caps.permissions {
            eprintln!(
                "  permission {} granted={}",
                permission.name, permission.granted
            );
        }
        for action in &caps.actions {
            eprintln!(
                "  action {} available={} route={:?} background={:?}",
                action.name, action.available, action.delivery_route, action.background_support
            );
        }
        assert!(!caps.platform.is_empty());
        assert!(!caps.backend.is_empty());
        assert_eq!(caps.backend, "praefectus-macos-ax");
        let accessibility_granted = caps
            .permissions
            .iter()
            .find(|permission| permission.name == "accessibility")
            .is_some_and(|permission| permission.granted);
        if accessibility_granted {
            assert!(
                caps.actions.iter().any(|action| matches!(
                    action.name.as_str(),
                    "invoke" | "set_value"
                ) && action.available),
                "with Accessibility granted, invoke/set_value must be available"
            );
        } else {
            assert!(
                caps.actions.is_empty() || caps.actions.iter().all(|action| !action.available),
                "without Accessibility, computer-use actions must be unavailable"
            );
        }
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn bind_rejects_invalid_actions_before_observation() {
        let token = CancellationToken::default();
        assert_eq!(
            bind(
                ComputerUseAction::Invoke {
                    target_name: " ".to_owned(),
                    background_only: false,
                },
                &token,
            ),
            Err(ComputerUseError::TargetUnavailable)
        );
        assert_eq!(
            bind(
                ComputerUseAction::SetValue {
                    target_name: "Email".to_owned(),
                    value: "x".repeat(16 * 1024 + 1),
                    background_only: false,
                },
                &token,
            ),
            Err(ComputerUseError::TargetUnavailable)
        );
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn cancelled_bind_fails_closed_for_missing_target() {
        let token = CancellationToken::default();
        token.cancel();
        let result = bind(
            ComputerUseAction::Invoke {
                target_name: "omi-nonexistent-target-9f3c2a1b".to_owned(),
                background_only: false,
            },
            &token,
        );
        assert_eq!(result, Err(ComputerUseError::TargetUnavailable));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn prepare_mints_stable_operation_hash_for_bound_action() {
        let bound = super::BoundComputerUseAction {
            display: ComputerUseAction::Invoke {
                target_name: "Save".to_owned(),
                background_only: false,
            },
            target: praefectus::semantic::SemanticTargetRef {
                observation_id: "1".repeat(64),
                generation: 1,
                provenance_hash: "2".repeat(64),
                element_id: "3".repeat(64),
                fingerprint_hash: "4".repeat(64),
            },
            provenance: crate::signals::ComputerUseTargetProvenance {
                process_id: 42,
                process_generation: "gen".to_owned(),
                window_id: "win".to_owned(),
                role: "button".to_owned(),
                observation_generation: 7,
            },
            expires_at_ms: i64::MAX,
        };
        let first = prepare(
            bound.clone(),
            "proposal-a",
            "user-a",
            ActionRisk::Destructive,
        )
        .unwrap_or_else(|error| panic!("prepare failed: {error:?}"));
        let second = prepare(bound, "proposal-a", "user-a", ActionRisk::Destructive)
            .unwrap_or_else(|error| panic!("prepare failed: {error:?}"));
        assert_eq!(first.operation_id, second.operation_id);
        assert_eq!(first.action_hash(), second.action_hash());
        assert!(first.action_hash().len() >= 32);
        assert!(first.operation_id.starts_with("omi-op:"));
        assert_eq!(first.subject, second.subject);
        assert!(first.subject.starts_with("omi-user:"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn live_semantic_observation_when_permitted() {
        use super::now_ms;
        use praefectus::{CancellationToken, NativeExecutor};

        if std::env::var("OMI_LIVE_CU").as_deref() != Ok("1") {
            return;
        }
        let caps = capabilities().unwrap_or_else(|| {
            panic!("praefectus capabilities must resolve on macOS when OMI_LIVE_CU=1")
        });
        let accessibility_granted = caps
            .permissions
            .iter()
            .find(|permission| permission.name == "accessibility")
            .is_some_and(|permission| permission.granted);
        if !accessibility_granted {
            panic!(
                "OMI_LIVE_CU=1 but Accessibility is not granted. \
                 System Settings → Privacy & Security → Accessibility → enable Terminal or Cursor."
            );
        }
        let executor = NativeExecutor::default();
        let cancellation = CancellationToken::default();
        let deadline = now_ms().saturating_add(15_000);
        let observation = executor
            .observe_semantic(&cancellation, deadline)
            .unwrap_or_else(|error| {
                panic!("semantic observation failed with Accessibility granted: {error:?}")
            });
        observation
            .validate(now_ms())
            .unwrap_or_else(|error| panic!("observation invalid: {error:?}"));
        eprintln!(
            "live semantic observation: generation={} elements={}",
            observation.generation,
            observation.elements.len()
        );
        assert!(observation.generation > 0);
        assert!(
            caps.actions.iter().any(|action| {
                matches!(action.name.as_str(), "invoke" | "set_value") && action.available
            }),
            "invoke/set_value must be available when Accessibility is granted"
        );
    }
}
