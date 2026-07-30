//! OAuth 2.1 protocol rules shared by the Worker handlers.
//!
//! This module intentionally owns no D1 or HTTP state. Keeping registration,
//! PKCE, scopes, and authorization-code validity pure makes the security
//! boundary testable before routes are wired.

pub const AUTHORIZATION_CODE_TTL_MS: i64 = 5 * 60 * 1000;
pub const ACCESS_TOKEN_TTL_MS: i64 = 60 * 60 * 1000;
pub const ISSUER: &str = "https://api.omi.tsc.hk";
pub const MCP_RESOURCE: &str = "https://api.omi.tsc.hk/mcp";

pub const ALLOWED_SCOPES: &[&str] = &[
    "assistant:write",
    "conversations:read",
    "currents:read",
    "currents:write",
    "facetime:write",
    "memory:read",
    "speech:write",
];

pub struct ClientRegistration {
    pub client_id: &'static str,
    pub redirect_uri: &'static str,
}

const CLIENTS: &[ClientRegistration] = &[ClientRegistration {
    // Matches upstream Omi's documented public Claude MCP connector contract.
    client_id: "omi-claude-prod",
    redirect_uri: "https://claude.ai/api/mcp/auth_callback",
}];

fn base64url_value(value: &str, min: usize, max: usize) -> bool {
    let len = value.len();
    (min..=max).contains(&len)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub fn valid_code_challenge(value: &str) -> bool {
    base64url_value(value, 43, 128)
}

/// OAuth 2.1 requires PKCE and this server supports only S256.
pub fn validate_pkce(method: &str, challenge: &str, verifier: &str) -> bool {
    method == "S256"
        && valid_code_challenge(challenge)
        && base64url_value(verifier, 43, 128)
        && crate::crypto_util::sha256_base64url(verifier) == challenge
}

/// Returns a stable least-privilege scope string, or rejects unknown/empty scope.
pub fn normalize_scopes(raw: &str) -> Option<String> {
    let mut scopes: Vec<&str> = raw.split_ascii_whitespace().collect();
    if scopes.is_empty() || scopes.iter().any(|scope| !ALLOWED_SCOPES.contains(scope)) {
        return None;
    }
    scopes.sort_unstable();
    scopes.dedup();
    Some(scopes.join(" "))
}

pub fn registered_client(client_id: &str, redirect_uri: &str) -> bool {
    CLIENTS
        .iter()
        .any(|client| client.client_id == client_id && client.redirect_uri == redirect_uri)
}

/// Store only a deterministic digest of a presented authorization code.
pub fn authorization_code_hash(code: &str) -> String {
    crate::crypto_util::sha256_base64url(code)
}

pub fn access_token_hash(token: &str) -> String {
    crate::crypto_util::sha256_base64url(token)
}

/// OAuth access credentials are the 32-byte base64url values minted by this
/// server. Reject malformed material before it reaches D1.
pub fn valid_bearer_token(token: &str) -> bool {
    base64url_value(token, 43, 43)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_s256_pkce_with_base64url_material() {
        let verifier = "a".repeat(43);
        let challenge = crate::crypto_util::sha256_base64url(&verifier);
        assert!(validate_pkce("S256", &challenge, &verifier));
        assert!(!validate_pkce("plain", &verifier, &verifier));
        assert!(!validate_pkce("S256", "bad+challenge", &verifier));
        assert!(!validate_pkce("S256", &challenge, "too-short"));
    }

    #[test]
    fn scopes_require_canonical_mcp_capability_strings() {
        assert_eq!(
            normalize_scopes("memory:read currents:read memory:read"),
            Some("currents:read memory:read".to_string())
        );
        assert_eq!(
            normalize_scopes(
                "currents:write conversations:read assistant:write speech:write facetime:write"
            ),
            Some(
                "assistant:write conversations:read currents:write facetime:write speech:write"
                    .to_string()
            )
        );
        assert_eq!(normalize_scopes("memory.read"), None);
        assert_eq!(normalize_scopes("currents.read"), None);
        assert_eq!(normalize_scopes("admin"), None);
        assert_eq!(normalize_scopes(""), None);
    }

    #[test]
    fn client_registration_is_exact() {
        assert!(registered_client(
            "omi-claude-prod",
            "https://claude.ai/api/mcp/auth_callback"
        ));
        assert!(!registered_client(
            "omi-claude-prod",
            "http://127.0.0.1:3000/callback"
        ));
        assert!(!registered_client(
            "omi-claude-prod",
            "https://claude.ai/api/mcp/auth_callback/extra"
        ));
        assert!(!registered_client(
            "other",
            "https://claude.ai/api/mcp/auth_callback"
        ));
    }

    #[test]
    fn issuer_and_resource_are_api_only() {
        assert_eq!(ISSUER, "https://api.omi.tsc.hk");
        assert_eq!(MCP_RESOURCE, "https://api.omi.tsc.hk/mcp");
    }

    #[test]
    fn authorization_code_hash_never_equals_presented_code() {
        assert_ne!(authorization_code_hash("opaque-code"), "opaque-code");
        assert_eq!(
            authorization_code_hash("opaque-code"),
            authorization_code_hash("opaque-code")
        );
    }

    #[test]
    fn bearer_tokens_are_fixed_length_base64url_values() {
        assert!(valid_bearer_token(&"a".repeat(43)));
        assert!(!valid_bearer_token("too-short"));
        assert!(!valid_bearer_token(&format!("{}+", "a".repeat(42))));
    }
}
