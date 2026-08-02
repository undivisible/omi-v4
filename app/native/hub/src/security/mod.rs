//! The inbound security boundary.
//!
//! [`posture`] holds the strict/auto/dangerous triad and the policy each one
//! resolves to; [`screen`] holds the provenance taxonomy and the classifier
//! that reads untrusted content before the assistant does. The runtime wires
//! the two together in `dispatch_assistant`: it labels the turn's content,
//! screens whatever did not come from the user themselves, composes the
//! verdict onto the configured posture floor, and frames the prompt with the
//! result.
//!
//! Ported from the MIT-licensed `yc-software/qm` security layer.

pub(crate) mod posture;
pub(crate) mod screen;
