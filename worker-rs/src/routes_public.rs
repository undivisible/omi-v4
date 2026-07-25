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
use worker::{Headers, Method, Request, RequestInit, Response, Result, RouteContext, Router, Stub};

use crate::glue::{error_json, ConvMessage};
use crate::mcp;
use crate::public_api::{self as api, Budget, OperationResult};
use crate::routes_ai::consume_rate_limit;
use crate::routes_keys::{require_api_access, require_scope, ApiAuth};
use crate::routes_memory::wasm_glue as memory;
use crate::worker_util::{now_ms, uuid_v4};
use crate::{managed_ai, speech};

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
        .post_async(
            "/api/v1/speech/transcriptions",
            handle_speech_transcriptions,
        )
        .post_async("/api/v1/speech/synthesis", handle_speech_synthesis)
        .post_async("/api/v1/facetime/calls", handle_facetime_calls)
        .post_async("/mcp", handle_mcp_post)
        .get_async("/mcp", handle_mcp_get)
        .delete_async("/mcp", handle_mcp_delete)
}

async fn do_post(stub: &Stub, url: &str, payload: &Value) -> Result<Response> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&payload.to_string())));
    stub.fetch_with_request(Request::new_with_init(url, &init)?)
        .await
}

fn speech_unavailable() -> OperationResult {
    OperationResult::new(503, json!({ "error": "Managed speech unavailable" }))
}

struct SpeechReservation {
    stub: Stub,
    token: String,
}

async fn release_speech(reservation: &SpeechReservation, request_id: &str, uid: &str) {
    let _ = do_post(
        &reservation.stub,
        "https://stt-admission.internal/release",
        &json!({ "sessionId": request_id, "uid": uid, "acquisitionToken": reservation.token }),
    )
    .await;
}

async fn admit_speech(
    stub: &Stub,
    request_id: &str,
    uid: &str,
    reserved_seconds: i64,
    estimated_cost: i64,
) -> std::result::Result<(String, bool), OperationResult> {
    let mut response = do_post(
        stub,
        "https://stt-admission.internal/admit",
        &json!({
            "sessionId": request_id, "uid": uid, "reservedSeconds": reserved_seconds,
            "costBudgetMicrousd": estimated_cost,
        }),
    )
    .await
    .map_err(|_| speech_unavailable())?;
    if response.status_code() >= 300 {
        let retry_after = response
            .headers()
            .get("retry-after")
            .ok()
            .flatten()
            .and_then(|v| v.parse().ok());
        return Err(OperationResult {
            status: 429,
            body: json!({ "error": "Managed speech capacity exceeded" }),
            retry_after,
        });
    }
    let body = response
        .json::<Value>()
        .await
        .map_err(|_| speech_unavailable())?;
    let token = body
        .get("acquisitionToken")
        .and_then(Value::as_str)
        .filter(|v| v.len() >= 16)
        .ok_or_else(speech_unavailable)?
        .to_string();
    if body.get("admitted").and_then(Value::as_bool) != Some(true) {
        return Err(speech_unavailable());
    }
    Ok((
        token,
        body.get("duplicate").and_then(Value::as_bool) != Some(true)
            || body.get("reacquired").and_then(Value::as_bool) == Some(true),
    ))
}

