//! workers-rs I/O layer for the third-party surface: the public API
//! (`/api/v1/*`) and the MCP streamable-HTTP transport (`/mcp`). Compiled only
//! for wasm32. Behaviour parity with `worker/src/public-api.ts` and
//! `worker/src/mcp.ts`.
//!
//! Every route is a thin adapter over an operation function, and the MCP tools
//! call the very same operations, so the two surfaces can never drift apart.
//! Operations own their own rate limiting so both are covered by one budget
//! per uid.

use serde_json::{json, Value};
use worker::wasm_bindgen::JsValue;
use worker::{Headers, Method, Request, RequestInit, Response, Result, RouteContext, Router};

use crate::facetime;
use crate::glue::{error_json, ConvMessage};
use crate::mcp;
use crate::public_api::{self as api, Budget, OperationResult};
use crate::routes_ai::consume_rate_limit;
use crate::routes_keys::{require_api_access, require_scope, ApiAuth};
use crate::routes_memory::wasm_glue as memory;
use crate::worker_util::{now_ms, secret_or_var as env_get, uuid_v4};

/// Register the public API and MCP routes on the shared glue router.
pub fn register(router: Router<'static, ()>) -> Router<'static, ()> {
    router
        .get_async("/api/v1/me", handle_me)
        .get_async("/api/v1/memory/search", handle_memory_search)
        .get_async("/api/v1/memories", handle_memories)
        .get_async("/api/v1/currents", handle_currents_get)
        .post_async("/api/v1/currents", handle_currents_post)
        .get_async(
            "/api/v1/conversations/messages",
            handle_conversation_messages,
        )
        .get_async("/api/v1/notes", handle_notes)
        .post_async("/api/v1/assistant/messages", handle_assistant_messages)
        .post_async("/api/v1/facetime/calls", handle_facetime_calls)
        .post_async("/mcp", handle_mcp_post)
        .get_async("/mcp", handle_mcp_get)
        .delete_async("/mcp", handle_mcp_delete)
}

macro_rules! api_auth {
    ($req:expr, $ctx:expr) => {
        match require_api_access(&$req, &$ctx).await {
            Ok(auth) => auth,
            Err(response) => return Ok(response),
        }
    };
}

macro_rules! scoped {
    ($auth:expr, $scope:expr) => {
        if let Some(response) = require_scope(&$auth, $scope) {
            return response;
        }
    };
}

/// `respond(result)` — the operation body, status and optional `retry-after`.
fn respond(result: OperationResult) -> Result<Response> {
    let response = Response::from_json(&result.body)?.with_status(result.status);
    match result.retry_after {
        None => Ok(response),
        Some(retry_after) => {
            let headers = Headers::new();
            headers.set("retry-after", &retry_after.to_string())?;
            Ok(response.with_headers(headers))
        }
    }
}

/// `gate(env, uid, bucket, budget)`.
async fn gate(ctx: &RouteContext<()>, uid: &str, budget: &Budget) -> Option<OperationResult> {
    let (allowed, retry_after) = consume_rate_limit(
        &ctx.env,
        &format!("{}:{}", budget.bucket, uid),
        budget.limit,
        budget.window_ms,
    )
    .await;
    (!allowed).then(|| api::too_many_requests(retry_after))
}

/// A JSON request body that must be an object; anything else is the route's
/// own 400 shape.
async fn object_body(
    req: &mut Request,
    message: &str,
) -> std::result::Result<Value, Result<Response>> {
    match req.json::<Value>().await.ok().filter(Value::is_object) {
        Some(body) => Ok(body),
        None => Err(error_json(message, 400)),
    }
}

fn internal(error: worker::Error) -> OperationResult {
    worker::console_error!("public API operation failed: {error}");
    OperationResult::new(500, json!({ "error": "Internal error" }))
}

// ---------------------------------------------------------------------------
// Operations — shared verbatim by the HTTP routes and the MCP tools
// ---------------------------------------------------------------------------

pub(crate) async fn search_memory_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let input = match api::validate_search(input) {
        Ok(input) => input,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::READ_BUDGET).await {
        return limited;
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        memory::ensure_projected(&db, uid).await?;
        if input.mode == "semantic" {
            let items =
                memory::search_memory_claims(&ctx.env, uid, &input.query, input.limit.min(20))
                    .await?;
            return Ok(OperationResult::new(
                200,
                json!({ "query": input.query, "mode": input.mode, "items": items }),
            ));
        }
        let mut body = memory::retrieve_cited_memory(&db, uid, &input.query, input.limit).await?;
        body["mode"] = Value::from(input.mode.clone());
        Ok::<_, worker::Error>(OperationResult::new(200, body))
    };
    run.await.unwrap_or_else(internal)
}

