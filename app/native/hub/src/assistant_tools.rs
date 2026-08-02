use crate::computer_use::Observation;
use crate::computer_use_tools::{
    COMPUTER_INVOKE_TOOL, COMPUTER_SET_VALUE_TOOL, COMPUTER_USE_PROPOSAL_TTL_MS, valid_call_id,
};
use crate::signals::{ActionProposal, ActionRisk};
use rs_ai_core::ToolDefinition;

pub(crate) const COMPUTER_OBSERVE_TOOL: &str = "computer_observe";
pub(crate) const MEMORY_SEARCH_TOOL: &str = "memory_search";
pub(crate) const PROFILE_READ_TOOL: &str = "profile_read";
pub(crate) const CURRENTS_READ_TOOL: &str = "currents_read";
pub(crate) const CURRENTS_WRITE_TOOL: &str = "currents_write";

/// How many times a turn may call tools and come back for more before it has
/// to answer with what it has. Four covers the deepest sequence the desktop
/// assistant actually needs — look at the screen, then look the user up, then
/// look again after something moved — while still bounding a model that would
/// otherwise observe forever. The last round is dispatched with no tools
/// attached at all, so the cap is enforced by the request rather than by
/// hoping the model stops.
pub(crate) const MAX_TOOL_ROUNDS: u32 = 4;

/// The most bytes one tool result may add to the conversation. A semantic
/// snapshot of a busy window and a memory search over a full capture history
/// are both unbounded in principle, and this is a prompt.
pub(crate) const MAX_TOOL_RESULT_BYTES: usize = 8 * 1024;

/// Whether running a tool changes anything a person would want to see first.
/// `rx4` draws the same line upstream as `ToolEffect::{Read, Write, Process}`;
/// the hub only needs two of those, because nothing it exposes starts a
/// process. The distinction is the whole safety story here: `Read` runs
/// unattended and feeds the model, `Write` never runs at all until the
/// approval ledger says a human said yes.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum ToolEffect {
    Read,
    Write,
}

pub(crate) fn tool_effect(tool_name: &str) -> Option<ToolEffect> {
    match tool_name {
        COMPUTER_OBSERVE_TOOL | MEMORY_SEARCH_TOOL | PROFILE_READ_TOOL | CURRENTS_READ_TOOL => {
            Some(ToolEffect::Read)
        }
        COMPUTER_INVOKE_TOOL | COMPUTER_SET_VALUE_TOOL | CURRENTS_WRITE_TOOL => {
            Some(ToolEffect::Write)
        }
        _ => None,
    }
}

/// The Current a `currents_write` call asked to create, in the field names the
/// worker's `POST /api/v1/currents` validates. It is carried through the
/// approval ledger rather than sent when the model asks for it: nothing here
/// reaches the account until a human says yes.
#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CurrentsWrite {
    pub(crate) title: String,
    pub(crate) summary: String,
    pub(crate) reason: String,
    pub(crate) proposed_next_step: String,
}

impl CurrentsWrite {
    pub(crate) fn body(&self) -> serde_json::Value {
        serde_json::json!({
            "title": self.title,
            "summary": self.summary,
            "reason": self.reason,
            "proposedNextStep": self.proposed_next_step,
        })
    }
}

/// Builds the proposal a `currents_write` call registers for approval. The
/// worker's own limits are applied here so a call that could only be rejected
/// costs a sentence rather than an approval the user has to read.
pub(crate) fn currents_write_proposal(
    request_id: &str,
    call_id: &str,
    arguments: &serde_json::Value,
) -> Result<(ActionProposal, CurrentsWrite), String> {
    if !valid_call_id(call_id) {
        return Err("currents_write was called with an invalid call id.".to_owned());
    }
    let field = |name: &str, limit: usize| -> Result<String, String> {
        let value = arguments
            .get(name)
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .trim();
        if value.is_empty() || value.chars().count() > limit {
            return Err(format!(
                "currents_write needs a {name} of 1 to {limit} characters."
            ));
        }
        Ok(value.to_owned())
    };
    let write = CurrentsWrite {
        title: field("title", 120)?,
        summary: field("summary", 500)?,
        reason: field("reason", 500)?,
        proposed_next_step: field("proposed_next_step", 500)?,
    };
    let proposal = ActionProposal {
        proposal_id: format!("{request_id}:tool:{call_id}"),
        request_id: request_id.to_owned(),
        title: "Write a Current".to_owned(),
        summary: format!("{} — {}", write.title, write.proposed_next_step),
        risk: ActionRisk::External,
        computer_action: None,
        operation_id: None,
        action_hash: None,
        target_provenance: None,
        expires_at_ms: Some(
            crate::approval::unix_time_ms().saturating_add(COMPUTER_USE_PROPOSAL_TTL_MS),
        ),
    };
    Ok((proposal, write))
}