async fn reserve_speech(
    ctx: &RouteContext<()>,
    uid: &str,
    kind: speech::SpeechKind,
    client_message_id: &str,
    model: &str,
    request_hash: &str,
    reserved_seconds: i64,
    estimated_cost: i64,
    request_id: &str,
) -> std::result::Result<SpeechReservation, OperationResult> {
    let db = ctx.env.d1("DB").map_err(|_| speech_unavailable())?;
    let existing = db
        .prepare("SELECT status, request_hash, result, updated_at FROM managed_speech_requests WHERE uid = ?1 AND kind = ?2 AND client_message_id = ?3")
        .bind(&[uid.into(), kind.slug().into(), client_message_id.into()])
        .map_err(|_| speech_unavailable())?
        .first::<Value>(None)
        .await
        .map_err(|_| speech_unavailable())?;
    let existing_ref = existing.as_ref().map(|row| {
        (
            row.get("status")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            row.get("request_hash")
                .and_then(Value::as_str)
                .unwrap_or_default(),
            row.get("result").and_then(Value::as_str),
            row.get("updated_at")
                .and_then(crate::glue::json_to_i64)
                .unwrap_or(0),
        )
    });
    let now = now_ms();
    let reclaims = match speech::decide_reservation(
        existing_ref,
        request_hash,
        speech::stale_started_window_ms(
            crate::worker_util::secret_or_var(&ctx.env, "SPEECH_UPSTREAM_TIMEOUT_MS").as_deref(),
        ),
        now,
    ) {
        speech::ReservationDecision::Replay(body) => {
            return Err(OperationResult::new(200, Value::Object(body)))
        }
        speech::ReservationDecision::Refuse(result) => return Err(result),
        speech::ReservationDecision::Fresh { reclaims } => reclaims,
    };
    let stub = ctx
        .env
        .durable_object("STT_ADMISSION")
        .map_err(|_| speech_unavailable())?
        .get_by_name("managed-stt-global")
        .map_err(|_| speech_unavailable())?;
    let (mut token, mut owns) =
        admit_speech(&stub, request_id, uid, reserved_seconds, estimated_cost).await?;
    if !owns && reclaims {
        let _ = do_post(
            &stub,
            "https://stt-admission.internal/release",
            &json!({ "sessionId": request_id, "uid": uid, "acquisitionToken": token }),
        )
        .await;
        (token, owns) =
            admit_speech(&stub, request_id, uid, reserved_seconds, estimated_cost).await?;
    }
    if !owns {
        return Err(OperationResult::new(
            409,
            json!({ "error": "Speech request in progress" }),
        ));
    }
    let reservation = SpeechReservation { stub, token };
    let changed = db.prepare("INSERT INTO managed_speech_requests (id, uid, client_message_id, kind, model, status, request_hash, reserved_seconds, estimated_cost_microusd, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, 'started', ?6, ?7, ?8, ?9, ?9) ON CONFLICT(uid, kind, client_message_id) DO UPDATE SET status = 'started', model = excluded.model, updated_at = excluded.updated_at, result = NULL, upstream_status = NULL, completed_at = NULL WHERE managed_speech_requests.status = 'failed' OR (?10 = 1 AND managed_speech_requests.updated_at = ?11)")
        .bind(&[request_id.into(), uid.into(), client_message_id.into(), kind.slug().into(), model.into(), request_hash.into(), (reserved_seconds as f64).into(), (estimated_cost as f64).into(), (now as f64).into(), if reclaims { 1.0.into() } else { 0.0.into() }, (existing_ref.map(|row| row.3).unwrap_or(0) as f64).into()])
        .map_err(|_| speech_unavailable())?.run().await.map_err(|_| speech_unavailable())?;
    if crate::worker_util::changes(&changed) != 1 {
        release_speech(&reservation, request_id, uid).await;
        return Err(OperationResult::new(
            409,
            json!({ "error": "Speech request in progress" }),
        ));
    }
    let claim = do_post(
        &reservation.stub,
        "https://stt-admission.internal/claim",
        &json!({ "sessionId": request_id, "uid": uid, "acquisitionToken": reservation.token }),
    )
    .await;
    if !claim
        .map(|response| response.status_code() < 300)
        .unwrap_or(false)
    {
        release_speech(&reservation, request_id, uid).await;
        return Err(OperationResult::new(
            409,
            json!({ "error": "Speech request in progress" }),
        ));
    }
    Ok(reservation)
}

