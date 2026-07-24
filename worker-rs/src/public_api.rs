//! Pure parity port of the input validation and rate-limit budgets in
//! `worker/src/public-api.ts`.
//!
//! Every public route is a thin adapter over an operation; `mcp` calls the very
//! same operations, so the HTTP API and the MCP tools can never drift apart.
//! Operations own their own rate limiting so both surfaces are covered by one
//! budget per uid.

use serde_json::{json, Value};

use crate::jsnum::{is_safe_integer, number_from_value};

/// `{ status, body, retryAfter? }`.
#[derive(Debug, Clone, PartialEq)]
pub struct OperationResult {
    pub status: u16,
    pub body: Value,
    pub retry_after: Option<i64>,
}

impl OperationResult {
    pub fn new(status: u16, body: Value) -> Self {
        Self {
            status,
            body,
            retry_after: None,
        }
    }
}

/// `invalid(message)` — the shared 400 shape.
pub fn invalid(message: &str) -> OperationResult {
    OperationResult::new(400, json!({ "error": message }))
}

/// `{ status: 429, body: { error: "Too many requests" }, retryAfter }`.
pub fn too_many_requests(retry_after: i64) -> OperationResult {
    OperationResult {
        status: 429,
        body: json!({ "error": "Too many requests" }),
        retry_after: Some(retry_after),
    }
}

pub struct Budget {
    pub bucket: &'static str,
    pub limit: i64,
    pub window_ms: i64,
}

pub const READ_BUDGET: Budget = Budget {
    bucket: "public-read",
    limit: 120,
    window_ms: 60_000,
};
pub const WRITE_BUDGET: Budget = Budget {
    bucket: "public-write",
    limit: 60,
    window_ms: 60_000,
};
pub const ASSISTANT_BUDGET: Budget = Budget {
    bucket: "public-assistant",
    limit: 20,
    window_ms: 60_000,
};
/// A FaceTime call rings a real person, so its budget is far tighter than the
/// other write paths.
pub const FACETIME_BUDGET: Budget = Budget {
    bucket: "public-facetime",
    limit: 5,
    window_ms: 60_000,
};

pub const ASSISTANT_HISTORY_LIMIT: i64 = 12;
pub const ASSISTANT_REPLY_CHARACTERS: usize = 4_096;

pub const ASSISTANT_SYSTEM_PROMPT: &str =
    "You are Omi, the user's personal assistant, answering a request that arrived over the public API. Answer directly and concisely in plain text.";

/// `positiveInteger(value, fallback)` — absent/null takes the fallback,
/// anything that is not a safe integer is invalid.
///
/// DEVIATION (stricter, deliberately): the TS returns `NaN` here and the
/// subsequent `limit < 1 || limit > 50` comparisons are all false for `NaN`,
/// so a non-numeric query parameter slips through and reaches the SQL bind. A
/// parity port must never be *more* permissive, so an unparsable value is
/// rejected with the same 400 the other invalid inputs get.
fn positive_integer(value: Option<&Value>, fallback: i64) -> Option<i64> {
    match value {
        None | Some(Value::Null) => Some(fallback),
        Some(value) => {
            let parsed = number_from_value(value);
            is_safe_integer(parsed).then_some(parsed as i64)
        }
    }
}

/// `trimmed(value, max)`.
fn trimmed(value: Option<&Value>, max: usize) -> Option<String> {
    let raw = value?.as_str()?;
    (!raw.trim().is_empty() && raw.chars().count() <= max).then(|| raw.trim().to_string())
}

/// A caller-supplied idempotency / client message id:
/// `/^[A-Za-z0-9._:-]{8,120}$/`.
pub fn is_client_token(value: &str) -> bool {
    (8..=120).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b':' | b'-'))
}

pub struct SearchInput {
    pub query: String,
    pub limit: i64,
    pub mode: String,
}

pub fn validate_search(input: &Value) -> Result<SearchInput, OperationResult> {
    let query = trimmed(input.get("query"), 500);
    let limit = positive_integer(input.get("limit"), 12);
    let mode = match input.get("mode") {
        None | Some(Value::Null) => Some("keyword".to_string()),
        Some(Value::String(mode)) if mode == "keyword" || mode == "semantic" => Some(mode.clone()),
        Some(_) => None,
    };
    match (query, limit, mode) {
        (Some(query), Some(limit), Some(mode)) if (1..=50).contains(&limit) => {
            Ok(SearchInput { query, limit, mode })
        }
        _ => Err(invalid("Invalid memory search")),
    }
}

