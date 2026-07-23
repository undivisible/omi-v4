//! Memory & Currents group — parity port of `worker/src/memory-sync.ts`,
//! `memory-vectors.ts`, `embeddings.ts`, `currents.ts`, and the memory routes
//! in `worker/src/routes.ts`.
//!
//! The module follows the crate's pure/glue split: all decision logic lives in
//! pure functions carrying `#[cfg(test)]` suites runnable on the host with
//! `cargo test`. The workers-rs I/O layer (route handlers, D1, Vectorize FFI,
//! Workers AI) is gated behind `#[cfg(target_arch = "wasm32")]` and wired into
//! the router through the single [`register`] hook plus the [`cron_slice`]
//! scheduled hook.

use serde_json::{json, Map, Value};

// ---------------------------------------------------------------------------
// Shared constants
// ---------------------------------------------------------------------------

/// zkr record kinds accepted by memory-sync (`recordKinds` in memory-sync.ts).
pub const RECORD_KINDS: &[&str] = &[
    "source",
    "evidence",
    "claim",
    "claim_evidence",
    "correction",
    "deletion",
    "profile",
    "daily_review",
];

/// `sourceKinds` allow-list from routes.ts POST /memories.
pub const SOURCE_KINDS: &[&str] = &[
    "conversation",
    "screen",
    "audio",
    "document",
    "integration",
    "user_correction",
];

/// Workers AI embedding model (embeddings.ts).
pub const EMBEDDING_MODEL: &str = "@cf/baai/bge-base-en-v1.5";
pub const EMBEDDING_DIMENSIONS: usize = 768;
pub const EMBEDDING_INPUT_CHARS: usize = 2_000;

// memory-vectors.ts tuning constants.
pub const MAXIMUM_ATTEMPTS: i64 = 8;
pub const DRAIN_BATCH_SIZE: i64 = 32;
pub const BACKFILL_BATCH_SIZE: i64 = 100;
pub const DELETE_CHUNK_SIZE: usize = 100;
pub const SNIPPET_CHARACTERS: usize = 300;
pub const CONTEXT_CHARACTER_CAP: usize = 2_000;

// currents.ts constants.
pub const APPROVAL_LIFETIME_MS: i64 = 5 * 60 * 1000;
pub const RECEIPT_LIFETIME_MS: i64 = 60 * 1000;
pub const RECEIPT_VERSION: &str = "omi-current-authority-v1";

// ---------------------------------------------------------------------------
// Generic JSON helpers (shared shapes with the TS `object`/`text`/`integer`)
// ---------------------------------------------------------------------------

/// `object(value)` — a JSON object that is neither null nor an array.
fn as_object(value: &Value) -> Option<&Map<String, Value>> {
    value.as_object()
}

/// memory-sync `text(value, limit)`: a non-empty string no longer than `limit`
/// (length compared as Unicode scalar values — an approximation of JS UTF-16
/// `.length`, exact for the BMP text these payloads carry).
fn ms_text(value: Option<&Value>, limit: usize) -> Option<String> {
    let s = value?.as_str()?;
    let len = s.chars().count();
    (len > 0 && len <= limit).then(|| s.to_string())
}

/// memory-sync `integer(value, minimum)`: `Number.isSafeInteger` and `>= min`.
fn safe_int(value: Option<&Value>, minimum: i64) -> Option<i64> {
    let value = value?;
    let n = if let Some(i) = value.as_i64() {
        i as f64
    } else if let Some(u) = value.as_u64() {
        u as f64
    } else {
        value.as_f64()?
    };
    if n.fract() != 0.0 || n.abs() > 9_007_199_254_740_991.0 || n < minimum as f64 {
        return None;
    }
    Some(n as i64)
}

/// Deterministic, key-sorted JSON serialization (`canonicalJson` in the TS).
pub fn canonical_json(value: &Value) -> String {
    match value {
        Value::Array(items) => {
            let inner: Vec<String> = items.iter().map(canonical_json).collect();
            format!("[{}]", inner.join(","))
        }
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let inner: Vec<String> = keys
                .iter()
                .map(|k| {
                    format!(
                        "{}:{}",
                        serde_json::to_string(k).unwrap_or_default(),
                        canonical_json(&map[*k])
                    )
                })
                .collect();
            format!("{{{}}}", inner.join(","))
        }
        other => serde_json::to_string(other).unwrap_or_else(|_| "null".into()),
    }
}

fn canonical_json_pair(a: &str, b: &str) -> String {
    canonical_json(&Value::Array(vec![
        Value::String(a.to_string()),
        Value::String(b.to_string()),
    ]))
}

// ---------------------------------------------------------------------------
// memory-vectors: claim-id projection + text
// ---------------------------------------------------------------------------

/// Uppercase hex of the UTF-8 bytes of `value` (`hex` in memory-vectors.ts).
pub fn hex_upper(value: &str) -> String {
    let mut out = String::with_capacity(value.len() * 2);
    for byte in value.as_bytes() {
        out.push_str(&format!("{byte:02X}"));
    }
    out
}

/// `projectedClaimId(uid, replicaId, recordId)`.
pub fn projected_claim_id(uid: &str, replica_id: &str, record_id: &str) -> String {
    format!(
        "zkr:{}:{}:claim:{}",
        hex_upper(uid),
        hex_upper(replica_id),
        hex_upper(record_id)
    )
}

/// `claimText(claim)` — subject/predicate (non-empty) then content, ` | `-joined.
pub fn claim_text(subject: Option<&str>, predicate: Option<&str>, content: &str) -> String {
    let mut parts: Vec<String> = [subject, predicate]
        .into_iter()
        .flatten()
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect();
    parts.push(content.to_string());
    parts.join(" | ")
}

