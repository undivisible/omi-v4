//! Pure link-code logic ported from `worker/src/channel-link.ts`. The code
//! alphabet, normalization, and HMAC derivation are host-testable; the D1
//! statements (issue/re-issue, resolve, consume) live in the wasm glue.

use crate::crypto_util::{hmac_sha256_hex, sha256_hex};

/// Unambiguous alphabet: no O/0, no I/l/1 (parity with `linkCodeAlphabet`).
pub const LINK_CODE_ALPHABET: &[u8] = b"23456789ABCDEFGHJKMNPQRSTUVWXYZ";
pub const LINK_CODE_LENGTH: usize = 7;
pub const LINK_CODE_TTL_MS: i64 = 15 * 60_000;

/// `normalizeLinkCode`: upper-case, strip whitespace/`._-`, then require the
/// exact length over the unambiguous alphabet. `None` when it does not match.
pub fn normalize_link_code(value: &str) -> Option<String> {
    let normalized: String = value
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '.' && *c != '_' && *c != '-')
        .flat_map(char::to_uppercase)
        .collect();
    if normalized.len() != LINK_CODE_LENGTH {
        return None;
    }
    if normalized.bytes().all(|b| LINK_CODE_ALPHABET.contains(&b)) {
        Some(normalized)
    } else {
        None
    }
}

/// `deriveLinkCode`: HMAC the channel/user/nonce tuple under the channel's
/// webhook secret, then fold each byte pair into the unambiguous alphabet.
pub fn derive_link_code(secret: &str, channel: &str, channel_user_id: &str, nonce: &str) -> String {
    let mac = hmac_sha256_hex(
        secret,
        &format!("channel-link-code {channel} {channel_user_id} {nonce}"),
    );
    let mut code = String::with_capacity(LINK_CODE_LENGTH);
    for index in 0..LINK_CODE_LENGTH {
        let byte = u8::from_str_radix(&mac[index * 2..index * 2 + 2], 16).unwrap_or(0);
        code.push(LINK_CODE_ALPHABET[(byte as usize) % LINK_CODE_ALPHABET.len()] as char);
    }
    code
}

/// SHA-256 hex of the plaintext code — the stored `code_hash`. The plaintext
/// is never persisted.
pub fn code_hash(code: &str) -> String {
    sha256_hex(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_uses_the_unambiguous_alphabet_and_is_stable() {
        let a = derive_link_code("secret", "telegram", "42", "nonce-1");
        let b = derive_link_code("secret", "telegram", "42", "nonce-1");
        assert_eq!(a, b);
        assert_eq!(a.len(), LINK_CODE_LENGTH);
        assert!(a.bytes().all(|c| LINK_CODE_ALPHABET.contains(&c)));
        assert!(!a.contains(['O', '0', 'I', '1', 'L']));
        // A different nonce yields a different code.
        assert_ne!(a, derive_link_code("secret", "telegram", "42", "nonce-2"));
    }

    #[test]
    fn normalize_accepts_case_and_separators() {
        let code = derive_link_code("secret", "telegram", "88", "n");
        let messy = format!("{}-{}", &code[..3], code[3..].to_lowercase());
        assert_eq!(normalize_link_code(&messy).as_deref(), Some(code.as_str()));
        assert_eq!(normalize_link_code("O0I1L__"), None);
        assert_eq!(normalize_link_code("short"), None);
    }

    #[test]
    fn hash_is_not_the_plaintext() {
        let code = derive_link_code("secret", "blooio", "+1555", "n");
        let hash = code_hash(&code);
        assert_ne!(hash, code);
        assert_eq!(hash.len(), 64);
    }
}
