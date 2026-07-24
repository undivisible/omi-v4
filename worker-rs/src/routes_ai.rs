//! workers-rs glue for the managed-AI route group (assistant / STT / ASR /
//! voice) and its Durable Objects. All behavioural decisions live in the pure
//! modules (`managed_ai`, `stt_logic`, `asr_logic`, `voice_logic`,
//! `assistant_admission`, `stt_admission`, `rate_limit`); this file is the thin
//! I/O layer that binds them to D1, outbound fetch, and the DO storage runtime.
//!
//! Compiled only for wasm32. A single `register` hook is added to the glue
//! router so the route group can be maintained without touching the rest of
//! `glue.rs`.

use futures_util::StreamExt;
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
use crate::{asr_logic, managed_ai, stt_logic, voice_logic};

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

fn rate_limiter_stub(env: &Env, key: &str) -> Result<Stub> {
    env.durable_object("RATE_LIMITER")?.get_by_name(key)
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
) -> Option<String> {
    let endpoint = env_get(env, "MIMO_CHAT_COMPLETIONS_URL")?;
    let secret = env_get(env, "MIMO_API_KEY")?;
    // Meeting-note-style one-shot completions run on the BALANCED tier, which
    // defaults to MIMO_MODEL when set.
    let model =
        managed_ai::model_for_tier(managed_ai::ModelTier::Balanced, |name| env_get(env, name));
    if messages.is_empty() {
        return None;
    }
    let endpoint_url = managed_ai::validate_pinned_endpoint(
        &endpoint,
        managed_ai::XIAOMI_COMPLETION_ENDPOINT,
        managed_ai::XIAOMI_HOSTNAME,
    )?;
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

    let message_values: Vec<Value> = messages
        .iter()
        .map(|m| json!({ "role": m.role, "content": m.content }))
        .collect();
    let body = json!({
        "model": model,
        "messages": message_values,
        "stream": false,
        "max_tokens": WORKER_COMPLETION_MAX_OUTPUT_TOKENS,
    });

    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    let _ = headers.set("authorization", &format!("Bearer {secret}"));
    let _ = headers.set("content-type", "application/json");
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
        return None;
    }

    let value = upstream.json::<Value>().await.ok();
    let (content, input_tokens, output_tokens) = match value.as_ref() {
        Some(v) => managed_ai::parse_completion(v),
        None => (None, None, None),
    };
    let status = if content.is_none() {
        "failed"
    } else {
        "complete"
    };
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
    content
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
    let (Some(endpoint), Some(secret)) = (endpoint, secret) else {
        return error_json("Managed AI unavailable", 503);
    };
    let Some(endpoint_url) = managed_ai::validate_pinned_endpoint(&endpoint, pinned, hostname)
    else {
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
            return error_json("Managed AI unavailable", 502);
        }
    };
    let upstream_status = upstream.status_code();
    if upstream_status >= 300 {
        finalize_managed_request(&ctx, &request_id, "failed", Some(upstream_status as i64)).await;
        release_assistant(&stub, &request_id).await;
        return error_json("Managed AI unavailable", 502);
    }

    mark_streaming(&ctx, &request_id, upstream_status as i64).await;

    let stream = upstream.stream()?;
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
    let endpoint = env_get(&ctx.env, "MIMO_CHAT_COMPLETIONS_URL");
    let secret = env_get(&ctx.env, "MIMO_API_KEY");
    let (Some(endpoint), Some(secret)) = (endpoint, secret) else {
        return error_json("Managed AI unavailable", 503);
    };
    let Some(endpoint_url) = managed_ai::validate_pinned_endpoint(
        &endpoint,
        managed_ai::XIAOMI_COMPLETION_ENDPOINT,
        managed_ai::XIAOMI_HOSTNAME,
    ) else {
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

    let bytes = req.bytes().await.ok();
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
        "mimo-asr",
        asr_logic::ASR_MODEL,
        request.audio.chars().count() as i64,
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
    let upstream_request = Request::new_with_init(endpoint_url.as_str(), &init)?;
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
    let deepgram = env_get(&ctx.env, "DEEPGRAM_API_KEY");
    let (Some(max_session_seconds), Some(cost_per_minute), true) =
        (max_session_seconds, cost_per_minute, deepgram.is_some())
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
            "INSERT INTO managed_stt_sessions\n             (id, uid, idempotency_key, provider, model, language, encoding, sample_rate,\n              channels, diarize, interim_results, device_id, source_id, status,\n              reserved_seconds, estimated_cost_microusd, created_at, updated_at, admission_token)\n             VALUES (?1, ?2, ?3, 'deepgram', ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,\n              'ready', ?13, ?14, ?15, ?15, ?16)\n             ON CONFLICT(uid, idempotency_key) DO UPDATE SET\n               admission_token = excluded.admission_token,\n               updated_at = excluded.updated_at\n             WHERE managed_stt_sessions.status = 'ready'",
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
    let admission_row = db
        .prepare("SELECT admission_token FROM managed_stt_sessions WHERE id = ?1 AND uid = ?2 AND status = 'ready'")
        .bind(&[session_id.clone().into(), auth.uid.clone().into()]);
    let acquisition_token = match admission_row {
        Ok(statement) => statement
            .first::<Value>(None)
            .await
            .ok()
            .flatten()
            .and_then(|row| {
                row.get("admission_token")
                    .and_then(Value::as_str)
                    .map(str::to_string)
            }),
        Err(_) => return error_json("Managed STT unavailable", 503),
    };
    let Some(acquisition_token) = acquisition_token else {
        return error_json("STT session unavailable", 409);
    };

    let secret = env_get(&ctx.env, "DEEPGRAM_API_KEY");
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

    let row = db
        .prepare(
            "SELECT model, language, encoding, sample_rate, channels, diarize,\n                    interim_results, reserved_seconds\n             FROM managed_stt_sessions WHERE id = ?1 AND uid = ?2",
        )
        .bind(&[session_id.clone().into(), auth.uid.clone().into()]);
    let row = match row {
        Ok(statement) => statement.first::<Value>(None).await.ok().flatten(),
        Err(_) => None,
    };
    let Some(row) = row else {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("STT session unavailable", 409);
    };
    let session_seconds = row
        .get("reserved_seconds")
        .and_then(Value::as_i64)
        .filter(|s| *s > 0 && *s <= max_session_seconds);
    let Some(_session_seconds) = session_seconds else {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("STT session unavailable", 409);
    };

    // Connect to Deepgram, upgrading to a WebSocket.
    let query = stt_logic::deepgram_query(
        row.get("model").and_then(Value::as_str).unwrap_or_default(),
        row.get("language")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        row.get("encoding")
            .and_then(Value::as_str)
            .unwrap_or_default(),
        row.get("sample_rate")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        row.get("channels")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        row.get("diarize")
            .and_then(Value::as_i64)
            .unwrap_or_default()
            == 1,
        row.get("interim_results")
            .and_then(Value::as_i64)
            .unwrap_or_default()
            == 1,
    );
    let mut upstream_url = url::Url::parse("https://api.deepgram.com/v1/listen")
        .map_err(|e| worker::Error::RustError(e.to_string()))?;
    {
        let mut pairs = upstream_url.query_pairs_mut();
        for (key, value) in &query {
            pairs.append_pair(key, value);
        }
    }
    let mut init = RequestInit::new();
    let headers = Headers::new();
    headers.set("Upgrade", "websocket")?;
    headers.set("Authorization", &format!("Token {secret}"))?;
    init.with_headers(headers);
    let upstream_request = Request::new_with_init(upstream_url.as_str(), &init)?;
    let upstream_response = match worker::Fetch::Request(upstream_request).send().await {
        Ok(response) => response,
        Err(_) => {
            fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
            return error_json("Managed STT unavailable", 502);
        }
    };
    let Some(upstream_socket) = upstream_response.websocket() else {
        fail_and_release_stt(&ctx, &stub, &session_id, &auth.uid, &acquisition_token).await;
        return error_json("Managed STT unavailable", 502);
    };

    let pair = WebSocketPair::new()?;
    let server = pair.server;
    let client = pair.client;
    server.accept()?;
    upstream_socket.accept()?;

    // Spawn the bidirectional relay. Terminal settlement (DB status +
    // admission release) mirrors `bridgeSttSockets`; the pure
    // `stt_logic::bridge_outcome` is the reference for the status decision.
    let env = ctx.env.clone();
    let relay_session = session_id.clone();
    let relay_uid = auth.uid.clone();
    let relay_token = acquisition_token.clone();
    wasm_bindgen_futures::spawn_local(async move {
        bridge_sockets(
            env,
            server,
            upstream_socket,
            relay_session,
            relay_uid,
            relay_token,
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
    upstream: worker::WebSocket,
    session_id: String,
    uid: String,
    token: String,
) {
    use stt_logic::{bridge_outcome, BridgeEvent, BridgeStatus};
    use worker::WebsocketEvent;

    let mut server_events = match server.events() {
        Ok(events) => events.fuse(),
        Err(_) => return,
    };
    let mut upstream_events = match upstream.events() {
        Ok(events) => events.fuse(),
        Err(_) => return,
    };

    let close_status = |code: u16| {
        if code == 1000 || code == 1001 {
            BridgeStatus::Complete
        } else {
            BridgeStatus::Failed
        }
    };

    let status = loop {
        futures_util::select! {
            client = server_events.next() => {
                match client {
                    Some(Ok(WebsocketEvent::Message(message))) => {
                        let event = if let Some(text) = message.text() {
                            BridgeEvent::ClientFrame { size: text.len() }
                        } else {
                            BridgeEvent::ClientFrame { size: message.bytes().map(|b| b.len()).unwrap_or(usize::MAX) }
                        };
                        if let Some(outcome) = bridge_outcome(&[event]) {
                            break outcome;
                        }
                        let sent = match message.text() {
                            Some(text) => upstream.send_with_str(&text),
                            None => upstream.send_with_bytes(message.bytes().unwrap_or_default()),
                        };
                        if sent.is_err() {
                            break BridgeStatus::Failed;
                        }
                    }
                    Some(Ok(WebsocketEvent::Close(event))) => break close_status(event.code()),
                    Some(Err(_)) | None => break BridgeStatus::Failed,
                }
            }
            provider = upstream_events.next() => {
                match provider {
                    Some(Ok(WebsocketEvent::Message(message))) => {
                        let sent = match message.text() {
                            Some(text) => server.send_with_str(&text),
                            None => server.send_with_bytes(message.bytes().unwrap_or_default()),
                        };
                        if sent.is_err() {
                            break BridgeStatus::Failed;
                        }
                    }
                    Some(Ok(WebsocketEvent::Close(event))) => break close_status(event.code()),
                    Some(Err(_)) | None => break BridgeStatus::Failed,
                }
            }
        }
    };

    let status_str = match status {
        BridgeStatus::Complete => "complete",
        BridgeStatus::Failed => "failed",
    };
    let _ = server.close(Some(1000), Some("Session closed"));
    let _ = upstream.close(Some(1000), Some("Session closed"));
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
