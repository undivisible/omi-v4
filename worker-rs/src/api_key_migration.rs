//! User-visible, metadata-only legacy API-key cutover contract.
//!
//! Upstream Omi keys (`omi_mcp_*` and `omi_dev_*`) cannot be copied into v4:
//! their plaintext is unrecoverable and must never be submitted to the new
//! service. A migration instead creates a fresh v4 key and records a receipt
//! that the authenticated account can inspect later.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde_json::{json, Value};
use url::Url;

use crate::api_keys::{is_scope, NAME_MAX_CHARACTERS};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LegacyKeyKind {
    Mcp,
    Dev,
}

impl LegacyKeyKind {
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "mcp" => Some(Self::Mcp),
            "dev" => Some(Self::Dev),
            _ => None,
        }
    }

    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Mcp => "mcp",
            Self::Dev => "dev",
        }
    }

    /// The single upstream path discovery may read for this kind. Returning a
    /// `&'static str` is the point: no caller-reachable value ever contributes
    /// to the path a forwarded bearer is sent to.
    pub fn metadata_path(self) -> &'static str {
        match self {
            Self::Mcp => "/v1/mcp/keys",
            Self::Dev => "/v1/dev/keys",
        }
    }
}

/// The closed set of upstream sources discovery will contact.
pub const LEGACY_KEY_KINDS: [LegacyKeyKind; 2] = [LegacyKeyKind::Mcp, LegacyKeyKind::Dev];

/// Resolve one allowlisted upstream endpoint under the configured Omi base.
///
/// The base must be a bare `https` origin. A base carrying credentials, a path,
/// a query or a fragment is refused outright rather than normalised away: those
/// are exactly the shapes that would send a forwarded bearer somewhere other
/// than [`LegacyKeyKind::metadata_path`].
pub fn legacy_metadata_endpoint(base: &str, kind: LegacyKeyKind) -> Option<String> {
    let parsed = Url::parse(base.trim()).ok()?;
    if parsed.scheme() != "https"
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || parsed.path() != "/"
        || parsed.host_str().is_none_or(str::is_empty)
    {
        return None;
    }
    Some(format!(
        "{}{}",
        parsed.origin().ascii_serialization(),
        kind.metadata_path()
    ))
}

/// The bearer, if any, that may be forwarded to the upstream Omi service.
///
/// Only a Firebase ID token means anything upstream, so only a Firebase-shaped
/// token is returned: an RS256 compact JWS naming the signing key. Everything
/// else — a worker-issued HS256 session, an `omi_sk_` API key, an opaque
/// refresh token, a malformed header — yields `None`, which is the caller's
/// instruction to answer "unavailable" without contacting upstream at all.
///
/// The returned token is for immediate, single-use forwarding. It is never
/// persisted, logged, or placed in a response.
pub fn forwardable_firebase_bearer(authorization: &str) -> Option<String> {
    let token = authorization.strip_prefix("Bearer ")?.trim();
    let mut parts = token.split('.');
    let (Some(header), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return None;
    };
    if payload.is_empty() || signature.is_empty() {
        return None;
    }
    let decoded = URL_SAFE_NO_PAD.decode(header.as_bytes()).ok()?;
    let header: Value = serde_json::from_slice(&decoded).ok()?;
    // `alg` is checked against the one algorithm Firebase signs with rather
    // than merely being read, so an `alg: none` or HS256 token cannot pass.
    if header.get("alg").and_then(Value::as_str) != Some("RS256") {
        return None;
    }
    let kid = header.get("kid").and_then(Value::as_str);
    if kid.is_none_or(str::is_empty) {
        return None;
    }
    Some(token.to_owned())
}

/// The exact, closed field list a discovered legacy key is projected onto.
pub const LEGACY_METADATA_FIELDS: [&str; 7] = [
    "legacyKind",
    "id",
    "name",
    "prefix",
    "scopes",
    "createdAt",
    "lastUsedAt",
];