async fn settle_speech(
    ctx: &RouteContext<()>,
    reservation: &SpeechReservation,
    uid: &str,
    request_id: &str,
    status: &str,
    upstream_status: Option<u16>,
    result: Option<&Value>,
) {
    if let Ok(db) = ctx.env.d1("DB") {
        let statement = db.prepare("UPDATE managed_speech_requests SET status = ?1, upstream_status = ?2, result = ?3, completed_at = ?4, updated_at = ?4 WHERE id = ?5 AND uid = ?6");
        if let Ok(statement) = statement.bind(&[
            status.into(),
            upstream_status
                .map(|value| (value as f64).into())
                .unwrap_or(JsValue::NULL),
            result
                .map(|value| value.to_string().into())
                .unwrap_or(JsValue::NULL),
            (now_ms() as f64).into(),
            request_id.into(),
            uid.into(),
        ]) {
            let _ = statement.run().await;
        }
    }
    release_speech(reservation, request_id, uid).await;
}

async fn call_speech_upstream(
    ctx: &RouteContext<()>,
    payload: &Value,
) -> std::result::Result<(Value, u16), Option<u16>> {
    let secret = crate::worker_util::secret_or_var(&ctx.env, "OPENROUTER_API_KEY")
        .or_else(|| crate::worker_util::secret_or_var(&ctx.env, "MIMO_API_KEY"))
        .filter(|value| !value.trim().is_empty())
        .ok_or(None)?;
    let gateway =
        managed_ai::ai_gateway_route(|name| crate::worker_util::secret_or_var(&ctx.env, name));
    let endpoint = match &gateway {
        Some(route) => route.url.clone(),
        None => crate::worker_util::secret_or_var(&ctx.env, "OPENROUTER_CHAT_COMPLETIONS_URL")
            .unwrap_or_else(|| speech::OPENROUTER_COMPLETION_ENDPOINT.into()),
    };
    if url::Url::parse(&endpoint)
        .ok()
        .filter(|url| url.scheme() == "https")
        .is_none()
    {
        return Err(None);
    }
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers
        .set("authorization", &format!("Bearer {secret}"))
        .map_err(|_| None)?;
    headers
        .set("content-type", "application/json")
        .map_err(|_| None)?;
    if let Some(token) = gateway.and_then(|route| route.token) {
        headers
            .set("cf-aig-authorization", &format!("Bearer {token}"))
            .map_err(|_| None)?;
    }
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&payload.to_string())));
    let request = Request::new_with_init(&endpoint, &init).map_err(|_| None)?;
    let mut response = worker::Fetch::Request(request)
        .send()
        .await
        .map_err(|_| None)?;
    let status = response.status_code();
    if status >= 300 {
        return Err(Some(status));
    }
    response
        .json::<Value>()
        .await
        .map(|body| (body, status))
        .map_err(|_| Some(status))
}

pub(crate) async fn transcribe_audio_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let plan = match speech::plan_transcription(
        |name| crate::worker_util::secret_or_var(&ctx.env, name),
        uid,
        input,
        speech::default_transcribe_preference(),
    ) {
        Ok(plan) => plan,
        Err(result) => return result,
    };
    if let Some(limited) = gate(
        ctx,
        uid,
        &Budget {
            bucket: "public-transcribe",
            limit: speech::TRANSCRIBE_LIMIT.0,
            window_ms: speech::TRANSCRIBE_LIMIT.1,
        },
    )
    .await
    {
        return limited;
    }
    if !crate::glue::has_active_pro(ctx, uid).await.unwrap_or(false) {
        return OperationResult::new(
            403,
            json!({ "error": "Pro subscription required for dictation. Subscribe in Settings → Billing." }),
        );
    }
    let reservation = match reserve_speech(
        ctx,
        uid,
        speech::SpeechKind::Transcribe,
        &plan.client_message_id,
        &plan.model,
        &plan.request_hash,
        plan.reserved_seconds,
        plan.estimated_cost,
        &plan.request_id,
    )
    .await
    {
        Ok(value) => value,
        Err(result) => return result,
    };
    let (body, status) = match call_speech_upstream(ctx, &plan.upstream_body()).await {
        Ok(value) => value,
        Err(status) => {
            settle_speech(
                ctx,
                &reservation,
                uid,
                &plan.request_id,
                "failed",
                status,
                None,
            )
            .await;
            return OperationResult::new(502, json!({ "error": "Managed speech unavailable" }));
        }
    };
    let Some(content) = speech::message_of(&body)
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    else {
        settle_speech(
            ctx,
            &reservation,
            uid,
            &plan.request_id,
            "failed",
            Some(status),
            None,
        )
        .await;
        return OperationResult::new(502, json!({ "error": "Managed speech unavailable" }));
    };
    let result = plan.result(&speech::parse_segments(
        content,
        plan.declared_duration.map(|value| value as f64),
    ));
    settle_speech(
        ctx,
        &reservation,
        uid,
        &plan.request_id,
        "complete",
        Some(status),
        Some(&result),
    )
    .await;
    OperationResult::new(200, result)
}

