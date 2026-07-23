//! Pure desktop-auth logic ported from `worker/src/desktop-auth.ts`:
//! session/confirmation validation, public-origin checks, the PKCE-style
//! verifier challenge, and RS256 service-account signing of Firebase custom
//! tokens (RustCrypto `rsa`, PKCS#8). The 3-step SQL handoff (start/complete/
//! exchange) is issued from the wasm glue.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use rsa::pkcs1v15::SigningKey;
use rsa::pkcs8::DecodePrivateKey;
use rsa::signature::{SignatureEncoding, Signer};
use rsa::RsaPrivateKey;
use sha2::Sha256;
use url::Url;

use crate::crypto_util::{base64url, sha256_base64url};

pub const LIFETIME_MS: i64 = 5 * 60 * 1000;

/// `sessionPattern`: `^[A-Za-z0-9_-]{32,128}$`. Used for sessionId, challenge,
/// confirmationChallenge, and verifier.
pub fn valid_session_value(input: &str) -> bool {
    let len = input.len();
    (32..=128).contains(&len)
        && input
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// `confirmationPattern`: `^[0-9]{6}$`.
pub fn valid_confirmation_code(input: &str) -> bool {
    input.len() == 6 && input.bytes().all(|b| b.is_ascii_digit())
}

/// SHA-256 → base64url of a verifier/confirmation code, matching
/// `verifierChallenge`.
pub fn verifier_challenge(verifier: &str) -> String {
    sha256_base64url(verifier)
}

/// Port of `validPublicOrigin`: https (or http on loopback) origin with no
/// credentials, query, fragment, and only an empty/`/` path. Returns the
/// normalized origin URL string on success.
pub fn valid_public_origin(source: &str) -> Option<String> {
    let url = Url::parse(source).ok()?;
    let host = url.host_str().unwrap_or("");
    let loopback = matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]");
    let scheme = url.scheme();
    if (scheme != "https" && !(loopback && scheme == "http"))
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || url.query().is_some()
        || (url.path() != "" && url.path() != "/")
    {
        return None;
    }
    Some(url.to_string())
}

/// Decode a PKCS#8 PEM private key body into DER bytes, matching
/// `privateKeyBytes` (unescape `\n`, strip the armor + whitespace, base64).
pub fn private_key_der(pem: &str) -> Option<Vec<u8>> {
    let normalized = pem.replace("\\n", "\n");
    let stripped: String = normalized
        .replace("-----BEGIN PRIVATE KEY-----", "")
        .replace("-----END PRIVATE KEY-----", "")
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    STANDARD.decode(stripped.as_bytes()).ok()
}

