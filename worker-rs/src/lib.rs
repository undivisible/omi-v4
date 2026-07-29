//! omi-v4-api-rs — Rust Cloudflare Worker.
//!
//! `worker/` remains a frozen TypeScript behavioural reference until every
//! retained surface has scenario-level Rust parity. See `PORT_STATUS.md`.

pub mod api_key_migration;
pub mod api_keys;
pub mod auth;
pub mod auth_session_flow;
pub mod billing;
pub mod byok_negotiation;
pub mod byok_pricing;
pub mod channel_auth;
pub mod channel_checkout;
pub mod channel_commands;
pub mod channel_group;
pub mod channel_link;
pub mod channel_signup;
pub mod channel_style;
pub mod conversations;
pub mod crepus_safety;
pub mod cron_cursor;
pub mod crypto_util;
pub mod currents;
pub mod currents_refresh;
pub mod delivery;
pub mod desktop_auth;
pub mod device_sync;
pub mod digests;
pub mod document_search;
pub mod entitlement;
pub mod facetime;
pub mod inbox_fallback;
pub mod mcp;
pub mod mcp_oauth;
pub mod mcp_oauth_routes;
pub mod memory_log;
pub mod observability;
pub mod public_api;
pub mod routes_memory;
pub mod sendblue;
pub mod session_token;
pub mod settings;
pub mod setup_health;
pub mod speech;
pub mod stripe_sync;
pub mod user_profile;
pub mod webhooks;

// AI route group (managed assistant / STT / ASR / voice) pure logic. Host-
// testable; the wasm glue in `routes_ai` binds these to the Worker runtime.
pub mod asr_logic;
pub mod assistant_admission;
pub mod jsnum;
pub mod managed_ai;
pub mod rate_limit;
pub mod rewind_description;
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
#[cfg(target_arch = "wasm32")]
mod routes_device;
#[cfg(target_arch = "wasm32")]
mod routes_documents;
#[cfg(target_arch = "wasm32")]
mod routes_facetime;
#[cfg(target_arch = "wasm32")]
mod routes_keys;
#[cfg(target_arch = "wasm32")]
mod routes_public;