pub(crate) async fn speak_text_operation(
    ctx: &RouteContext<()>,
    uid: &str,
    input: &Value,
) -> OperationResult {
    let plan = match speech::plan_speech(
        |name| crate::worker_util::secret_or_var(&ctx.env, name),
        uid,
        input,
    ) {
        Ok(plan) => plan,
        Err(result) => return result,
    };
    if let Some(limited) = gate(
        ctx,
        uid,
        &Budget {
            bucket: "public-speak",
            limit: speech::SPEAK_LIMIT.0,
            window_ms: speech::SPEAK_LIMIT.1,
        },
    )
    .await
    {
        return limited;
    }
    if !crate::glue::has_active_pro(ctx, uid).await.unwrap_or(false) {
        return OperationResult::new(
            403,
            json!({ "error": "Pro subscription required for speech synthesis. Subscribe in Settings → Billing." }),
        );
    }
    let reservation = match reserve_speech(
        ctx,
        uid,
        speech::SpeechKind::Speak,
        &plan.client_message_id,
        &plan.model,
        &plan.request_hash,
        plan.reserved_seconds,
        plan.estimated_cost,
        &plan.request_id,
    )
    .await
    {
        Ok(value) => value,
        Err(result) => return result,
    };
    let (body, status) = match call_speech_upstream(ctx, &plan.upstream_body()).await {
        Ok(value) => value,
        Err(status) => {
            settle_speech(
                ctx,
                &reservation,
                uid,
                &plan.request_id,
                "failed",
                status,
                None,
            )
            .await;
            return OperationResult::new(502, json!({ "error": "Managed speech unavailable" }));
        }
    };
    let Some(audio) = speech::message_of(&body)
        .and_then(|message| message.get("audio"))
        .and_then(Value::as_object)
        .and_then(|audio| audio.get("data"))
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        settle_speech(
            ctx,
            &reservation,
            uid,
            &plan.request_id,
            "failed",
            Some(status),
            None,
        )
        .await;
        return OperationResult::new(502, json!({ "error": "Managed speech unavailable" }));
    };
    if audio.len() > speech::MAXIMUM_SPEAK_BASE64_CHARS {
        settle_speech(
            ctx,
            &reservation,
            uid,
            &plan.request_id,
            "failed",
            Some(status),
            None,
        )
        .await;
        return OperationResult::new(502, json!({ "error": "Synthesized audio too large" }));
    }
    let result = plan.result(audio);
    settle_speech(
        ctx,
        &reservation,
        uid,
        &plan.request_id,
        "complete",
        Some(status),
        Some(&result),
    )
    .await;
    OperationResult::new(200, result)
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

/// FaceTime requires the Gemini Live bridge container (TS-only). Fail closed
/// with 501 so API clients get an explicit signal rather than a missing route.
async fn handle_facetime_calls(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = api_auth!(req, ctx);
    scoped!(auth, "facetime:write");
    Ok(Response::from_json(&json!({
        "error": "FaceTime calling is not available on this deployment",
        "code": "facetime_not_ported",
    }))?
    .with_status(501))
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
        "transcribe_audio" => transcribe_audio_operation(ctx, uid, arguments).await,
        "speak_text" => speak_text_operation(ctx, uid, arguments).await,
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
