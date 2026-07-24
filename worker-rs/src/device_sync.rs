//! Pure parity port of `worker/src/device-sync.ts`.
//!
//! Pendant home-STA self-sync: phone registers a device (Firebase) and receives
//! a long-lived `omi_dev_` token; the pendant uploads audio metadata with that
//! bearer. Audio bytes are not persisted yet (`persisted: false` stub).

use serde_json::Value;

use crate::api_keys::{digest, timing_safe_equal};
use crate::crypto_util::{base64url, to_hex_lower};
use crate::jsnum::{is_safe_integer, number_from_value};

pub use crate::api_keys::digest as digest_token;

pub const DEVICE_TOKEN_PREFIX: &str = "omi_dev_";
pub const MAXIMUM_UPLOADS_PER_MINUTE: i64 = 30;
pub const MAXIMUM_UPLOAD_BYTES: i64 = 4 * 1024 * 1024;
pub const MAXIMUM_PACKET_COUNT: i64 = 100_000;
pub const MAXIMUM_REGISTERS_PER_HOUR: i64 = 10;
pub const REGISTER_RATE_WINDOW_MS: i64 = 60 * 60_000;
pub const DEVICE_UID_MAX_CHARS: usize = 128;

/// A freshly minted device token: plaintext (returned once), public prefix, digest.
pub struct MintedDeviceToken {
    pub token: String,
    pub prefix: String,
    pub hash: String,
}

/// `mintDeviceToken` with randomness injected so host tests stay deterministic.
pub fn mint_device_token(prefix_bytes: [u8; 4], secret_bytes: [u8; 32]) -> MintedDeviceToken {
    let prefix = to_hex_lower(&prefix_bytes);
    let secret = base64url(&secret_bytes);
    let token = format!("{DEVICE_TOKEN_PREFIX}{prefix}_{secret}");
    let hash = digest(&token);
    MintedDeviceToken {
        token,
        prefix,
        hash,
    }
}

/// `tokenPattern = /^omi_dev_([0-9a-f]{8})_([A-Za-z0-9_-]{43})$/` — returns the
/// public prefix capture when the token is well formed.
pub fn parse_device_token(token: &str) -> Option<&str> {
    let rest = token.strip_prefix(DEVICE_TOKEN_PREFIX)?;
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

/// Candidate row from the device-token prefix lookup.
pub struct DeviceTokenCandidate {
    pub id: String,
    pub device_id: String,
    pub uid: String,
    pub token_hash: String,
}

/// Selects the row whose stored digest matches the presented one.
/// Every candidate is compared (no early exit), matching the TS loop.
pub fn select_device_match<'a>(
    presented: &str,
    candidates: &'a [DeviceTokenCandidate],
) -> Option<&'a DeviceTokenCandidate> {
    let mut matched: Option<&DeviceTokenCandidate> = None;
    for row in candidates {
        if timing_safe_equal(presented, &row.token_hash) {
            matched = Some(row);
        }
    }
    matched
}

/// Validated `POST /api/v1/devices/register` body.
#[derive(Debug)]
pub struct RegisterRequest {
    pub device_uid: String,
    pub name: Option<String>,
}

/// Validation for register. `None` → `{ error: "Invalid …" }, 400`.
pub fn validate_register(body: Option<&Value>) -> Result<RegisterRequest, &'static str> {
    let Some(body) = body.filter(|value| value.is_object()) else {
        return Err("Invalid register body");
    };
    let device_uid = match body.get("deviceUid") {
        Some(Value::String(raw)) => {
            let trimmed = raw.trim();
            if trimmed.is_empty() || trimmed.len() > DEVICE_UID_MAX_CHARS {
                return Err("Invalid deviceUid");
            }
            trimmed.to_string()
        }
        _ => return Err("Invalid deviceUid"),
    };
    let name = match body.get("name") {
        Some(Value::String(raw)) => {
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        }
        _ => None,
    };
    Ok(RegisterRequest { device_uid, name })
}

