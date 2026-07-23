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
pub mod channel_commands;
pub mod channel_link;
pub mod conversations;
pub mod crypto_util;
pub mod currents;
pub mod delivery;
pub mod desktop_auth;
pub mod entitlement;
pub mod inbox_fallback;
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
#[cfg(target_arch = "wasm32")]
pub(crate) mod worker_util;

// The Vectorize JS FFI is the single implementation in
// `routes_memory::wasm_glue` (compiled by default). It binds the JS
// `VectorizeIndex` object via `js_sys` with a graceful runtime fallback when
// `MEMORY_VECTORS`/`AI` are unbound. See PORT_STATUS.md for the interop outcome.
#[cfg(target_arch = "wasm32")]
mod routes_ai;
#[cfg(target_arch = "wasm32")]
mod routes_channels;