pub(crate) async fn list_memories_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let limit = match api::validate_list_memories(input) {
        Ok(limit) => limit,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::READ_BUDGET).await {
        return limited;
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        memory::ensure_projected(&db, uid).await?;
        let memories = memory::list_profile_memories(&db, uid, limit as usize).await?;
        Ok::<_, worker::Error>(OperationResult::new(200, json!({ "memories": memories })))
    };
    run.await.unwrap_or_else(internal)
}

pub(crate) async fn list_currents_operation(ctx: &RouteContext<()>, uid: &str) -> OperationResult {
    if let Some(limited) = gate(ctx, uid, &api::READ_BUDGET).await {
        return limited;
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        memory::ensure_projected(&db, uid).await?;
        let currents = memory::list_currents(&db, uid).await?;
        Ok::<_, worker::Error>(OperationResult::new(200, json!({ "currents": currents })))
    };
    run.await.unwrap_or_else(internal)
}

pub(crate) async fn create_current_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let input = match api::validate_current(input, now_ms()) {
        Ok(input) => input,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::WRITE_BUDGET).await {
        return limited;
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        memory::ensure_projected(&db, uid).await?;
        Ok::<_, worker::Error>(match memory::create_current(&db, uid, &input).await? {
            None => OperationResult::new(404, json!({ "error": "Cited evidence not found" })),
            Some(current) => OperationResult::new(201, json!({ "current": current })),
        })
    };
    run.await.unwrap_or_else(internal)
}

pub(crate) async fn list_conversation_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let (after, limit) = match api::validate_conversation(input) {
        Ok(range) => range,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::READ_BUDGET).await {
        return limited;
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        let body = crate::glue::list_conversation_messages(&db, uid, after, limit).await?;
        Ok::<_, worker::Error>(OperationResult::new(200, body))
    };
    run.await.unwrap_or_else(internal)
}

pub(crate) async fn list_notes_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let limit = match api::validate_notes(input) {
        Ok(limit) => limit,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::READ_BUDGET).await {
        return limited;
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        memory::ensure_projected(&db, uid).await?;
        let notes = memory::list_daily_reviews(&db, uid, limit as usize).await?;
        Ok::<_, worker::Error>(OperationResult::new(200, json!({ "notes": notes })))
    };
    run.await.unwrap_or_else(internal)
}

/// `recentHistory` — the last few turns of the user's own conversation.
async fn recent_history(
    db: &worker::D1Database,
    uid: &str,
) -> Result<Vec<crate::managed_ai::Message>> {
    let rows = memory::d1_all(
        db,
        "SELECT role, text FROM conversation_messages\n       WHERE uid = ?1 AND conversation_id = ?1\n       ORDER BY cursor DESC LIMIT ?2",
        &[memory::s(uid), memory::n(api::ASSISTANT_HISTORY_LIMIT)],
    )
    .await?;
    Ok(rows
        .iter()
        .rev()
        .filter_map(|row| {
            let role = memory::str_field(row, "role");
            (role == "user" || role == "assistant").then(|| crate::managed_ai::Message {
                role,
                content: memory::str_field(row, "text"),
            })
        })
        .collect())
}

