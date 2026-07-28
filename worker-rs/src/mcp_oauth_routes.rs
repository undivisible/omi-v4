//! Route contracts for OAuth metadata discovery on the MCP resource.
//!
//! Keeping the standardized paths beside the response selection makes the
//! route-level contract host-testable while the Worker adapter stays thin.

use serde_json::Value;

pub const AUTHORIZATION_SERVER_METADATA_PATH: &str = "/.well-known/oauth-authorization-server";
pub const PROTECTED_RESOURCE_METADATA_PATH: &str = "/.well-known/oauth-protected-resource/mcp";

pub fn metadata_for_path(path: &str) -> Option<Value> {
    match path {
        AUTHORIZATION_SERVER_METADATA_PATH => {
            Some(crate::mcp_oauth::authorization_server_metadata())
        }
        PROTECTED_RESOURCE_METADATA_PATH => Some(crate::mcp_oauth::protected_resource_metadata()),
        _ => None,
    }
}
