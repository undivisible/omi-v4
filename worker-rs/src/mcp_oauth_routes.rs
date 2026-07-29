//! Route contracts for OAuth metadata discovery on the MCP resource.
//!
//! Keeping the standardized paths beside the response selection makes the
//! route-level contract host-testable while the Worker adapter stays thin.

use serde_json::Value;

pub const AUTHORIZATION_SERVER_METADATA_PATH: &str = "/.well-known/oauth-authorization-server";
pub const PROTECTED_RESOURCE_METADATA_PATH: &str = "/.well-known/oauth-protected-resource/mcp";

pub fn metadata_for_path(path: &str) -> Option<Value> {
    let _ = path;
    // OAuth authorization-code/token/revocation routes are not implemented.
    // Do not advertise an authorization server until its complete flow is live.
    None
}
