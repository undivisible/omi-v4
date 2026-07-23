//! Pure parity port of `worker/src/api-keys.ts`.
//!
//! Programmatic clients cannot hold a Firebase ID token, so an `omi_sk_` API
//! key is the long-lived, per-uid, revocable alternative. Only the SHA-256
//! digest is ever stored; a database read cannot recover a usable credential.
//!
//! Everything here is decision logic and is host-testable; the D1 lookup and
//! the HTTP routes live in `routes_keys` (wasm only).

use serde_json::Value;

use crate::crypto_util::{base64url, constant_time_eq, sha256_hex, to_hex_lower};
use crate::jsnum::{is_safe_integer, number_from_value};

pub const API_KEY_PREFIX: &str = "omi_sk_";
pub const MAXIMUM_KEYS_PER_UID: i64 = 25;
pub const LAST_USED_RESOLUTION_MS: i64 = 60_000;
/// `consumeRateLimit(env, "api-key-mint:<uid>", 10, 60 * 60_000)`.
pub const MINT_RATE_LIMIT: i64 = 10;
pub const MINT_RATE_WINDOW_MS: i64 = 60 * 60_000;
pub const NAME_MAX_CHARACTERS: usize = 120;

/// `allScopes` — the closed set of scopes a key may carry.
pub const ALL_SCOPES: &[&str] = &[
    "memory:read",
    "currents:read",
    "currents:write",
    "conversations:read",
    "assistant:write",
    "facetime:write",
    "speech:write",
];

/// `scopeSet.has(scope)`.
pub fn is_scope(value: &str) -> bool {
    ALL_SCOPES.contains(&value)
}

/// SHA-256 → lowercase hex, matching the TS `digest`.
pub fn digest(value: &str) -> String {
    sha256_hex(value)
}

/// Constant-time hex-digest comparison (`timingSafeEqual`).
pub fn timing_safe_equal(left: &str, right: &str) -> bool {
    constant_time_eq(left, right)
}

/// `keyPattern = /^omi_sk_([0-9a-f]{8})_([A-Za-z0-9_-]{43})$/` — returns the
/// public prefix capture when the token is well formed.
pub fn parse_key(token: &str) -> Option<&str> {
    let rest = token.strip_prefix(API_KEY_PREFIX)?;
    let (prefix, secret) = rest.split_once('_')?;
    if prefix.len() != 8
        || !prefix
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    {
        return None;
    }
    if secret.len() != 43
        || !secret
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return None;
    }
    Some(prefix)
}

/// `parseScopes` — a JSON-encoded array column, filtered to the known set.
/// Anything unparsable or non-array yields an empty list.
pub fn parse_scopes(value: Option<&Value>) -> Vec<String> {
    let Some(Value::String(raw)) = value else {
        return Vec::new();
    };
    let Ok(Value::Array(items)) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };
    items
        .iter()
        .filter_map(Value::as_str)
        .filter(|scope| is_scope(scope))
        .map(str::to_string)
        .collect()
}

/// A candidate row from the prefix lookup.
pub struct KeyCandidate {
    pub id: String,
    pub uid: String,
    pub key_hash: String,
    pub scopes: Vec<String>,
    pub email: Option<String>,
}

/// Selects the row whose stored digest matches the presented one.
///
/// Every candidate is compared — there is no early exit — so a partial prefix
/// collision cannot be distinguished from a miss by response time. The last
/// match wins, matching the TS loop exactly.
pub fn select_match<'a>(
    presented: &str,
    candidates: &'a [KeyCandidate],
) -> Option<&'a KeyCandidate> {
    let mut matched: Option<&KeyCandidate> = None;
    for row in candidates {
        if timing_safe_equal(presented, &row.key_hash) {
            matched = Some(row);
        }
    }
    matched
}

/// The credential presented on the programmatic surface.
pub enum Credential {
    /// An `omi_sk_` API key: verify against D1.
    ApiKey(String),
    /// Anything else (including nothing): fall through to Firebase `requireAuth`.
    Firebase,
}

/// `requireApiAccess`'s credential selection: `Authorization: Bearer …` first,
/// then `x-api-key`. Only a token starting with the `omi_sk_` prefix takes the
/// API-key path.
pub fn credential(authorization: &str, x_api_key: &str) -> Credential {
    let bearer = authorization
        .strip_prefix("Bearer ")
        .map(str::trim)
        .unwrap_or("");
    let token = if bearer.is_empty() {
        x_api_key.trim()
    } else {
        bearer
    };
    if token.starts_with(API_KEY_PREFIX) {
        Credential::ApiKey(token.to_string())
    } else {
        Credential::Firebase
    }
}

