//! Pure settings logic ported from the `GET`/`PUT /settings` handlers in
//! `worker/src/routes.ts`.
//!
//! `PUT /settings` owns `user_settings.revision` — the `policy_generation` value
//! the currents approval gate reads (`policy_generation = COALESCE((SELECT
//! revision FROM user_settings…), 0)`). Bumping the revision is how a user
//! revokes standing current-approvals, so this validation must match the TS
//! worker exactly. Everything here is host-testable; the D1/auth glue in
//! `glue.rs` drives these functions.

use serde_json::{json, Value};

use crate::jsnum::{is_safe_integer, number_from_value};

/// A settings-change scope duration. Mirrors the TS `SettingsDuration` union.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Duration {
    Task,
    Session,
    Persistent,
}

impl Duration {
    pub fn as_str(self) -> &'static str {
        match self {
            Duration::Task => "task",
            Duration::Session => "session",
            Duration::Persistent => "persistent",
        }
    }

    pub fn parse(value: &str) -> Option<Duration> {
        match value {
            "task" => Some(Duration::Task),
            "session" => Some(Duration::Session),
            "persistent" => Some(Duration::Persistent),
            _ => None,
        }
    }
}

/// Effective user settings. Mirrors the TS `UserSettings` shape.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UserSettings {
    pub approval_mode: String,
    pub proactive_recommendations: bool,
}

impl Default for UserSettings {
    /// Matches the TS `parseJson` fallback: `{ approvalMode: "once",
    /// proactiveRecommendations: true }`.
    fn default() -> Self {
        UserSettings {
            approval_mode: "once".to_string(),
            proactive_recommendations: true,
        }
    }
}

impl UserSettings {
    /// Serialize to the `{ approvalMode, proactiveRecommendations }` object the
    /// TS worker echoes and stores (key order matches `{...previous, ...patch}`).
    pub fn to_value(&self) -> Value {
        json!({
            "approvalMode": self.approval_mode,
            "proactiveRecommendations": self.proactive_recommendations,
        })
    }
}

/// `authority` ranking used by `expandsAuthority`: ask < once < auto.
fn authority(mode: &str) -> i64 {
    match mode {
        "ask" => 0,
        "once" => 1,
        "auto" => 2,
        _ => -1,
    }
}

/// Port of `parseJson<UserSettings>(row?.value, fallback)`. Parses the stored
/// JSON string, falling back to the defaults on absence or parse failure.
pub fn parse_settings(raw: Option<&str>) -> UserSettings {
    let Some(raw) = raw else {
        return UserSettings::default();
    };
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return UserSettings::default();
    };
    let default = UserSettings::default();
    UserSettings {
        approval_mode: value
            .get("approvalMode")
            .and_then(Value::as_str)
            .map(String::from)
            .unwrap_or(default.approval_mode),
        proactive_recommendations: value
            .get("proactiveRecommendations")
            .and_then(Value::as_bool)
            .unwrap_or(default.proactive_recommendations),
    }
}

/// The validated up-front shape of a `PUT /settings` body (before any DB read).
pub struct PatchValidation {
    /// `patch.approvalMode` when present.
    pub approval_mode: Option<String>,
    /// `patch.proactiveRecommendations` when present.
    pub proactive_recommendations: Option<bool>,
    /// `Number(body.expectedRevision)` — a validated non-negative safe integer.
    pub expected_revision: i64,
    /// The scope duration.
    pub duration: Duration,
}

/// Port of the up-front validation block in `PUT /settings`. Returns `None`
/// (→ 400 "Invalid settings change") when the patch shape, expected revision,
/// duration, or field values are invalid.
pub fn validate_patch(body: &Value) -> Option<PatchValidation> {
    let patch = body.get("patch").and_then(|p| match p {
        Value::Object(map) => Some(map),
        _ => None,
    })?;
    if patch.is_empty() {
        return None;
    }
    for key in patch.keys() {
        if key != "approvalMode" && key != "proactiveRecommendations" {
            return None;
        }
    }

    let expected_revision = match body.get("expectedRevision") {
        Some(value) => number_from_value(value),
        // Missing key → `Number(undefined)` → NaN → rejected.
        None => f64::NAN,
    };
    if !is_safe_integer(expected_revision) || expected_revision < 0.0 {
        return None;
    }

    let duration = body
        .get("duration")
        .and_then(Value::as_str)
        .and_then(Duration::parse)?;

    // `patch.approvalMode` must be undefined or one of ask/once/auto.
    let approval_mode = match patch.get("approvalMode") {
        None => None,
        Some(Value::String(mode)) if mode == "ask" || mode == "once" || mode == "auto" => {
            Some(mode.clone())
        }
        _ => return None,
    };

    // `patch.proactiveRecommendations` must be undefined or a boolean.
    let proactive_recommendations = match patch.get("proactiveRecommendations") {
        None => None,
        Some(Value::Bool(value)) => Some(*value),
        _ => return None,
    };

    Some(PatchValidation {
        approval_mode,
        proactive_recommendations,
        expected_revision: expected_revision as i64,
        duration,
    })
}

/// Port of `{ ...previous, ...patch }`.
pub fn merge(
    previous: &UserSettings,
    approval_mode: Option<&str>,
    proactive_recommendations: Option<bool>,
) -> UserSettings {
    UserSettings {
        approval_mode: approval_mode
            .map(String::from)
            .unwrap_or_else(|| previous.approval_mode.clone()),
        proactive_recommendations: proactive_recommendations
            .unwrap_or(previous.proactive_recommendations),
    }
}

