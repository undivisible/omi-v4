//! omi-v4-api-rs — a parity port of the TypeScript Cloudflare Worker
//! (`worker/`) to Rust via workers-rs.
//!
//! The pure modules (`auth`, `entitlement`, `setup_health`) contain all the
//! decision logic and carry `#[cfg(test)]` suites runnable with `cargo test` on
//! the host. The worker-specific glue (`glue`) is compiled only for
//! `wasm32-unknown-unknown` so the host test build never pulls the `worker`
//! crate.

pub mod auth;
pub mod delivery;
pub mod entitlement;
pub mod inbox_fallback;
pub mod oauth;
pub mod setup_health;

#[cfg(target_arch = "wasm32")]
mod glue;
#[cfg(target_arch = "wasm32")]
mod rate_limit_lock;
#[cfg(target_arch = "wasm32")]
mod routes_channels;
