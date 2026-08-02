//! workers-rs glue for the managed-AI route group (assistant / STT / ASR /
//! voice) and its Durable Objects. All behavioural decisions live in the pure
//! modules (`managed_ai`, `stt_logic`, `asr_logic`, `voice_logic`,
//! `assistant_admission`, `stt_admission`, `rate_limit`); this file is the thin
//! I/O layer that binds them to D1, outbound fetch, and the DO storage runtime.
//!
//! Compiled only for wasm32. A single `register` hook is added to the glue
//! router so the route group can be maintained without touching the rest of
//! `glue.rs`.

use std::{
    cell::{Cell, RefCell},
    rc::Rc,
};

use base64::Engine;
use futures_util::{stream, StreamExt};
use serde_json::{json, Value};
use worker::wasm_bindgen;
use worker::wasm_bindgen::JsValue;
use worker::{
    durable_object, Env, Headers, Method, Request, RequestInit, Response, Result, RouteContext,
    Router, State, Stub, WebSocketPair,
};

use crate::assistant_admission::{AssistantAdmission, Limits as AssistantLimits, Outcome};
use crate::glue::{authenticate, error_json, has_active_pro, AuthOutcome};
use crate::rate_limit::RateLimiter;
use crate::stt_admission::{Limits as SttLimits, SttAdmission};
use crate::worker_util::{now_ms, secret_or_var as env_get, uuid_v4};
use crate::{asr_logic, managed_ai, observability, stt_logic, voice_logic};

const DO_STATE_KEY: &str = "state";

/// Register the managed-AI routes on the shared glue router.
pub fn register(router: Router<'static, ()>) -> Router<'static, ()> {
    router
        .post_async("/v1/chat/completions", handle_chat_completions)
        .post_async("/v1/asr/transcribe", handle_asr)
        .post_async("/v1/voice/gemini/token", handle_voice_token)
        .post_async("/v1/stt/sessions", handle_stt_create)
        .get_async("/v1/stt/sessions/:sessionId/stream", handle_stt_stream)
}

// ---------------------------------------------------------------------------
// Small shared helpers
// ---------------------------------------------------------------------------

/// Materialize a DO state-machine outcome into a `Response`.
fn outcome_response(outcome: Outcome) -> Result<Response> {
    let mut response = if outcome.body.is_null() {
        Response::empty()?.with_status(outcome.status)
    } else {
        Response::from_json(&outcome.body)?.with_status(outcome.status)
    };
    if let Some(retry_after) = outcome.retry_after {
        response.headers_mut().set("retry-after", &retry_after)?;
    }
    Ok(response)
}

/// POST a JSON payload to a Durable Object stub over its internal URL.
async fn do_post(stub: &Stub, url: &str, payload: &Value) -> Result<Response> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&payload.to_string())));
    let request = Request::new_with_init(url, &init)?;
    stub.fetch_with_request(request).await
}

fn assistant_admission_stub(env: &Env) -> Result<Stub> {
    env.durable_object("ASSISTANT_ADMISSION")?
        .get_by_name("managed-ai-global")
}

fn stt_admission_stub(env: &Env) -> Result<Stub> {
    env.durable_object("STT_ADMISSION")?
        .get_by_name("managed-stt-global")
}

#[allow(clippy::too_many_arguments)]
async fn send_foglamp_trace(
    env: &Env,
    trace_id: &str,
    name: &str,
    provider: &str,
    model: &str,
    start_time: i64,
    status: &str,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
) {
    let Some(key) = env_get(env, "FOGLAMP_API_KEY").filter(|value| !value.is_empty()) else {
        return;
    };
    let endpoint = env_get(env, "FOGLAMP_INGEST_URL")
        .unwrap_or_else(|| "https://ingest.foglamp.dev/ingest".into());
    let Ok(url) = worker::Url::parse(&endpoint) else {
        return;
    };
    if url.scheme() != "https" {
        return;
    }
    let environment = env_get(env, "ENVIRONMENT").unwrap_or_else(|| "development".into());
    let payload = observability::foglamp_trace(
        trace_id,
        name,
        provider,
        model,
        start_time,
        now_ms(),
        status,
        input_tokens,
        output_tokens,
        &environment,
    );
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    if headers
        .set("authorization", &format!("Bearer {key}"))
        .and_then(|_| headers.set("content-type", "application/json"))
        .is_err()
    {
        return;
    }
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&payload.to_string())));
    let Ok(request) = Request::new_with_init(url.as_str(), &init) else {
        return;
    };
    let _ = worker::Fetch::Request(request).send().await;
}

fn rate_limiter_stub(env: &Env, key: &str) -> Result<Stub> {
    env.durable_object("RATE_LIMITER")?.get_by_name(key)
}

/// Read the request body while enforcing `limit`, aborting as soon as the
/// accumulated size would exceed it. Mirrors the streaming size gate in the
/// TypeScript `boundedJson` helper so multi-megabyte ASR posts are not fully
/// buffered before refusal (workers-rs `Request::bytes` has no mid-read cap).
async fn read_body_limited(req: &mut Request, limit: usize) -> Option<Vec<u8>> {
    let declared = req
        .headers()
        .get("content-length")
        .ok()
        .flatten()
        .map(|raw| crate::jsnum::number_from_str(&raw));
    if let Some(n) = declared {
        if n.is_finite() && n > limit as f64 {
            return None;
        }
    }
    let capacity = declared
        .filter(|n| n.is_finite() && *n >= 0.0 && *n <= limit as f64)
        .map(|n| n as usize)
        .unwrap_or(0);
    let mut stream = req.stream().ok()?;
    let mut buf = Vec::with_capacity(capacity);
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.ok()?;
        if asr_logic::body_chunk_exceeds(buf.len(), chunk.len(), limit) {
            return None;
        }
        buf.extend_from_slice(&chunk);
    }
    Some(buf)
}

pub(crate) async fn consume_rate_limit(
    env: &Env,
    key: &str,
    limit: i64,
    window_ms: i64,
) -> (bool, i64) {
    let stub = match rate_limiter_stub(env, key) {
        Ok(stub) => stub,
        Err(_) => return (true, 0),
    };
    let payload = json!({ "limit": limit, "windowMs": window_ms });
    match do_post(&stub, "https://rate-limit.internal/consume", &payload).await {
        Ok(mut response) => match response.json::<Value>().await {
            Ok(value) => (
                value
                    .get("allowed")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                value.get("retryAfter").and_then(Value::as_i64).unwrap_or(1),
            ),
            Err(_) => (false, 1),
        },
        Err(_) => (false, 1),
    }
}

/// Insert a managed_ai_requests ledger row in the `started` state. Returns an
/// error to the caller so it can release the admission on failure.
#[allow(clippy::too_many_arguments)]
async fn insert_managed_request(
    ctx: &RouteContext<()>,
    request_id: &str,
    uid: &str,
    provider: &str,
    model: &str,
    input_characters: i64,
    requested_max_output_tokens: i64,
    estimated_cost_microusd: Option<i64>,
    now: i64,
) -> Result<()> {
    let db = ctx.env.d1("DB")?;
    let statement = if let Some(cost) = estimated_cost_microusd {
        db.prepare(
            "INSERT INTO managed_ai_requests\n             (id, uid, provider, model, status, input_characters, requested_max_output_tokens,\n              estimated_cost_microusd, created_at, updated_at)\n             VALUES (?1, ?2, ?3, ?4, 'started', ?5, ?6, ?7, ?8, ?8)",
        )
        .bind(&[
            request_id.into(),
            uid.into(),
            provider.into(),
            model.into(),
            (input_characters as f64).into(),
            (requested_max_output_tokens as f64).into(),
            (cost as f64).into(),
            (now as f64).into(),
        ])?
    } else {
        db.prepare(
            "INSERT INTO managed_ai_requests\n             (id, uid, provider, model, status, input_characters, requested_max_output_tokens,\n              created_at, updated_at)\n             VALUES (?1, ?2, ?3, ?4, 'started', ?5, ?6, ?7, ?7)",
        )
        .bind(&[
            request_id.into(),
            uid.into(),
            provider.into(),
            model.into(),
            (input_characters as f64).into(),
            (requested_max_output_tokens as f64).into(),
            (now as f64).into(),
        ])?
    };
    statement.run().await.map(|_| ())
}