/// Truncate every input to `EMBEDDING_INPUT_CHARS` (embeddings.ts slice).
pub fn embedding_inputs(texts: &[String]) -> Vec<String> {
    texts
        .iter()
        .map(|t| t.chars().take(EMBEDDING_INPUT_CHARS).collect())
        .collect()
}

/// Validate a Workers AI embedding response `data` against the request size.
/// Mirrors `embedTexts` — `null` unless it is an array of the expected length
/// whose entries are all non-empty numeric vectors.
pub fn parse_embeddings(data: &Value, expected: usize) -> Option<Vec<Vec<f64>>> {
    let arr = data.as_array()?;
    if arr.len() != expected {
        return None;
    }
    let mut out = Vec::with_capacity(arr.len());
    for entry in arr {
        let inner = entry.as_array()?;
        if inner.is_empty() {
            return None;
        }
        let mut row = Vec::with_capacity(inner.len());
        for n in inner {
            row.push(n.as_f64()?);
        }
        out.push(row);
    }
    Some(out)
}

/// A `pending_embeddings` row (uid + projected claim id).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PendingRow {
    pub uid: String,
    pub claim_id: String,
}

/// A `memory_claims` lookup row used during a drain.
#[derive(Clone, Debug, PartialEq)]
pub struct ClaimRow {
    pub id: String,
    pub uid: String,
    pub content: String,
    pub subject: Option<String>,
    pub predicate: Option<String>,
    pub recorded_at: i64,
    pub eligible: i64,
}

/// Split pending rows into vector upserts (eligible claims still present) and
/// deletions (missing or ineligible claims), matching `drainPendingEmbeddings`.
pub fn partition_drain(
    rows: &[PendingRow],
    lookups: &[Option<ClaimRow>],
) -> (Vec<ClaimRow>, Vec<PendingRow>) {
    let mut upserts = Vec::new();
    let mut deletions = Vec::new();
    for (index, row) in rows.iter().enumerate() {
        match lookups.get(index).and_then(|c| c.as_ref()) {
            Some(claim) if claim.eligible == 1 => upserts.push(claim.clone()),
            _ => deletions.push(row.clone()),
        }
    }
    (upserts, deletions)
}

/// Build the `Relevant synced memory` context string (`memoryContextFor`).
pub fn build_memory_context(contents: &[String], cap: usize) -> Option<String> {
    if contents.is_empty() {
        return None;
    }
    let mut output = String::from("Relevant synced memory (server-retrieved, may be partial):");
    for item in contents {
        let snippet: String = item.chars().take(SNIPPET_CHARACTERS).collect();
        let line = format!("\n- {snippet}");
        if output.chars().count() + line.chars().count() > cap {
            break;
        }
        output.push_str(&line);
    }
    Some(output)
}

