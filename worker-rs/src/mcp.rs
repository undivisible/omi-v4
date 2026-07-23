//! Pure parity port of `worker/src/mcp.ts`.
//!
//! A direct implementation of the MCP streamable-HTTP transport: JSON-RPC 2.0
//! over a single POST endpoint. The server is stateless — no session ids, no
//! server-initiated stream — so every request carries its own credential and
//! the whole protocol fits in one module rather than a dependency.

use serde_json::{json, Value};

pub const PROTOCOL_VERSION: &str = "2025-06-18";
pub const SERVER_NAME: &str = "omi";
pub const SERVER_VERSION: &str = "1.0.0";
pub const MAXIMUM_BODY_BYTES: usize = 256 * 1024;
/// A JSON-RPC batch is dispatched one message at a time and each message can
/// cost a rate-limiter round-trip, so the batch itself is capped rather than
/// left to the body size alone.
pub const MAXIMUM_BATCH_MESSAGES: usize = 64;

// JSON-RPC 2.0 error codes; -32000 is the implementation-defined range MCP
// uses for transport-level refusals such as a missing scope.
pub const PARSE_ERROR: i64 = -32700;
pub const INVALID_REQUEST: i64 = -32600;
pub const METHOD_NOT_FOUND: i64 = -32601;
pub const INVALID_PARAMS: i64 = -32602;
pub const SERVER_ERROR: i64 = -32000;

pub const INSTRUCTIONS: &str = "Omi is the user's personal memory and assistant. Search or list their memory before answering questions about them, read their Currents for what they intend to do next, and use ask_omi when a synthesised answer is wanted rather than raw records.";

pub fn result(id: Value, value: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": value })
}

pub fn failure(id: Value, code: i64, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

/// `toolResult(outcome)` — the operation body is carried both as text and as
/// structured content, and any status at or above 400 is an error result.
pub fn tool_result(status: u16, body: &Value) -> Value {
    json!({
        "content": [{ "type": "text", "text": body.to_string() }],
        "structuredContent": body,
        "isError": status >= 400,
    })
}

pub struct ToolDefinition {
    pub name: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    pub scope: &'static str,
}

pub const TOOLS: &[ToolDefinition] = &[
    ToolDefinition {
        name: "search_memory",
        title: "Search Omi memory",
        description: "Search the user's Omi memory for claims relevant to a query. Every returned item cites the evidence it came from. Use mode 'keyword' (default, exact term match, BM25-ranked) or 'semantic' (embedding similarity, better for paraphrases).",
        scope: "memory:read",
    },
    ToolDefinition {
        name: "list_memories",
        title: "List Omi profile memories",
        description: "List the user's active profile memories (stable traits and current context) newest first, each with its supporting evidence. Use this for an overview; use search_memory to answer a specific question.",
        scope: "memory:read",
    },
    ToolDefinition {
        name: "list_currents",
        title: "List Currents",
        description: "List the user's open Currents — proposed next actions derived from their memory — ranked by confidence. Only surfaced and accepted Currents are returned; dismissed, expired and snoozed ones are not.",
        scope: "currents:read",
    },
    ToolDefinition {
        name: "create_current",
        title: "Create a Current",
        description: "Create a new Current (a proposed next action) for the user. It is created as a candidate and surfaces to the user at surfaceAt. Omit evidenceId unless you hold a real Omi evidence id; when omitted the citation is recorded from the `reason` you supply.",
        scope: "currents:write",
    },
    ToolDefinition {
        name: "list_meeting_notes",
        title: "List meeting and daily notes",
        description: "List the user's generated notes — one per local day, each citing the conversation and meeting evidence it was written from — newest first.",
        scope: "conversations:read",
    },
    ToolDefinition {
        name: "list_conversation_messages",
        title: "List conversation messages",
        description: "Read the user's assistant conversation in cursor order. Pass the nextCursor from a previous call as `after` to page forward.",
        scope: "conversations:read",
    },
    ToolDefinition {
        name: "ask_omi",
        title: "Ask Omi",
        description: "Ask the user's Omi assistant a question. Omi answers with the user's synced memory and recent conversation in context, and the exchange is recorded in their conversation history. Requires an Omi Pro account.",
        scope: "assistant:write",
    },
    ToolDefinition {
        name: "start_facetime_call",
        title: "Start a FaceTime call",
        description: "Place a real FaceTime Audio call. This rings the given handle on the person's actual device immediately and returns a shareable FaceTime link that auto-admits the first person to join. Side-effectful and not undoable — confirm the handle with the user before calling it. The handle must be an E.164 phone number (like +15551234567) or an email address. Note: the upstream provider currently has FaceTime calling switched off, so this usually returns a 'not yet available' error.",
        scope: "facetime:write",
    },
];

pub fn tool_for(name: &str) -> Option<&'static ToolDefinition> {
    TOOLS.iter().find(|tool| tool.name == name)
}