/// Sign a Firebase custom token (RS256) for `uid` with the service account.
/// Parity with `createFirebaseCustomToken`. `now_seconds` is unix seconds.
/// Returns `None` when the key is invalid (TS throws; the glue maps that to a
/// 503).
pub fn create_firebase_custom_token(
    uid: &str,
    service_account_email: &str,
    private_key_pem: &str,
    now_seconds: i64,
) -> Option<String> {
    let der = private_key_der(private_key_pem)?;
    let key = RsaPrivateKey::from_pkcs8_der(&der).ok()?;
    let header = base64url(br#"{"alg":"RS256","typ":"JWT"}"#);
    let payload_json = serde_json::json!({
        "iss": service_account_email,
        "sub": service_account_email,
        "aud": "https://identitytoolkit.googleapis.com/google.identity.identitytoolkit.v1.IdentityToolkit",
        "iat": now_seconds,
        "exp": now_seconds + 3600,
        "uid": uid,
    })
    .to_string();
    let payload = base64url(payload_json.as_bytes());
    let unsigned = format!("{header}.{payload}");
    let signing_key: SigningKey<Sha256> = SigningKey::new(key);
    let signature = signing_key.sign(unsigned.as_bytes());
    Some(format!("{unsigned}.{}", base64url(&signature.to_bytes())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs1v15::VerifyingKey;
    use rsa::pkcs8::EncodePrivateKey;
    use rsa::signature::Verifier;
    use rsa::RsaPrivateKey;

    #[test]
    fn session_value_bounds() {
        assert!(valid_session_value(&"a".repeat(32)));
        assert!(valid_session_value(&"A-b_9".repeat(8)));
        assert!(!valid_session_value(&"a".repeat(31)));
        assert!(!valid_session_value(&"a".repeat(129)));
        assert!(!valid_session_value(&format!("{}!", "a".repeat(40))));
    }

    #[test]
    fn confirmation_code_pattern() {
        assert!(valid_confirmation_code("123456"));
        assert!(!valid_confirmation_code("12345"));
        assert!(!valid_confirmation_code("1234567"));
        assert!(!valid_confirmation_code("12a456"));
    }

    #[test]
    fn public_origin_accepts_https_and_loopback() {
        assert_eq!(
            valid_public_origin("https://app.example.test").as_deref(),
            Some("https://app.example.test/")
        );
        assert!(valid_public_origin("http://localhost:3000").is_some());
        assert!(valid_public_origin("http://127.0.0.1").is_some());
    }

    #[test]
    fn public_origin_rejects_bad_shapes() {
        assert!(valid_public_origin("http://app.example.test").is_none());
        assert!(valid_public_origin("https://user:pass@app.test").is_none());
        assert!(valid_public_origin("https://app.test/path").is_none());
        assert!(valid_public_origin("https://app.test/?q=1").is_none());
        assert!(valid_public_origin("https://app.test/#h").is_none());
        assert!(valid_public_origin("not a url").is_none());
    }

    #[test]
    fn verifier_challenge_matches_crypto_util() {
        // SHA-256("123456") base64url — cross-checked in crypto_util tests.
        assert_eq!(
            verifier_challenge("123456"),
            "jZae727K08KaOmKSgOaGzww_XVqGr_PKEgIMkjrcbJI"
        );
    }

    fn test_key() -> RsaPrivateKey {
        let mut rng = rand::thread_rng();
        RsaPrivateKey::new(&mut rng, 2048).expect("keygen")
    }

    #[test]
    fn custom_token_round_trips_and_verifies() {
        let key = test_key();
        let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).unwrap().to_string();
        let now = 1_700_000_000i64;
        let token = create_firebase_custom_token(
            "user-1",
            "firebase-adminsdk@example.test",
            &pem,
            now,
        )
        .expect("token");
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);

        // Verify the RS256 signature and claims.
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let signed = format!("{}.{}", parts[0], parts[1]);
        let sig_bytes = URL_SAFE_NO_PAD.decode(parts[2]).unwrap();
        let vk: VerifyingKey<Sha256> = VerifyingKey::new(key.to_public_key());
        let sig = rsa::pkcs1v15::Signature::try_from(sig_bytes.as_slice()).unwrap();
        assert!(vk.verify(signed.as_bytes(), &sig).is_ok());

        let payload: serde_json::Value =
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(parts[1]).unwrap()).unwrap();
        assert_eq!(payload["uid"], "user-1");
        assert_eq!(payload["iss"], "firebase-adminsdk@example.test");
        assert_eq!(payload["iat"], now);
        assert_eq!(payload["exp"], now + 3600);
    }

    #[test]
    fn pem_with_escaped_newlines_decodes() {
        let key = test_key();
        let pem = key.to_pkcs8_pem(rsa::pkcs8::LineEnding::LF).unwrap().to_string();
        let escaped = pem.replace('\n', "\\n");
        assert!(create_firebase_custom_token("u", "e", &escaped, 0).is_some());
    }

    #[test]
    fn invalid_key_returns_none() {
        assert!(create_firebase_custom_token("u", "e", "not-a-key", 0).is_none());
    }
}
