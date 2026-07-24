//! Pure parity port of `worker/src/memory-log.ts`.
//!
//! The authoritative memory log. This is the record of truth for a user's
//! memory: a record is not remembered until the Worker has appended it here and
//! assigned it a sequence. Devices mint records (that is where evidence and
//! transcript locators come from) but never decide ordering, and the D1 read
//! tables are a projection rebuildable from this log.
//!
//! The sequence is assigned by the Worker, inside the statement, from
//! `MAX(sequence) + 1` for the uid — never by the caller. Two concurrent
//! requests can both read the same MAX; the primary key turns that into a
//! failed batch the caller retries, never into two records sharing a sequence.

use serde_json::Value;

/// The record kinds the log accepts, mirroring migration 0029's CHECK.
pub const MEMORY_LOG_KINDS: &[&str] = &[
    "source",
    "evidence",
    "claim",
    "claim_evidence",
    "correction",
    "deletion",
    "profile",
    "daily_review",
];

pub fn is_memory_log_kind(kind: &str) -> bool {
    MEMORY_LOG_KINDS.contains(&kind)
}

/// The cursor bounds `GET /v1/memory/log` enforces.
pub const DEFAULT_LOG_LIMIT: i64 = 200;
pub const MAXIMUM_LOG_LIMIT: i64 = 500;
pub const MAXIMUM_REPLICA_ID_CHARACTERS: usize = 200;

#[derive(Clone, Debug, PartialEq)]
pub struct MemoryLogAppend {
    pub record_kind: String,
    pub record_id: String,
    pub payload: Value,
    pub recorded_at: i64,
}

/// Stable key order so an identical record re-sent by a retrying device
/// compares equal to the copy already in the log and is skipped rather than
/// reordered. Byte-for-byte identical to `canonicalJson`, which means it must
/// match `JSON.stringify` for scalars too — including the `null` a non-finite
/// or otherwise unrepresentable value collapses to.
pub fn canonical_json(value: &Value) -> String {
    match value {
        Value::Array(items) => {
            let parts: Vec<String> = items.iter().map(canonical_json).collect();
            format!("[{}]", parts.join(","))
        }
        Value::Object(entry) => {
            let mut keys: Vec<&String> = entry.keys().collect();
            keys.sort();
            let parts: Vec<String> = keys
                .into_iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        Value::String(key.clone()),
                        canonical_json(&entry[key])
                    )
                })
                .collect();
            format!("{{{}}}", parts.join(","))
        }
        other => other.to_string(),
    }
}

/// One statement per record, run inside a single D1 batch so each append sees
/// the sequences allocated by the appends before it.
pub const APPEND_SQL: &str = "INSERT INTO memory_log
         (uid, sequence, origin_replica, record_kind, record_id, payload, recorded_at, appended_at)
       SELECT ?1,
              COALESCE((SELECT MAX(sequence) FROM memory_log WHERE uid = ?1), 0) + 1,
              ?2, ?3, ?4, ?5, ?6, ?7
       WHERE NOT EXISTS (
         SELECT 1 FROM memory_log current
         WHERE current.uid = ?1 AND current.origin_replica = ?2
           AND current.record_kind = ?3 AND current.record_id = ?4
           AND current.payload = ?5
           AND current.sequence = (
             SELECT MAX(newest.sequence) FROM memory_log newest
             WHERE newest.uid = ?1 AND newest.origin_replica = ?2
               AND newest.record_kind = ?3 AND newest.record_id = ?4
           )
       )";

pub const HEAD_SQL: &str =
    "SELECT COALESCE(MAX(sequence), 0) AS sequence FROM memory_log WHERE uid = ?1";

pub const READ_SQL: &str =
    "SELECT sequence, origin_replica, record_kind, record_id, payload, recorded_at, appended_at
       FROM memory_log WHERE uid = ?1 AND sequence > ?2 ORDER BY sequence LIMIT ?3";

pub const CURSOR_SQL: &str =
    "INSERT INTO memory_log_cursors (uid, replica_id, mirrored_sequence, updated_at)
       VALUES (?1, ?2, ?3, ?4)
       ON CONFLICT(uid, replica_id) DO UPDATE SET
         mirrored_sequence = MAX(memory_log_cursors.mirrored_sequence, excluded.mirrored_sequence),
         updated_at = excluded.updated_at";

/// The records an append actually writes: anything whose kind the log does not
/// recognise is dropped rather than rejected, exactly as `appendMemoryLog`
/// filters before batching.
pub fn appendable(records: Vec<MemoryLogAppend>) -> Vec<MemoryLogAppend> {
    records
        .into_iter()
        .filter(|record| is_memory_log_kind(&record.record_kind))
        .collect()
}

/// The validated `GET /v1/memory/log` cursor.
#[derive(Clone, Debug, PartialEq)]
pub struct LogCursor {
    pub after: i64,
    pub limit: i64,
    pub replica_id: Option<String>,
}