/// Programmatic assistant turns are recorded in the same conversation the app
/// reads, so a reply asked for over the API is visible in the user's history.
/// The conversation source vocabulary predates the public API; API traffic is
/// recorded as `web`.
pub(crate) async fn ask_omi_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let generated = format!("api:{}", uuid_v4());
    let input = match api::validate_ask(input, &generated) {
        Ok(input) => input,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::ASSISTANT_BUDGET).await {
        return limited;
    }
    if !crate::glue::has_active_pro(ctx, uid).await.unwrap_or(false) {
        return OperationResult::new(403, json!({ "error": "Managed Pro required" }));
    }
    let run = async {
        let db = ctx.env.d1("DB")?;
        let stored = crate::glue::append_conversation_message(
            &db,
            &ConvMessage {
                uid: uid.to_string(),
                client_message_id: input.client_message_id.clone(),
                role: "user".into(),
                source: "web".into(),
                text: input.question.clone(),
                channel_message_id: None,
                delivery_id: None,
                created_at: now_ms() as f64,
            },
            Vec::new(),
        )
        .await?;
        let Some(stored) = stored else {
            return Ok(OperationResult::new(
                409,
                json!({ "error": "Client message ID conflict" }),
            ));
        };
        let memory_context = memory::memory_context_for(&ctx.env, uid, &input.question).await;
        let mut messages = vec![crate::managed_ai::Message {
            role: "system".into(),
            content: match memory_context {
                None => api::ASSISTANT_SYSTEM_PROMPT.to_string(),
                Some(context) => format!("{}\n\n{}", api::ASSISTANT_SYSTEM_PROMPT, context),
            },
        }];
        messages.extend(recent_history(&db, uid).await?);
        let Some(completion) =
            crate::routes_ai::run_managed_inbox_completion(&ctx.env, uid, &messages).await
        else {
            return Ok(OperationResult::new(
                502,
                json!({ "error": "Managed AI unavailable" }),
            ));
        };
        let reply: String = completion
            .trim()
            .chars()
            .take(api::ASSISTANT_REPLY_CHARACTERS)
            .collect();
        let answer = crate::glue::append_conversation_message(
            &db,
            &ConvMessage {
                uid: uid.to_string(),
                client_message_id: format!("{}:reply", input.client_message_id),
                role: "assistant".into(),
                source: "web".into(),
                text: reply.clone(),
                channel_message_id: None,
                delivery_id: None,
                created_at: now_ms() as f64,
            },
            Vec::new(),
        )
        .await?;
        Ok::<_, worker::Error>(OperationResult::new(
            200,
            json!({
                "reply": reply,
                "message": stored.value,
                "answer": answer.map(|appended| appended.value),
            }),
        ))
    };
    run.await.unwrap_or_else(internal)
}

/// Port of `startFaceTimeCall`. The handle has already been validated: the
/// upstream call rings a real phone, so nothing unvalidated is ever forwarded.
async fn start_facetime_call(
    ctx: &RouteContext<()>,
    uid: &str,
    handle: &str,
    token: &str,
) -> facetime::FaceTimeOutcome {
    let Some(secret) = env_get(&ctx.env, "BLOOIO_API_KEY").filter(|key| !key.is_empty()) else {
        return facetime::FaceTimeOutcome::Unconfigured;
    };
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    if headers
        .set("authorization", &format!("Bearer {secret}"))
        .is_err()
        || headers.set("content-type", "application/json").is_err()
        || headers
            .set("idempotency-key", &facetime::idempotency_key(uid, token))
            .is_err()
    {
        return facetime::FaceTimeOutcome::Failed;
    }
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(
        &json!({ "handle": handle }).to_string(),
    )));
    let Ok(request) = Request::new_with_init(facetime::FACETIME_ENDPOINT, &init) else {
        return facetime::FaceTimeOutcome::Failed;
    };
    let Ok(mut upstream) = worker::Fetch::Request(request).send().await else {
        return facetime::FaceTimeOutcome::Failed;
    };
    let status = upstream.status_code();
    let body = upstream.json::<Value>().await.ok();
    facetime::outcome_for(status, body.as_ref(), handle)
}

