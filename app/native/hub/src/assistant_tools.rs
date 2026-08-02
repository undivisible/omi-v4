use crate::computer_use::Observation;
use crate::computer_use_tools::{COMPUTER_INVOKE_TOOL, COMPUTER_SET_VALUE_TOOL, valid_call_id};
use rs_ai_core::ToolDefinition;

pub(crate) const COMPUTER_OBSERVE_TOOL: &str = "computer_observe";
pub(crate) const MEMORY_SEARCH_TOOL: &str = "memory_search";
pub(crate) const PROFILE_READ_TOOL: &str = "profile_read";

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
        COMPUTER_OBSERVE_TOOL | MEMORY_SEARCH_TOOL | PROFILE_READ_TOOL => Some(ToolEffect::Read),
        COMPUTER_INVOKE_TOOL | COMPUTER_SET_VALUE_TOOL => Some(ToolEffect::Write),
        _ => None,
    }
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
    fn a_memory_search_without_a_query_is_refused_rather_than_run_empty() {
        assert!(memory_search_query(&serde_json::json!({})).is_err());
        assert!(memory_search_query(&serde_json::json!({"query": "  "})).is_err());
        assert_eq!(
            memory_search_query(&serde_json::json!({"query": " cats "})),
            Ok("cats".to_owned())
        );
    }
}