/// A freshly minted key: the plaintext (returned exactly once), the public
/// prefix, and the digest that is all the database ever holds.
pub struct MintedKey {
    pub key: String,
    pub prefix: String,
    pub hash: String,
}

/// `mintApiKey` with the randomness injected so it is testable.
pub fn mint_api_key(prefix_bytes: [u8; 4], secret_bytes: [u8; 32]) -> MintedKey {
    let prefix = to_hex_lower(&prefix_bytes);
    let secret = base64url(&secret_bytes);
    let key = format!("{API_KEY_PREFIX}{prefix}_{secret}");
    let hash = digest(&key);
    MintedKey { key, prefix, hash }
}

/// A validated `POST /v1/api-keys` body.
pub struct MintRequest {
    pub name: String,
    pub scopes: Vec<String>,
    pub expires_at: Option<i64>,
}

/// Validation for `POST /v1/api-keys`. `None` is the TS
/// `{ error: "Invalid API key request" }, 400`.
pub fn validate_mint(body: Option<&Value>, now: i64) -> Option<MintRequest> {
    let name = match body.and_then(|b| b.get("name")) {
        Some(Value::String(raw)) => {
            let trimmed = raw.trim();
            (!trimmed.is_empty() && raw.chars().count() <= NAME_MAX_CHARACTERS)
                .then(|| trimmed.to_string())
        }
        _ => None,
    }?;

    let requested: Vec<String> = match body.and_then(|b| b.get("scopes")) {
        None => ALL_SCOPES.iter().map(|s| s.to_string()).collect(),
        Some(Value::Array(items)) => {
            if items.is_empty() || items.iter().any(|i| !i.as_str().is_some_and(is_scope)) {
                return None;
            }
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        }
        // `scopes: null` (or any non-array) is not an array: rejected.
        Some(_) => return None,
    };

    let expires_at = match body.and_then(|b| b.get("expiresAt")) {
        None | Some(Value::Null) => None,
        Some(value) => {
            let parsed = number_from_value(value);
            if !is_safe_integer(parsed) || parsed <= now as f64 {
                return None;
            }
            Some(parsed as i64)
        }
    };

    // `[...new Set(requested)]` — de-duplicated, insertion order preserved.
    let mut scopes: Vec<String> = Vec::new();
    for scope in requested {
        if !scopes.contains(&scope) {
            scopes.push(scope);
        }
    }
    Some(MintRequest {
        name,
        scopes,
        expires_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn candidate(id: &str, uid: &str, hash: &str) -> KeyCandidate {
        KeyCandidate {
            id: id.into(),
            uid: uid.into(),
            key_hash: hash.into(),
            scopes: vec!["memory:read".into()],
            email: None,
        }
    }

    #[test]
    fn mint_produces_a_pattern_matching_key_and_stores_only_the_digest() {
        let minted = mint_api_key([0xde, 0xad, 0xbe, 0xef], [7u8; 32]);
        assert_eq!(minted.prefix, "deadbeef");
        assert!(minted.key.starts_with("omi_sk_deadbeef_"));
        assert_eq!(parse_key(&minted.key), Some("deadbeef"));
        assert_eq!(minted.hash, digest(&minted.key));
        assert!(!minted.hash.contains(&minted.key));
    }

    #[test]
    fn rejects_malformed_keys() {
        for token in [
            "",
            "omi_sk_",
            "omi_sk_deadbeef",
            "omi_sk_DEADBEEF_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "omi_sk_deadbee_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            // 42 secret characters, one short.
            "omi_sk_deadbeef_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "omi_sk_deadbeef_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa+",
            "sk_deadbeef_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ] {
            assert!(parse_key(token).is_none(), "should reject {token}");
        }
    }

    #[test]
    fn compares_digests_without_early_exit() {
        let real = digest("omi_sk_deadbeef_real");
        let forged = digest("omi_sk_deadbeef_forged");
        let rows = [
            candidate("a", "uid-a", &forged),
            candidate("b", "uid-b", &real),
        ];
        assert_eq!(select_match(&real, &rows).map(|r| r.id.as_str()), Some("b"));
        // A prefix collision with a forged secret matches nothing.
        assert!(select_match(&digest("omi_sk_deadbeef_other"), &rows).is_none());
        assert!(select_match(&real, &[]).is_none());
    }

    #[test]
    fn forged_secret_with_a_real_prefix_is_rejected() {
        let minted = mint_api_key([1, 2, 3, 4], [9u8; 32]);
        let rows = [candidate("k", "uid", &minted.hash)];
        let forged = format!("{}x", &minted.key[..minted.key.len() - 1]);
        assert_eq!(parse_key(&forged), parse_key(&minted.key));
        assert!(select_match(&digest(&forged), &rows).is_none());
        assert!(select_match(&digest(&minted.key), &rows).is_some());
    }

    #[test]
    fn parse_scopes_drops_unknown_and_malformed_values() {
        assert_eq!(
            parse_scopes(Some(&json!(r#"["memory:read","nope","currents:write"]"#))),
            vec!["memory:read".to_string(), "currents:write".to_string()]
        );
        assert!(parse_scopes(Some(&json!("not json"))).is_empty());
        assert!(parse_scopes(Some(&json!(r#"{"a":1}"#))).is_empty());
        assert!(parse_scopes(Some(&Value::Null)).is_empty());
        assert!(parse_scopes(None).is_empty());
    }

    #[test]
    fn credential_prefers_bearer_then_x_api_key() {
        assert!(matches!(
            credential("Bearer omi_sk_abc", ""),
            Credential::ApiKey(token) if token == "omi_sk_abc"
        ));
        assert!(matches!(
            credential("", "  omi_sk_abc  "),
            Credential::ApiKey(token) if token == "omi_sk_abc"
        ));
        assert!(matches!(
            credential("Bearer eyJhbGciOi", ""),
            Credential::Firebase
        ));
        assert!(matches!(credential("", ""), Credential::Firebase));
    }

    #[test]
    fn mint_validation_defaults_to_every_scope() {
        let request = validate_mint(Some(&json!({ "name": "  laptop  " })), 1_000).unwrap();
        assert_eq!(request.name, "laptop");
        assert_eq!(request.scopes.len(), ALL_SCOPES.len());
        assert!(request.expires_at.is_none());
    }

    #[test]
    fn mint_validation_rejects_unknown_scopes_and_empty_lists() {
        for body in [
            json!({ "name": "k", "scopes": [] }),
            json!({ "name": "k", "scopes": ["memory:read", "admin"] }),
            json!({ "name": "k", "scopes": "memory:read" }),
            json!({ "name": "k", "scopes": null }),
            json!({ "name": "   " }),
            json!({ "scopes": ["memory:read"] }),
            json!({ "name": 12 }),
        ] {
            assert!(
                validate_mint(Some(&body), 1_000).is_none(),
                "should reject {body}"
            );
        }
        assert!(validate_mint(None, 1_000).is_none());
    }

    #[test]
    fn mint_validation_rejects_a_past_or_unsafe_expiry() {
        assert!(validate_mint(Some(&json!({ "name": "k", "expiresAt": 999 })), 1_000).is_none());
        assert!(validate_mint(Some(&json!({ "name": "k", "expiresAt": 1_000 })), 1_000).is_none());
        assert!(validate_mint(Some(&json!({ "name": "k", "expiresAt": 1.5 })), 1_000).is_none());
        assert!(validate_mint(Some(&json!({ "name": "k", "expiresAt": "nope" })), 1_000).is_none());
        assert_eq!(
            validate_mint(Some(&json!({ "name": "k", "expiresAt": 2_000 })), 1_000)
                .unwrap()
                .expires_at,
            Some(2_000)
        );
        assert!(
            validate_mint(Some(&json!({ "name": "k", "expiresAt": null })), 1_000)
                .unwrap()
                .expires_at
                .is_none()
        );
    }

    #[test]
    fn mint_validation_deduplicates_scopes() {
        let request = validate_mint(
            Some(&json!({ "name": "k", "scopes": ["memory:read", "memory:read"] })),
            0,
        )
        .unwrap();
        assert_eq!(request.scopes, vec!["memory:read".to_string()]);
    }

    #[test]
    fn candidate_email_is_carried_through() {
        let row = KeyCandidate {
            email: Some("a@b.co".into()),
            ..candidate("i", "u", "h")
        };
        assert_eq!(row.email.as_deref(), Some("a@b.co"));
        assert_eq!(row.scopes, vec!["memory:read".to_string()]);
    }
}