/// Validated audio upload fields (metadata stub; bytes not persisted).
#[derive(Debug)]
pub struct UploadRequest {
    /// Decimal string — ring counters may exceed JS safe-integer range.
    pub start_seq: String,
    pub packet_count: i64,
    pub byte_count: i64,
}

/// Approximate decoded byte length from base64 text (`Math.floor(len * 3 / 4)`).
pub fn base64_byte_count(audio: &str) -> i64 {
    ((audio.len() as i64) * 3) / 4
}

/// `parseStartSeq` — number or decimal string (u64-safe); never negative.
pub fn parse_start_seq(value: Option<&Value>) -> Option<String> {
    match value {
        Some(Value::Number(n)) => {
            let parsed = n.as_f64().unwrap_or(f64::NAN);
            if is_safe_integer(parsed) && parsed >= 0.0 {
                Some((parsed as i64).to_string())
            } else {
                None
            }
        }
        Some(Value::String(raw)) if !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit()) => {
            Some(raw.clone())
        }
        _ => None,
    }
}

/// Validation for `POST /api/v1/devices/:id/audio`. Error message is TS-shaped.
pub fn validate_upload(body: Option<&Value>) -> Result<UploadRequest, &'static str> {
    let Some(body) = body.filter(|value| value.is_object()) else {
        return Err("Invalid upload body");
    };
    let Some(start_seq) = parse_start_seq(body.get("startSeq")) else {
        return Err("Invalid upload fields");
    };
    let packet_count = body
        .get("packetCount")
        .map(number_from_value)
        .unwrap_or(f64::NAN);
    let audio = match body.get("audio") {
        Some(Value::String(s)) if !s.is_empty() => s.clone(),
        _ => match body.get("audioBase64") {
            Some(Value::String(s)) if !s.is_empty() => s.clone(),
            _ => String::new(),
        },
    };
    if !is_safe_integer(packet_count)
        || packet_count < 0.0
        || packet_count > MAXIMUM_PACKET_COUNT as f64
        || audio.is_empty()
    {
        return Err("Invalid upload fields");
    }
    let byte_count = base64_byte_count(&audio);
    if byte_count > MAXIMUM_UPLOAD_BYTES {
        return Err("Audio too large");
    }
    Ok(UploadRequest {
        start_seq,
        packet_count: packet_count as i64,
        byte_count,
    })
}

/// Parsed home-STA binary upload preamble (`0xc1` / version 1).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HomeUploadPreamble {
    pub device_id: String,
    /// Decimal string of the big-endian u64 counter (TS `.toString()` parity).
    pub start_seq: String,
    pub packet_count: u32,
    pub packet_bytes: u16,
    pub header_len: usize,
}