pub fn validate_list_memories(input: &Value) -> Result<i64, OperationResult> {
    match positive_integer(input.get("limit"), 100) {
        Some(limit) if (1..=100).contains(&limit) => Ok(limit),
        _ => Err(invalid("Invalid memory list")),
    }
}

pub fn validate_notes(input: &Value) -> Result<i64, OperationResult> {
    match positive_integer(input.get("limit"), 50) {
        Some(limit) if (1..=100).contains(&limit) => Ok(limit),
        _ => Err(invalid("Invalid note list")),
    }
}

pub fn validate_conversation(input: &Value) -> Result<(i64, i64), OperationResult> {
    let after = positive_integer(input.get("after"), 0);
    let limit = positive_integer(input.get("limit"), 100);
    match (after, limit) {
        (Some(after), Some(limit)) if after >= 0 && (1..=200).contains(&limit) => {
            Ok((after, limit))
        }
        _ => Err(invalid("Invalid replay range")),
    }
}

pub struct CurrentInput {
    pub title: String,
    pub summary: String,
    pub reason: String,
    pub instruction: String,
    pub evidence_id: Option<String>,
    pub confidence: f64,
    pub surface_at: i64,
    pub expires_at: Option<i64>,
}

pub fn validate_current(input: &Value, now: i64) -> Result<CurrentInput, OperationResult> {
    let error = || invalid("Invalid Current");
    let title = trimmed(input.get("title"), 120).ok_or_else(error)?;
    let summary = trimmed(input.get("summary"), 500).ok_or_else(error)?;
    let reason = trimmed(input.get("reason"), 500).ok_or_else(error)?;
    let instruction = trimmed(input.get("proposedNextStep"), 500).ok_or_else(error)?;

    let evidence_id = match input.get("evidenceId") {
        None | Some(Value::Null) => None,
        Some(value) => Some(trimmed(Some(value), 200).ok_or_else(error)?),
    };

    let confidence = match input.get("confidence") {
        None => 0.7,
        Some(value) => number_from_value(value),
    };
    if !confidence.is_finite() || !(0.0..=1.0).contains(&confidence) {
        return Err(error());
    }

    let surface_at = positive_integer(input.get("surfaceAt"), now).ok_or_else(error)?;
    if surface_at <= 0 {
        return Err(error());
    }
    let expires_at = match input.get("expiresAt") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let parsed = number_from_value(value);
            if !is_safe_integer(parsed) || parsed as i64 <= surface_at {
                return Err(error());
            }
            Some(parsed as i64)
        }
    };
    Ok(CurrentInput {
        title,
        summary,
        reason,
        instruction,
        evidence_id,
        confidence,
        surface_at,
        expires_at,
    })
}

pub struct AskInput {
    pub question: String,
    pub client_message_id: String,
}

/// `askOmiOperation`'s validation. `generated` is the `api:<uuid>` fallback the
/// caller mints when no `clientMessageId` is supplied.
pub fn validate_ask(input: &Value, generated: &str) -> Result<AskInput, OperationResult> {
    let question = trimmed(input.get("text"), 20_000);
    let client_message_id = match input.get("clientMessageId") {
        None => Some(generated.to_string()),
        Some(Value::String(value)) if is_client_token(value) => Some(value.clone()),
        Some(_) => None,
    };
    match (question, client_message_id) {
        (Some(question), Some(client_message_id)) => Ok(AskInput {
            question,
            client_message_id,
        }),
        _ => Err(invalid("Invalid assistant message")),
    }
}

pub struct FaceTimeInput {
    pub handle: String,
    pub token: String,
}

/// `startFaceTimeOperation`'s validation. `generated` is the random token used
/// when the caller supplies no idempotency key.
pub fn validate_facetime(input: &Value, generated: &str) -> Result<FaceTimeInput, OperationResult> {
    let handle = crate::facetime::normalize_handle(input.get("handle"));
    let token = match input.get("idempotencyKey") {
        None => Some(generated.to_string()),
        Some(Value::String(value)) if is_client_token(value) => Some(value.clone()),
        Some(_) => None,
    };
    match (handle, token) {
        (Some(handle), Some(token)) => Ok(FaceTimeInput { handle, token }),
        _ => Err(invalid("Invalid FaceTime handle")),
    }
}