// ---------------------------------------------------------------------------
// memory-sync: commit parsing / scope checks / record identity
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
pub struct SyncRecord {
    pub kind: String,
    pub record: Value,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SyncCommit {
    pub sequence: i64,
    pub recorded_at: i64,
    pub event_count: i64,
    pub first_event_index: i64,
    pub records: Vec<SyncRecord>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct RecordIdentity {
    pub kind: String,
    pub id: String,
    pub deleted_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeletionTarget {
    pub kind: String,
    pub id: String,
    pub deleted_at: i64,
}

/// `scopedRecord(value, uid)` — envelope with a scoped `record`; the tenant and
/// person ids must both equal `uid`.
pub fn scoped_record(value: &Value, uid: &str) -> Option<SyncRecord> {
    let envelope = as_object(value)?;
    let record = envelope.get("record").and_then(as_object)?;
    let kind = envelope.get("kind").and_then(Value::as_str)?;
    if !RECORD_KINDS.contains(&kind) {
        return None;
    }
    let scope = match kind {
        "source" => record.get("source").and_then(as_object)?,
        "evidence" => record.get("evidence").and_then(as_object)?,
        _ => record,
    };
    let tenant = scope.get("tenant_id").and_then(Value::as_str);
    let person = scope.get("person_id").and_then(Value::as_str);
    if tenant != Some(uid) || person != Some(uid) {
        return None;
    }
    Some(SyncRecord {
        kind: kind.to_string(),
        record: Value::Object(record.clone()),
    })
}

/// `parseCommit(value, uid)`.
pub fn parse_commit(value: &Value, uid: &str) -> Option<SyncCommit> {
    let commit = value.as_object();
    let sequence = safe_int(commit.and_then(|c| c.get("sequence")), 1)?;
    let recorded_at = safe_int(commit.and_then(|c| c.get("recorded_at")), 0)?;
    let event_count = safe_int(commit.and_then(|c| c.get("event_count")), 1)?;
    let first_event_index = safe_int(commit.and_then(|c| c.get("first_event_index")), 0)?;
    let records_value = commit
        .and_then(|c| c.get("records"))
        .and_then(Value::as_array)?;
    if records_value.is_empty() || first_event_index + records_value.len() as i64 > event_count {
        return None;
    }
    let mut records = Vec::with_capacity(records_value.len());
    for entry in records_value {
        records.push(scoped_record(entry, uid)?);
    }
    Some(SyncCommit {
        sequence,
        recorded_at,
        event_count,
        first_event_index,
        records,
    })
}

/// Normalize a deletion target kind: camelCase→snake_case, lowercase, and
/// `profile_entry`→`profile` (matches the TS `replaceAll`/`replace` chain).
fn normalize_kind(raw: &str) -> String {
    let mut snake = String::with_capacity(raw.len() + 4);
    let chars: Vec<char> = raw.chars().collect();
    for (i, c) in chars.iter().enumerate() {
        if i > 0 {
            let prev = chars[i - 1];
            if prev.is_ascii_lowercase() && c.is_ascii_uppercase() {
                snake.push('_');
            }
        }
        snake.push(*c);
    }
    snake.to_lowercase().replace("profile_entry", "profile")
}

/// `deletionTarget(record)`.
pub fn deletion_target(record: &SyncRecord) -> Option<DeletionTarget> {
    if record.kind != "deletion" {
        return None;
    }
    let body = as_object(&record.record)?;
    let target = body.get("target").and_then(as_object);
    let tagged_kind = target.and_then(|t| ms_text(t.get("kind"), 100));
    let tagged_id = target.and_then(|t| ms_text(t.get("id"), 500));
    let first_entry = target.and_then(|t| t.iter().next());
    let id = tagged_id.or_else(|| first_entry.and_then(|(_, v)| ms_text(Some(v), 500)))?;
    let deleted_at = safe_int(body.get("deleted_at"), 0)?;
    let base = tagged_kind
        .or_else(|| first_entry.map(|(k, _)| k.clone()))
        .unwrap_or_default();
    let kind = normalize_kind(&base);
    RECORD_KINDS
        .contains(&kind.as_str())
        .then_some(DeletionTarget {
            kind,
            id,
            deleted_at,
        })
}

/// `recordIdentity(value)`.
pub fn record_identity(record: &SyncRecord) -> Option<RecordIdentity> {
    let body = as_object(&record.record)?;
    let kind = record.kind.clone();
    match record.kind.as_str() {
        "source" => {
            let source = body.get("source").and_then(as_object);
            let id = source.and_then(|s| ms_text(s.get("id"), 500))?;
            Some(RecordIdentity {
                kind,
                id,
                deleted_at: source.and_then(|s| safe_int(s.get("deleted_at"), 0)),
            })
        }
        "evidence" => {
            let evidence = body.get("evidence").and_then(as_object);
            let id = evidence.and_then(|e| ms_text(e.get("id"), 500))?;
            Some(RecordIdentity {
                kind,
                id,
                deleted_at: safe_int(body.get("deleted_at"), 0),
            })
        }
        "claim" | "profile" | "daily_review" => {
            let id = ms_text(body.get("id"), 500)?;
            Some(RecordIdentity {
                kind,
                id,
                deleted_at: None,
            })
        }
        "claim_evidence" => {
            let claim_id = ms_text(body.get("claim_id"), 500)?;
            let evidence_id = ms_text(body.get("evidence_id"), 500)?;
            Some(RecordIdentity {
                kind,
                id: canonical_json_pair(&claim_id, &evidence_id),
                deleted_at: None,
            })
        }
        "correction" => {
            let old_id = ms_text(body.get("superseded_claim_id"), 500)?;
            let new_id = ms_text(body.get("claim_id"), 500)?;
            Some(RecordIdentity {
                kind,
                id: canonical_json_pair(&old_id, &new_id),
                deleted_at: None,
            })
        }
        _ => {
            let target = deletion_target(record)?;
            let target_value = body.get("target").cloned().unwrap_or(Value::Null);
            Some(RecordIdentity {
                kind,
                id: canonical_json(&target_value),
                deleted_at: Some(target.deleted_at),
            })
        }
    }
}

/// `touchedClaimIds(uid, replicaId, records)` — projected ids for claims that a
/// commit created, corrected, or deleted (insertion-ordered, deduped).
pub fn touched_claim_ids(uid: &str, replica_id: &str, records: &[SyncRecord]) -> Vec<String> {
    let mut raw: Vec<String> = Vec::new();
    let add = |raw: &mut Vec<String>, id: String| {
        if !raw.contains(&id) {
            raw.push(id);
        }
    };
    for record in records {
        if record.kind == "claim" {
            if let Some(id) = ms_text(record.record.get("id"), 500) {
                add(&mut raw, id);
            }
        }
        if record.kind == "correction" {
            if let Some(id) = ms_text(record.record.get("superseded_claim_id"), 500) {
                add(&mut raw, id);
            }
            if let Some(id) = ms_text(record.record.get("claim_id"), 500) {
                add(&mut raw, id);
            }
        }
        if let Some(target) = deletion_target(record) {
            if target.kind == "claim" {
                add(&mut raw, target.id);
            }
        }
    }
    raw.iter()
        .map(|id| projected_claim_id(uid, replica_id, id))
        .collect()
}

// ---------------------------------------------------------------------------
// currents: input validation, projection, learned-adjustment weights
// ---------------------------------------------------------------------------

/// currents `text(value, limit)` — trimmed, non-empty, original length bounded.
fn c_text(value: Option<&Value>, limit: usize) -> Option<String> {
    let s = value?.as_str()?;
    let trimmed = s.trim();
    (!trimmed.is_empty() && s.chars().count() <= limit).then(|| trimmed.to_string())
}

/// `bounded(value, limit)` — first `limit` Unicode code points.
pub fn bounded(value: &str, limit: usize) -> String {
    value.chars().take(limit).collect()
}

/// `exactText(value, limit)` — non-empty, bounded, and already trimmed.
fn exact_text(value: Option<&Value>, limit: usize) -> Option<String> {
    let s = value?.as_str()?;
    let n = s.chars().count();
    (n > 0 && n <= limit && s.trim() == s).then(|| s.to_string())
}

/// `onlyKeys(body, keys)` — every key present is in the allow-list.
pub fn only_keys(body: &Map<String, Value>, keys: &[&str]) -> bool {
    body.keys().all(|k| keys.contains(&k.as_str()))
}

/// `risk(value)`.
pub fn risk(value: Option<&Value>) -> Option<&'static str> {
    match value.and_then(Value::as_str) {
        Some("reversible") => Some("reversible"),
        Some("external") => Some("external"),
        Some("destructive") => Some("destructive"),
        _ => None,
    }
}

const ACTION_HASH_LEN: usize = 64;
const RECEIPT_TOKEN_LEN: usize = 43;

/// `/^[0-9a-f]{64}$/`.
pub fn is_action_hash(value: &str) -> bool {
    value.len() == ACTION_HASH_LEN
        && value
            .bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// `/^[A-Za-z0-9_-]{43}$/`.
pub fn is_receipt_token(value: &str) -> bool {
    value.chars().count() == RECEIPT_TOKEN_LEN
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Confidence-basis-points feedback weight (`current_feedback` sum term).
pub fn feedback_weight(kind: &str) -> i64 {
    if kind == "dismissed" {
        -1000
    } else {
        -250
    }
}

/// Execution-outcome weight (`current_executions` sum term).
pub fn execution_weight(state: &str) -> i64 {
    match state {
        "succeeded" => 500,
        "failed" => -500,
        _ => -250,
    }
}

/// Deterministic list ordering key used by `GET /currents`:
/// `confidence_basis_points + learned_adjustment` descending, then
/// `updated_at` descending, then `id` ascending.
pub fn current_sort_key(
    confidence_basis_points: i64,
    learned_adjustment: i64,
    updated_at: i64,
    id: &str,
) -> (std::cmp::Reverse<i64>, std::cmp::Reverse<i64>, String) {
    (
        std::cmp::Reverse(confidence_basis_points + learned_adjustment),
        std::cmp::Reverse(updated_at),
        id.to_string(),
    )
}

/// Format epoch milliseconds as an ISO-8601 UTC instant with millisecond
/// precision (`new Date(ms).toISOString()`).
pub fn iso_from_ms(ms: i64) -> String {
    let days = ms.div_euclid(86_400_000);
    let millis_of_day = ms.rem_euclid(86_400_000);
    let (year, month, day) = civil_from_days(days);
    let hour = millis_of_day / 3_600_000;
    let minute = (millis_of_day / 60_000) % 60;
    let second = (millis_of_day / 1000) % 60;
    let milli = millis_of_day % 1000;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{milli:03}Z")
}

/// Howard Hinnant's `civil_from_days` (days since 1970-01-01 → y/m/d).
fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn field_str(row: &Value, key: &str) -> String {
    row.get(key)
        .map(|v| match v {
            Value::String(s) => s.clone(),
            Value::Null => String::new(),
            other => other.to_string(),
        })
        .unwrap_or_default()
}

fn field_i64(row: &Value, key: &str) -> i64 {
    row.get(key)
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
        .unwrap_or(0)
}

fn field_opt_i64(row: &Value, key: &str) -> Option<i64> {
    match row.get(key) {
        Some(Value::Null) | None => None,
        Some(v) => v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)),
    }
}

fn field_opt_str(row: &Value, key: &str) -> Option<String> {
    match row.get(key) {
        Some(Value::Null) | None => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(other) => Some(other.to_string()),
    }
}

/// `rowToCurrent(row)` — DB row → API Current shape.
pub fn row_to_current(row: &Value) -> Value {
    let proposed_action_raw = field_str(row, "proposed_action");
    let proposed_action: Value = serde_json::from_str(&proposed_action_raw).unwrap_or(Value::Null);
    let confidence = field_i64(row, "confidence_basis_points") as f64 / 10_000.0;
    json!({
        "id": field_str(row, "id"),
        "status": field_str(row, "status"),
        "title": field_str(row, "title"),
        "summary": field_str(row, "summary"),
        "evidence": [{
            "sourceId": field_str(row, "source_id"),
            "reason": field_str(row, "reason"),
        }],
        "sourceKind": field_opt_str(row, "source_kind"),
        "reason": field_str(row, "reason"),
        "confidence": confidence,
        "proposedNextStep": field_str(row, "instruction"),
        "proposedAction": proposed_action,
        "timing": {
            "surfaceAt": iso_from_ms(field_i64(row, "surface_at")),
            "expiresAt": field_opt_i64(row, "expires_at").map(iso_from_ms),
            "snoozedUntil": field_opt_i64(row, "snoozed_until").map(iso_from_ms),
        },
        "feedbackReference": field_opt_str(row, "feedback_reference"),
        "executionReference": field_opt_str(row, "execution_reference"),
        "createdAt": iso_from_ms(field_i64(row, "created_at")),
        "updatedAt": iso_from_ms(field_i64(row, "updated_at")),
    })
}

/// Validated `POST /currents/candidates` input.
#[derive(Debug, PartialEq)]
pub struct CandidateInput {
    pub evidence_id: String,
    pub title: String,
    pub summary: String,
    pub reason: String,
    pub instruction: String,
    pub confidence_basis_points: i64,
    pub surface_at: i64,
    pub expires_at: Option<i64>,
}

/// Validate a candidate body (`Invalid Current candidate` on failure).
pub fn validate_candidate(body: Option<&Value>) -> Result<CandidateInput, &'static str> {
    let err = "Invalid Current candidate";
    let evidence_id = c_text(body.and_then(|b| b.get("evidenceId")), 200).ok_or(err)?;
    let title = c_text(body.and_then(|b| b.get("title")), 120).ok_or(err)?;
    let summary = c_text(body.and_then(|b| b.get("summary")), 500).ok_or(err)?;
    let reason = c_text(body.and_then(|b| b.get("reason")), 500).ok_or(err)?;
    let instruction = c_text(body.and_then(|b| b.get("proposedNextStep")), 500).ok_or(err)?;
    let confidence = body
        .and_then(|b| b.get("confidence"))
        .and_then(Value::as_f64)
        .filter(|c| c.is_finite() && *c >= 0.0 && *c <= 1.0)
        .ok_or(err)?;
    let surface_at = body
        .and_then(|b| b.get("surfaceAt"))
        .and_then(safe_int_value)
        .ok_or(err)?;
    let expires_at = match body.and_then(|b| b.get("expiresAt")) {
        None | Some(Value::Null) => None,
        Some(v) => {
            let value = safe_int_value(v).filter(|e| *e > surface_at).ok_or(err)?;
            Some(value)
        }
    };
    Ok(CandidateInput {
        evidence_id,
        title,
        summary,
        reason,
        instruction,
        confidence_basis_points: (confidence * 10_000.0).round() as i64,
        surface_at,
        expires_at,
    })
}

fn safe_int_value(value: &Value) -> Option<i64> {
    safe_int(Some(value), i64::MIN)
}

/// Validated feedback body.
#[derive(Debug, PartialEq)]
pub struct FeedbackInput {
    pub kind: String,
    pub snoozed_until: Option<i64>,
}

/// Validate `POST /currents/:id/feedback` (`Invalid feedback` on failure).
pub fn validate_feedback(body: Option<&Value>, now: i64) -> Result<FeedbackInput, &'static str> {
    let err = "Invalid feedback";
    let kind = body.and_then(|b| b.get("kind")).and_then(Value::as_str);
    let snoozed_raw = body.and_then(|b| b.get("snoozedUntil"));
    match kind {
        Some("dismissed") => Ok(FeedbackInput {
            kind: "dismissed".into(),
            snoozed_until: None,
        }),
        Some("snoozed") => {
            let snoozed = snoozed_raw
                .and_then(safe_int_value)
                .filter(|s| *s > now)
                .ok_or(err)?;
            Ok(FeedbackInput {
                kind: "snoozed".into(),
                snoozed_until: Some(snoozed),
            })
        }
        _ => Err(err),
    }
}