pub(crate) fn valid_tool_identity(call_id: &str, tool_name: &str) -> bool {
    valid_call_id(call_id) && tool_effect(tool_name).is_some()
}

/// The screen-reading tool. It is deliberately the only way the model learns
/// an element's exact name: before this existed the only source of a
/// `target_name` was a guess, and a guess costs an approval round to disprove.
pub(crate) fn computer_observe_tool() -> ToolDefinition {
    ToolDefinition {
        name: COMPUTER_OBSERVE_TOOL.to_owned(),
        description:
            "List the interface elements on screen right now, with the exact names computer_invoke and computer_set_value take. Call this before proposing any action"
                .to_owned(),
        parameters: serde_json::json!({
            "type": "object",
            "properties": {},
        }),
        examples: None,
    }
}

pub(crate) fn user_data_tools() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition {
            name: MEMORY_SEARCH_TOOL.to_owned(),
            description:
                "Search the user's own recorded memory — conversations, captures and notes — for anything matching a query"
                    .to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "query": {"type": "string"}
                },
                "required": ["query"]
            }),
            examples: None,
        },
        ToolDefinition {
            name: PROFILE_READ_TOOL.to_owned(),
            description: "Read what is already known about the user: their profile and the notes they wrote about themselves"
                .to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {},
            }),
            examples: None,
        },
        ToolDefinition {
            name: CURRENTS_READ_TOOL.to_owned(),
            description:
                "List the user's Currents — the things Omi is currently tracking for them, with each one's title, summary and proposed next step"
                    .to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {},
            }),
            examples: None,
        },
        ToolDefinition {
            name: CURRENTS_WRITE_TOOL.to_owned(),
            description:
                "Propose writing a new Current to the user's account, for their approval. Read the existing Currents first so a change to one is written as its successor rather than as a duplicate"
                    .to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "summary": {"type": "string"},
                    "reason": {"type": "string"},
                    "proposed_next_step": {"type": "string"}
                },
                "required": ["title", "summary", "reason", "proposed_next_step"]
            }),
            examples: None,
        },
    ]
}

/// Pulls the query out of a `memory_search` call. Providers disagree about
/// whether absent arguments arrive as `{}`, `null` or a JSON string, so the
/// shape is read rather than deserialized into a struct.
pub(crate) fn memory_search_query(arguments: &serde_json::Value) -> Result<String, String> {
    let query = arguments
        .get("query")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .trim();
    if query.is_empty() {
        return Err("memory_search needs a non-empty query.".to_owned());
    }
    Ok(query.to_owned())
}

/// Shortens a tool result to something a prompt can carry, and says in the
/// result that it did. A silently shortened list reads to the model as a
/// complete one, and it will then answer as if it had seen everything.
pub(crate) fn truncated_tool_result(text: &str) -> String {
    if text.len() <= MAX_TOOL_RESULT_BYTES {
        return text.to_owned();
    }
    let mut cut = MAX_TOOL_RESULT_BYTES;
    while cut > 0 && !text.is_char_boundary(cut) {
        cut -= 1;
    }
    format!(
        "{}\n[truncated: only the first {cut} bytes of this result are shown]",
        &text[..cut]
    )
}

