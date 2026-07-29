//! Pure OAuth 2.1 policy for the Omi MCP resource server.
//!
//! HTTP/D1 bindings intentionally live elsewhere. Keeping issuer, resource,
//! redirect, and PKCE decisions here makes the security contract host-testable.

use url::Url;

/// This must never be inferred from `Host`: reverse proxies and hostile
/// requests can control that header. Deployments use the one public API origin.
pub const CANONICAL_ISSUER: &str = "https://api.omi.tsc.hk";
pub const CANONICAL_RESOURCE: &str = "https://api.omi.tsc.hk/mcp";

/// OAuth v1 deliberately excludes FaceTime: it can initiate an external call
/// and therefore needs a separately reviewed grant class.
pub const OAUTH_SCOPES: &[&str] = &[
    "memory:read",
    "currents:read",
    "currents:write",
    "conversations:read",
    "assistant:write",
    "speech:write",
];

pub fn canonical_issuer() -> &'static str {
    CANONICAL_ISSUER
}

pub fn canonical_resource() -> &'static str {
    CANONICAL_RESOURCE
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RedirectError {
    Invalid,
}

/// Validates an OAuth callback at client-registration time. The caller keeps
/// the original string and compares it exactly later; normalization is only a
/// security check, never a way to broaden an approved callback.
pub fn validate_redirect_uri(value: &str) -> Result<String, RedirectError> {
    let url = Url::parse(value).map_err(|_| RedirectError::Invalid)?;
    if url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.host_str().is_none()
    {
        return Err(RedirectError::Invalid);
    }

    match url.scheme() {
        "https" if !url.host_str().is_some_and(|host| host.contains('*')) => Ok(value.to_owned()),
        "http" if matches!(url.host_str(), Some("127.0.0.1" | "::1")) => Ok(value.to_owned()),
        _ => Err(RedirectError::Invalid),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PkceError {
    Method,
    Malformed,
}

/// RFC 7636 validation for public OAuth clients. `plain` is intentionally
/// unsupported: allowing it would turn a leaked authorization code into a
/// bearer credential.
pub fn validate_pkce_s256(challenge: &str, method: &str, verifier: &str) -> Result<(), PkceError> {
    if method != "S256" {
        return Err(PkceError::Method);
    }
    let valid_challenge = (43..=128).contains(&challenge.len())
        && challenge
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_');
    let valid_verifier = (43..=128).contains(&verifier.len())
        && verifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~'));
    if valid_challenge && valid_verifier {
        Ok(())
    } else {
        Err(PkceError::Malformed)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GrantScopeError {
    NotAllowed,
    FreshConfirmationRequired,
    NotAvailable,
}

/// Produces the exact client grant recorded after explicit first-party consent.
/// A grant can only narrow registered capabilities; it cannot be broadened by
/// request parameters or an approval UI default.
pub fn decide_grant_scopes(
    client_allowed: &[&str],
    requested: &[&str],
    fresh_privileged_confirmation: bool,
) -> Result<Vec<String>, GrantScopeError> {
    let mut approved = Vec::new();
    for scope in requested {
        if !crate::api_keys::is_scope(scope) || !client_allowed.contains(scope) {
            return Err(GrantScopeError::NotAllowed);
        }
        // FaceTime can initiate an external call, so it stays outside OAuth v1.
        if *scope == "facetime:write" {
            return Err(GrantScopeError::NotAvailable);
        }
        let privileged = matches!(*scope, "assistant:write" | "speech:write");
        if privileged && !fresh_privileged_confirmation {
            return Err(GrantScopeError::FreshConfirmationRequired);
        }
        if !approved.iter().any(|existing: &String| existing == scope) {
            approved.push((*scope).to_owned());
        }
    }
    Ok(approved)
}

#[cfg(test)]
mod tests {
    use super::{
        canonical_issuer, canonical_resource, decide_grant_scopes, validate_pkce_s256,
        validate_redirect_uri, GrantScopeError, PkceError, RedirectError,
    };

    #[test]
    fn only_allows_exact_https_or_loopback_redirects() {
        assert_eq!(
            validate_redirect_uri("https://client.example/callback"),
            Ok("https://client.example/callback".to_owned())
        );
        assert_eq!(
            validate_redirect_uri("http://127.0.0.1:49152/callback"),
            Ok("http://127.0.0.1:49152/callback".to_owned())
        );
        for invalid in [
            "http://client.example/callback",
            "https://client.example/callback#fragment",
            "https://user:pass@client.example/callback",
            "https://*.example/callback",
            "http://localhost/callback",
        ] {
            assert_eq!(validate_redirect_uri(invalid), Err(RedirectError::Invalid));
        }
    }

    #[test]
    fn consent_cannot_broaden_a_client_and_privileged_scopes_need_fresh_confirmation() {
        assert_eq!(
            decide_grant_scopes(
                &["memory:read", "assistant:write"],
                &["memory:read", "memory:read"],
                false,
            ),
            Ok(vec!["memory:read".to_owned()])
        );
        assert_eq!(
            decide_grant_scopes(&["memory:read"], &["currents:read"], false),
            Err(GrantScopeError::NotAllowed)
        );
        assert_eq!(
            decide_grant_scopes(&["assistant:write"], &["assistant:write"], false),
            Err(GrantScopeError::FreshConfirmationRequired)
        );
        assert_eq!(
            decide_grant_scopes(&["facetime:write"], &["facetime:write"], true),
            Err(GrantScopeError::NotAvailable)
        );
    }

    #[test]
    fn requires_s256_pkce_with_well_formed_values() {
        assert_eq!(
            validate_pkce_s256(
                "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
                "S256",
                "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            ),
            Ok(())
        );
        assert_eq!(
            validate_pkce_s256("challenge", "plain", "verifier"),
            Err(PkceError::Method)
        );
        assert_eq!(
            validate_pkce_s256("too-short", "S256", "short"),
            Err(PkceError::Malformed)
        );
    }

    #[test]
    fn issuer_and_resource_are_canonical_not_request_derived() {
        assert_eq!(canonical_issuer(), "https://api.omi.tsc.hk");
        assert_eq!(canonical_resource(), "https://api.omi.tsc.hk/mcp");
    }
}