/// Validated approval body.
#[derive(Debug, PartialEq)]
pub struct ApprovalInput {
    pub nonce: String,
    pub operation_id: String,
    pub proposal_id: String,
    pub action_hash: String,
    pub risk: &'static str,
    pub generation: i64,
}

/// Validate `POST /currents/executions/:id/approve` (`Invalid approval`).
pub fn validate_approval(body: Option<&Value>) -> Result<ApprovalInput, &'static str> {
    let err = "Invalid approval";
    let object = body.and_then(Value::as_object).ok_or(err)?;
    if !only_keys(
        object,
        &[
            "approvalNonce",
            "operationId",
            "proposalId",
            "actionHash",
            "risk",
            "generation",
        ],
    ) {
        return Err(err);
    }
    let nonce = exact_text(object.get("approvalNonce"), 200).ok_or(err)?;
    let operation_id = exact_text(object.get("operationId"), 200).ok_or(err)?;
    let proposal_id = exact_text(object.get("proposalId"), 200).ok_or(err)?;
    let action_hash = exact_text(object.get("actionHash"), 64)
        .filter(|h| is_action_hash(h))
        .ok_or(err)?;
    let action_risk = risk(object.get("risk")).ok_or(err)?;
    let generation = object
        .get("generation")
        .and_then(safe_int_value)
        .filter(|g| *g >= 0)
        .ok_or(err)?;
    Ok(ApprovalInput {
        nonce,
        operation_id,
        proposal_id,
        action_hash,
        risk: action_risk,
        generation,
    })
}