/// Finalize a managed_ai_requests row (non-streaming providers).
async fn finalize_managed_request(
    ctx: &RouteContext<()>,
    request_id: &str,
    status: &str,
    upstream_status: Option<i64>,
) {
    let Ok(db) = ctx.env.d1("DB") else { return };
    let now = now_ms();
    let upstream = upstream_status
        .map(|s| (s as f64).into())
        .unwrap_or(JsValue::NULL);
    if let Ok(statement) = db
        .prepare(
            "UPDATE managed_ai_requests\n             SET status = ?1, upstream_status = ?2, finalization_attempts = finalization_attempts + 1,\n                 finalized_at = COALESCE(finalized_at, ?3), updated_at = ?3\n             WHERE id = ?4 AND finalized_at IS NULL",
        )
        .bind(&[status.into(), upstream, (now as f64).into(), request_id.into()])
    {
        let _ = statement.run().await;
    }
}

/// Worker-side inbox completion output cap. Mirrors `workerCompletionMaxOutputTokens`.
const WORKER_COMPLETION_MAX_OUTPUT_TOKENS: i64 = managed_ai::WORKER_COMPLETION_MAX_OUTPUT_TOKENS;

/// Port of `runManagedInboxCompletion` (assistant.ts). Non-streaming managed
/// completion used by the channel inbox fallback responder. Returns the trimmed
/// assistant reply, or `None` when managed AI is unconfigured / admission is
/// denied / the upstream fails — exactly the cases where TS returns `null` and
/// the caller releases the claim for retry.
pub async fn run_managed_inbox_completion(
    env: &Env,
    uid: &str,
    messages: &[managed_ai::Message],
    tier: managed_ai::ModelTier,
) -> Option<String> {
    run_managed_inbox_turn(env, uid, messages, tier, None)
        .await
        .and_then(|turn| turn.content)
}

/// One completion: either words, or a request to run tools.
///
/// A turn with tool calls and no content is the normal shape of "call these
/// first" and is not a failure, which is why this is a struct rather than an
/// `Option<String>` — the old return type could not say it.
pub struct InboxTurn {
    pub content: Option<String>,
    /// The `tool_calls` array exactly as the model sent it, to be echoed back
    /// in the follow-up request.
    pub tool_calls_raw: Option<Value>,
    pub tool_calls: Vec<managed_ai::ToolCall>,
}

/// `run_managed_inbox_completion`, but able to offer tools and report the calls
/// that come back. Everything else — admission, accounting, tracing — is the
/// same path, because a tool round is a completion like any other and is billed
/// like one.
pub async fn run_managed_inbox_turn(
    env: &Env,
    uid: &str,
    messages: &[managed_ai::Message],
    tier: managed_ai::ModelTier,
    tools: Option<&[Value]>,
) -> Option<InboxTurn> {
    let endpoint = env_get(env, "MIMO_CHAT_COMPLETIONS_URL");
    // Meeting-note-style one-shot completions run on the BALANCED tier, which
    // defaults to MIMO_MODEL when set. Callers answering someone who has not
    // signed in anywhere yet pass SPEED instead: the conversation is free and
    // uncapped, so what keeps it affordable is the model, not a quota.
    let model = managed_ai::model_for_tier(tier, |name| env_get(env, name));
    if messages.is_empty() {
        return None;
    }
    let gateway = managed_ai::ai_gateway_route(|name| env_get(env, name)).ok()?;
    let trace_provider = if gateway.is_some() {
        "openrouter"
    } else {
        "mimo"
    };
    let (endpoint_url, secret) = match &gateway {
        Some(route) => (
            worker::Url::parse(&route.url).ok()?,
            env_get(env, "OPENROUTER_API_KEY")?,
        ),
        None => (
            managed_ai::validate_pinned_endpoint(
                &endpoint?,
                managed_ai::XIAOMI_COMPLETION_ENDPOINT,
                managed_ai::XIAOMI_HOSTNAME,
            )?,
            env_get(env, "MIMO_API_KEY")?,
        ),
    };
    let input_price =
        managed_ai::price(env_get(env, "MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS").as_deref())?;
    let output_price =
        managed_ai::price(env_get(env, "MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS").as_deref())?;

    let estimated_input_tokens = managed_ai::input_token_reservation(messages);
    let estimated_cost = managed_ai::cost_for(
        estimated_input_tokens,
        WORKER_COMPLETION_MAX_OUTPUT_TOKENS,
        input_price,
        output_price,
    );

    let request_id = uuid_v4();
    let trace_started_at = now_ms();
    let stub = assistant_admission_stub(env).ok()?;
    let admission = do_post(
        &stub,
        "https://assistant-admission.internal/admit",
        &json!({
            "requestId": request_id,
            "uid": uid,
            "tokenBudget": estimated_input_tokens + WORKER_COMPLETION_MAX_OUTPUT_TOKENS,
            "costBudgetMicrousd": estimated_cost,
        }),
    )
    .await
    .ok()?;
    if admission.status_code() >= 300 {
        return None;
    }

    let now = now_ms();
    let input_characters: i64 = messages
        .iter()
        .map(|m| m.content.encode_utf16().count() as i64)
        .sum();
    if insert_managed_request_env(
        env,
        &request_id,
        uid,
        "mimo",
        &model,
        input_characters,
        WORKER_COMPLETION_MAX_OUTPUT_TOKENS,
        Some(estimated_cost),
        now,
    )
    .await
    .is_err()
    {
        release_assistant(&stub, &request_id).await;
        return None;
    }

    let message_values: Vec<Value> = messages.iter().map(managed_ai::Message::to_json).collect();
    let mut body = json!({
        "model": model,
        "messages": message_values,
        "stream": false,
        "max_tokens": WORKER_COMPLETION_MAX_OUTPUT_TOKENS,
    });
    if let Some(tools) = tools.filter(|t| !t.is_empty()) {
        let obj = body.as_object_mut().expect("object");
        obj.insert("tools".into(), Value::Array(tools.to_vec()));
        // `auto`, not `required`: most messages are just conversation, and a
        // model forced to call something on every turn will invent a reason to.
        obj.insert("tool_choice".into(), Value::String("auto".into()));
    }

    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    let _ = headers.set("authorization", &format!("Bearer {secret}"));
    let _ = headers.set("content-type", "application/json");
    if let Some(token) = gateway.and_then(|route| route.token) {
        let _ = headers.set("cf-aig-authorization", &format!("Bearer {token}"));
    }
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let Ok(upstream_request) = Request::new_with_init(endpoint_url.as_str(), &init) else {
        settle_managed_inbox(
            env,
            &stub,
            &request_id,
            "failed",
            None,
            None,
            None,
            input_price,
            output_price,
        )
        .await;
        return None;
    };
    let mut upstream = match worker::Fetch::Request(upstream_request).send().await {
        Ok(response) => response,
        Err(_) => {
            settle_managed_inbox(
                env,
                &stub,
                &request_id,
                "failed",
                None,
                None,
                None,
                input_price,
                output_price,
            )
            .await;
            send_foglamp_trace(
                env,
                &request_id,
                "managed-inbox-completion",
                trace_provider,
                &model,
                trace_started_at,
                "error",
                None,
                None,
            )
            .await;
            return None;
        }
    };
    let upstream_status = upstream.status_code() as i64;
    if upstream_status >= 300 {
        settle_managed_inbox(
            env,
            &stub,
            &request_id,
            "failed",
            None,
            None,
            Some(upstream_status),
            input_price,
            output_price,
        )
        .await;
        send_foglamp_trace(
            env,
            &request_id,
            "managed-inbox-completion",
            trace_provider,
            &model,
            trace_started_at,
            "error",
            None,
            None,
        )
        .await;
        return None;
    }

    let value = upstream.json::<Value>().await.ok();
    let (content, input_tokens, output_tokens) = match value.as_ref() {
        Some(v) => managed_ai::parse_completion(v),
        None => (None, None, None),
    };
    let calls = value.as_ref().and_then(managed_ai::parse_tool_calls);
    // A turn that asked for tools and said nothing is a complete, successful
    // turn. Judging it by content alone would bill it as a failure and hand the
    // caller a `None` that releases the inbox claim for a pointless retry.
    let produced = content.is_some() || calls.is_some();
    let status = if produced { "complete" } else { "failed" };
    settle_managed_inbox(
        env,
        &stub,
        &request_id,
        status,
        input_tokens,
        output_tokens,
        Some(upstream_status),
        input_price,
        output_price,
    )
    .await;
    send_foglamp_trace(
        env,
        &request_id,
        "managed-inbox-completion",
        trace_provider,
        &model,
        trace_started_at,
        if produced { "ok" } else { "error" },
        input_tokens,
        output_tokens,
    )
    .await;
    if !produced {
        return None;
    }
    let (tool_calls_raw, tool_calls) = match calls {
        Some((raw, calls)) => (Some(raw), calls),
        None => (None, Vec::new()),
    };
    Some(InboxTurn {
        content,
        tool_calls_raw,
        tool_calls,
    })
}