pub(crate) async fn start_facetime_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let generated = uuid_v4();
    let input = match api::validate_facetime(input, &generated) {
        Ok(input) => input,
        Err(result) => return result,
    };
    if let Some(limited) = gate(ctx, uid, &api::FACETIME_BUDGET).await {
        return limited;
    }
    api::facetime_result(start_facetime_call(ctx, uid, &input.handle, &input.token).await)
}

// ---------------------------------------------------------------------------
// /api/v1 routes
// ---------------------------------------------------------------------------

/// The query string as a JSON object, so the query and body surfaces share one
/// validator.
fn query_input(req: &Request, keys: &[(&str, &str)]) -> Result<Value> {
    let url = req.url()?;
    let mut input = serde_json::Map::new();
    for (parameter, field) in keys {
        if let Some((_, value)) = url.query_pairs().find(|(key, _)| key == parameter) {
            input.insert((*field).to_string(), Value::from(value.to_string()));
        }
    }
    Ok(Value::Object(input))
}

async fn handle_me(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    Response::from_json(&json!({
        "uid": auth.uid,
        "email": auth.email,
        "auth": if auth.key.is_some() { "api_key" } else { "firebase" },
        "keyId": auth.key.as_ref().map(|key| key.id.clone()),
        "scopes": auth.key.as_ref().map(|key| key.scopes.clone()),
    }))
}

async fn handle_memory_search(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "memory:read");
    let input = query_input(
        &req,
        &[("q", "query"), ("limit", "limit"), ("mode", "mode")],
    )?;
    respond(search_memory_operation(&ctx, &auth.uid, &input).await)
}

async fn handle_memories(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "memory:read");
    let input = query_input(&req, &[("limit", "limit")])?;
    respond(list_memories_operation(&ctx, &auth.uid, &input).await)
}

async fn handle_currents_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "currents:read");
    respond(list_currents_operation(&ctx, &auth.uid).await)
}

async fn handle_currents_post(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "currents:write");
    let body = match object_body(&mut req, "Invalid Current").await {
        Ok(body) => body,
        Err(response) => return response,
    };
    respond(create_current_operation(&ctx, &auth.uid, &body).await)
}

async fn handle_conversation_messages(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "conversations:read");
    let input = query_input(&req, &[("after", "after"), ("limit", "limit")])?;
    respond(list_conversation_operation(&ctx, &auth.uid, &input).await)
}

async fn handle_notes(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "conversations:read");
    let input = query_input(&req, &[("limit", "limit")])?;
    respond(list_notes_operation(&ctx, &auth.uid, &input).await)
}

async fn handle_assistant_messages(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "assistant:write");
    let body = match object_body(&mut req, "Invalid assistant message").await {
        Ok(body) => body,
        Err(response) => return response,
    };
    respond(ask_omi_operation(&ctx, &auth.uid, &body).await)
}

async fn handle_facetime_calls(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "facetime:write");
    let body = match object_body(&mut req, "Invalid FaceTime handle").await {
        Ok(body) => body,
        Err(response) => return response,
    };
    respond(start_facetime_operation(&ctx, &auth.uid, &body).await)
}

// ---------------------------------------------------------------------------
// /mcp — JSON-RPC 2.0 over a single POST endpoint
// ---------------------------------------------------------------------------

/// Runs a planned tool call against the shared operations.
async fn run_tool(
    ctx: &RouteContext<()>,
    uid: &str,
    tool: &str,
    arguments: &Value,
) -> OperationResult {
    match tool {
        "search_memory" => search_memory_operation(ctx, uid, arguments).await,
        "list_memories" => list_memories_operation(ctx, uid, arguments).await,
        "list_currents" => list_currents_operation(ctx, uid).await,
        "create_current" => create_current_operation(ctx, uid, arguments).await,
        "list_meeting_notes" => list_notes_operation(ctx, uid, arguments).await,
        "list_conversation_messages" => list_conversation_operation(ctx, uid, arguments).await,
        "ask_omi" => ask_omi_operation(ctx, uid, arguments).await,
        "start_facetime_call" => start_facetime_operation(ctx, uid, arguments).await,
        // Unreachable: `mcp::plan` only ever names a tool from `mcp::TOOLS`.
        _ => OperationResult::new(400, json!({ "error": "Unknown tool" })),
    }
}