/// Validated receipt-claim body.
#[derive(Debug, PartialEq)]
pub struct ReceiptClaimInput {
    pub token: String,
    pub operation_id: String,
    pub proposal_id: String,
    pub action_hash: String,
    pub risk: &'static str,
    pub policy_generation: i64,
}

/// Validate the receipt-claim body (`Invalid receipt claim`). `subject` must
/// equal the authenticated uid.
pub fn validate_receipt_claim(
    body: Option<&Value>,
    uid: &str,
) -> Result<ReceiptClaimInput, &'static str> {
    let err = "Invalid receipt claim";
    let object = body.and_then(Value::as_object).ok_or(err)?;
    if !only_keys(
        object,
        &[
            "receiptToken",
            "subject",
            "policyGeneration",
            "operationId",
            "proposalId",
            "actionHash",
            "risk",
        ],
    ) {
        return Err(err);
    }
    let token = exact_text(object.get("receiptToken"), 43)
        .filter(|t| is_receipt_token(t))
        .ok_or(err)?;
    let subject = exact_text(object.get("subject"), 200).ok_or(err)?;
    if subject != uid {
        return Err(err);
    }
    let operation_id = exact_text(object.get("operationId"), 200).ok_or(err)?;
    let proposal_id = exact_text(object.get("proposalId"), 200).ok_or(err)?;
    let action_hash = exact_text(object.get("actionHash"), 64)
        .filter(|h| is_action_hash(h))
        .ok_or(err)?;
    let action_risk = risk(object.get("risk")).ok_or(err)?;
    let policy_generation = object
        .get("policyGeneration")
        .and_then(safe_int_value)
        .filter(|g| *g >= 0)
        .ok_or(err)?;
    Ok(ReceiptClaimInput {
        token,
        operation_id,
        proposal_id,
        action_hash,
        risk: action_risk,
        policy_generation,
    })
}

