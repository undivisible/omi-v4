//! Rewind: the screen-history engine.
//!
//! Everything that decides *whether* a moment is worth keeping lives here —
//! the perceptual hash, the per-app heartbeat, the privacy refusals, the
//! retention bounds and the on-disk timeline. The only thing that does not is
//! the capture surface itself: reading the framebuffer and running Apple's
//! Vision text recognition are platform calls, and they stay behind Flutter's
//! `omi/rewind_capture` MethodChannel on the Swift side.
//!
//! That split is why [`engine`] is written as a state machine rather than a
//! loop. The engine cannot reach across the bridge to grab a frame, so instead
//! it answers each thing the Flutter side reports with the one instruction it
//! may carry out next, and the crucial decision — keep this frame or drop it —
//! is taken from 72 bytes of luminance while the full frame is still held,
//! unencoded, in native memory. See [`engine`] for the protocol in full.
//!
//! The whole module is desktop-only and entirely synchronous: no timers, no
//! sockets, no async. The runtime drives it from `spawn_blocking`, which keeps
//! the file writes off the current-thread reactor and keeps every rule in here
//! testable against a clock the test supplies.

pub mod bridge;
pub mod dhash;
pub mod engine;
pub mod models;
pub mod policy;
pub mod privacy;
pub mod settings;
pub mod store;

pub use engine::{Directive, Engine, Request, Response, Status};
pub use models::{Frame, Retention, WindowContext};
pub use privacy::SkipReason;