async fn dispatch(ctx: &RouteContext<()>, auth: &ApiAuth, message: &Value) -> Option<Value> {
    match mcp::plan(auth.scopes(), message) {
        mcp::Plan::Silent => None,
        mcp::Plan::Reply(response) => Some(response),
        mcp::Plan::Call {
            id,
            tool,
            arguments,
        } => {
            let outcome = run_tool(ctx, &auth.uid, tool.name, &arguments).await;
            Some(mcp::result(
                id,
                mcp::tool_result(outcome.status, &outcome.body),
            ))
        }
    }
}

/// Port of `boundedPayload`.
///
/// DEVIATION: workers-rs hands the body over as a whole rather than as a
/// reader, so an oversized chunked body is refused after buffering rather than
/// mid-stream. The declared `content-length` short-circuit and the decoded-size
/// refusal are both preserved, so the accept/reject decision is identical.
async fn bounded_payload(
    req: &mut Request,
    limit: usize,
) -> std::result::Result<Value, &'static str> {
    if let Some(declared) = req
        .headers()
        .get("content-length")
        .ok()
        .flatten()
        .and_then(|value| value.trim().parse::<usize>().ok())
    {
        if declared > limit {
            return Err("too_large");
        }
    }
    let text = req.text().await.map_err(|_| "invalid")?;
    if text.len() > limit {
        return Err("too_large");
    }
    serde_json::from_str::<Value>(&text).map_err(|_| "invalid")
}

async fn handle_mcp_post(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    let payload = match bounded_payload(&mut req, mcp::MAXIMUM_BODY_BYTES).await {
        Ok(payload) => payload,
        Err("too_large") => {
            return Ok(Response::from_json(&mcp::failure(
                Value::Null,
                mcp::INVALID_REQUEST,
                "Request too large",
            ))?
            .with_status(413))
        }
        Err(_) => {
            return Ok(Response::from_json(&mcp::failure(
                Value::Null,
                mcp::PARSE_ERROR,
                "Invalid JSON",
            ))?
            .with_status(400))
        }
    };
    let batch = match mcp::parse_batch(&payload) {
        Ok(batch) => batch,
        Err(mcp::BatchError::TooLarge) => {
            return Ok(Response::from_json(&mcp::failure(
                Value::Null,
                mcp::INVALID_REQUEST,
                &format!(
                    "Batch too large: at most {} messages",
                    mcp::MAXIMUM_BATCH_MESSAGES
                ),
            ))?
            .with_status(413))
        }
        Err(mcp::BatchError::Invalid) => {
            return Ok(Response::from_json(&mcp::failure(
                Value::Null,
                mcp::INVALID_REQUEST,
                "Invalid JSON-RPC",
            ))?
            .with_status(400))
        }
    };
    let mut responses: Vec<Value> = Vec::new();
    for message in &batch.messages {
        if let Some(response) = dispatch(&ctx, &auth, message).await {
            responses.push(response);
        }
    }
    // Notifications only: the transport requires 202 with an empty body.
    if responses.is_empty() {
        return Ok(Response::empty()?.with_status(202));
    }
    let body = if batch.batched {
        Value::Array(responses)
    } else {
        responses.remove(0)
    };
    let headers = Headers::new();
    headers.set("mcp-protocol-version", mcp::PROTOCOL_VERSION)?;
    Ok(Response::from_json(&body)?.with_headers(headers))
}

// This server never initiates messages and holds no session, so the optional
// SSE stream and session-termination verbs are declined rather than faked.
async fn handle_mcp_get(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let _auth = api_auth!(req, ctx);
    Ok(Response::from_json(&mcp::failure(
        Value::Null,
        mcp::METHOD_NOT_FOUND,
        "SSE stream not supported",
    ))?
    .with_status(405))
}

async fn handle_mcp_delete(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let _auth = api_auth!(req, ctx);
    Ok(Response::from_json(&mcp::failure(
        Value::Null,
        mcp::METHOD_NOT_FOUND,
        "Sessions not supported",
    ))?
    .with_status(405))
}