/// `parseHomeUploadPreamble` — firmware WiFi sync framing helper.
pub fn parse_home_upload_preamble(bytes: &[u8]) -> Option<HomeUploadPreamble> {
    if bytes.len() < 16 {
        return None;
    }
    if bytes[0] != 0xc1 || bytes[1] != 1 {
        return None;
    }
    let device_len = bytes[2] as usize;
    if device_len == 0 || 3 + device_len + 14 > bytes.len() {
        return None;
    }
    let device_id = std::str::from_utf8(&bytes[3..3 + device_len])
        .ok()?
        .to_string();
    let base = 3 + device_len;
    let start_seq = u64::from_be_bytes(bytes[base..base + 8].try_into().ok()?).to_string();
    let packet_count = u32::from_be_bytes(bytes[base + 8..base + 12].try_into().ok()?);
    let packet_bytes = u16::from_be_bytes(bytes[base + 12..base + 14].try_into().ok()?);
    Some(HomeUploadPreamble {
        device_id,
        start_seq,
        packet_count,
        packet_bytes,
        header_len: base + 14,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn mints_omi_dev_tokens() {
        let minted = mint_device_token([0xab, 0xcd, 0xef, 0x01], [7u8; 32]);
        assert!(minted.token.starts_with(DEVICE_TOKEN_PREFIX));
        assert_eq!(minted.prefix.len(), 8);
        assert_eq!(minted.hash.len(), 64);
        assert_eq!(parse_device_token(&minted.token), Some(minted.prefix.as_str()));
        assert_eq!(digest(&minted.token), minted.hash);
    }

    #[test]
    fn rejects_malformed_tokens() {
        assert!(parse_device_token(
            "omi_sk_abcd1234_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        )
        .is_none());
        assert!(parse_device_token(
            "omi_dev_ABCD1234_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        )
        .is_none());
        assert!(parse_device_token(
            "omi_dev_abcd123_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        )
        .is_none());
    }

    #[test]
    fn select_match_is_last_hit() {
        let presented = "deadbeef";
        let candidates = [
            DeviceTokenCandidate {
                id: "a".into(),
                device_id: "d1".into(),
                uid: "u1".into(),
                token_hash: "cafebabe".into(),
            },
            DeviceTokenCandidate {
                id: "b".into(),
                device_id: "d2".into(),
                uid: "u2".into(),
                token_hash: presented.into(),
            },
            DeviceTokenCandidate {
                id: "c".into(),
                device_id: "d3".into(),
                uid: "u3".into(),
                token_hash: presented.into(),
            },
        ];
        let matched = select_device_match(presented, &candidates).unwrap();
        assert_eq!(matched.id, "c");
    }

    #[test]
    fn validate_register_shapes() {
        assert!(validate_register(None).is_err());
        assert!(validate_register(Some(&json!([]))).is_err());
        assert_eq!(
            validate_register(Some(&json!({ "deviceUid": "" }))).unwrap_err(),
            "Invalid deviceUid"
        );
        let ok = validate_register(Some(&json!({
            "deviceUid": "  pendant-1  ",
            "name": "  Kitchen  "
        })))
        .unwrap();
        assert_eq!(ok.device_uid, "pendant-1");
        assert_eq!(ok.name.as_deref(), Some("Kitchen"));
    }

    #[test]
    fn validate_upload_fields_and_size() {
        assert_eq!(
            validate_upload(Some(&json!({}))).unwrap_err(),
            "Invalid upload fields"
        );
        assert_eq!(parse_start_seq(Some(&json!(42))).as_deref(), Some("42"));
        assert_eq!(
            parse_start_seq(Some(&json!("18446744073709551615"))).as_deref(),
            Some("18446744073709551615")
        );
        assert!(parse_start_seq(Some(&json!(-1))).is_none());

        let ok = validate_upload(Some(&json!({
            "startSeq": 1,
            "packetCount": 2,
            "audio": "AAAA"
        })))
        .unwrap();
        assert_eq!(ok.start_seq, "1");
        assert_eq!(ok.packet_count, 2);
        assert_eq!(ok.byte_count, 3);

        let huge = "A".repeat(((MAXIMUM_UPLOAD_BYTES as usize) * 4 / 3) + 8);
        assert_eq!(
            validate_upload(Some(&json!({
                "startSeq": 0,
                "packetCount": 1,
                "audioBase64": huge
            })))
            .unwrap_err(),
            "Audio too large"
        );
    }

    #[test]
    fn parses_home_upload_preamble() {
        let device_id = b"dev-1";
        let mut buf = vec![0u8; 3 + device_id.len() + 14];
        buf[0] = 0xc1;
        buf[1] = 1;
        buf[2] = device_id.len() as u8;
        buf[3..3 + device_id.len()].copy_from_slice(device_id);
        let base = 3 + device_id.len();
        buf[base..base + 8].copy_from_slice(&42u64.to_be_bytes());
        buf[base + 8..base + 12].copy_from_slice(&7u32.to_be_bytes());
        buf[base + 12..base + 14].copy_from_slice(&444u16.to_be_bytes());
        let parsed = parse_home_upload_preamble(&buf).unwrap();
        assert_eq!(parsed.device_id, "dev-1");
        assert_eq!(parsed.start_seq, "42");
        assert_eq!(parsed.packet_count, 7);
        assert_eq!(parsed.packet_bytes, 444);
        assert_eq!(parsed.header_len, base + 14);
    }
}