/// Env-based variant of `insert_managed_request` for the inbox completion path
/// (which has an `&Env`, not a `RouteContext`).
#[allow(clippy::too_many_arguments)]
async fn insert_managed_request_env(
    env: &Env,
    request_id: &str,
    uid: &str,
    provider: &str,
    model: &str,
    input_characters: i64,
    requested_max_output_tokens: i64,
    estimated_cost_microusd: Option<i64>,
    now: i64,
) -> Result<()> {
    let db = env.d1("DB")?;
    let statement = if let Some(cost) = estimated_cost_microusd {
        db.prepare(
            "INSERT INTO managed_ai_requests\n             (id, uid, provider, model, status, input_characters, requested_max_output_tokens,\n              estimated_cost_microusd, created_at, updated_at)\n             VALUES (?1, ?2, ?3, ?4, 'started', ?5, ?6, ?7, ?8, ?8)",
        )
        .bind(&[
            request_id.into(),
            uid.into(),
            provider.into(),
            model.into(),
            (input_characters as f64).into(),
            (requested_max_output_tokens as f64).into(),
            (cost as f64).into(),
            (now as f64).into(),
        ])?
    } else {
        db.prepare(
            "INSERT INTO managed_ai_requests\n             (id, uid, provider, model, status, input_characters, requested_max_output_tokens,\n              created_at, updated_at)\n             VALUES (?1, ?2, ?3, ?4, 'started', ?5, ?6, ?7, ?7)",
        )
        .bind(&[
            request_id.into(),
            uid.into(),
            provider.into(),
            model.into(),
            (input_characters as f64).into(),
            (requested_max_output_tokens as f64).into(),
            (now as f64).into(),
        ])?
    };
    statement.run().await.map(|_| ())
}

