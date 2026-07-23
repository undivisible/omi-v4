//! omi-v4-api-rs — a parity port of the TypeScript Cloudflare Worker
//! (`worker/`) to Rust via workers-rs.
//!
//! The pure modules (`auth`, `entitlement`, `setup_health`) contain all the
//! decision logic and carry `#[cfg(test)]` suites runnable with `cargo test` on
//! the host. The worker-specific glue (`glue`) is compiled only for
//! `wasm32-unknown-unknown` so the host test build never pulls the `worker`
//! crate.

pub mod auth;
pub mod entitlement;
pub mod setup_health;

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
mod glue;

#[cfg(target_arch = "wasm32")]
mod routes_ai;
