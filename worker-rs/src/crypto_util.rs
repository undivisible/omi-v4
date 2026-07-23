//! Pure crypto helpers shared by the Phase-2 modules (webhooks, desktop-auth,
//! conversations). All RustCrypto-based and host-testable; no WebCrypto.
//!
//! Parity targets:
//! - `equal` (constant-time string compare) in webhooks.ts
//! - `hmac` (HMAC-SHA256 → lowercase hex) in webhooks.ts
//! - `digest` (SHA-256 → lowercase hex) in webhooks.ts / conversations.ts
//! - `base64Url` in desktop-auth.ts

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;

type HmacSha256 = Hmac<Sha256>;

/// Lowercase-hex encode a byte slice (matches the TS
/// `byte.toString(16).padStart(2, "0")` join).
pub fn to_hex_lower(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02x}"));
    }
    out
}

/// HMAC-SHA256 of `payload` under `secret`, lowercase hex. Mirrors the TS
/// `hmac` helper (raw key import + SHA-256 + hex).
pub fn hmac_sha256_hex(secret: &str, payload: &str) -> String {
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .expect("HMAC accepts keys of any length");
    mac.update(payload.as_bytes());
    to_hex_lower(&mac.finalize().into_bytes())
}

/// SHA-256 of `value`, lowercase hex. Mirrors the TS `digest` helper.
pub fn sha256_hex(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    to_hex_lower(&hasher.finalize())
}

/// SHA-256 of `value`, base64url (no padding). Mirrors
/// `verifierChallenge` in desktop-auth.ts.
pub fn sha256_base64url(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    URL_SAFE_NO_PAD.encode(hasher.finalize())
}

/// base64url (no padding) of arbitrary bytes. Mirrors `base64Url`.
pub fn base64url(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Constant-time equality of two ASCII strings. Matches the TS `equal`:
/// length mismatch is an immediate (non-constant-time) reject, then a
/// constant-time compare of the equal-length byte sequences.
pub fn constant_time_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.as_bytes().ct_eq(right.as_bytes()).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hmac_matches_known_vector() {
        // RFC 4231-style check: HMAC-SHA256(key="key", "The quick brown fox
        // jumps over the lazy dog") is a well-known vector.
        assert_eq!(
            hmac_sha256_hex("key", "The quick brown fox jumps over the lazy dog"),
            "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8"
        );
    }

    #[test]
    fn hmac_stripe_style_payload() {
        // t.body form used by Stripe/Blooio timestamped signatures.
        let sig = hmac_sha256_hex("whsec_test", "1700000000.{}");
        assert_eq!(sig.len(), 64);
        assert!(sig.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
    }

    #[test]
    fn sha256_hex_known_vector() {
        assert_eq!(
            sha256_hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn sha256_base64url_no_padding() {
        // SHA-256("123456") base64url, matching the desktop-auth confirmation
        // challenge derivation.
        let out = sha256_base64url("123456");
        assert!(!out.contains('='));
        assert!(!out.contains('+'));
        assert!(!out.contains('/'));
        // Cross-checked against Buffer.from(sha256("123456")).toString("base64url").
        assert_eq!(out, "jZae727K08KaOmKSgOaGzww_XVqGr_PKEgIMkjrcbJI");
    }

    #[test]
    fn constant_time_eq_behaviour() {
        assert!(constant_time_eq("secret", "secret"));
        assert!(!constant_time_eq("secret", "secrew"));
        assert!(!constant_time_eq("secret", "secre"));
        assert!(!constant_time_eq("", "x"));
        assert!(constant_time_eq("", ""));
    }

    #[test]
    fn to_hex_lower_pads() {
        assert_eq!(to_hex_lower(&[0x00, 0x0f, 0xff]), "000fff");
    }
}