pub(crate) fn render_observation(observation: &Observation) -> String {
    if observation.elements.is_empty() {
        return "No actionable elements are on screen right now.".to_owned();
    }
    let mut lines = vec![
        "Elements on screen. Use the quoted name verbatim as target_name; an element marked ambiguous cannot be acted on because its name is shared."
            .to_owned(),
    ];
    for element in &observation.elements {
        let name = match element.name.as_deref() {
            Some(name) => format!("{name:?}"),
            None => "(unnamed)".to_owned(),
        };
        let mut traits = Vec::new();
        if element.invokable {
            traits.push("invokable");
        }
        if element.editable {
            traits.push("editable");
        }
        if !element.unambiguous {
            traits.push("ambiguous");
        }
        lines.push(format!(
            "{} {} {name} [{}]",
            element.tag,
            element.role,
            traits.join(", ")
        ));
    }
    if observation.truncated {
        lines.push("[truncated: more elements are on screen than are listed here]".to_owned());
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::computer_use::ObservedElement;

    #[test]
    fn effect_splits_reading_the_screen_from_acting_on_it() {
        assert_eq!(tool_effect(COMPUTER_OBSERVE_TOOL), Some(ToolEffect::Read));
        assert_eq!(tool_effect(MEMORY_SEARCH_TOOL), Some(ToolEffect::Read));
        assert_eq!(tool_effect(PROFILE_READ_TOOL), Some(ToolEffect::Read));
        assert_eq!(tool_effect(COMPUTER_INVOKE_TOOL), Some(ToolEffect::Write));
        assert_eq!(
            tool_effect(COMPUTER_SET_VALUE_TOOL),
            Some(ToolEffect::Write)
        );
        assert_eq!(tool_effect(CURRENTS_READ_TOOL), Some(ToolEffect::Read));
        assert_eq!(tool_effect(CURRENTS_WRITE_TOOL), Some(ToolEffect::Write));
        assert_eq!(tool_effect("bash"), None);
        assert!(!valid_tool_identity("call_1", "bash"));
        assert!(!valid_tool_identity("call/1", COMPUTER_OBSERVE_TOOL));
        assert!(valid_tool_identity("call_1", COMPUTER_OBSERVE_TOOL));
    }

    #[test]
    fn an_over_long_result_says_that_it_was_cut() {
        let long = "x".repeat(MAX_TOOL_RESULT_BYTES * 2);
        let result = truncated_tool_result(&long);
        assert!(result.contains("[truncated"));
        assert!(result.len() < long.len());
        assert_eq!(truncated_tool_result("short"), "short");
    }

    #[test]
    fn a_rendered_snapshot_names_elements_and_admits_what_it_left_out() {
        let rendered = render_observation(&Observation {
            elements: vec![
                ObservedElement {
                    tag: "e1".to_owned(),
                    role: "AXButton".to_owned(),
                    name: Some("Save".to_owned()),
                    invokable: true,
                    editable: false,
                    unambiguous: true,
                },
                ObservedElement {
                    tag: "e2".to_owned(),
                    role: "AXButton".to_owned(),
                    name: Some("Open".to_owned()),
                    invokable: true,
                    editable: false,
                    unambiguous: false,
                },
            ],
            truncated: true,
        });
        assert!(rendered.contains("e1 AXButton \"Save\" [invokable]"));
        assert!(rendered.contains("ambiguous"));
        assert!(rendered.contains("[truncated"));
        assert_eq!(
            render_observation(&Observation::default()),
            "No actionable elements are on screen right now."
        );
    }

    #[test]
    fn a_currents_write_is_proposed_with_every_field_the_worker_requires() {
        let arguments = serde_json::json!({
            "title": " Ship the installer ",
            "summary": "The desktop installer is the last thing between the beta and users.",
            "reason": "You said twice this week that the build is blocked on packaging.",
            "proposed_next_step": "Cut a signed build and send it to the three testers."
        });
        let (proposal, write) = currents_write_proposal("chat-1", "call_1", &arguments)
            .unwrap_or_else(|_| panic!("proposal"));
        assert_eq!(proposal.proposal_id, "chat-1:tool:call_1");
        assert_eq!(proposal.request_id, "chat-1");
        assert_eq!(proposal.risk, ActionRisk::External);
        assert!(proposal.computer_action.is_none());
        assert_eq!(write.title, "Ship the installer");
        let body = write.body();
        assert_eq!(body["title"], "Ship the installer");
        assert_eq!(
            body["proposedNextStep"],
            "Cut a signed build and send it to the three testers."
        );
    }

    #[test]
    fn a_currents_write_missing_a_field_is_refused_before_it_costs_an_approval() {
        let complete = serde_json::json!({
            "title": "t",
            "summary": "s",
            "reason": "r",
            "proposed_next_step": "n"
        });
        assert!(currents_write_proposal("chat-1", "call/1", &complete).is_err());
        for field in ["title", "summary", "reason", "proposed_next_step"] {
            let mut arguments = complete.clone();
            arguments[field] = serde_json::json!("   ");
            assert!(currents_write_proposal("chat-1", "call_1", &arguments).is_err());
        }
        let mut too_long = complete.clone();
        too_long["title"] = serde_json::json!("t".repeat(121));
        assert!(currents_write_proposal("chat-1", "call_1", &too_long).is_err());
    }

    #[test]
    fn a_memory_search_without_a_query_is_refused_rather_than_run_empty() {
        assert!(memory_search_query(&serde_json::json!({})).is_err());
        assert!(memory_search_query(&serde_json::json!({"query": "  "})).is_err());
        assert_eq!(
            memory_search_query(&serde_json::json!({"query": " cats "})),
            Ok("cats".to_owned())
        );
    }
}