/// Project an upstream discovery payload onto [`LEGACY_METADATA_FIELDS`].
///
/// This is an allowlist, not a filter: the response is rebuilt field by field,
/// so an upstream payload that grows a secret-bearing member cannot widen what
/// this route exposes. Timestamps are accepted only as numbers, so an upstream
/// string field can never ride out through a date.
pub fn project_legacy_metadata(kind: LegacyKeyKind, upstream: &Value) -> Vec<Value> {
    let direct = upstream.as_array();
    let nested = upstream.get("keys").and_then(Value::as_array);
    let Some(entries) = direct.or(nested) else {
        return Vec::new();
    };
    entries
        .iter()
        .filter_map(|entry| project_legacy_entry(kind, entry))
        .collect()
}

/// What an exposed string becomes once part of it looks like key material.
const REDACTED: &str = "[redacted]";

/// The legacy and v4 credential prefixes, used only to recognise material that
/// must not be echoed back.
const CREDENTIAL_PREFIXES: [&str; 3] = ["omi_mcp_", "omi_dev_", "omi_sk_"];

fn is_base64url_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
}

/// Three non-trivial base64url segments — the shape of any bearer token.
fn is_compact_jws(run: &str) -> bool {
    let mut parts = run.split('.');
    let (Some(header), Some(payload), Some(signature), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return false;
    };
    for segment in [header, payload, signature] {
        if segment.len() < 8 || !segment.bytes().all(is_base64url_byte) {
            return false;
        }
    }
    true
}

/// Whether one unbroken run of token characters looks like raw credential
/// material. The length floors matter: a truncated public display prefix such
/// as `omi_mcp_ab12` carries no secret and stays readable, while a full key,
/// a long hex secret, or a bearer token does not.
fn is_raw_token_like(run: &str) -> bool {
    for prefix in CREDENTIAL_PREFIXES {
        if run.len() >= 16 && run.starts_with(prefix) {
            return true;
        }
    }
    if run.len() >= 32 && run.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return true;
    }
    if is_compact_jws(run) {
        return true;
    }
    run.len() >= 40
        && run.bytes().all(is_base64url_byte)
        && run.bytes().any(|byte| byte.is_ascii_digit())
        && run.bytes().any(|byte| byte.is_ascii_alphabetic())
}

fn is_run_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || matches!(character, '_' | '-' | '.')
}

fn flush_run(out: &mut String, run: &mut String) {
    if run.is_empty() {
        return;
    }
    if is_raw_token_like(run) {
        out.push_str(REDACTED);
    } else {
        out.push_str(run);
    }
    run.clear();
}

/// Replace every raw-token-like run inside a string that is about to be
/// exposed. Redaction is per-run rather than whole-string so a display name
/// that merely *contains* a leaked secret keeps the part that is safe to read.
fn redact_raw_tokens(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut run = String::new();
    for character in value.chars() {
        if is_run_character(character) {
            run.push(character);
            continue;
        }
        flush_run(&mut out, &mut run);
        out.push(character);
    }
    flush_run(&mut out, &mut run);
    out
}

fn project_legacy_entry(kind: LegacyKeyKind, entry: &Value) -> Option<Value> {
    let entry = entry.as_object()?;
    let text = |key: &str| -> Option<String> {
        let value = entry.get(key)?.as_str()?;
        Some(redact_raw_tokens(value))
    };
    let stamp = |key: &str| entry.get(key).and_then(Value::as_i64);
    let mut scopes = Vec::new();
    if let Some(values) = entry.get("scopes").and_then(Value::as_array) {
        for value in values.iter().filter_map(Value::as_str) {
            scopes.push(redact_raw_tokens(value));
        }
    }
    Some(json!({
        "legacyKind": kind.wire_name(),
        "id": text("id"),
        "name": text("name"),
        "prefix": text("prefix"),
        "scopes": scopes,
        "createdAt": stamp("createdAt"),
        "lastUsedAt": stamp("lastUsedAt"),
    }))
}

/// The success envelope: projected metadata and nothing else.
pub fn legacy_metadata_response(entries: Vec<Value>) -> Value {
    json!({ "legacyKeys": entries })
}

/// Status paired with [`legacy_metadata_unavailable`].
pub const LEGACY_METADATA_UNAVAILABLE_STATUS: u16 = 503;

