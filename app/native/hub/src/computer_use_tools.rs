use crate::computer_use::valid_action;
use crate::signals::{ActionProposal, ActionRisk, ComputerUseAction};
use std::time::{SystemTime, UNIX_EPOCH};

pub(crate) const COMPUTER_INVOKE_TOOL: &str = "computer_invoke";
pub(crate) const COMPUTER_SET_VALUE_TOOL: &str = "computer_set_value";
pub(crate) const COMPUTER_USE_PROPOSAL_TTL_MS: i64 = 5 * 60 * 1_000;

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

pub(crate) fn valid_computer_tool_identity(call_id: &str, tool_name: &str) -> bool {
    !call_id.is_empty()
        && call_id.len() <= 256
        && call_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        && matches!(tool_name, COMPUTER_INVOKE_TOOL | COMPUTER_SET_VALUE_TOOL)
}

/// Builds the same `ActionProposal` chat and Live both register for approval.
pub(crate) fn computer_use_proposal(
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
            if !valid_action(&action) {
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
            if !valid_action(&action) {
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

/// Status JSON sent back on the Live socket for a single function call.
/// Live does not await user approval mid-session; a successful parse means
/// the call was proposed for approval, not that it ran.
pub(crate) fn live_tool_call_status(
    call_id: &str,
    tool_name: &str,
    args_json: &str,
) -> serde_json::Value {
    if !matches!(tool_name, COMPUTER_INVOKE_TOOL | COMPUTER_SET_VALUE_TOOL) {
        return serde_json::json!({
            "status": "unavailable",
            "detail": "Only computer_invoke and computer_set_value are supported.",
        });
    }
    let arguments: serde_json::Value = match serde_json::from_str(args_json) {
        Ok(value) => value,
        Err(_) => {
            return serde_json::json!({
                "status": "rejected",
                "detail": "Tool arguments were not valid JSON.",
            });
        }
    };
    match computer_use_proposal("live", call_id, tool_name, arguments) {
        Ok(_) => serde_json::json!({
            "status": "proposed_for_approval",
            "detail": "Action proposed to the user; wait for approval before assuming it ran.",
        }),
        Err(_) => serde_json::json!({
            "status": "rejected",
            "detail": "Tool call was invalid or unsafe and was not proposed.",
        }),
    }
}

fn unix_time_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| {
            duration.as_millis().min(i64::MAX as u128) as i64
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn live_tool_status_is_honest_for_valid_invalid_and_unknown() {
        let proposed = live_tool_call_status(
            "call_1",
            COMPUTER_INVOKE_TOOL,
            r#"{"target_name":"Save","background_only":false}"#,
        );
        assert_eq!(proposed["status"], "proposed_for_approval");

        let rejected = live_tool_call_status(
            "call_1",
            COMPUTER_INVOKE_TOOL,
            r#"{"target_name":"","background_only":false}"#,
        );
        assert_eq!(rejected["status"], "rejected");

        let unavailable = live_tool_call_status("call_1", "browser_open", "{}");
        assert_eq!(unavailable["status"], "unavailable");

        let bad_id = live_tool_call_status(
            "call/1",
            COMPUTER_INVOKE_TOOL,
            r#"{"target_name":"Save","background_only":false}"#,
        );
        assert_eq!(bad_id["status"], "rejected");
    }
}
