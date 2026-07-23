//! Small helpers shared by the wasm-only route glue modules.

use worker::{D1Result, Date, Env};

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

/// Read a value from `[vars]` first, then from secrets (parity with the
/// setup-health `any()` fallback so presence works regardless of binding kind).
pub(crate) fn secret_or_var(env: &Env, name: &str) -> Option<String> {
    env.var(name)
        .ok()
        .map(|v| v.to_string())
        .or_else(|| env.secret(name).ok().map(|v| v.to_string()))
}