fn schema_object(properties: Value, required: &[&str]) -> Value {
    let mut schema = json!({ "type": "object", "properties": properties });
    if !required.is_empty() {
        schema["required"] = json!(required);
    }
    schema["additionalProperties"] = json!(false);
    schema
}

fn integer_schema(description: &str, minimum: i64, maximum: i64) -> Value {
    json!({ "type": "integer", "description": description, "minimum": minimum, "maximum": maximum })
}

/// The `inputSchema` advertised for a tool.
pub fn input_schema(name: &str) -> Value {
    match name {
        "search_memory" => schema_object(
            json!({
                "query": {
                    "type": "string",
                    "description": "Natural-language or keyword query.",
                    "minLength": 1,
                    "maxLength": 500,
                },
                "limit": integer_schema("Maximum number of results. Defaults to 12.", 1, 50),
                "mode": {
                    "type": "string",
                    "enum": ["keyword", "semantic"],
                    "description": "Retrieval strategy. Defaults to 'keyword'.",
                },
            }),
            &["query"],
        ),
        "list_memories" => schema_object(
            json!({ "limit": integer_schema("Maximum number of memories. Defaults to 100.", 1, 100) }),
            &[],
        ),
        "list_currents" => schema_object(json!({}), &[]),
        "create_current" => schema_object(
            json!({
                "title": {
                    "type": "string",
                    "description": "Short action title shown to the user.",
                    "minLength": 1,
                    "maxLength": 120,
                },
                "summary": {
                    "type": "string",
                    "description": "One or two sentences of context.",
                    "minLength": 1,
                    "maxLength": 500,
                },
                "reason": {
                    "type": "string",
                    "description": "Why this is being proposed now. Recorded as the citation when evidenceId is omitted.",
                    "minLength": 1,
                    "maxLength": 500,
                },
                "proposedNextStep": {
                    "type": "string",
                    "description": "The single smallest concrete next step to take.",
                    "minLength": 1,
                    "maxLength": 500,
                },
                "confidence": {
                    "type": "number",
                    "description": "Confidence from 0 to 1. Defaults to 0.7.",
                    "minimum": 0,
                    "maximum": 1,
                },
                "surfaceAt": {
                    "type": "integer",
                    "description": "Unix epoch milliseconds at which to surface it. Defaults to now.",
                    "minimum": 1,
                },
                "expiresAt": {
                    "type": "integer",
                    "description": "Unix epoch milliseconds after which it expires. Must be greater than surfaceAt. Optional.",
                    "minimum": 1,
                },
                "evidenceId": {
                    "type": "string",
                    "description": "Existing Omi evidence id to cite. Omit unless you have one.",
                    "maxLength": 200,
                },
            }),
            &["title", "summary", "reason", "proposedNextStep"],
        ),
        "list_meeting_notes" => schema_object(
            json!({ "limit": integer_schema("Maximum number of notes. Defaults to 50.", 1, 100) }),
            &[],
        ),
        "list_conversation_messages" => schema_object(
            json!({
                "after": integer_schema(
                    "Return messages with a cursor strictly greater than this. Defaults to 0.",
                    0,
                    9_007_199_254_740_991,
                ),
                "limit": integer_schema("Maximum number of messages. Defaults to 100.", 1, 200),
            }),
            &[],
        ),
        "ask_omi" => schema_object(
            json!({
                "text": {
                    "type": "string",
                    "description": "The question or instruction to send to Omi.",
                    "minLength": 1,
                    "maxLength": 20_000,
                },
            }),
            &["text"],
        ),
        "start_facetime_call" => schema_object(
            json!({
                "handle": {
                    "type": "string",
                    "description": "Who to call: an E.164 phone number ('+' then 7-15 digits) or an email address.",
                    "minLength": 3,
                    "maxLength": 254,
                },
                "idempotencyKey": {
                    "type": "string",
                    "description": "Optional caller-supplied key, 8-120 characters of [A-Za-z0-9._:-], so a retry does not place a second call.",
                    "minLength": 8,
                    "maxLength": 120,
                },
            }),
            &["handle"],
        ),
        _ => Value::Null,
    }
}

