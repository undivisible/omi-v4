use std::rc::Rc;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use worker::wasm_bindgen;
use worker::wasm_bindgen::{JsCast, JsValue};
use worker::{
    durable_object, ContainerStartupOptions, Env, Fetch, Headers, Method, Request, RequestInit,
    Response, Result, RouteContext, State, Stub,
};

use crate::facetime::{
    self, AgoraCredentials, FaceTimeOutcome, FaceTimeSessionOutcome, FACETIME_ENDPOINT,
    UPSTREAM_TIMEOUT_MS,
};
use crate::public_api::{self as api, OperationResult};
use crate::routes_ai::consume_rate_limit;
use crate::worker_util::{now_ms, secret_or_var, uuid_v4};

const BRIDGE_PORT: u16 = 8080;
const MAXIMUM_START_BODY_BYTES: usize = 16_384;
const DEFAULT_SYSTEM_PROMPT: &str =
    "You are Omi, speaking with the user over a FaceTime Audio call. Keep replies short and conversational. You cannot see anything: this call carries audio only.";

#[wasm_bindgen::prelude::wasm_bindgen]
extern "C" {
    #[wasm_bindgen::prelude::wasm_bindgen(catch, js_namespace = AbortSignal, js_name = timeout)]
    fn timeout_signal(milliseconds: u32) -> std::result::Result<JsValue, JsValue>;
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct BridgeStart {
    session_id: String,
    uid: String,
    acquisition_token: String,
    handle: String,
    agora: AgoraCredentials,
    max_session_seconds: i64,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct StoredSession {
    session_id: String,
    uid: String,
    acquisition_token: String,
    started_at: i64,
    max_session_seconds: i64,
}

fn response(value: Value, status: u16) -> Result<Response> {
    Ok(Response::from_json(&value)?.with_status(status))
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

fn stt_admission_stub(env: &Env) -> Result<Stub> {
    env.durable_object("STT_ADMISSION")?
        .get_by_name("managed-stt-global")
}

fn bridge_stub(env: &Env, session_id: &str) -> Result<Stub> {
    env.durable_object("FACETIME_BRIDGE")?
        .get_by_name(session_id)
}

async fn release_admission(env: &Env, session_id: &str, uid: &str, token: &str) {
    let Ok(stub) = stt_admission_stub(env) else {
        return;
    };
    let _ = do_post(
        &stub,
        "https://stt-admission.internal/release",
        &json!({
            "sessionId": session_id,
            "uid": uid,
            "acquisitionToken": token,
        }),
    )
    .await;
}

async fn start_call(ctx: &RouteContext<()>, handle: &str) -> FaceTimeOutcome {
    let key_id = secret_or_var(&ctx.env, "SENDBLUE_API_KEY_ID")
        .or_else(|| secret_or_var(&ctx.env, "SENDBLUE_API_KEY"))
        .unwrap_or_default()
        .trim()
        .to_string();
    let secret = secret_or_var(&ctx.env, "SENDBLUE_API_KEY_SECRET")
        .or_else(|| secret_or_var(&ctx.env, "SENDBLUE_SECRET_KEY"))
        .unwrap_or_default()
        .trim()
        .to_string();
    let from_number = secret_or_var(&ctx.env, "SENDBLUE_FACETIME_NUMBER").unwrap_or_default();
    if key_id.is_empty() || secret.is_empty() || from_number.trim().is_empty() {
        return FaceTimeOutcome::Unconfigured;
    }
    if !facetime::is_diallable_handle(handle) {
        return FaceTimeOutcome::Rejected { status: 400 };
    }
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    if headers.set("sb-api-key-id", &key_id).is_err()
        || headers.set("sb-api-secret-key", &secret).is_err()
        || headers.set("content-type", "application/json").is_err()
    {
        return FaceTimeOutcome::Failed;
    }
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(
        &facetime::upstream_body(handle, &from_number).to_string(),
    )));
    let Ok(request) = Request::new_with_init(FACETIME_ENDPOINT, &init) else {
        return FaceTimeOutcome::Failed;
    };
    let Ok(signal) = timeout_signal(UPSTREAM_TIMEOUT_MS as u32) else {
        return FaceTimeOutcome::Failed;
    };
    let signal = worker::AbortSignal::from(signal.unchecked_into::<web_sys::AbortSignal>());
    let Ok(mut upstream) = Fetch::Request(request).send_with_signal(&signal).await else {
        return FaceTimeOutcome::Failed;
    };
    let status = upstream.status_code();
    let body = upstream.json::<Value>().await.ok();
    facetime::outcome_for(status, body.as_ref(), handle)
}

async fn start_bridge(env: &Env, start: &BridgeStart) -> bool {
    let Ok(stub) = bridge_stub(env, &start.session_id) else {
        return false;
    };
    do_post(
        &stub,
        "https://facetime-bridge.internal/start",
        &json!({
            "sessionId": start.session_id,
            "uid": start.uid,
            "acquisitionToken": start.acquisition_token,
            "handle": start.handle,
            "agora": start.agora,
            "maxSessionSeconds": start.max_session_seconds,
        }),
    )
    .await
    .map(|response| response.status_code() < 300)
    .unwrap_or(false)
}

async fn stop_bridge(env: &Env, session_id: &str) {
    let Ok(stub) = bridge_stub(env, session_id) else {
        return;
    };
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let Ok(request) = Request::new_with_init("https://facetime-bridge.internal/stop", &init) else {
        return;
    };
    let _ = stub.fetch_with_request(request).await;
}

async fn start_session(
    ctx: &RouteContext<()>,
    uid: &str,
    handle: String,
    session_id: String,
) -> FaceTimeSessionOutcome {
    if !facetime::facetime_provider_configured(|name| secret_or_var(&ctx.env, name)) {
        return FaceTimeSessionOutcome::Unconfigured;
    }
    if !facetime::bridge_configured(|name| secret_or_var(&ctx.env, name))
        || bridge_stub(&ctx.env, &session_id).is_err()
    {
        return FaceTimeSessionOutcome::Unavailable;
    }
    let get = |name| secret_or_var(&ctx.env, name);
    let max_session_seconds =
        facetime::max_session_seconds(get("FACETIME_MAX_SESSION_SECONDS").as_deref());
    let estimated_cost = (max_session_seconds
        * facetime::cost_microusd_per_minute(get("FACETIME_COST_MICROUSD_PER_MINUTE").as_deref())
        + 59)
        / 60;
    let Ok(admission_stub) = stt_admission_stub(&ctx.env) else {
        return FaceTimeSessionOutcome::Failed;
    };
    let Ok(mut admission) = do_post(
        &admission_stub,
        "https://stt-admission.internal/admit",
        &json!({
            "sessionId": session_id,
            "uid": uid,
            "reservedSeconds": max_session_seconds,
            "costBudgetMicrousd": estimated_cost,
        }),
    )
    .await
    else {
        return FaceTimeSessionOutcome::Failed;
    };
    if admission.status_code() >= 300 {
        let retry_after = admission
            .headers()
            .get("retry-after")
            .ok()
            .flatten()
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(60);
        return FaceTimeSessionOutcome::Capacity { retry_after };
    }
    let Ok(admission) = admission.json::<Value>().await else {
        return FaceTimeSessionOutcome::Failed;
    };
    let Some(acquisition_token) = admission
        .get("acquisitionToken")
        .and_then(Value::as_str)
        .filter(|value| value.len() >= 16)
        .map(str::to_string)
    else {
        return FaceTimeSessionOutcome::Failed;
    };
    if admission.get("admitted") != Some(&Value::Bool(true))
        || (admission.get("duplicate") == Some(&Value::Bool(true))
            && admission.get("reacquired") != Some(&Value::Bool(true)))
    {
        return FaceTimeSessionOutcome::Failed;
    }
    let model = get("GEMINI_LIVE_MODEL").unwrap_or_default();
    let now = now_ms();
    let inserted = match ctx.env.d1("DB") {
        Ok(db) => match db
            .prepare(
                "INSERT INTO managed_ai_requests\n                 (id, uid, provider, model, status, input_characters, requested_max_output_tokens,\n                  created_at, updated_at)\n                 VALUES (?1, ?2, 'facetime-gemini-live', ?3, 'started', 0, 0, ?4, ?4)",
            )
            .bind(&[
                session_id.clone().into(),
                uid.into(),
                model.into(),
                (now as f64).into(),
            ])
        {
            Ok(statement) => statement.run().await.is_ok(),
            Err(_) => false,
        },
        Err(_) => false,
    };
    if !inserted {
        release_admission(&ctx.env, &session_id, uid, &acquisition_token).await;
        return FaceTimeSessionOutcome::Failed;
    }
    let call = start_call(ctx, &handle).await;
    let FaceTimeOutcome::Ok { handle, agora } = call else {
        release_admission(&ctx.env, &session_id, uid, &acquisition_token).await;
        return match call {
            FaceTimeOutcome::Unconfigured => FaceTimeSessionOutcome::Unconfigured,
            FaceTimeOutcome::Unavailable => FaceTimeSessionOutcome::Unavailable,
            FaceTimeOutcome::Rejected { status } => FaceTimeSessionOutcome::Rejected { status },
            FaceTimeOutcome::Failed | FaceTimeOutcome::Ok { .. } => FaceTimeSessionOutcome::Failed,
        };
    };
    let start = BridgeStart {
        session_id: session_id.clone(),
        uid: uid.to_string(),
        acquisition_token: acquisition_token.clone(),
        handle: handle.clone(),
        agora,
        max_session_seconds,
    };
    if !start_bridge(&ctx.env, &start).await {
        stop_bridge(&ctx.env, &session_id).await;
        release_admission(&ctx.env, &session_id, uid, &acquisition_token).await;
        return FaceTimeSessionOutcome::Failed;
    }
    FaceTimeSessionOutcome::Ok { handle, session_id }
}

pub(crate) async fn operation(ctx: &RouteContext<()>, uid: &str, input: &Value) -> OperationResult {
    let generated = uuid_v4();
    let input = match api::validate_facetime(input, &generated) {
        Ok(input) => input,
        Err(result) => return result,
    };
    let (allowed, retry_after) = consume_rate_limit(
        &ctx.env,
        &format!("{}:{uid}", api::FACETIME_BUDGET.bucket),
        api::FACETIME_BUDGET.limit,
        api::FACETIME_BUDGET.window_ms,
    )
    .await;
    if !allowed {
        return api::too_many_requests(retry_after);
    }
    let session_id = facetime::session_id(uid, &input.token);
    let app_url = secret_or_var(&ctx.env, "APP_URL");
    api::facetime_session_result(
        start_session(ctx, uid, input.handle, session_id).await,
        app_url.as_deref(),
    )
}

async fn bounded_start(req: &mut Request) -> Option<BridgeStart> {
    let declared = req
        .headers()
        .get("content-length")
        .ok()
        .flatten()
        .and_then(|value| value.parse::<usize>().ok());
    if declared.is_some_and(|value| value > MAXIMUM_START_BODY_BYTES) {
        return None;
    }
    let body = req.text().await.ok()?;
    if body.len() > MAXIMUM_START_BODY_BYTES {
        return None;
    }
    serde_json::from_str(&body).ok()
}

async fn settle(state: &State, env: &Env, status: &str) -> Result<()> {
    let Some(session) = state.storage().get::<StoredSession>("session").await? else {
        return Ok(());
    };
    state.storage().delete("session").await?;
    let _ = state.storage().delete_alarm().await;
    release_admission(
        env,
        &session.session_id,
        &session.uid,
        &session.acquisition_token,
    )
    .await;
    if let Ok(db) = env.d1("DB") {
        if let Ok(statement) = db
            .prepare(
                "UPDATE managed_ai_requests\n                 SET status = ?1, finalization_attempts = finalization_attempts + 1,\n                     finalized_at = COALESCE(finalized_at, ?2), updated_at = ?2\n                 WHERE id = ?3 AND finalized_at IS NULL",
            )
            .bind(&[
                status.into(),
                (now_ms() as f64).into(),
                session.session_id.into(),
            ])
        {
            let _ = statement.run().await;
        }
    }
    Ok(())
}

#[durable_object]
pub struct FaceTimeBridge {
    state: Rc<State>,
    env: Env,
}

impl FaceTimeBridge {
    async fn teardown(&self, completed: bool) -> Result<()> {
        if let Some(container) = self.state.container() {
            if container.running() {
                let _ = container.destroy(None).await;
            }
        }
        settle(
            &self.state,
            &self.env,
            if completed { "complete" } else { "failed" },
        )
        .await
    }

    async fn start(&self, req: &mut Request) -> Result<Response> {
        let Some(container) = self.state.container() else {
            return response(json!({ "error": "Bridge unavailable" }), 503);
        };
        let Some(start) = bounded_start(req).await else {
            return response(json!({ "error": "Invalid request" }), 400);
        };
        if container.running() {
            return response(json!({ "error": "Session in progress" }), 409);
        }
        let get = |name| secret_or_var(&self.env, name);
        let key = get("GEMINI_API_KEY");
        let model = get("GEMINI_LIVE_MODEL");
        let (Some(key), Some(model)) = (key, model) else {
            return response(json!({ "error": "Bridge unavailable" }), 503);
        };
        let max_session_seconds =
            facetime::max_session_seconds(Some(&start.max_session_seconds.to_string()));
        let session = StoredSession {
            session_id: start.session_id.clone(),
            uid: start.uid.clone(),
            acquisition_token: start.acquisition_token.clone(),
            started_at: now_ms(),
            max_session_seconds,
        };
        self.state.storage().put("session", &session).await?;
        let mut options = ContainerStartupOptions::new();
        options.enable_internet(true);
        options.add_env("AGORA_APP_ID", &start.agora.app_id);
        options.add_env("AGORA_CHANNEL_NAME", &start.agora.channel_name);
        options.add_env("AGORA_TOKEN", &start.agora.token);
        options.add_env("AGORA_UID", &start.agora.uid.to_string());
        options.add_env(
            "AGORA_CLOUD_PROXY",
            &get("AGORA_CLOUD_PROXY").unwrap_or_else(|| "tcp".to_string()),
        );
        options.add_env("GEMINI_API_KEY", &key);
        options.add_env("GEMINI_LIVE_MODEL", &model);
        options.add_env(
            "GEMINI_SYSTEM_PROMPT",
            &get("FACETIME_SYSTEM_PROMPT").unwrap_or_else(|| DEFAULT_SYSTEM_PROMPT.to_string()),
        );
        options.add_env("MAX_SESSION_SECONDS", &max_session_seconds.to_string());
        options.add_env("SESSION_ID", &start.session_id);
        if container.start(Some(options)).is_err() {
            let _ = settle(&self.state, &self.env, "failed").await;
            return response(json!({ "error": "Bridge unavailable" }), 503);
        }
        self.state
            .storage()
            .set_alarm(session.started_at + (max_session_seconds + 15) * 1_000)
            .await?;
        let Some(monitor) = self.state.container() else {
            self.teardown(false).await?;
            return response(json!({ "error": "Bridge unavailable" }), 503);
        };
        let state = Rc::clone(&self.state);
        let env = self.env.clone();
        self.state.wait_until(async move {
            let status = if monitor.wait_for_exit().await.is_ok() {
                "complete"
            } else {
                "failed"
            };
            let _ = settle(&state, &env, status).await;
        });
        let mut init = RequestInit::new();
        init.with_method(Method::Post);
        let headers = Headers::new();
        headers.set("content-type", "application/json")?;
        init.with_headers(headers);
        init.with_body(Some(JsValue::from_str(
            &json!({ "handle": start.handle }).to_string(),
        )));
        let request = Request::new_with_init("http://bridge.internal/start", &init)?;
        let started = container
            .get_tcp_port(BRIDGE_PORT)?
            .fetch_request(request)
            .await
            .map(|response| response.status().is_success())
            .unwrap_or(false);
        if !started {
            self.teardown(false).await?;
            return response(json!({ "error": "Bridge unavailable" }), 503);
        }
        response(json!({ "started": true }), 200)
    }
}

impl worker::DurableObject for FaceTimeBridge {
    fn new(state: State, env: Env) -> Self {
        Self {
            state: Rc::new(state),
            env,
        }
    }

    async fn fetch(&self, mut req: Request) -> Result<Response> {
        if req.method() != Method::Post {
            return Response::empty().map(|response| response.with_status(405));
        }
        match req.path().as_str() {
            "/start" => self.start(&mut req).await,
            "/stop" => {
                self.teardown(true).await?;
                response(json!({ "stopped": true }), 200)
            }
            _ => Response::empty().map(|response| response.with_status(404)),
        }
    }

    async fn alarm(&self) -> Result<Response> {
        self.teardown(false).await?;
        Response::empty()
    }
}
