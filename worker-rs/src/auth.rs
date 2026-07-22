use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use base64::Engine;
use rsa::pkcs1v15::{Signature, VerifyingKey};
use rsa::signature::Verifier;
use rsa::{BigUint, RsaPublicKey};
use serde::Deserialize;
use sha2::Sha256;

// Ported from worker/src/auth.ts. Behaviour parity: RS256-only Firebase ID
// tokens, aud == projectId, iss == https://securetoken.google.com/<projectId>,
// non-empty sub, exp in the future, iat no more than 60s in the future.

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Auth {
    pub uid: String,
    pub email: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct JwtHeader {
    pub alg: Option<String>,
    pub kid: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct FirebaseClaims {
    pub aud: Option<String>,
    pub email: Option<String>,
    pub exp: Option<i64>,
    pub iat: Option<i64>,
    pub iss: Option<String>,
    pub sub: Option<String>,
}

/// A single JWK entry from the Firebase securetoken JWKS endpoint.
#[derive(Debug, Clone, Deserialize)]
pub struct FirebaseJwk {
    pub kid: Option<String>,
    pub n: Option<String>,
    pub e: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct FirebaseJwks {
    pub keys: Vec<FirebaseJwk>,
}

pub struct ParsedToken {
    pub header: JwtHeader,
    pub claims: FirebaseClaims,
    pub signature: Vec<u8>,
    pub signed: Vec<u8>,
}

/// Decode a base64url segment, tolerating missing padding (matches the TS
/// `decode` helper which pads to a multiple of 4).
fn decode_segment(value: &str) -> Option<Vec<u8>> {
    if let Ok(bytes) = URL_SAFE_NO_PAD.decode(value.as_bytes()) {
        return Some(bytes);
    }
    // Fallback for inputs that already carry padding or use the standard
    // alphabet variants.
    let normalized: String = value.replace('-', "+").replace('_', "/");
    let padded_len = normalized.len().div_ceil(4) * 4;
    let padded = format!("{normalized:=<padded_len$}");
    STANDARD.decode(padded.as_bytes()).ok()
}

/// Split and decode a compact JWS into its parts. Returns `None` on any
/// structural failure (parity with the TS `parse` returning null).
pub fn parse_token(token: &str) -> Option<ParsedToken> {
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    let header: JwtHeader = serde_json::from_slice(&decode_segment(parts[0])?).ok()?;
    let claims: FirebaseClaims = serde_json::from_slice(&decode_segment(parts[1])?).ok()?;
    let signature = decode_segment(parts[2])?;
    let signed = format!("{}.{}", parts[0], parts[1]).into_bytes();
    Some(ParsedToken {
        header,
        claims,
        signature,
        signed,
    })
}

/// Validate the header and registered claims against the expected project.
/// `now` is unix seconds. Mirrors the TS comparison chain exactly.
pub fn claims_valid(parsed: &ParsedToken, project_id: &str, now: i64) -> bool {
    if parsed.header.alg.as_deref() != Some("RS256") {
        return false;
    }
    if parsed.header.kid.is_none() {
        return false;
    }
    let expected_issuer = format!("https://securetoken.google.com/{project_id}");
    if parsed.claims.aud.as_deref() != Some(project_id) {
        return false;
    }
    if parsed.claims.iss.as_deref() != Some(expected_issuer.as_str()) {
        return false;
    }
    match &parsed.claims.sub {
        Some(sub) if !sub.is_empty() => {}
        _ => return false,
    }
    match parsed.claims.exp {
        Some(exp) if exp > now => {}
        _ => return false,
    }
    match parsed.claims.iat {
        Some(iat) if iat <= now + 60 => {}
        _ => return false,
    }
    true
}

/// Verify the RS256 signature against a JWK (modulus `n`, exponent `e`, both
/// base64url). Returns false on any decode/parse/verification failure.
pub fn verify_rs256(jwk: &FirebaseJwk, signed: &[u8], signature: &[u8]) -> bool {
    let (Some(n_b64), Some(e_b64)) = (jwk.n.as_deref(), jwk.e.as_deref()) else {
        return false;
    };
    let Some(n_bytes) = decode_segment(n_b64) else {
        return false;
    };
    let Some(e_bytes) = decode_segment(e_b64) else {
        return false;
    };
    let n = BigUint::from_bytes_be(&n_bytes);
    let e = BigUint::from_bytes_be(&e_bytes);
    let Ok(public_key) = RsaPublicKey::new(n, e) else {
        return false;
    };
    let verifying_key: VerifyingKey<Sha256> = VerifyingKey::new(public_key);
    let Ok(sig) = Signature::try_from(signature) else {
        return false;
    };
    verifying_key.verify(signed, &sig).is_ok()
}

/// End-to-end token verification given the already-fetched JWKS. Returns the
/// authenticated identity or `None`. The JWKS fetch/cache lives in the worker
/// glue; this stays pure for `cargo test`.
pub fn verify_firebase_token(
    token: &str,
    project_id: &str,
    now: i64,
    jwks: &[FirebaseJwk],
) -> Option<Auth> {
    let parsed = parse_token(token)?;
    if !claims_valid(&parsed, project_id, now) {
        return None;
    }
    let kid = parsed.header.kid.as_deref()?;
    let jwk = jwks.iter().find(|candidate| candidate.kid.as_deref() == Some(kid))?;
    if !verify_rs256(jwk, &parsed.signed, &parsed.signature) {
        return None;
    }
    let sub = parsed.claims.sub.clone()?;
    Some(Auth {
        uid: sub,
        email: parsed.claims.email.clone(),
    })
}

/// Extract a bearer token from an Authorization header value, matching the TS
/// `authorization.startsWith("Bearer ")` + slice(7).trim() behaviour.
pub fn bearer_token(authorization: &str) -> Option<String> {
    let rest = authorization.strip_prefix("Bearer ")?;
    let trimmed = rest.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Parse the max-age (seconds) out of a Cache-Control header, defaulting to 300
/// as the TS code does.
pub fn cache_max_age(cache_control: &str) -> u64 {
    let needle = "max-age=";
    if let Some(idx) = cache_control.find(needle) {
        let tail = &cache_control[idx + needle.len()..];
        let digits: String = tail.chars().take_while(|c| c.is_ascii_digit()).collect();
        if let Ok(value) = digits.parse::<u64>() {
            return value;
        }
    }
    300
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use rsa::pkcs1v15::SigningKey;
    use rsa::signature::{SignatureEncoding, Signer};
    use rsa::traits::PublicKeyParts;
    use rsa::RsaPrivateKey;

    const PROJECT: &str = "based-hardware";

    fn b64(bytes: &[u8]) -> String {
        URL_SAFE_NO_PAD.encode(bytes)
    }

    fn make_key() -> RsaPrivateKey {
        // 2048-bit key generated per test with the OS RNG (host-only tests).
        let mut rng = rand::thread_rng();
        RsaPrivateKey::new(&mut rng, 2048).expect("keygen")
    }

    fn jwk_from(key: &RsaPrivateKey, kid: &str) -> FirebaseJwk {
        let pk = key.to_public_key();
        FirebaseJwk {
            kid: Some(kid.to_string()),
            n: Some(b64(&pk.n().to_bytes_be())),
            e: Some(b64(&pk.e().to_bytes_be())),
        }
    }

    fn sign_token(key: &RsaPrivateKey, header_json: &str, claims_json: &str) -> String {
        let h = b64(header_json.as_bytes());
        let c = b64(claims_json.as_bytes());
        let signing_input = format!("{h}.{c}");
        let signing_key: SigningKey<Sha256> = SigningKey::new(key.clone());
        let sig = signing_key.sign(signing_input.as_bytes());
        format!("{signing_input}.{}", b64(&sig.to_bytes()))
    }

    #[test]
    fn valid_token_round_trips() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"user-abc","email":"u@x.com","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        let auth = verify_firebase_token(&token, PROJECT, now, &[jwk]).expect("valid");
        assert_eq!(auth.uid, "user-abc");
        assert_eq!(auth.email.as_deref(), Some("u@x.com"));
    }

    #[test]
    fn rejects_wrong_audience() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"other","iss":"https://securetoken.google.com/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_wrong_issuer() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://evil.example/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_expired() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now - 1,
            now - 100
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_future_iat() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now + 3600,
            now + 120
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_empty_sub() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_non_rs256() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"HS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_unknown_kid() {
        let key = make_key();
        let jwk = jwk_from(&key, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"other-kid"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn rejects_tampered_signature() {
        let key = make_key();
        let other = make_key();
        let jwk = jwk_from(&other, "kid-1");
        let now = 1_700_000_000i64;
        let claims = format!(
            r#"{{"aud":"{PROJECT}","iss":"https://securetoken.google.com/{PROJECT}","sub":"u","exp":{},"iat":{}}}"#,
            now + 3600,
            now - 10
        );
        let token = sign_token(&key, r#"{"alg":"RS256","kid":"kid-1"}"#, &claims);
        assert!(verify_firebase_token(&token, PROJECT, now, &[jwk]).is_none());
    }

    #[test]
    fn malformed_tokens_rejected() {
        assert!(parse_token("only.two").is_none());
        assert!(parse_token("a.b.c.d").is_none());
        assert!(parse_token("!!!.???.###").is_none());
    }

    #[test]
    fn bearer_extraction() {
        assert_eq!(bearer_token("Bearer abc").as_deref(), Some("abc"));
        assert_eq!(bearer_token("Bearer   abc  ").as_deref(), Some("abc"));
        assert_eq!(bearer_token("Bearer "), None);
        assert_eq!(bearer_token("Basic abc"), None);
        assert_eq!(bearer_token(""), None);
    }

    #[test]
    fn cache_max_age_parsing() {
        assert_eq!(cache_max_age("public, max-age=19008, must-revalidate"), 19008);
        assert_eq!(cache_max_age("no-cache"), 300);
        assert_eq!(cache_max_age(""), 300);
    }
}