/// `after` defaults to 0 and `limit` to 200; both must be safe integers, and
/// `limit` must be within 1..=500.
pub fn validate_cursor(
    after: Option<&str>,
    limit: Option<&str>,
    replica_id: Option<&str>,
) -> Option<LogCursor> {
    let parse = |raw: Option<&str>, fallback: i64| -> Option<i64> {
        let value = match raw {
            None => fallback as f64,
            Some(text) => crate::jsnum::number_from_str(text),
        };
        crate::jsnum::is_safe_integer(value).then_some(value as i64)
    };
    let after = parse(after, 0)?;
    let limit = parse(limit, DEFAULT_LOG_LIMIT)?;
    if after < 0 || !(1..=MAXIMUM_LOG_LIMIT).contains(&limit) {
        return None;
    }
    Some(LogCursor {
        after,
        limit,
        replica_id: replica_id
            .map(str::trim)
            .filter(|value| {
                !value.is_empty() && value.chars().count() <= MAXIMUM_REPLICA_ID_CHARACTERS
            })
            .map(str::to_string),
    })
}

/// The page envelope: `next_after` stays at the cursor when the page is empty,
/// and `complete` reports whether the reader has caught up with the head.
pub fn page_envelope(records: Vec<Value>, after: i64, head: i64) -> Value {
    let next_after = records
        .last()
        .and_then(|record| record.get("sequence"))
        .and_then(Value::as_i64)
        .unwrap_or(after);
    serde_json::json!({
        "records": records,
        "next_after": next_after,
        "head": head,
        "complete": next_after >= head,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn canonical_json_sorts_keys_at_every_depth() {
        assert_eq!(
            canonical_json(&json!({ "b": 1, "a": { "d": [1, 2], "c": "x" } })),
            r#"{"a":{"c":"x","d":[1,2]},"b":1}"#
        );
        assert_eq!(canonical_json(&json!([])), "[]");
        assert_eq!(canonical_json(&json!({})), "{}");
        assert_eq!(canonical_json(&Value::Null), "null");
        assert_eq!(canonical_json(&json!(true)), "true");
        assert_eq!(canonical_json(&json!("a\"b")), r#""a\"b""#);
        assert_eq!(canonical_json(&json!(1.5)), "1.5");
        // Key order in the input must not change the output, which is what
        // makes a retried record compare equal to the stored copy.
        assert_eq!(
            canonical_json(&json!({ "a": 1, "b": 2 })),
            canonical_json(&json!({ "b": 2, "a": 1 }))
        );
    }

    #[test]
    fn unknown_record_kinds_are_dropped_not_appended() {
        let record = |kind: &str| MemoryLogAppend {
            record_kind: kind.into(),
            record_id: "r".into(),
            payload: json!({}),
            recorded_at: 0,
        };
        let kept = appendable(vec![
            record("claim"),
            record("nonsense"),
            record("daily_review"),
        ]);
        assert_eq!(kept.len(), 2);
        assert_eq!(kept[0].record_kind, "claim");
        assert_eq!(kept[1].record_kind, "daily_review");
        assert!(appendable(vec![record("Claim")]).is_empty());
    }

    #[test]
    fn the_worker_assigns_the_sequence_not_the_caller() {
        // The contract this test guards: nothing in the append path takes a
        // caller-supplied sequence, and the statement derives it from MAX+1.
        assert!(APPEND_SQL.contains("COALESCE((SELECT MAX(sequence) FROM memory_log WHERE uid = ?1), 0) + 1"));
        assert!(!APPEND_SQL.contains("VALUES"));
    }

    #[test]
    fn cursor_defaults_and_bounds() {
        assert_eq!(
            validate_cursor(None, None, None),
            Some(LogCursor {
                after: 0,
                limit: 200,
                replica_id: None
            })
        );
        assert_eq!(
            validate_cursor(Some("12"), Some("1"), Some("  replica-a  ")),
            Some(LogCursor {
                after: 12,
                limit: 1,
                replica_id: Some("replica-a".into())
            })
        );
        assert_eq!(
            validate_cursor(Some("0"), Some("500"), Some("  ")).map(|c| c.replica_id),
            Some(None)
        );
        for (after, limit) in [
            (Some("-1"), None),
            (Some("1.5"), None),
            (Some("abc"), None),
            (None, Some("0")),
            (None, Some("501")),
            (None, Some("-1")),
            (None, Some("x")),
        ] {
            assert!(
                validate_cursor(after, limit, None).is_none(),
                "should refuse after={after:?} limit={limit:?}"
            );
        }
        let long = "r".repeat(201);
        assert_eq!(
            validate_cursor(None, None, Some(&long)).map(|c| c.replica_id),
            Some(None)
        );
    }

    #[test]
    fn an_empty_page_keeps_the_cursor_and_reports_completeness() {
        assert_eq!(
            page_envelope(Vec::new(), 7, 7),
            json!({ "records": [], "next_after": 7, "head": 7, "complete": true })
        );
        assert_eq!(
            page_envelope(Vec::new(), 3, 9),
            json!({ "records": [], "next_after": 3, "head": 9, "complete": false })
        );
        let records = vec![json!({ "sequence": 4 }), json!({ "sequence": 5 })];
        assert_eq!(
            page_envelope(records, 3, 9)["next_after"],
            json!(5)
        );
    }
}