/// The one answer given whenever discovery cannot run: a worker-issued session
/// with no forwardable Firebase bearer, an unconfigured or malformed Omi base,
/// or an upstream that refused. Distinguishing them would tell a caller which
/// credential they hold and whether the account exists upstream, so the body
/// carries a single fixed message and no cause.
pub fn legacy_metadata_unavailable() -> Value {
    json!({ "error": "Legacy metadata unavailable" })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MigrationRequest {
    pub legacy_kind: LegacyKeyKind,
    pub name: String,
    pub scopes: Vec<String>,
}

/// A zero-click reconciliation request. The app sends only `{}`; eligible
/// legacy integration metadata is discovered server-side from an account-owned
/// migration source, never supplied by the caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AutomaticMigrationRequest {
    pub name: String,
    pub scopes: Vec<String>,
}

pub fn migration_defaults() -> AutomaticMigrationRequest {
    AutomaticMigrationRequest {
        name: "Migrated MCP integration".to_owned(),
        scopes: vec!["memory:read".to_owned(), "conversations:read".to_owned()],
    }
}

/// Reject any supplied fields so a caller cannot smuggle a legacy credential,
/// name, or scope through the automatic path.
pub fn automatic_migration_request(
    body: &Value,
) -> Result<AutomaticMigrationRequest, MigrationRequestError> {
    if body
        .as_object()
        .filter(|object| object.is_empty())
        .is_none()
    {
        return Err(MigrationRequestError::Invalid);
    }
    Ok(migration_defaults())
}

/// Safe metadata-only discovery response for the zero-click legacy API-key
/// migration path. It reuses the automatic defaults and the existing receipt id,
/// but never accepts, returns, persists, logs, or derives raw credentials.
pub fn eligible_migration(existing_receipt_id: Option<&str>) -> Value {
    let defaults = migration_defaults();
    json!({
        "legacyKind": LegacyKeyKind::Mcp.wire_name(),
        "name": defaults.name,
        "scopes": defaults.scopes,
        "alreadyMigrated": existing_receipt_id.is_some(),
        "receiptId": existing_receipt_id,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MigrationRequestError {
    Invalid,
}

/// Validates a metadata-only request. Reject unknown members so a caller cannot
/// accidentally send a legacy credential to this endpoint.
pub fn validate_migration_request(
    body: &Value,
    _now: i64,
) -> Result<MigrationRequest, MigrationRequestError> {
    let object = body.as_object().ok_or(MigrationRequestError::Invalid)?;
    if object
        .keys()
        .any(|key| key != "legacyKind" && key != "name" && key != "scopes")
    {
        return Err(MigrationRequestError::Invalid);
    }
    let legacy_kind = object
        .get("legacyKind")
        .and_then(Value::as_str)
        .and_then(LegacyKeyKind::parse)
        .ok_or(MigrationRequestError::Invalid)?;
    let name = object
        .get("name")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|name| !name.is_empty() && name.chars().count() <= NAME_MAX_CHARACTERS)
        .filter(|name| !name.starts_with("omi_mcp_") && !name.starts_with("omi_dev_"))
        .map(str::to_owned)
        .ok_or(MigrationRequestError::Invalid)?;
    let scopes = object
        .get("scopes")
        .and_then(Value::as_array)
        .filter(|scopes| !scopes.is_empty())
        .ok_or(MigrationRequestError::Invalid)?;
    let mut normalized = Vec::new();
    for scope in scopes {
        let Some(scope) = scope.as_str().filter(|scope| is_scope(scope)) else {
            return Err(MigrationRequestError::Invalid);
        };
        if !normalized.iter().any(|held| held == scope) {
            normalized.push(scope.to_owned());
        }
    }
    Ok(MigrationRequest {
        legacy_kind,
        name,
        scopes: normalized,
    })
}

/// Public receipt projection. It deliberately excludes both old and new raw
/// credentials; the key-creation response is the only secret-bearing response.
pub fn migration_receipt(
    id: &str,
    _uid: &str,
    replacement_key_id: &str,
    legacy_kind: LegacyKeyKind,
    completed_at: i64,
) -> Value {
    json!({
        "id": id,
        "legacyKind": legacy_kind.wire_name(),
        "replacementKeyId": replacement_key_id,
        "completedAt": completed_at,
    })
}