/// Validate `POST /currents/executions/:id/outcome` (`Invalid outcome`).
pub fn validate_outcome(body: Option<&Value>) -> Result<(String, String), &'static str> {
    let err = "Invalid outcome";
    let object = body.and_then(Value::as_object).ok_or(err)?;
    if !only_keys(object, &["state", "detail"]) {
        return Err(err);
    }
    let detail = exact_text(object.get("detail"), 1000).ok_or(err)?;
    let state = object.get("state").and_then(Value::as_str).ok_or(err)?;
    if !matches!(
        state,
        "succeeded"
            | "failed"
            | "outcome_unknown"
            | "cancelled_before_effect"
            | "expired_before_effect"
    ) {
        return Err(err);
    }
    Ok((state.to_string(), detail))
}

// ---------------------------------------------------------------------------
// routes.ts memory retrieval helpers
// ---------------------------------------------------------------------------

/// Build the FTS `MATCH` expression for `/memory/retrieve`: split on
/// whitespace, keep ≤16 terms, quote each (doubling inner quotes), `AND`-join.
pub fn retrieve_match(query: &str) -> String {
    query
        .split_whitespace()
        .take(16)
        .map(|term| format!("\"{}\"", term.replace('"', "\"\"")))
        .collect::<Vec<_>>()
        .join(" AND ")
}

/// `relevance_basis_points` for the retrieve result at `index`.
pub fn relevance_basis_points(index: usize) -> i64 {
    (10_000 - index as i64 * 500).max(1)
}

#[cfg(target_arch = "wasm32")]
pub(crate) mod wasm_glue;

