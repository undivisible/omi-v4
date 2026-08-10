//! Small helpers shared by the wasm-only route glue modules.

use serde_json::Value;
use worker::wasm_bindgen::JsValue;
use worker::{D1Result, Date, Env, Headers, Method, Request, RequestInit, Response, Result, Stub};

use crate::crypto_util::to_hex_lower;

pub(crate) fn now_ms() -> i64 {
    Date::now().as_millis() as i64
}

pub(crate) fn now_ms_f64() -> f64 {
    Date::now().as_millis() as f64
}

/// A v4-shaped random UUID (parity with `crypto.randomUUID()`).
pub(crate) fn uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    let _ = getrandom::getrandom(&mut bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let h = to_hex_lower(&bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &h[0..8],
        &h[8..12],
        &h[12..16],
        &h[16..20],
        &h[20..32]
    )
}

/// Number of rows changed by a run/batch statement (D1 `meta.changes`).
pub(crate) fn changes(result: &D1Result) -> usize {
    result
        .meta()
        .ok()
        .flatten()
        .and_then(|m| m.changes)
        .unwrap_or(0)
}

pub(crate) async fn do_post(stub: &Stub, url: &str, payload: &Value) -> Result<Response> {
    let mut init = RequestInit::new();
    init.with_method(Method::Post);
    let headers = Headers::new();
    headers.set("content-type", "application/json")?;
    init.with_headers(headers);
    init.with_body(Some(JsValue::from_str(&payload.to_string())));
    let request = Request::new_with_init(url, &init)?;
    stub.fetch_with_request(request).await
}

pub(crate) fn stt_admission_stub(env: &Env) -> Result<Stub> {
    env.durable_object("STT_ADMISSION")?
        .get_by_name("managed-stt-global")
}

/// Read a value from `[vars]` first, then from secrets (parity with the
/// setup-health `any()` fallback so presence works regardless of binding kind).
pub(crate) fn secret_or_var(env: &Env, name: &str) -> Option<String> {
    env.var(name)
        .ok()
        .map(|v| v.to_string())
        .or_else(|| env.secret(name).ok().map(|v| v.to_string()))
}