/// Port of `settingsDiff(from, to)` — an object with only the changed fields.
pub fn settings_diff(from: &UserSettings, to: &UserSettings) -> Value {
    let mut diff = serde_json::Map::new();
    if from.approval_mode != to.approval_mode {
        diff.insert(
            "approvalMode".to_string(),
            json!({ "from": from.approval_mode, "to": to.approval_mode }),
        );
    }
    if from.proactive_recommendations != to.proactive_recommendations {
        diff.insert(
            "proactiveRecommendations".to_string(),
            json!({
                "from": from.proactive_recommendations,
                "to": to.proactive_recommendations,
            }),
        );
    }
    Value::Object(diff)
}

/// Port of `expandsAuthority`: true only when the patch raises `approvalMode`
/// to a higher authority than the previous value.
pub fn expands_authority(previous: &UserSettings, patch_approval: Option<&str>) -> bool {
    match patch_approval {
        Some(mode) => authority(mode) > authority(&previous.approval_mode),
        None => false,
    }
}

/// Port of the `text(value, limit)` helper: trims a JSON string, requiring it to
/// be non-empty after trimming and within `limit` (untrimmed length).
pub fn text(value: Option<&Value>, limit: usize) -> Option<String> {
    let s = value?.as_str()?;
    let trimmed = s.trim();
    (!trimmed.is_empty() && s.chars().count() <= limit).then(|| trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_settings_falls_back() {
        assert_eq!(parse_settings(None), UserSettings::default());
        assert_eq!(parse_settings(Some("not json")), UserSettings::default());
        assert_eq!(
            parse_settings(Some(
                r#"{"approvalMode":"auto","proactiveRecommendations":false}"#
            )),
            UserSettings {
                approval_mode: "auto".to_string(),
                proactive_recommendations: false,
            }
        );
    }

    #[test]
    fn validate_patch_accepts_valid() {
        let body = json!({
            "patch": { "approvalMode": "auto" },
            "expectedRevision": 3,
            "duration": "persistent",
        });
        let v = validate_patch(&body).expect("valid");
        assert_eq!(v.approval_mode.as_deref(), Some("auto"));
        assert_eq!(v.proactive_recommendations, None);
        assert_eq!(v.expected_revision, 3);
        assert_eq!(v.duration, Duration::Persistent);
    }

    #[test]
    fn validate_patch_rejects_bad_shape() {
        // no patch
        assert!(validate_patch(&json!({ "expectedRevision": 0, "duration": "task" })).is_none());
        // empty patch
        assert!(
            validate_patch(&json!({ "patch": {}, "expectedRevision": 0, "duration": "task" }))
                .is_none()
        );
        // unknown key
        assert!(validate_patch(&json!({
            "patch": { "approvalMode": "auto", "other": 1 },
            "expectedRevision": 0,
            "duration": "task",
        }))
        .is_none());
        // bad approvalMode value
        assert!(validate_patch(&json!({
            "patch": { "approvalMode": "nope" },
            "expectedRevision": 0,
            "duration": "task",
        }))
        .is_none());
        // bad proactive type
        assert!(validate_patch(&json!({
            "patch": { "proactiveRecommendations": "yes" },
            "expectedRevision": 0,
            "duration": "task",
        }))
        .is_none());
        // missing expectedRevision → NaN
        assert!(validate_patch(&json!({
            "patch": { "approvalMode": "auto" },
            "duration": "task",
        }))
        .is_none());
        // negative revision
        assert!(validate_patch(&json!({
            "patch": { "approvalMode": "auto" },
            "expectedRevision": -1,
            "duration": "task",
        }))
        .is_none());
        // bad duration
        assert!(validate_patch(&json!({
            "patch": { "approvalMode": "auto" },
            "expectedRevision": 0,
            "duration": "forever",
        }))
        .is_none());
    }

    #[test]
    fn expected_revision_coerces_string() {
        let body = json!({
            "patch": { "proactiveRecommendations": false },
            "expectedRevision": "5",
            "duration": "session",
        });
        let v = validate_patch(&body).expect("valid");
        assert_eq!(v.expected_revision, 5);
        assert_eq!(v.proactive_recommendations, Some(false));
    }

    #[test]
    fn merge_and_diff() {
        let previous = UserSettings::default();
        let merged = merge(&previous, Some("auto"), None);
        assert_eq!(merged.approval_mode, "auto");
        assert!(merged.proactive_recommendations);
        let diff = settings_diff(&previous, &merged);
        assert_eq!(
            diff,
            json!({ "approvalMode": { "from": "once", "to": "auto" } })
        );
    }

    #[test]
    fn diff_empty_when_unchanged() {
        let previous = UserSettings::default();
        let merged = merge(&previous, None, None);
        assert_eq!(settings_diff(&previous, &merged), json!({}));
    }

    #[test]
    fn expands_authority_matches_ranking() {
        let previous = UserSettings::default(); // once (1)
        assert!(expands_authority(&previous, Some("auto"))); // 2 > 1
        assert!(!expands_authority(&previous, Some("ask"))); // 0 < 1
        assert!(!expands_authority(&previous, Some("once"))); // 1 == 1
        assert!(!expands_authority(&previous, None));
    }

    #[test]
    fn text_trims_and_caps() {
        assert_eq!(text(Some(&json!("  hi  ")), 200), Some("hi".to_string()));
        assert_eq!(text(Some(&json!("   ")), 200), None);
        assert_eq!(text(Some(&json!("abcdef")), 3), None);
        assert_eq!(text(Some(&Value::Null), 200), None);
        assert_eq!(text(None, 200), None);
    }
}