#[cfg(target_arch = "wasm32")]
pub use wasm_glue::{cron_slice, memory_context_for, register};

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn scoped_record_rejects_foreign_scope() {
        let source = json!({
            "kind": "source",
            "record": { "source": { "id": "x", "tenant_id": "beta", "person_id": "beta" } }
        });
        assert!(scoped_record(&source, "alpha").is_none());
        let owned = json!({
            "kind": "source",
            "record": { "source": { "id": "x", "tenant_id": "alpha", "person_id": "alpha" } }
        });
        assert!(scoped_record(&owned, "alpha").is_some());
    }

    #[test]
    fn scoped_record_requires_both_ids_to_match() {
        let mixed = json!({
            "kind": "claim",
            "record": { "id": "c", "tenant_id": "alpha", "person_id": "beta" }
        });
        assert!(scoped_record(&mixed, "alpha").is_none());
    }

    #[test]
    fn parse_commit_rejects_out_of_range_window() {
        // first_event_index + records.len() > event_count
        let commit = json!({
            "sequence": 1, "recorded_at": 5, "event_count": 1, "first_event_index": 1,
            "records": [{ "kind": "claim", "record": { "id": "c", "tenant_id": "a", "person_id": "a" } }]
        });
        assert!(parse_commit(&commit, "a").is_none());
    }

    #[test]
    fn parse_commit_rejects_empty_and_foreign() {
        let empty = json!({
            "sequence": 1, "recorded_at": 5, "event_count": 1, "first_event_index": 0, "records": []
        });
        assert!(parse_commit(&empty, "a").is_none());
        let foreign = json!({
            "sequence": 1, "recorded_at": 5, "event_count": 1, "first_event_index": 0,
            "records": [{ "kind": "claim", "record": { "id": "c", "tenant_id": "b", "person_id": "b" } }]
        });
        assert!(parse_commit(&foreign, "a").is_none());
    }

    #[test]
    fn parse_commit_accepts_valid_window() {
        let commit = json!({
            "sequence": 2, "recorded_at": 13, "event_count": 2, "first_event_index": 0,
            "records": [{ "kind": "claim", "record": { "id": "c", "tenant_id": "a", "person_id": "a" } }]
        });
        let parsed = parse_commit(&commit, "a").expect("valid");
        assert_eq!(parsed.sequence, 2);
        assert_eq!(parsed.event_count, 2);
        assert_eq!(parsed.records.len(), 1);
    }

    #[test]
    fn canonical_json_is_key_sorted_and_stable() {
        let value = json!({ "b": 1, "a": [3, 2], "c": { "z": true, "y": null } });
        assert_eq!(
            canonical_json(&value),
            "{\"a\":[3,2],\"b\":1,\"c\":{\"y\":null,\"z\":true}}"
        );
    }

    #[test]
    fn record_identity_covers_every_kind() {
        let claim = SyncRecord {
            kind: "claim".into(),
            record: json!({ "id": "old-claim" }),
        };
        assert_eq!(
            record_identity(&claim).unwrap(),
            RecordIdentity {
                kind: "claim".into(),
                id: "old-claim".into(),
                deleted_at: None
            }
        );

        let link = SyncRecord {
            kind: "claim_evidence".into(),
            record: json!({ "claim_id": "c", "evidence_id": "e" }),
        };
        assert_eq!(record_identity(&link).unwrap().id, "[\"c\",\"e\"]");

        let source = SyncRecord {
            kind: "source".into(),
            record: json!({ "source": { "id": "s", "deleted_at": 22 } }),
        };
        assert_eq!(record_identity(&source).unwrap().deleted_at, Some(22));
    }

    #[test]
    fn deletion_target_normalizes_tagged_and_shorthand() {
        // Shorthand `{ Claim: "old-claim" }` → kind "claim".
        let shorthand = SyncRecord {
            kind: "deletion".into(),
            record: json!({ "target": { "Claim": "old-claim" }, "deleted_at": 22 }),
        };
        let target = deletion_target(&shorthand).unwrap();
        assert_eq!(target.kind, "claim");
        assert_eq!(target.id, "old-claim");
        assert_eq!(target.deleted_at, 22);

        // Tagged `{ kind: "evidence", id }`.
        let tagged = SyncRecord {
            kind: "deletion".into(),
            record: json!({ "target": { "kind": "evidence", "id": "ev" }, "deleted_at": 5 }),
        };
        assert_eq!(deletion_target(&tagged).unwrap().kind, "evidence");

        // profileEntry → profile.
        let profile = SyncRecord {
            kind: "deletion".into(),
            record: json!({ "target": { "profileEntry": "p1" }, "deleted_at": 9 }),
        };
        assert_eq!(deletion_target(&profile).unwrap().kind, "profile");
    }

    #[test]
    fn touched_claim_ids_projects_and_dedupes() {
        let records = vec![
            SyncRecord {
                kind: "claim".into(),
                record: json!({ "id": "old-claim" }),
            },
            SyncRecord {
                kind: "correction".into(),
                record: json!({ "superseded_claim_id": "old-claim", "claim_id": "new-claim" }),
            },
            SyncRecord {
                kind: "deletion".into(),
                record: json!({ "target": { "kind": "claim", "id": "old-claim" }, "deleted_at": 1 }),
            },
        ];
        let ids = touched_claim_ids("alpha", "desktop", &records);
        assert_eq!(ids.len(), 2); // old-claim + new-claim, deduped
        assert_eq!(ids[0], projected_claim_id("alpha", "desktop", "old-claim"));
        assert_eq!(ids[1], projected_claim_id("alpha", "desktop", "new-claim"));
    }

    #[test]
    fn projected_claim_id_matches_uppercase_hex() {
        // "a" = 0x61.
        assert_eq!(projected_claim_id("a", "b", "c"), "zkr:61:62:claim:63");
    }

    #[test]
    fn claim_text_filters_empty_parts() {
        assert_eq!(
            claim_text(Some("Sam"), Some("employer"), "Acme"),
            "Sam | employer | Acme"
        );
        assert_eq!(claim_text(None, Some(""), "just content"), "just content");
    }

    #[test]
    fn parse_embeddings_validates_shape() {
        // Fake AI shape: [value.length, charCode, 1].
        let good = json!([[11.0, 109.0, 1.0], [8.0, 101.0, 1.0]]);
        assert_eq!(parse_embeddings(&good, 2).unwrap().len(), 2);
        assert!(parse_embeddings(&good, 3).is_none()); // wrong length
        let empty_row = json!([[]]);
        assert!(parse_embeddings(&empty_row, 1).is_none());
        let non_numeric = json!([["x"]]);
        assert!(parse_embeddings(&non_numeric, 1).is_none());
    }

    #[test]
    fn partition_drain_splits_eligible_and_missing() {
        let rows = vec![
            PendingRow {
                uid: "a".into(),
                claim_id: "c1".into(),
            },
            PendingRow {
                uid: "a".into(),
                claim_id: "c2".into(),
            },
            PendingRow {
                uid: "a".into(),
                claim_id: "c3".into(),
            },
        ];
        let lookups = vec![
            Some(ClaimRow {
                id: "c1".into(),
                uid: "a".into(),
                content: "x".into(),
                subject: None,
                predicate: None,
                recorded_at: 1,
                eligible: 1,
            }),
            Some(ClaimRow {
                id: "c2".into(),
                uid: "a".into(),
                content: "y".into(),
                subject: None,
                predicate: None,
                recorded_at: 1,
                eligible: 0,
            }),
            None,
        ];
        let (upserts, deletions) = partition_drain(&rows, &lookups);
        assert_eq!(upserts.len(), 1);
        assert_eq!(upserts[0].id, "c1");
        assert_eq!(deletions.len(), 2);
        assert_eq!(deletions[0].claim_id, "c2");
        assert_eq!(deletions[1].claim_id, "c3");
    }

    #[test]
    fn build_memory_context_caps_output() {
        assert!(build_memory_context(&[], 2000).is_none());
        let ctx = build_memory_context(&["espresso".into()], 2000).unwrap();
        assert!(ctx.contains("Relevant synced memory"));
        assert!(ctx.contains("espresso"));
    }

    #[test]
    fn row_to_current_projects_confidence_and_source_kind() {
        let row = json!({
            "id": "cur-1", "status": "surfaced", "title": "Revisit: Ship",
            "summary": "s", "reason": "Based on: q", "source_id": "src",
            "source_kind": "conversation", "confidence_basis_points": 9000,
            "instruction": "do it", "proposed_action": "{\"kind\":\"review\"}",
            "surface_at": 0, "expires_at": null, "snoozed_until": null,
            "feedback_reference": null, "execution_reference": null,
            "created_at": 0, "updated_at": 1000,
        });
        let current = row_to_current(&row);
        assert_eq!(current["confidence"], json!(0.9));
        assert_eq!(current["sourceKind"], json!("conversation"));
        assert_eq!(current["proposedAction"]["kind"], json!("review"));
        assert_eq!(
            current["timing"]["surfaceAt"],
            json!("1970-01-01T00:00:00.000Z")
        );
        assert_eq!(current["timing"]["expiresAt"], Value::Null);
        assert_eq!(current["updatedAt"], json!("1970-01-01T00:00:01.000Z"));
    }

    #[test]
    fn row_to_current_nulls_missing_source_kind() {
        let row = json!({
            "id": "c", "status": "surfaced", "title": "t", "summary": "s",
            "reason": "r", "source_id": "src", "source_kind": null,
            "confidence_basis_points": 0, "instruction": "i",
            "proposed_action": "{}", "surface_at": 0,
            "created_at": 0, "updated_at": 0,
        });
        assert_eq!(row_to_current(&row)["sourceKind"], Value::Null);
    }

    #[test]
    fn learned_adjustment_weights() {
        assert_eq!(feedback_weight("dismissed"), -1000);
        assert_eq!(feedback_weight("snoozed"), -250);
        assert_eq!(execution_weight("succeeded"), 500);
        assert_eq!(execution_weight("failed"), -500);
        assert_eq!(execution_weight("outcome_unknown"), -250);
    }

    #[test]
    fn current_sort_key_orders_by_adjusted_confidence() {
        let mut items = [
            (current_sort_key(9000, -1000, 10, "b"), "b"),
            (current_sort_key(9000, 0, 5, "a"), "a"),
            (current_sort_key(9000, 0, 5, "c"), "c"),
        ];
        items.sort_by(|x, y| x.0.cmp(&y.0));
        // 9000 beats 8000; between equal scores updated_at desc then id asc.
        assert_eq!(
            items.iter().map(|(_, id)| *id).collect::<Vec<_>>(),
            ["a", "c", "b"]
        );
    }

    #[test]
    fn validate_candidate_enforces_bounds() {
        let good = json!({
            "evidenceId": "e", "title": "t", "summary": "s", "reason": "r",
            "proposedNextStep": "step", "confidence": 0.5, "surfaceAt": 100,
        });
        let parsed = validate_candidate(Some(&good)).unwrap();
        assert_eq!(parsed.confidence_basis_points, 5000);
        assert_eq!(parsed.expires_at, None);

        let bad_confidence = json!({
            "evidenceId": "e", "title": "t", "summary": "s", "reason": "r",
            "proposedNextStep": "step", "confidence": 1.5, "surfaceAt": 100,
        });
        assert_eq!(
            validate_candidate(Some(&bad_confidence)),
            Err("Invalid Current candidate")
        );

        let bad_expiry = json!({
            "evidenceId": "e", "title": "t", "summary": "s", "reason": "r",
            "proposedNextStep": "step", "confidence": 0.5, "surfaceAt": 100, "expiresAt": 50,
        });
        assert!(validate_candidate(Some(&bad_expiry)).is_err());
    }

    #[test]
    fn validate_feedback_checks_snooze_future() {
        assert!(validate_feedback(Some(&json!({ "kind": "dismissed" })), 100).is_ok());
        assert!(validate_feedback(
            Some(&json!({ "kind": "snoozed", "snoozedUntil": 200 })),
            100
        )
        .is_ok());
        assert!(
            validate_feedback(Some(&json!({ "kind": "snoozed", "snoozedUntil": 50 })), 100)
                .is_err()
        );
        assert!(validate_feedback(Some(&json!({ "kind": "other" })), 100).is_err());
    }

    #[test]
    fn validate_approval_enforces_key_allowlist_and_patterns() {
        let hash = "a".repeat(64);
        let good = json!({
            "approvalNonce": "n", "operationId": "op", "proposalId": "pr",
            "actionHash": hash, "risk": "reversible", "generation": 0,
        });
        assert!(validate_approval(Some(&good)).is_ok());

        let extra_key = json!({
            "approvalNonce": "n", "operationId": "op", "proposalId": "pr",
            "actionHash": hash, "risk": "reversible", "generation": 0, "x": 1,
        });
        assert_eq!(validate_approval(Some(&extra_key)), Err("Invalid approval"));

        let bad_hash = json!({
            "approvalNonce": "n", "operationId": "op", "proposalId": "pr",
            "actionHash": "ZZZ", "risk": "reversible", "generation": 0,
        });
        assert!(validate_approval(Some(&bad_hash)).is_err());
    }

    #[test]
    fn validate_receipt_claim_requires_subject_match() {
        let token = "A".repeat(43);
        let hash = "b".repeat(64);
        let good = json!({
            "receiptToken": token, "subject": "alpha", "policyGeneration": 0,
            "operationId": "op", "proposalId": "pr", "actionHash": hash, "risk": "external",
        });
        assert!(validate_receipt_claim(Some(&good), "alpha").is_ok());
        assert_eq!(
            validate_receipt_claim(Some(&good), "beta"),
            Err("Invalid receipt claim")
        );
    }

    #[test]
    fn validate_outcome_accepts_known_states() {
        let good = json!({ "state": "succeeded", "detail": "done" });
        assert_eq!(
            validate_outcome(Some(&good)).unwrap(),
            ("succeeded".into(), "done".into())
        );
        let bad_state = json!({ "state": "weird", "detail": "d" });
        assert!(validate_outcome(Some(&bad_state)).is_err());
        let extra = json!({ "state": "failed", "detail": "d", "x": 1 });
        assert!(validate_outcome(Some(&extra)).is_err());
    }

    #[test]
    fn retrieve_match_quotes_and_limits_terms() {
        assert_eq!(
            retrieve_match("concise release"),
            "\"concise\" AND \"release\""
        );
        assert_eq!(retrieve_match("say \"hi\""), "\"say\" AND \"\"\"hi\"\"\"");
        assert_eq!(relevance_basis_points(0), 10_000);
        assert_eq!(relevance_basis_points(1), 9_500);
        assert_eq!(relevance_basis_points(100), 1); // clamped
    }

    #[test]
    fn iso_from_ms_formats_utc_millis() {
        assert_eq!(iso_from_ms(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso_from_ms(1_000), "1970-01-01T00:00:01.000Z");
        // 2021-01-01T00:00:00.000Z
        assert_eq!(iso_from_ms(1_609_459_200_000), "2021-01-01T00:00:00.000Z");
        assert_eq!(iso_from_ms(1_609_459_200_123), "2021-01-01T00:00:00.123Z");
    }

    #[test]
    fn receipt_and_hash_patterns() {
        assert!(is_action_hash(&"a".repeat(64)));
        assert!(!is_action_hash(&"A".repeat(64))); // uppercase rejected
        assert!(!is_action_hash(&"a".repeat(63)));
        assert!(is_receipt_token(
            &"Aa0_-".repeat(9).chars().take(43).collect::<String>()
        ));
        assert!(!is_receipt_token(&"A".repeat(42)));
    }
}