/// Port of the `settle` closure inside `runManagedInboxCompletion`: finalize the
/// ledger row then settle (or release) the admission reservation.
#[allow(clippy::too_many_arguments)]
async fn settle_managed_inbox(
    env: &Env,
    stub: &Stub,
    request_id: &str,
    status: &str,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    upstream_status: Option<i64>,
    input_price: i64,
    output_price: i64,
) {
    let actual_cost = match (input_tokens, output_tokens) {
        (Some(i), Some(o)) => Some(managed_ai::cost_for(i, o, input_price, output_price)),
        _ => None,
    };
    let now = now_ms();
    if let Ok(db) = env.d1("DB") {
        let coalesce = |v: Option<i64>| v.map(|n| (n as f64).into()).unwrap_or(JsValue::NULL);
        if let Ok(statement) = db
            .prepare(
                "UPDATE managed_ai_requests\n                 SET status = ?1, input_tokens = COALESCE(?2, input_tokens),\n                     output_tokens = COALESCE(?3, output_tokens),\n                     actual_cost_microusd = COALESCE(?4, actual_cost_microusd),\n                     upstream_status = COALESCE(?5, upstream_status),\n                     finalization_attempts = finalization_attempts + 1,\n                     finalized_at = COALESCE(finalized_at, ?6), updated_at = ?6\n                 WHERE id = ?7 AND finalized_at IS NULL",
            )
            .bind(&[
                status.into(),
                coalesce(input_tokens),
                coalesce(output_tokens),
                coalesce(actual_cost),
                coalesce(upstream_status),
                (now as f64).into(),
                request_id.into(),
            ])
        {
            let _ = statement.run().await;
        }
    }
    let settled = match (input_tokens, output_tokens, actual_cost) {
        (Some(i), Some(o), Some(c)) => do_post(
            stub,
            "https://assistant-admission.internal/settle",
            &json!({ "requestId": request_id, "tokenBudget": i + o, "costBudgetMicrousd": c }),
        )
        .await
        .is_ok(),
        _ => do_post(
            stub,
            "https://assistant-admission.internal/release",
            &json!({ "requestId": request_id }),
        )
        .await
        .is_ok(),
    };
    if settled {
        if let Ok(db) = env.d1("DB") {
            if let Ok(statement) = db
                .prepare("UPDATE managed_ai_requests SET admission_settled_at = COALESCE(admission_settled_at, ?1), updated_at = ?1 WHERE id = ?2")
                .bind(&[(now as f64).into(), request_id.into()])
            {
                let _ = statement.run().await;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Managed assistant: POST /v1/chat/completions
// ---------------------------------------------------------------------------

async fn handle_chat_completions(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let content_length = req.headers().get("content-length").ok().flatten();
    let bytes = req.bytes().await.ok();
    let body = managed_ai::bounded_json(
        content_length.as_deref(),
        bytes.as_deref(),
        managed_ai::MAXIMUM_BODY_BYTES,
    );

    // The requested model decides the tier and therefore the upstream: BALANCED
    // is pinned to MiMo, SEARCH is routed to OpenRouter (perplexity/sonar) whose
    // grounded reply carries its `url_citation` sources through unchanged. A
    // model naming neither tier is rejected.
    let requested_model = body
        .as_ref()
        .and_then(|b| b.get("model"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let tier = requested_model.as_deref().and_then(|model| {
        managed_ai::completion_tier_for_model(model, |name| env_get(&ctx.env, name))
    });
    let Some(tier) = tier else {
        return error_json("Invalid request", 400);
    };

    let (endpoint, secret, pinned, hostname, model, provider) = match tier {
        managed_ai::ManagedCompletionTier::Balanced => (
            env_get(&ctx.env, "MIMO_CHAT_COMPLETIONS_URL"),
            env_get(&ctx.env, "MIMO_API_KEY"),
            managed_ai::XIAOMI_COMPLETION_ENDPOINT,
            managed_ai::XIAOMI_HOSTNAME,
            managed_ai::model_for_tier(managed_ai::ModelTier::Balanced, |name| {
                env_get(&ctx.env, name)
            }),
            "mimo",
        ),
        managed_ai::ManagedCompletionTier::Search => (
            Some(
                env_get(&ctx.env, "OPENROUTER_CHAT_COMPLETIONS_URL")
                    .unwrap_or_else(|| managed_ai::OPENROUTER_COMPLETION_ENDPOINT.to_owned()),
            ),
            env_get(&ctx.env, "OPENROUTER_API_KEY"),
            managed_ai::OPENROUTER_COMPLETION_ENDPOINT,
            managed_ai::OPENROUTER_HOSTNAME,
            managed_ai::model_for_tier(managed_ai::ModelTier::Search, |name| {
                env_get(&ctx.env, name)
            }),
            "openrouter",
        ),
    };
    let gateway = match managed_ai::ai_gateway_route(|name| env_get(&ctx.env, name)) {
        Ok(gateway) => gateway,
        Err(_) => return error_json("Managed AI unavailable", 503),
    };
    let (endpoint_url, secret) = match &gateway {
        Some(route) => (
            worker::Url::parse(&route.url).ok(),
            env_get(&ctx.env, "OPENROUTER_API_KEY"),
        ),
        None => (
            endpoint
                .as_deref()
                .and_then(|value| managed_ai::validate_pinned_endpoint(value, pinned, hostname)),
            secret,
        ),
    };
    let (Some(endpoint_url), Some(secret)) = (endpoint_url, secret) else {
        return error_json("Managed AI unavailable", 503);
    };

    let Some(parsed) = body
        .as_ref()
        .and_then(|b| managed_ai::parse_request(b, &model))
    else {
        return error_json("Invalid request", 400);
    };

    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    if !has_active_pro(&ctx, &auth.uid).await.unwrap_or(false) {
        return error_json("Managed Pro required", 403);
    }

    let input_price =
        managed_ai::price(env_get(&ctx.env, "MIMO_INPUT_MICROUSD_PER_MILLION_TOKENS").as_deref());
    let output_price =
        managed_ai::price(env_get(&ctx.env, "MIMO_OUTPUT_MICROUSD_PER_MILLION_TOKENS").as_deref());
    let (Some(input_price), Some(output_price)) = (input_price, output_price) else {
        return error_json("Managed AI unavailable", 503);
    };

    let request_id = uuid_v4();
    let now = now_ms();
    let input_characters: i64 = parsed
        .messages
        .iter()
        .map(|m| m.content.encode_utf16().count() as i64)
        .sum();
    let estimated_input_tokens = managed_ai::input_token_reservation(&parsed.messages);
    let estimated_cost = managed_ai::cost_for(
        estimated_input_tokens,
        parsed.max_tokens,
        input_price,
        output_price,
    );

    let stub = match assistant_admission_stub(&ctx.env) {
        Ok(stub) => stub,
        Err(_) => return error_json("Managed AI unavailable", 503),
    };
    let admission_payload = json!({
        "requestId": request_id,
        "uid": auth.uid,
        "tokenBudget": estimated_input_tokens + parsed.max_tokens,
        "costBudgetMicrousd": estimated_cost,
    });
    let admission = match do_post(
        &stub,
        "https://assistant-admission.internal/admit",
        &admission_payload,
    )
    .await
    {
        Ok(response) => response,
        Err(_) => return error_json("Managed AI unavailable", 503),
    };
    if admission.status_code() >= 300 {
        let retry_after = admission.headers().get("retry-after").ok().flatten();
        let mut response =
            Response::from_json(&json!({ "error": "Managed AI capacity exceeded" }))?
                .with_status(429);
        if let Some(retry_after) = retry_after {
            response.headers_mut().set("retry-after", &retry_after)?;
        }
        return Ok(response);
    }

    if insert_managed_request(
        &ctx,
        &request_id,
        &auth.uid,
        provider,
        &model,
        input_characters,
        parsed.max_tokens,
        Some(estimated_cost),
        now,
    )
    .await
    .is_err()
    {
        let _ = do_post(
            &stub,
            "https://assistant-admission.internal/release",
            &json!({ "requestId": request_id }),
        )
        .await;
        return error_json("Managed AI unavailable", 503);
    }

    // Forward to the pinned upstream and stream the SSE response straight
    // through. Budget settlement from the usage tail is reconciled by
    // `reconcile_managed_assistant_requests`; see the module note.
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("authorization", &format!("Bearer {secret}"))?;
    headers.set("content-type", "application/json")?;
    if let Some(token) = gateway.and_then(|route| route.token) {
        headers.set("cf-aig-authorization", &format!("Bearer {token}"))?;
    }
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(
        &managed_ai::upstream_body(&parsed).to_string(),
    )));
    let upstream_request = Request::new_with_init(endpoint_url.as_str(), &init)?;
    let mut upstream = match worker::Fetch::Request(upstream_request).send().await {
        Ok(response) => response,
        Err(_) => {
            finalize_managed_request(&ctx, &request_id, "failed", None).await;
            release_assistant(&stub, &request_id).await;
            send_foglamp_trace(
                &ctx.env,
                &request_id,
                "managed-chat-completion",
                provider,
                &model,
                now,
                "error",
                None,
                None,
            )
            .await;
            return error_json("Managed AI unavailable", 502);
        }
    };
    let upstream_status = upstream.status_code();
    if upstream_status >= 300 {
        finalize_managed_request(&ctx, &request_id, "failed", Some(upstream_status as i64)).await;
        release_assistant(&stub, &request_id).await;
        send_foglamp_trace(
            &ctx.env,
            &request_id,
            "managed-chat-completion",
            provider,
            &model,
            now,
            "error",
            None,
            None,
        )
        .await;
        return error_json("Managed AI unavailable", 502);
    }

    mark_streaming(&ctx, &request_id, upstream_status as i64).await;

    let upstream_stream = upstream.stream()?;
    let usage_tail = Rc::new(RefCell::new(managed_ai::UsageTail::default()));
    let stream_tail = Rc::clone(&usage_tail);
    let failed = Rc::new(Cell::new(false));
    let stream_failed = Rc::clone(&failed);
    let final_env = ctx.env.clone();
    let final_request_id = request_id.clone();
    let final_model = model.clone();
    let final_provider = provider.to_owned();
    let stream = upstream_stream
        .map(move |chunk| match chunk {
            Ok(chunk) => {
                stream_tail.borrow_mut().push(&chunk);
                Ok(chunk)
            }
            Err(_) => {
                stream_failed.set(true);
                Ok(Vec::new())
            }
        })
        .chain(stream::once(async move {
            let (input_tokens, output_tokens) = usage_tail.borrow().usage();
            if let Ok(stub) = assistant_admission_stub(&final_env) {
                let status = if failed.get() { "error" } else { "ok" };
                settle_managed_inbox(
                    &final_env,
                    &stub,
                    &final_request_id,
                    if failed.get() { "failed" } else { "complete" },
                    input_tokens,
                    output_tokens,
                    Some(upstream_status as i64),
                    input_price,
                    output_price,
                )
                .await;
                send_foglamp_trace(
                    &final_env,
                    &final_request_id,
                    "managed-chat-completion",
                    &final_provider,
                    &final_model,
                    now,
                    status,
                    input_tokens,
                    output_tokens,
                )
                .await;
            }
            Ok::<Vec<u8>, worker::Error>(Vec::new())
        }));
    let mut response = Response::from_stream(stream)?.with_status(200);
    let headers = response.headers_mut();
    headers.set("cache-control", "no-store")?;
    headers.set("content-type", "text/event-stream; charset=utf-8")?;
    headers.set("x-omi-request-id", &request_id)?;
    headers.set("x-content-type-options", "nosniff")?;
    Ok(response)
}

async fn release_assistant(stub: &Stub, request_id: &str) {
    let _ = do_post(
        stub,
        "https://assistant-admission.internal/release",
        &json!({ "requestId": request_id }),
    )
    .await;
}

async fn mark_streaming(ctx: &RouteContext<()>, request_id: &str, upstream_status: i64) {
    let Ok(db) = ctx.env.d1("DB") else { return };
    let now = now_ms();
    if let Ok(statement) = db
        .prepare("UPDATE managed_ai_requests SET status = 'streaming', upstream_status = ?1, updated_at = ?2 WHERE id = ?3")
        .bind(&[(upstream_status as f64).into(), (now as f64).into(), request_id.into()])
    {
        let _ = statement.run().await;
    }
}

// ---------------------------------------------------------------------------
// Managed ASR: POST /v1/asr/transcribe
// ---------------------------------------------------------------------------

async fn handle_asr(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let Some(secret) = env_get(&ctx.env, "OPENROUTER_API_KEY") else {
        return error_json("Managed AI unavailable", 503);
    };

    let content_length = req.headers().get("content-length").ok().flatten();
    if asr_logic::declared_length_exceeds(content_length.as_deref()) {
        return error_json("Audio too large", 413);
    }

    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    if !has_active_pro(&ctx, &auth.uid).await.unwrap_or(false) {
        return error_json("Managed Pro required", 403);
    }

    // Stream with an early size abort; content-length was already checked above.
    let bytes = read_body_limited(&mut req, asr_logic::maximum_body_bytes()).await;
    let Some(body) = managed_ai::bounded_json(
        content_length.as_deref(),
        bytes.as_deref(),
        asr_logic::maximum_body_bytes(),
    ) else {
        return error_json("Invalid request", 400);
    };
    let request = match asr_logic::classify(&body) {
        asr_logic::AsrOutcome::Ok(request) => request,
        asr_logic::AsrOutcome::TooLarge => return error_json("Audio too large", 413),
        asr_logic::AsrOutcome::Invalid => return error_json("Invalid request", 400),
    };

    let (allowed, retry_after) =
        consume_rate_limit(&ctx.env, &format!("asr:{}", auth.uid), 10, 60_000).await;
    if !allowed {
        let mut response =
            Response::from_json(&json!({ "error": "Too many requests" }))?.with_status(429);
        response
            .headers_mut()
            .set("retry-after", &retry_after.to_string())?;
        return Ok(response);
    }

    let request_id = uuid_v4();
    let now = now_ms();
    if insert_managed_request(
        &ctx,
        &request_id,
        &auth.uid,
        "openrouter-grok-stt",
        asr_logic::ASR_MODEL,
        // Base64 audio is ASCII; byte length matches JS `String.length`.
        request.audio.len() as i64,
        0,
        None,
        now,
    )
    .await
    .is_err()
    {
        return error_json("Managed AI unavailable", 503);
    }

    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("authorization", &format!("Bearer {secret}"))?;
    headers.set("content-type", "application/json")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(
        &asr_logic::upstream_body(&request).to_string(),
    )));
    let upstream_request = Request::new_with_init(asr_logic::OPENROUTER_STT_ENDPOINT, &init)?;
    let mut upstream = match worker::Fetch::Request(upstream_request).send().await {
        Ok(response) => response,
        Err(_) => {
            finalize_managed_request(&ctx, &request_id, "failed", None).await;
            return error_json("Managed AI unavailable", 502);
        }
    };
    let upstream_status = upstream.status_code();
    if upstream_status >= 300 {
        finalize_managed_request(&ctx, &request_id, "failed", Some(upstream_status as i64)).await;
        return error_json("Managed AI unavailable", 502);
    }
    let transcript = match upstream.json::<Value>().await {
        Ok(value) => asr_logic::parse_transcript(&value),
        Err(_) => None,
    };
    let Some(text) = transcript else {
        finalize_managed_request(&ctx, &request_id, "failed", Some(upstream_status as i64)).await;
        return error_json("Managed AI unavailable", 502);
    };
    finalize_managed_request(&ctx, &request_id, "complete", Some(upstream_status as i64)).await;
    Response::from_json(&json!({ "text": text }))
}

// ---------------------------------------------------------------------------
// Live voice: POST /v1/voice/gemini/token
// ---------------------------------------------------------------------------

async fn handle_voice_token(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let key = env_get(&ctx.env, "GEMINI_API_KEY");
    let model = env_get(&ctx.env, "GEMINI_LIVE_MODEL");
    let (Some(key), Some(model)) = (key, model) else {
        return error_json("Live voice unavailable", 503);
    };
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    if !has_active_pro(&ctx, &auth.uid).await.unwrap_or(false) {
        return error_json("Managed Pro required", 403);
    }
    let (allowed, retry_after) =
        consume_rate_limit(&ctx.env, &format!("voice-token:{}", auth.uid), 10, 60_000).await;
    if !allowed {
        let mut response =
            Response::from_json(&json!({ "error": "Too many requests" }))?.with_status(429);
        response
            .headers_mut()
            .set("retry-after", &retry_after.to_string())?;
        return Ok(response);
    }

    let now = now_ms();
    let request_id = uuid_v4();
    if insert_managed_request(
        &ctx,
        &request_id,
        &auth.uid,
        "gemini-live",
        &model,
        0,
        0,
        None,
        now,
    )
    .await
    .is_err()
    {
        return error_json("Live voice unavailable", 503);
    }

    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    headers.set("x-goog-api-key", &key)?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(
        &voice_logic::token_request_body(now, &model).to_string(),
    )));
    let upstream_request = Request::new_with_init(voice_logic::TOKEN_ENDPOINT, &init)?;
    let mut upstream = match worker::Fetch::Request(upstream_request).send().await {
        Ok(response) => response,
        Err(_) => {
            finalize_managed_request(&ctx, &request_id, "failed", None).await;
            return error_json("Live voice provider unavailable", 502);
        }
    };
    let upstream_status = upstream.status_code();
    if upstream_status >= 300 {
        finalize_managed_request(&ctx, &request_id, "failed", Some(upstream_status as i64)).await;
        return error_json("Live voice provider unavailable", 502);
    }
    let token_name = match upstream.json::<Value>().await {
        Ok(value) => voice_logic::parse_token_name(&value),
        Err(_) => None,
    };
    let Some(token_name) = token_name else {
        finalize_managed_request(&ctx, &request_id, "failed", Some(upstream_status as i64)).await;
        return error_json("Live voice provider unavailable", 502);
    };
    finalize_managed_request(&ctx, &request_id, "complete", Some(upstream_status as i64)).await;
    Response::from_json(&voice_logic::client_response(now, &model, &token_name))
}