/// `listedTools` — name, title, description, inputSchema.
pub fn listed_tools() -> Value {
    Value::Array(
        TOOLS
            .iter()
            .map(|tool| {
                json!({
                    "name": tool.name,
                    "title": tool.title,
                    "description": tool.description,
                    "inputSchema": input_schema(tool.name),
                })
            })
            .collect(),
    )
}

/// The outcome of planning a single JSON-RPC message.
pub enum Plan {
    /// A notification: no reply is emitted.
    Silent,
    /// A complete response, ready to send.
    Reply(Value),
    /// A validated `tools/call`: the caller runs the operation and wraps the
    /// result with [`tool_result`].
    Call {
        id: Value,
        tool: &'static ToolDefinition,
        arguments: Value,
    },
}

/// `dispatch` up to the point of running a tool. `scopes` is `None` for a
/// Firebase-authenticated caller, who carries every scope.
pub fn plan(scopes: Option<&[String]>, message: &Value) -> Plan {
    let Some(record) = message.as_object() else {
        return Plan::Reply(failure(
            Value::Null,
            INVALID_REQUEST,
            "Invalid JSON-RPC request",
        ));
    };
    if record.get("jsonrpc") != Some(&Value::String("2.0".into()))
        || !record.get("method").is_some_and(Value::is_string)
    {
        return Plan::Reply(failure(
            Value::Null,
            INVALID_REQUEST,
            "Invalid JSON-RPC request",
        ));
    }
    let method = record["method"].as_str().unwrap_or_default();
    let id = match record.get("id") {
        Some(value @ Value::String(_)) | Some(value @ Value::Number(_)) => value.clone(),
        _ => Value::Null,
    };
    // A notification carries no id and expects no reply.
    if record.get("id").is_none() {
        return if method.starts_with("notifications/") {
            Plan::Silent
        } else {
            Plan::Reply(failure(
                Value::Null,
                INVALID_REQUEST,
                "Notification method not supported",
            ))
        };
    }
    match method {
        "initialize" => Plan::Reply(result(
            id,
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": { "tools": { "listChanged": false } },
                "serverInfo": { "name": SERVER_NAME, "version": SERVER_VERSION },
                "instructions": INSTRUCTIONS,
            }),
        )),
        "ping" => Plan::Reply(result(id, json!({}))),
        "tools/list" => Plan::Reply(result(id, json!({ "tools": listed_tools() }))),
        "tools/call" => {
            let params = record.get("params").and_then(Value::as_object);
            let Some(name) = params.and_then(|p| p.get("name")).and_then(Value::as_str) else {
                return Plan::Reply(failure(id, INVALID_PARAMS, "Missing tool name"));
            };
            let Some(tool) = tool_for(name) else {
                return Plan::Reply(failure(
                    id,
                    INVALID_PARAMS,
                    &format!("Unknown tool: {name}"),
                ));
            };
            let arguments = match params.and_then(|p| p.get("arguments")) {
                None => json!({}),
                Some(value) if value.is_object() => value.clone(),
                Some(_) => {
                    return Plan::Reply(failure(
                        id,
                        INVALID_PARAMS,
                        "Tool arguments must be an object",
                    ))
                }
            };
            if let Some(scopes) = scopes {
                if !scopes.iter().any(|scope| scope == tool.scope) {
                    return Plan::Reply(failure(
                        id,
                        SERVER_ERROR,
                        &format!("API key is missing the {} scope", tool.scope),
                    ));
                }
            }
            Plan::Call {
                id,
                tool,
                arguments,
            }
        }
        _ => Plan::Reply(failure(
            id,
            METHOD_NOT_FOUND,
            &format!("Unknown method: {method}"),
        )),
    }
}

