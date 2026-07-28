//! OAuth 2.1 protocol rules shared by the Worker handlers.
//!
//! This module intentionally owns no D1 or HTTP state. Keeping registration,
//! PKCE, scopes, and authorization-code validity pure makes the security
//! boundary testable before routes are wired.

use url::Url;

pub const AUTHORIZATION_CODE_TTL_MS: i64 = 5 * 60 * 1000;

const ALLOWED_SCOPES: &[&str] = &[
    "currents.read",
    "memory.read",
    "memory.write",
    "notes.read",
    "omi.ask",
];

fn base64url_value(value: &str, min: usize, max: usize) -> bool {
    let len = value.len();
    (min..=max).contains(&len)
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

/// OAuth 2.1 requires PKCE and this server supports only S256.
pub fn validate_pkce(method: &str, challenge: &str, verifier: &str) -> bool {
    method == "S256"
        && base64url_value(challenge, 43, 128)
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

/// Parse a candidate redirect URI. The caller must exact-match it against that
/// client's registered URI; this helper merely excludes dangerous shapes.
pub fn valid_redirect_uri(raw: &str) -> bool {
    let Ok(uri) = Url::parse(raw) else {
        return false;
    };
    let Some(host) = uri.host_str() else {
        return false;
    };
    let loopback = matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]");
    (uri.scheme() == "https" || (loopback && uri.scheme() == "http"))
        && uri.username().is_empty()
        && uri.password().is_none()
        && uri.fragment().is_none()
}

/// Store only a deterministic digest of a presented authorization code.
pub fn authorization_code_hash(code: &str) -> String {
    crate::crypto_util::sha256_base64url(code)
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
    fn scopes_are_allowlisted_normalized_and_deduplicated() {
        assert_eq!(
            normalize_scopes("memory.read currents.read memory.read"),
            Some("currents.read memory.read".to_string())
        );
        assert_eq!(
            normalize_scopes("memory.write"),
            Some("memory.write".to_string())
        );
        assert_eq!(normalize_scopes("admin"), None);
        assert_eq!(normalize_scopes(""), None);
    }

    #[test]
    fn redirect_uris_are_https_or_loopback_and_have_no_credential_or_fragment() {
        assert!(valid_redirect_uri("https://claude.ai/oauth/callback"));
        assert!(valid_redirect_uri("http://127.0.0.1:3000/callback"));
        assert!(!valid_redirect_uri("http://example.test/callback"));
        assert!(!valid_redirect_uri(
            "https://user:pass@example.test/callback"
        ));
        assert!(!valid_redirect_uri("https://example.test/callback#steal"));
    }

    #[test]
    fn authorization_code_hash_never_equals_presented_code() {
        assert_ne!(authorization_code_hash("opaque-code"), "opaque-code");
        assert_eq!(
            authorization_code_hash("opaque-code"),
            authorization_code_hash("opaque-code")
        );
    }
}