/// Maps a [`crate::facetime::FaceTimeOutcome`] to the operation result.
///
/// `session_id` is derived from the caller's idempotency key by
/// `faceTimeSessionId`, not from anything the provider returns, and `app_url`
/// is `APP_URL` — both are supplied by the caller so this stays pure.
pub fn facetime_result(
    outcome: crate::facetime::FaceTimeOutcome,
    session_id: &str,
    app_url: Option<&str>,
) -> OperationResult {
    use crate::facetime::FaceTimeOutcome as Outcome;
    match outcome {
        // The client keeps reading `call.link`, so the session URL is returned
        // under that name; the Agora credentials belong to the bridge, not to
        // the caller, and are deliberately not exposed here.
        Outcome::Ok { handle, .. } => OperationResult::new(
            201,
            json!({
                "call": {
                    "handle": handle,
                    "sessionId": session_id,
                    "link": crate::facetime::session_link(app_url, session_id),
                },
            }),
        ),
        Outcome::Unavailable => OperationResult::new(
            503,
            json!({
                "error": "FaceTime calling is not provisioned on this account",
                "code": "facetime_unavailable",
            }),
        ),
        Outcome::Unconfigured => {
            OperationResult::new(503, json!({ "error": "FaceTime calling unavailable" }))
        }
        Outcome::Rejected { .. } => {
            OperationResult::new(400, json!({ "error": "Handle rejected by provider" }))
        }
        Outcome::Failed => {
            OperationResult::new(502, json!({ "error": "FaceTime calling unavailable" }))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::facetime::FaceTimeOutcome;

    #[test]
    fn search_defaults_and_bounds() {
        let ok = validate_search(&json!({ "query": "  coffee " })).unwrap();
        assert_eq!(ok.query, "coffee");
        assert_eq!(ok.limit, 12);
        assert_eq!(ok.mode, "keyword");
        assert_eq!(
            validate_search(&json!({ "query": "x", "limit": "20", "mode": "semantic" }))
                .unwrap()
                .limit,
            20
        );
        for input in [
            json!({}),
            json!({ "query": "  " }),
            json!({ "query": "x", "limit": 0 }),
            json!({ "query": "x", "limit": 51 }),
            json!({ "query": "x", "limit": "abc" }),
            json!({ "query": "x", "mode": "vector" }),
            json!({ "query": "x".repeat(501) }),
        ] {
            assert_eq!(
                validate_search(&input).err().unwrap().status,
                400,
                "should reject {input}"
            );
        }
    }

    #[test]
    fn list_and_note_limits() {
        assert_eq!(validate_list_memories(&json!({})).unwrap(), 100);
        assert_eq!(validate_notes(&json!({})).unwrap(), 50);
        assert!(validate_list_memories(&json!({ "limit": 101 })).is_err());
        assert!(validate_notes(&json!({ "limit": 0 })).is_err());
        assert!(validate_notes(&json!({ "limit": "junk" })).is_err());
    }

    #[test]
    fn replay_range_is_bounded() {
        assert_eq!(validate_conversation(&json!({})).unwrap(), (0, 100));
        assert_eq!(
            validate_conversation(&json!({ "after": "5", "limit": "1" })).unwrap(),
            (5, 1)
        );
        for input in [
            json!({ "after": -1 }),
            json!({ "limit": 201 }),
            json!({ "limit": 0 }),
            json!({ "after": "junk" }),
        ] {
            assert!(
                validate_conversation(&input).is_err(),
                "should reject {input}"
            );
        }
    }

    #[test]
    fn current_validation_mirrors_the_first_party_route() {
        let base = json!({
            "title": "Call Ada",
            "summary": "She asked",
            "reason": "You said so",
            "proposedNextStep": "Ring her",
        });
        let ok = validate_current(&base, 1_000).unwrap();
        assert_eq!(ok.confidence, 0.7);
        assert_eq!(ok.surface_at, 1_000);
        assert!(ok.evidence_id.is_none());
        assert!(ok.expires_at.is_none());

        let mut with_evidence = base.clone();
        with_evidence["evidenceId"] = json!("ev-1");
        assert_eq!(
            validate_current(&with_evidence, 1_000).unwrap().evidence_id,
            Some("ev-1".to_string())
        );

        for (key, value) in [
            ("title", json!("")),
            ("confidence", json!(1.5)),
            ("confidence", json!(-0.1)),
            ("confidence", json!("nope")),
            ("surfaceAt", json!(0)),
            ("surfaceAt", json!(1.5)),
            ("expiresAt", json!(500)),
            ("evidenceId", json!("")),
            ("evidenceId", json!(7)),
        ] {
            let mut input = base.clone();
            input[key] = value.clone();
            assert!(
                validate_current(&input, 1_000).is_err(),
                "should reject {key}={value}"
            );
        }
        let mut expiring = base.clone();
        expiring["surfaceAt"] = json!(1_000);
        expiring["expiresAt"] = json!(2_000);
        assert_eq!(
            validate_current(&expiring, 0).unwrap().expires_at,
            Some(2_000)
        );
    }

    #[test]
    fn ask_validation_bounds_the_client_message_id() {
        let ok = validate_ask(&json!({ "text": " hi " }), "api:generated-id").unwrap();
        assert_eq!(ok.question, "hi");
        assert_eq!(ok.client_message_id, "api:generated-id");
        assert_eq!(
            validate_ask(&json!({ "text": "hi", "clientMessageId": "abcdefgh" }), "g")
                .unwrap()
                .client_message_id,
            "abcdefgh"
        );
        for input in [
            json!({}),
            json!({ "text": "  " }),
            json!({ "text": "hi", "clientMessageId": "short" }),
            json!({ "text": "hi", "clientMessageId": "has space here" }),
            json!({ "text": "hi", "clientMessageId": null }),
            json!({ "text": "x".repeat(20_001) }),
        ] {
            assert!(validate_ask(&input, "g").is_err(), "should reject {input}");
        }
    }

    #[test]
    fn facetime_validation_refuses_before_any_dial() {
        let ok = validate_facetime(&json!({ "handle": "+15551234567" }), "gen-token").unwrap();
        assert_eq!(ok.handle, "+15551234567");
        assert_eq!(ok.token, "gen-token");
        for input in [
            json!({}),
            json!({ "handle": "not-a-handle" }),
            json!({ "handle": "+15551234567", "idempotencyKey": "short" }),
            json!({ "handle": "+15551234567", "idempotencyKey": 7 }),
        ] {
            assert_eq!(
                validate_facetime(&input, "gen").err().unwrap().status,
                400,
                "should reject {input}"
            );
        }
    }

    #[test]
    fn facetime_outcomes_map_to_the_documented_statuses() {
        let placed = facetime_result(
            FaceTimeOutcome::Ok {
                handle: "+15551234567".into(),
                agora: crate::facetime::AgoraCredentials {
                    app_id: "app".into(),
                    channel_name: "chan".into(),
                    token: "tok".into(),
                    uid: 1,
                },
            },
            "0123456789abcdef",
            None,
        );
        assert_eq!(placed.status, 201);
        assert_eq!(placed.body["call"]["sessionId"], json!("0123456789abcdef"));
        assert_eq!(
            placed.body["call"]["link"],
            json!("https://omi.tsc.hk/facetime/sessions/0123456789abcdef")
        );
        // The bridge's Agora credentials never reach the caller.
        assert!(!placed.body.to_string().contains("tok"));
        assert_eq!(
            facetime_result(
                FaceTimeOutcome::Ok {
                    handle: "+15551234567".into(),
                    agora: crate::facetime::AgoraCredentials {
                        app_id: "app".into(),
                        channel_name: "chan".into(),
                        token: "tok".into(),
                        uid: 1,
                    },
                },
                "abc",
                Some("https://app.example.com"),
            )
            .body["call"]["link"],
            json!("https://app.example.com/facetime/sessions/abc")
        );
        let unavailable = facetime_result(FaceTimeOutcome::Unavailable, "abc", None);
        assert_eq!(unavailable.status, 503);
        assert_eq!(unavailable.body["code"], json!("facetime_unavailable"));
        assert_eq!(
            facetime_result(FaceTimeOutcome::Unconfigured, "abc", None).status,
            503
        );
        assert_eq!(
            facetime_result(FaceTimeOutcome::Rejected { status: 422 }, "abc", None).status,
            400
        );
        assert_eq!(
            facetime_result(FaceTimeOutcome::Failed, "abc", None).status,
            502
        );
    }

    #[test]
    fn client_token_pattern() {
        assert!(is_client_token("abcdefgh"));
        assert!(is_client_token("api:1234-5678._x"));
        assert!(!is_client_token("abcdefg"));
        assert!(!is_client_token(&"a".repeat(121)));
        assert!(!is_client_token("has space"));
        assert!(!is_client_token("has/slash/x"));
    }
}