// ---------------------------------------------------------------------------
// Managed STT: POST /v1/stt/sessions and GET .../stream
// ---------------------------------------------------------------------------

async fn handle_stt_create(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let max_session_seconds =
        crate::jsnum::positive_integer_str(env_get(&ctx.env, "STT_MAX_SESSION_SECONDS").as_deref());
    let cost_per_minute = crate::jsnum::positive_integer_str(
        env_get(&ctx.env, "STT_COST_MICROUSD_PER_MINUTE").as_deref(),
    );
    let xai = env_get(&ctx.env, "OPENROUTER_API_KEY");
    let (Some(max_session_seconds), Some(cost_per_minute), true) =
        (max_session_seconds, cost_per_minute, xai.is_some())
    else {
        return error_json("Managed STT unavailable", 503);
    };
    if max_session_seconds > 3600 {
        return error_json("Managed STT unavailable", 503);
    }

    let content_length = req.headers().get("content-length").ok().flatten();
    let bytes = req.bytes().await.ok();
    // stt.ts caps the body at 4096 bytes before JSON parsing.
    let body = managed_ai::bounded_json(content_length.as_deref(), bytes.as_deref(), 4096);
    let Some(parsed) = body.as_ref().and_then(stt_logic::parse_request) else {
        return error_json("Invalid request", 400);
    };

    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    if !has_active_pro(&ctx, &auth.uid).await.unwrap_or(false) {
        return error_json("Managed Pro required", 403);
    }

    let session_id = stt_logic::session_id_for(&auth.uid, &parsed.idempotency_key);
    let estimated_cost = ((max_session_seconds * cost_per_minute) as f64 / 60.0).ceil() as i64;
    if estimated_cost <= 0 {
        return error_json("Managed STT unavailable", 503);
    }

    let stub = match stt_admission_stub(&ctx.env) {
        Ok(stub) => stub,
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    let admission_payload = json!({
        "sessionId": session_id,
        "uid": auth.uid,
        "reservedSeconds": max_session_seconds,
        "costBudgetMicrousd": estimated_cost,
    });
    let mut admission = match do_post(
        &stub,
        "https://stt-admission.internal/admit",
        &admission_payload,
    )
    .await
    {
        Ok(response) => response,
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    if admission.status_code() >= 300 {
        let retry_after = admission.headers().get("retry-after").ok().flatten();
        let mut response =
            Response::from_json(&json!({ "error": "Managed STT capacity exceeded" }))?
                .with_status(429);
        if let Some(retry_after) = retry_after {
            response.headers_mut().set("retry-after", &retry_after)?;
        }
        return Ok(response);
    }
    let result = admission.json::<Value>().await.unwrap_or(Value::Null);
    let acquisition_token = result
        .get("acquisitionToken")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if result.get("admitted").and_then(Value::as_bool) != Some(true) || acquisition_token.len() < 16
    {
        return error_json("Managed STT unavailable", 503);
    }
    let duplicate = result.get("duplicate").and_then(Value::as_bool) == Some(true);
    let owns_admission =
        !duplicate || result.get("reacquired").and_then(Value::as_bool) == Some(true);

    let now = now_ms();
    let db = match ctx.env.d1("DB") {
        Ok(db) => db,
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    let insert = db
        .prepare(
            "INSERT INTO managed_stt_sessions\n             (id, uid, idempotency_key, provider, model, language, encoding, sample_rate,\n              channels, diarize, interim_results, device_id, source_id, status,\n              reserved_seconds, estimated_cost_microusd, created_at, updated_at, admission_token)\n             VALUES (?1, ?2, ?3, 'openrouter', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,\n              'ready', ?13, ?14, ?15, ?15, ?16)\n             ON CONFLICT(uid, idempotency_key) DO UPDATE SET\n               admission_token = excluded.admission_token,\n               updated_at = excluded.updated_at\n             WHERE managed_stt_sessions.status = 'ready'",
        )
        .bind(&[
            session_id.clone().into(),
            auth.uid.clone().into(),
            parsed.idempotency_key.clone().into(),
            parsed.model.clone().into(),
            parsed.language.clone().into(),
            parsed.encoding.clone().into(),
            (parsed.sample_rate as f64).into(),
            (parsed.channels as f64).into(),
            (if parsed.diarize { 1.0 } else { 0.0 }).into(),
            (if parsed.interim_results { 1.0 } else { 0.0 }).into(),
            parsed.device_id.clone().into(),
            parsed.source_id.clone().into(),
            (max_session_seconds as f64).into(),
            (estimated_cost as f64).into(),
            (now as f64).into(),
            acquisition_token.clone().into(),
        ]);
    let insert_ok = match insert {
        Ok(statement) => statement.run().await.is_ok(),
        Err(_) => false,
    };
    if !insert_ok {
        if owns_admission {
            release_stt(&stub, &session_id, &auth.uid, &acquisition_token).await;
        }
        return error_json("Managed STT unavailable", 503);
    }

    let row = db
        .prepare(
            "SELECT id, model, language, encoding, sample_rate, channels, diarize,\n                    interim_results, device_id, source_id, status, reserved_seconds\n             FROM managed_stt_sessions WHERE uid = ?1 AND idempotency_key = ?2",
        )
        .bind(&[auth.uid.clone().into(), parsed.idempotency_key.clone().into()]);
    let row = match row {
        Ok(statement) => statement.first::<Value>(None).await.ok().flatten(),
        Err(_) => None,
    };
    let Some(row) = row else {
        if owns_admission {
            release_stt(&stub, &session_id, &auth.uid, &acquisition_token).await;
        }
        return error_json("Managed STT unavailable", 503);
    };
    if !stt_logic::idempotency_matches(&session_id, &parsed, &row, max_session_seconds) {
        if owns_admission {
            release_stt(&stub, &session_id, &auth.uid, &acquisition_token).await;
        }
        return error_json("Idempotency conflict", 409);
    }

    let status = row
        .get("status")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let request_url = req.url()?;
    let websocket_url =
        stt_logic::websocket_url(request_url.as_str(), &session_id).unwrap_or_default();
    let response = Response::from_json(&json!({
        "sessionId": session_id,
        "websocketUrl": websocket_url,
        "maxSessionSeconds": max_session_seconds,
        "state": status,
    }))?;
    let response = response.with_status(if status == "ready" { 201 } else { 200 });
    Ok(response)
}

async fn release_stt(stub: &Stub, session_id: &str, uid: &str, token: &str) {
    let _ = do_post(
        stub,
        "https://stt-admission.internal/release",
        &json!({ "sessionId": session_id, "uid": uid, "acquisitionToken": token }),
    )
    .await;
}

/// GET /v1/stt/sessions/:sessionId/stream — establishes the Worker↔Deepgram
/// WebSocket bridge. The bidirectional relay itself is spawned; the pure
/// `stt_logic::bridge_outcome` documents the terminal-status contract it
/// follows.
async fn handle_stt_stream(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let session_id = ctx.param("sessionId").cloned().unwrap_or_default();
    let is_upgrade = req
        .headers()
        .get("upgrade")
        .ok()
        .flatten()
        .map(|v| v.to_lowercase() == "websocket")
        .unwrap_or(false);
    if !stt_logic::is_session_id(&session_id) || !is_upgrade {
        return error_json("Managed STT unavailable", 503);
    }
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let db = match ctx.env.d1("DB") {
        Ok(db) => db,
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    // One D1 read for admission + Deepgram session params (avoids a second
    // SELECT after claim; those columns are immutable after create).
    let session_row = db
        .prepare(
            "SELECT admission_token, model, language, encoding, sample_rate, channels, diarize,\n                    interim_results, reserved_seconds\n             FROM managed_stt_sessions WHERE id = ?1 AND uid = ?2 AND status = 'ready'",
        )
        .bind(&[session_id.clone().into(), auth.uid.clone().into()]);
    let session_row = match session_row {
        Ok(statement) => statement.first::<Value>(None).await.ok().flatten(),
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    let Some(row) = session_row else {
        return error_json("STT session unavailable", 409);
    };
    let Some(acquisition_token) = row
        .get("admission_token")
        .and_then(Value::as_str)
        .map(str::to_string)
    else {
        return error_json("STT session unavailable", 409);
    };

    let secret = env_get(&ctx.env, "OPENROUTER_API_KEY");
    let max_session_seconds =
        crate::jsnum::positive_integer_str(env_get(&ctx.env, "STT_MAX_SESSION_SECONDS").as_deref());
    let connect_timeout = crate::jsnum::positive_integer_str(
        env_get(&ctx.env, "STT_UPSTREAM_CONNECT_TIMEOUT_MS").as_deref(),
    );
    let stub = match stt_admission_stub(&ctx.env) {
        Ok(stub) => stub,
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    let (Some(secret), Some(max_session_seconds), Some(connect_timeout)) =
        (secret, max_session_seconds, connect_timeout)
    else {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("Managed STT unavailable", 503);
    };
    if max_session_seconds > 3600 || connect_timeout > 15_000 {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("Managed STT unavailable", 503);
    }

    if !has_active_pro(&ctx, &auth.uid).await.unwrap_or(false) {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("Managed Pro required", 403);
    }

    // Atomically claim the session in D1.
    let now = now_ms();
    let claim = db
        .prepare(
            "UPDATE managed_stt_sessions\n             SET status = 'streaming', claimed_at = ?1, updated_at = ?1\n             WHERE id = ?2 AND uid = ?3 AND status = 'ready' AND admission_token = ?4",
        )
        .bind(&[(now as f64).into(), session_id.clone().into(), auth.uid.clone().into(), acquisition_token.clone().into()]);
    let claimed = match claim {
        Ok(statement) => statement
            .run()
            .await
            .ok()
            .map(|r| r.meta().ok().flatten().and_then(|m| m.changes).unwrap_or(0)),
        Err(_) => None,
    };
    match claimed {
        Some(1) => {}
        Some(_) => return error_json("STT session unavailable", 409),
        None => {
            fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
            return error_json("Managed STT unavailable", 503);
        }
    }
    // Confirm the claim in the admission DO.
    let claim_ack = do_post(
        &stub,
        "https://stt-admission.internal/claim",
        &json!({ "sessionId": session_id, "uid": auth.uid, "acquisitionToken": acquisition_token }),
    )
    .await;
    let claimed_ok = match claim_ack {
        Ok(mut response) => {
            response
                .json::<Value>()
                .await
                .ok()
                .and_then(|v| v.get("claimed").and_then(Value::as_bool))
                == Some(true)
        }
        Err(_) => false,
    };
    if !claimed_ok {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("Managed STT unavailable", 503);
    }

    let session_seconds = row
        .get("reserved_seconds")
        .and_then(Value::as_i64)
        .filter(|s| *s > 0 && *s <= max_session_seconds);
    let Some(session_seconds) = session_seconds else {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("STT session unavailable", 409);
    };

    // Connect to Deepgram, upgrading to a WebSocket.

    let pair = WebSocketPair::new()?;
    let server = pair.server;
    let client = pair.client;
    server.accept()?;

    // Spawn the bidirectional relay. Terminal settlement (DB status +
    // admission release) mirrors `bridgeSttSockets`; the pure
    // `stt_logic::bridge_outcome` is the reference for the status decision.
    let env = ctx.env.clone();
    let relay_session = session_id.clone();
    let relay_uid = auth.uid.clone();
    let relay_token = acquisition_token.clone();
    let relay_config = OpenRouterStt {
        secret,
        language: row
            .get("language")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
        sample_rate: row
            .get("sample_rate")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        channels: row
            .get("channels")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        diarize: row
            .get("diarize")
            .and_then(Value::as_i64)
            .unwrap_or_default()
            == 1,
        session_seconds,
    };
    wasm_bindgen_futures::spawn_local(async move {
        bridge_sockets(
            env,
            server,
            relay_session,
            relay_uid,
            relay_token,
            relay_config,
        )
        .await;
    });

    Response::from_websocket(client)
}

async fn fail_and_release_stt(
    ctx: &RouteContext<()>,
    stub: &Stub,
    session_id: &str,
    uid: &str,
    token: &str,
) {
    if let Ok(db) = ctx.env.d1("DB") {
        let now = now_ms();
        if let Ok(statement) = db
            .prepare("UPDATE managed_stt_sessions SET status = 'failed', completed_at = COALESCE(completed_at, ?1), updated_at = ?1 WHERE id = ?2 AND uid = ?3 AND status IN ('ready', 'streaming')")
            .bind(&[(now as f64).into(), session_id.into(), uid.into()])
        {
            let _ = statement.run().await;
        }
    }
    release_stt(stub, session_id, uid, token).await;
}

/// Relay frames between the client and Deepgram until either side closes,
/// then settle the session. Frame-size enforcement and terminal-status rules
/// follow `stt_logic::bridge_outcome`.
async fn bridge_sockets(
    env: Env,
    server: worker::WebSocket,
    session_id: String,
    uid: String,
    token: String,
    config: OpenRouterStt,
) {
    use stt_logic::{bridge_outcome, BridgeEvent, BridgeStatus};
    use worker::WebsocketEvent;

    let mut server_events = match server.events() {
        Ok(events) => events.fuse(),
        Err(_) => return,
    };
    let Some(chunk_bytes) = stt_logic::chunk_bytes(config.sample_rate, config.channels) else {
        return;
    };
    let bytes_per_second = config
        .sample_rate
        .checked_mul(config.channels)
        .and_then(|value| value.checked_mul(2))
        .unwrap_or_default();
    let maximum_bytes = bytes_per_second
        .checked_mul(config.session_seconds)
        .and_then(|value| usize::try_from(value).ok())
        .unwrap_or_default();
    let mut audio = Vec::with_capacity(chunk_bytes);
    let mut accepted_bytes = 0usize;
    let mut transcribed_bytes = 0usize;

    let status = 'relay: loop {
        match server_events.next().await {
            Some(Ok(WebsocketEvent::Message(message))) => {
                let event = if let Some(text) = message.text() {
                    BridgeEvent::ClientFrame { size: text.len() }
                } else {
                    BridgeEvent::ClientFrame {
                        size: message.bytes().map(|b| b.len()).unwrap_or(usize::MAX),
                    }
                };
                if let Some(outcome) = bridge_outcome(&[event]) {
                    break outcome;
                }
                if let Some(text) = message.text() {
                    if text != r#"{"type":"audio.done"}"# {
                        break BridgeStatus::Failed;
                    }
                    if !audio.is_empty()
                        && send_openrouter_chunk(&server, &config, transcribed_bytes, &audio)
                            .await
                            .is_err()
                    {
                        break BridgeStatus::Failed;
                    }
                    break BridgeStatus::Complete;
                }
                let bytes = message.bytes().unwrap_or_default();
                accepted_bytes = match accepted_bytes.checked_add(bytes.len()) {
                    Some(value) if value <= maximum_bytes => value,
                    _ => break BridgeStatus::Failed,
                };
                audio.extend_from_slice(&bytes);
                while audio.len() >= chunk_bytes {
                    let remainder = audio.split_off(chunk_bytes);
                    let chunk = std::mem::replace(&mut audio, remainder);
                    if send_openrouter_chunk(&server, &config, transcribed_bytes, &chunk)
                        .await
                        .is_err()
                    {
                        break 'relay BridgeStatus::Failed;
                    }
                    transcribed_bytes += chunk.len();
                }
            }
            Some(Ok(WebsocketEvent::Close(event))) => {
                break if event.code() == 1000 || event.code() == 1001 {
                    BridgeStatus::Complete
                } else {
                    BridgeStatus::Failed
                };
            }
            Some(Err(_)) | None => break BridgeStatus::Failed,
        }
    };

    let status_str = match status {
        BridgeStatus::Complete => "complete",
        BridgeStatus::Failed => "failed",
    };
    let _ = server.close(Some(1000), Some("Session closed"));
    if let Ok(db) = env.d1("DB") {
        let now = now_ms();
        if let Ok(statement) = db
            .prepare("UPDATE managed_stt_sessions SET status = ?1, completed_at = ?2, updated_at = ?2 WHERE id = ?3 AND uid = ?4 AND status = 'streaming'")
            .bind(&[status_str.into(), (now as f64).into(), session_id.clone().into(), uid.clone().into()])
        {
            let _ = statement.run().await;
        }
    }
    if let Ok(stub) = stt_admission_stub(&env) {
        release_stt(&stub, &session_id, &uid, &token).await;
    }
}

struct OpenRouterStt {
    secret: String,
    language: String,
    sample_rate: i64,
    channels: i64,
    diarize: bool,
    session_seconds: i64,
}

async fn send_openrouter_chunk(
    server: &worker::WebSocket,
    config: &OpenRouterStt,
    offset_bytes: usize,
    audio: &[u8],
) -> std::result::Result<(), ()> {
    let wav = stt_logic::wav(audio, config.sample_rate, config.channels).ok_or(())?;
    let body = stt_logic::openrouter_body(
        base64::engine::general_purpose::STANDARD.encode(wav),
        &config.language,
        config.diarize,
    );
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers
        .set("authorization", &format!("Bearer {}", config.secret))
        .map_err(|_| ())?;
    headers
        .set("content-type", "application/json")
        .map_err(|_| ())?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&body.to_string())));
    let request =
        Request::new_with_init(stt_logic::OPENROUTER_STT_ENDPOINT, &init).map_err(|_| ())?;
    let mut response = worker::Fetch::Request(request)
        .send()
        .await
        .map_err(|_| ())?;
    if response.status_code() >= 300 {
        return Err(());
    }
    let response = response.json::<Value>().await.map_err(|_| ())?;
    let bytes_per_second = config
        .sample_rate
        .checked_mul(config.channels)
        .and_then(|value| value.checked_mul(2))
        .filter(|value| *value > 0)
        .ok_or(())? as f64;
    for event in stt_logic::transcript_events(
        &response,
        offset_bytes as f64 / bytes_per_second,
        config.channels,
    ) {
        server.send_with_str(event.to_string()).map_err(|_| ())?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Cron reconcile piece (assistant.ts `reconcileManagedAssistantRequests`)
// ---------------------------------------------------------------------------

/// Settle stale/finalized managed assistant requests against the admission DO.
pub async fn reconcile_managed_assistant_requests(env: &Env) -> Result<()> {
    let now = now_ms();
    let db = env.d1("DB")?;
    let statement = db
        .prepare(
            "SELECT id, finalized_at, input_tokens, output_tokens, actual_cost_microusd\n             FROM managed_ai_requests\n             WHERE admission_settled_at IS NULL AND (\n               finalized_at IS NOT NULL OR\n               (status IN ('started', 'streaming') AND updated_at <= ?1)\n             ) LIMIT 100",
        )
        .bind(&[((now - managed_ai::STALE_REQUEST_MS) as f64).into()])?;
    let rows = statement.all().await?.results::<Value>()?;
    let stub = assistant_admission_stub(env)?;
    for row in rows {
        let id = row
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if id.is_empty() {
            continue;
        }
        if row.get("finalized_at").map(Value::is_null).unwrap_or(true) {
            if let Ok(statement) = db
                .prepare("UPDATE managed_ai_requests SET status = 'failed', finalization_attempts = finalization_attempts + 1, finalized_at = COALESCE(finalized_at, ?1), updated_at = ?1 WHERE id = ?2 AND finalized_at IS NULL")
                .bind(&[(now as f64).into(), id.clone().into()])
            {
                let _ = statement.run().await;
            }
        }
        let input_tokens = row.get("input_tokens").and_then(Value::as_i64);
        let output_tokens = row.get("output_tokens").and_then(Value::as_i64);
        let cost = row.get("actual_cost_microusd").and_then(Value::as_i64);
        let settle = match (input_tokens, output_tokens, cost) {
            (Some(i), Some(o), Some(c)) => do_post(
                &stub,
                "https://assistant-admission.internal/settle",
                &json!({ "requestId": id, "tokenBudget": i + o, "costBudgetMicrousd": c }),
            )
            .await
            .is_ok(),
            _ => do_post(
                &stub,
                "https://assistant-admission.internal/release",
                &json!({ "requestId": id }),
            )
            .await
            .is_ok(),
        };
        if settle {
            if let Ok(statement) = db
                .prepare("UPDATE managed_ai_requests SET admission_settled_at = COALESCE(admission_settled_at, ?1), updated_at = ?1 WHERE id = ?2")
                .bind(&[(now as f64).into(), id.clone().into()])
            {
                let _ = statement.run().await;
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Durable Objects — thin wrappers over the pure state machines. State is
// snapshotted as JSON in DO storage so the ledger survives eviction. (The TS
// worker uses the SQLite storage API directly; the state-machine semantics are
// identical and covered by the `cargo test` suites in the pure modules.)
// ---------------------------------------------------------------------------

async fn read_body(req: &mut Request) -> Value {
    req.json::<Value>().await.unwrap_or(Value::Null)
}

#[durable_object]
pub struct AssistantAdmissionDo {
    state: State,
    env: Env,
}

impl worker::DurableObject for AssistantAdmissionDo {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        let path = req.path();
        let method = req.method().to_string();
        let body = read_body(&mut req).await;
        let limits = AssistantLimits::from_env(|k| env_get(&self.env, k));
        let now = now_ms();
        let mut machine: AssistantAdmission = self
            .state
            .storage()
            .get(DO_STATE_KEY)
            .await
            .ok()
            .flatten()
            .unwrap_or_default();
        let outcome = machine.dispatch(limits, now, &method, &path, &body);
        self.state.storage().put(DO_STATE_KEY, &machine).await?;
        outcome_response(outcome)
    }
}

#[durable_object]
pub struct SttAdmissionDo {
    state: State,
    env: Env,
}

impl SttAdmissionDo {
    async fn load(&self) -> SttAdmission {
        self.state
            .storage()
            .get(DO_STATE_KEY)
            .await
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    async fn save_and_schedule(&self, machine: &SttAdmission) -> Result<()> {
        self.state.storage().put(DO_STATE_KEY, machine).await?;
        match machine.next_alarm() {
            Some(at) => {
                let _ = self.state.storage().set_alarm(at).await;
            }
            None => {
                let _ = self.state.storage().delete_alarm().await;
            }
        }
        Ok(())
    }
}

impl worker::DurableObject for SttAdmissionDo {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        let path = req.path();
        let method = req.method().to_string();
        let body = read_body(&mut req).await;
        let limits = SttLimits::from_env(|k| env_get(&self.env, k));
        let now = now_ms();
        let mut machine = self.load().await;
        let outcome = machine.dispatch(limits, now, &method, &path, &body, &uuid_v4());
        self.save_and_schedule(&machine).await?;
        outcome_response(outcome)
    }

    async fn alarm(&self) -> Result<Response> {
        let mut machine = self.load().await;
        machine.alarm(now_ms());
        self.save_and_schedule(&machine).await?;
        Response::empty()
    }
}

#[durable_object]
pub struct RateLimiterDo {
    state: State,
    #[allow(dead_code)]
    env: Env,
}

impl worker::DurableObject for RateLimiterDo {
    fn new(state: State, env: Env) -> Self {
        Self { state, env }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        let path = req.path();
        let method = req.method().to_string();
        let body = read_body(&mut req).await;
        let now = now_ms();
        let mut machine: RateLimiter = self
            .state
            .storage()
            .get(DO_STATE_KEY)
            .await
            .ok()
            .flatten()
            .unwrap_or_default();
        let outcome = machine.dispatch(now, &method, &path, &body);
        self.state.storage().put(DO_STATE_KEY, &machine).await?;
        outcome_response(outcome)
    }
}
