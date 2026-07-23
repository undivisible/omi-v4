//! omi-v4-api-rs — a parity port of the TypeScript Cloudflare Worker
//! (`worker/`) to Rust via workers-rs.
//!
//! The pure modules (`auth`, `entitlement`, `setup_health`) contain all the
//! decision logic and carry `#[cfg(test)]` suites runnable with `cargo test` on
//! the host. The worker-specific glue (`glue`) is compiled only for
//! `wasm32-unknown-unknown` so the host test build never pulls the `worker`
//! crate.

pub mod auth;
pub mod billing;
pub mod conversations;
pub mod crypto_util;
pub mod desktop_auth;
pub mod delivery;
pub mod entitlement;
pub mod inbox_fallback;
pub mod oauth;
pub mod routes_memory;
pub mod setup_health;
pub mod webhooks;

// AI route group (managed assistant / STT / ASR / voice) pure logic. Host-
// testable; the wasm glue in `routes_ai` binds these to the Worker runtime.
pub mod asr_logic;
pub mod assistant_admission;
pub mod jsnum;
pub mod managed_ai;
pub mod rate_limit;
pub mod stt_admission;
pub mod stt_logic;
pub mod voice_logic;

#[cfg(target_arch = "wasm32")]
pub(crate) mod glue;

// Hand-written Vectorize JS FFI. Compiled only when the `vectorize` feature is
// enabled AND targeting wasm (it binds the JS `VectorizeIndex` object). Off by
// default — see PORT_STATUS.md for the interop outcome.
#[cfg(all(target_arch = "wasm32", feature = "vectorize"))]
mod vectorize_ffi;
#[cfg(target_arch = "wasm32")]
mod rate_limit_lock;
#[cfg(target_arch = "wasm32")]
mod routes_channels;
#[cfg(target_arch = "wasm32")]
mod routes_ai;
