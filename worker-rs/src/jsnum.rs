//! Small helpers reproducing the JavaScript `Number(...)` coercion and
//! `Number.isSafeInteger` semantics the TypeScript worker relies on for
//! request/budget validation. Kept pure so the admission and route logic
//! can be exercised with `cargo test` on the host.

use serde_json::Value;

pub const MAX_SAFE_INTEGER: f64 = 9_007_199_254_740_991.0; // 2^53 - 1

/// Mirrors `Number.isSafeInteger`.
pub fn is_safe_integer(value: f64) -> bool {
    value.is_finite() && value.fract() == 0.0 && value.abs() <= MAX_SAFE_INTEGER
}

/// Mirrors `Number(string)` for the decimal inputs the worker sees. Empty or
/// whitespace-only strings coerce to `0`; anything unparsable becomes `NaN`.
pub fn number_from_str(value: &str) -> f64 {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return 0.0;
    }
    trimmed.parse::<f64>().unwrap_or(f64::NAN)
}

/// Mirrors `Number(value)` for the JSON `unknown` values the Durable Object
/// bodies carry: numbers pass through, strings coerce, booleans map to 0/1,
/// null coerces to 0, and objects/arrays become `NaN`.
pub fn number_from_value(value: &Value) -> f64 {
    match value {
        Value::Number(n) => n.as_f64().unwrap_or(f64::NAN),
        Value::String(s) => number_from_str(s),
        Value::Bool(b) => {
            if *b {
                1.0
            } else {
                0.0
            }
        }
        Value::Null => 0.0,
        _ => f64::NAN,
    }
}

/// `Number.isSafeInteger(Number(str)) && n > 0 ? n : null` over an env string.
pub fn positive_integer_str(value: Option<&str>) -> Option<i64> {
    let raw = value?;
    let parsed = number_from_str(raw);
    if is_safe_integer(parsed) && parsed > 0.0 {
        Some(parsed as i64)
    } else {
        None
    }
}

/// `Number.isSafeInteger(Number(value)) && n > 0 ? n : null` over a JSON value.
pub fn positive_integer_value(value: &Value) -> Option<i64> {
    let parsed = number_from_value(value);
    if is_safe_integer(parsed) && parsed > 0.0 {
        Some(parsed as i64)
    } else {
        None
    }
}

/// `Number.isSafeInteger(Number(value)) && n >= 0 ? n : null` over a JSON value.
pub fn non_negative_integer_value(value: &Value) -> Option<i64> {
    let parsed = number_from_value(value);
    if is_safe_integer(parsed) && parsed >= 0.0 {
        Some(parsed as i64)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn safe_integer_matches_js() {
        assert!(is_safe_integer(0.0));
        assert!(is_safe_integer(MAX_SAFE_INTEGER));
        assert!(!is_safe_integer(MAX_SAFE_INTEGER + 1.0));
        assert!(!is_safe_integer(1.5));
        assert!(!is_safe_integer(f64::NAN));
        assert!(!is_safe_integer(f64::INFINITY));
    }

    #[test]
    fn number_from_str_matches_js() {
        assert_eq!(number_from_str(""), 0.0);
        assert_eq!(number_from_str("   "), 0.0);
        assert_eq!(number_from_str("435000"), 435000.0);
        assert!(number_from_str("NaN").is_nan());
        assert!(number_from_str("abc").is_nan());
        assert_eq!(number_from_str("1.5"), 1.5);
    }

    #[test]
    fn positive_integer_str_matches_js() {
        assert_eq!(positive_integer_str(Some("435000")), Some(435000));
        for invalid in [
            None,
            Some(""),
            Some("0"),
            Some("-1"),
            Some("1.5"),
            Some("NaN"),
        ] {
            assert_eq!(positive_integer_str(invalid), None);
        }
    }

    #[test]
    fn non_negative_accepts_zero() {
        assert_eq!(non_negative_integer_value(&json!(0)), Some(0));
        assert_eq!(non_negative_integer_value(&json!(-1)), None);
        assert_eq!(non_negative_integer_value(&json!("5")), Some(5));
        assert_eq!(positive_integer_value(&json!(0)), None);
    }
}