/// A parsed POST payload: the message list plus whether the client sent a
/// batch (which decides whether the response is an array).
pub struct Batch {
    pub messages: Vec<Value>,
    pub batched: bool,
}

/// The refusals the POST handler answers before dispatching anything.
pub enum BatchError {
    /// 413 with `Batch too large: at most 64 messages`.
    TooLarge,
    /// 400 with `Invalid JSON-RPC`.
    Invalid,
}

pub fn parse_batch(payload: &Value) -> Result<Batch, BatchError> {
    let (messages, batched) = match payload {
        Value::Array(items) => (items.clone(), true),
        other => (vec![other.clone()], false),
    };
    if messages.len() > MAXIMUM_BATCH_MESSAGES {
        return Err(BatchError::TooLarge);
    }
    if messages.is_empty() || messages.iter().any(|message| !message.is_object()) {
        return Err(BatchError::Invalid);
    }
    Ok(Batch { messages, batched })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(plan: Plan) -> Value {
        match plan {
            Plan::Reply(value) => value,
            Plan::Silent => panic!("expected a reply, got a notification"),
            Plan::Call { .. } => panic!("expected a reply, got a tool call"),
        }
    }

    #[test]
    fn initializes_with_the_advertised_protocol_version() {
        let response = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize" }),
        ));
        assert_eq!(
            response["result"]["protocolVersion"],
            json!(PROTOCOL_VERSION)
        );
        assert_eq!(response["result"]["serverInfo"]["name"], json!("omi"));
        assert_eq!(response["id"], json!(1));
    }

    #[test]
    fn answers_ping_and_rejects_unknown_methods() {
        let ping = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": "a", "method": "ping" }),
        ));
        assert_eq!(ping["result"], json!({}));
        let unknown = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 2, "method": "nope" }),
        ));
        assert_eq!(unknown["error"]["code"], json!(METHOD_NOT_FOUND));
        assert_eq!(unknown["error"]["message"], json!("Unknown method: nope"));
    }

    #[test]
    fn rejects_non_conforming_envelopes() {
        for message in [
            json!({ "id": 1, "method": "ping" }),
            json!({ "jsonrpc": "1.0", "id": 1, "method": "ping" }),
            json!({ "jsonrpc": "2.0", "id": 1 }),
            json!({ "jsonrpc": "2.0", "id": 1, "method": 7 }),
            json!([1, 2]),
            json!("nope"),
        ] {
            let response = reply(plan(None, &message));
            assert_eq!(
                response["error"]["code"],
                json!(INVALID_REQUEST),
                "for {message}"
            );
            assert_eq!(response["id"], Value::Null);
        }
    }

    #[test]
    fn accepts_notifications_silently_and_refuses_other_id_less_calls() {
        assert!(matches!(
            plan(
                None,
                &json!({ "jsonrpc": "2.0", "method": "notifications/initialized" })
            ),
            Plan::Silent
        ));
        let refused = reply(plan(None, &json!({ "jsonrpc": "2.0", "method": "ping" })));
        assert_eq!(
            refused["error"]["message"],
            json!("Notification method not supported")
        );
    }

    #[test]
    fn lists_every_tool_with_a_precise_input_schema() {
        let listed = listed_tools();
        let tools = listed.as_array().unwrap();
        assert_eq!(tools.len(), 8);
        for tool in tools {
            let schema = &tool["inputSchema"];
            assert_eq!(schema["type"], json!("object"));
            assert_eq!(schema["additionalProperties"], json!(false));
            assert!(tool["description"].as_str().unwrap().len() > 20);
        }
        assert_eq!(tools[0]["inputSchema"]["required"], json!(["query"]));
        assert_eq!(
            tools[3]["inputSchema"]["required"],
            json!(["title", "summary", "reason", "proposedNextStep"])
        );
        assert!(listed_tools()[2]["inputSchema"].get("required").is_none());
    }

    #[test]
    fn a_scoped_call_is_planned_for_execution() {
        let scopes = vec!["memory:read".to_string()];
        let message = json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": { "name": "search_memory", "arguments": { "query": "x" } },
        });
        match plan(Some(&scopes), &message) {
            Plan::Call {
                id,
                tool,
                arguments,
            } => {
                assert_eq!(id, json!(3));
                assert_eq!(tool.name, "search_memory");
                assert_eq!(arguments["query"], json!("x"));
            }
            _ => panic!("expected a tool call"),
        }
        // Omitted arguments default to an empty object.
        match plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": "list_currents" } }),
        ) {
            Plan::Call { arguments, .. } => assert_eq!(arguments, json!({})),
            _ => panic!("expected a tool call"),
        }
    }

    #[test]
    fn refuses_a_tool_the_key_has_no_scope_for() {
        let scopes = vec!["memory:read".to_string()];
        let response = reply(plan(
            Some(&scopes),
            &json!({
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": { "name": "start_facetime_call", "arguments": { "handle": "+15551234567" } },
            }),
        ));
        assert_eq!(response["error"]["code"], json!(SERVER_ERROR));
        assert_eq!(
            response["error"]["message"],
            json!("API key is missing the facetime:write scope")
        );
        // A Firebase caller carries every scope.
        assert!(matches!(
            plan(
                None,
                &json!({
                    "jsonrpc": "2.0",
                    "id": 4,
                    "method": "tools/call",
                    "params": { "name": "start_facetime_call", "arguments": { "handle": "+15551234567" } },
                })
            ),
            Plan::Call { .. }
        ));
    }

    #[test]
    fn rejects_an_unknown_tool_and_non_object_arguments() {
        let unknown = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": "rm_rf" } }),
        ));
        assert_eq!(unknown["error"]["message"], json!("Unknown tool: rm_rf"));
        let bad_args = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": "ping_tool", "arguments": [] } }),
        ));
        assert_eq!(bad_args["error"]["code"], json!(INVALID_PARAMS));
        let missing = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call" }),
        ));
        assert_eq!(missing["error"]["message"], json!("Missing tool name"));
        let list_args = reply(plan(
            None,
            &json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": "list_currents", "arguments": [1] } }),
        ));
        assert_eq!(
            list_args["error"]["message"],
            json!("Tool arguments must be an object")
        );
    }

    #[test]
    fn tool_results_carry_text_and_structured_content() {
        let ok = tool_result(200, &json!({ "memories": [] }));
        assert_eq!(ok["isError"], json!(false));
        assert_eq!(ok["structuredContent"], json!({ "memories": [] }));
        assert_eq!(ok["content"][0]["type"], json!("text"));
        // A validation failure is an error *result*, not a protocol error.
        let failed = tool_result(400, &json!({ "error": "Invalid memory search" }));
        assert_eq!(failed["isError"], json!(true));
    }

    #[test]
    fn rejects_an_oversized_batch_instead_of_dispatching_it() {
        let oversized: Vec<Value> = (0..MAXIMUM_BATCH_MESSAGES + 1)
            .map(|i| json!({ "jsonrpc": "2.0", "id": i, "method": "ping" }))
            .collect();
        assert!(matches!(
            parse_batch(&Value::Array(oversized)),
            Err(BatchError::TooLarge)
        ));
        let at_cap: Vec<Value> = (0..MAXIMUM_BATCH_MESSAGES)
            .map(|i| json!({ "jsonrpc": "2.0", "id": i, "method": "ping" }))
            .collect();
        assert_eq!(
            parse_batch(&Value::Array(at_cap))
                .ok()
                .unwrap()
                .messages
                .len(),
            MAXIMUM_BATCH_MESSAGES
        );
    }

    #[test]
    fn rejects_malformed_and_non_object_payloads() {
        for payload in [
            json!([]),
            json!([null]),
            json!([{ "a": 1 }, 7]),
            json!(7),
            json!("x"),
            Value::Null,
        ] {
            assert!(
                matches!(parse_batch(&payload), Err(BatchError::Invalid)),
                "should reject {payload}"
            );
        }
        let single = parse_batch(&json!({ "jsonrpc": "2.0", "id": 1, "method": "ping" }))
            .ok()
            .unwrap();
        assert!(!single.batched);
        let batch = parse_batch(&json!([{ "jsonrpc": "2.0", "id": 1, "method": "ping" }]))
            .ok()
            .unwrap();
        assert!(batch.batched);
    }
}
