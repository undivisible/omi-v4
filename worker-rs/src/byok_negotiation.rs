//! Pure parity port of the decision logic in `worker/src/byok-negotiation.ts`.
//!
//! The user argues their case in a real conversation with the model; the model
//! may only *suggest* which of the server-defined concessions applies. The
//! price itself is computed in [`crate::byok_pricing`] and written to D1 as an
//! auditable record together with the conversation that produced it. No price
//! value is ever read from a request body or from model output.

use serde_json::{json, Value};

use crate::byok_pricing::{concession_for, format_price, Concession, PriceBand};

pub const MAXIMUM_BODY_BYTES: usize = 8 * 1024;
pub const MAXIMUM_MESSAGE_CHARACTERS: usize = 600;
pub const MAXIMUM_TRANSCRIPT_ENTRIES: usize = 64;
pub const UPSTREAM_TIMEOUT_MS: i64 = 20_000;
/// `sessionStartLimit` / `messageLimit`.
pub const SESSION_START_LIMIT: i64 = 3;
pub const SESSION_START_WINDOW_MS: i64 = 24 * 3_600_000;
pub const MESSAGE_LIMIT: i64 = 24;
pub const MESSAGE_WINDOW_MS: i64 = 3_600_000;

#[derive(Clone, Debug, PartialEq)]
pub struct TranscriptEntry {
    pub role: String,
    pub content: String,
}

impl TranscriptEntry {
    pub fn to_value(&self) -> Value {
        json!({ "role": self.role, "content": self.content })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgreedPrice {
    pub price_cents: i64,
    pub outcome: String,
    pub agreed_at: i64,
}

/// A JSON-encoded array column; anything else is an empty list.
pub fn parse_json_array(value: Option<&Value>) -> Vec<Value> {
    let Some(Value::String(raw)) = value else {
        return Vec::new();
    };
    match serde_json::from_str::<Value>(raw) {
        Ok(Value::Array(items)) => items,
        _ => Vec::new(),
    }
}

/// `parseTranscript` — only `user`/`omi` entries with string content survive.
pub fn parse_transcript(value: Option<&Value>) -> Vec<TranscriptEntry> {
    parse_json_array(value)
        .iter()
        .filter_map(|entry| {
            let record = entry.as_object()?;
            let role = record.get("role")?.as_str()?;
            let content = record.get("content")?.as_str()?;
            (role == "user" || role == "omi").then(|| TranscriptEntry {
                role: role.to_string(),
                content: content.to_string(),
            })
        })
        .collect()
}

/// Clamp a stored agreement into the band in force today: a row written under
/// an older, wider band can never undercut the current floor or ceiling.
pub fn clamp_agreement(
    band: &PriceBand,
    price_cents: i64,
    outcome: &str,
    agreed_at: i64,
) -> AgreedPrice {
    AgreedPrice {
        price_cents: band.standard_cents.min(band.floor_cents.max(price_cents)),
        outcome: if outcome == "negotiated" {
            "negotiated".to_string()
        } else {
            "standard".to_string()
        },
        agreed_at,
    }
}

/// `planPayload(band, agreement, now)`.
pub fn plan_payload(band: &PriceBand, agreement: Option<&AgreedPrice>, now: i64) -> Value {
    json!({
        "standardPriceCents": band.standard_cents,
        "floorPriceCents": band.floor_cents,
        "priceCents": agreement.map_or(band.standard_cents, |a| a.price_cents),
        "outcome": agreement.map(|a| a.outcome.clone()),
        "agreedAt": agreement.map(|a| a.agreed_at),
        "negotiable": agreement.is_none_or(|a| now >= a.agreed_at + band.cooldown_ms),
        "renegotiableAt": agreement.map(|a| a.agreed_at + band.cooldown_ms),
    })
}

/// The opening line of a fresh negotiation.
pub fn opening_entry(band: &PriceBand) -> TranscriptEntry {
    TranscriptEntry {
        role: "omi".to_string(),
        content: format!(
            "Standard with your own key is {} a month. If that is not right for you, tell me why and I will see what I can do.",
            format_price(band.standard_cents)
        ),
    }
}

/// `systemPrompt(band, granted)`.
pub fn system_prompt(band: &PriceBand, granted: &[String]) -> String {
    let available: Vec<&Concession> = band
        .concessions
        .iter()
        .filter(|concession| !granted.iter().any(|code| code == concession.code))
        .collect();
    let offer = if available.is_empty() {
        "(none left; you have nothing further to offer)".to_string()
    } else {
        available
            .iter()
            .map(|concession| format!("- {}: {}", concession.code, concession.label))
            .collect::<Vec<_>>()
            .join("\n")
    };
    [
        "You are Omi, negotiating your own subscription price with a user who has",
        "just connected their own AI provider key. Be warm, brief (two sentences",
        "at most), and honest. Never invent urgency, deadlines or scarcity.",
        "",
        "You do not set prices. You may only suggest at most one concession per",
        "reply, chosen from this list, when the user has genuinely made that case:",
        &offer,
        "",
        "Never state a number, a price or a percentage; the app shows the price.",
        r#"Reply with JSON only: {"reply": string, "concession": string or null}."#,
    ]
    .join("\n")
}

pub struct Suggestion {
    pub reply: String,
    pub concession: Option<Concession>,
}

/// `parseSuggestion` — the model's output is untrusted text. Only the reply
/// string and a *known, not-yet-granted* concession code survive.
pub fn parse_suggestion(band: &PriceBand, granted: &[String], raw: &str) -> Option<Suggestion> {
    let start = raw.find('{')?;
    let end = raw.rfind('}')?;
    if end <= start {
        return None;
    }
    let parsed = serde_json::from_str::<Value>(&raw[start..=end]).ok()?;
    let record = parsed.as_object()?;
    let reply = record.get("reply")?.as_str()?;
    if reply.trim().is_empty() {
        return None;
    }
    let concession = concession_for(band, record.get("concession").and_then(Value::as_str))
        // A concession already granted in this session cannot be granted
        // twice, whatever the model repeats.
        .filter(|concession| !granted.iter().any(|code| code == concession.code))
        .cloned();
    Some(Suggestion {
        reply: reply
            .trim()
            .chars()
            .take(MAXIMUM_MESSAGE_CHARACTERS)
            .collect(),
        concession,
    })
}

/// The model is told not to quote numbers, but "told not to" is not a control.
/// Any currency or percentage figure that survives is replaced with the price
/// the server computed, so the text can never disagree with the record.
///
/// Mirrors `reply.replace(/\$\s?\d+(?:[.,]\d+)?/g, formatPrice(price))
///              .replace(/\d+(?:\.\d+)?\s?%/g, "a bit")`.
pub fn sanitize_reply(reply: &str, price_cents: i64) -> String {
    replace_percentages(&replace_currency(reply, &format_price(price_cents)))
}

fn replace_currency(input: &str, replacement: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut index = 0;
    while index < chars.len() {
        if chars[index] == '$' {
            if let Some(end) = currency_match(&chars, index) {
                out.push_str(replacement);
                index = end;
                continue;
            }
        }
        out.push(chars[index]);
        index += 1;
    }
    out
}

/// `\$\s?\d+(?:[.,]\d+)?` anchored at `start`; returns the end index.
fn currency_match(chars: &[char], start: usize) -> Option<usize> {
    let mut index = start + 1;
    if chars.get(index).is_some_and(|c| c.is_whitespace()) {
        index += 1;
    }
    let digits_start = index;
    while chars.get(index).is_some_and(char::is_ascii_digit) {
        index += 1;
    }
    if index == digits_start {
        return None;
    }
    if matches!(chars.get(index), Some('.') | Some(','))
        && chars.get(index + 1).is_some_and(char::is_ascii_digit)
    {
        index += 1;
        while chars.get(index).is_some_and(char::is_ascii_digit) {
            index += 1;
        }
    }
    Some(index)
}

fn replace_percentages(input: &str) -> String {
    let chars: Vec<char> = input.chars().collect();
    let mut out = String::with_capacity(input.len());
    let mut index = 0;
    while index < chars.len() {
        if let Some(end) = percentage_match(&chars, index) {
            out.push_str("a bit");
            index = end;
            continue;
        }
        out.push(chars[index]);
        index += 1;
    }
    out
}

/// `\d+(?:\.\d+)?\s?%` anchored at `start`; returns the end index.
fn percentage_match(chars: &[char], start: usize) -> Option<usize> {
    let mut index = start;
    while chars.get(index).is_some_and(char::is_ascii_digit) {
        index += 1;
    }
    if index == start {
        return None;
    }
    if chars.get(index) == Some(&'.') && chars.get(index + 1).is_some_and(char::is_ascii_digit) {
        index += 1;
        while chars.get(index).is_some_and(char::is_ascii_digit) {
            index += 1;
        }
    }
    if chars.get(index).is_some_and(|c| c.is_whitespace()) {
        index += 1;
    }
    (chars.get(index) == Some(&'%')).then_some(index + 1)
}

/// `POST /v1/byok/negotiation/:id/message` body validation.
pub fn validate_message(body: Option<&Value>) -> Option<String> {
    let raw = body?.get("message")?.as_str()?;
    let message = raw.trim();
    (!message.is_empty() && message.chars().count() <= MAXIMUM_MESSAGE_CHARACTERS)
        .then(|| message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::byok_pricing::{price_band, price_for_grants};

    fn band() -> PriceBand {
        price_band(|_| None)
    }

    #[test]
    fn plan_payload_reflects_the_cooldown() {
        let band = band();
        let open = plan_payload(&band, None, 1_000);
        assert_eq!(open["priceCents"], json!(1_200));
        assert_eq!(open["negotiable"], json!(true));
        assert_eq!(open["outcome"], Value::Null);
        assert_eq!(open["renegotiableAt"], Value::Null);

        let agreement = AgreedPrice {
            price_cents: 900,
            outcome: "negotiated".into(),
            agreed_at: 1_000,
        };
        let fresh = plan_payload(&band, Some(&agreement), 2_000);
        assert_eq!(fresh["priceCents"], json!(900));
        assert_eq!(fresh["negotiable"], json!(false));
        assert_eq!(fresh["renegotiableAt"], json!(1_000 + band.cooldown_ms));
        let later = plan_payload(&band, Some(&agreement), 1_000 + band.cooldown_ms);
        assert_eq!(later["negotiable"], json!(true));
    }

    #[test]
    fn a_stored_row_is_clamped_into_the_band_on_read() {
        let band = band();
        assert_eq!(clamp_agreement(&band, 1, "negotiated", 0).price_cents, 700);
        assert_eq!(
            clamp_agreement(&band, 99_999, "standard", 0).price_cents,
            1_200
        );
        assert_eq!(clamp_agreement(&band, 900, "weird", 0).outcome, "standard");
    }

    #[test]
    fn transcript_parsing_drops_foreign_roles_and_shapes() {
        let raw = json!(
            r#"[{"role":"user","content":"hi"},{"role":"system","content":"x"},{"role":"omi","content":"there"},{"role":"omi"},null,7]"#
        );
        assert_eq!(
            parse_transcript(Some(&raw)),
            vec![
                TranscriptEntry {
                    role: "user".into(),
                    content: "hi".into()
                },
                TranscriptEntry {
                    role: "omi".into(),
                    content: "there".into()
                },
            ]
        );
        assert!(parse_transcript(Some(&json!("nonsense"))).is_empty());
        assert!(parse_transcript(None).is_empty());
    }

    #[test]
    fn grants_a_concession_the_model_suggests_once() {
        let band = band();
        let raw = r#"Sure! {"reply":"That is fair.","concession":"student"}"#;
        let first = parse_suggestion(&band, &[], raw).unwrap();
        assert_eq!(first.concession.as_ref().unwrap().code, "student");
        let granted = vec!["student".to_string()];
        let second = parse_suggestion(&band, &granted, raw).unwrap();
        assert!(second.concession.is_none());
    }

    #[test]
    fn a_manipulated_model_reply_cannot_invent_a_lever_or_a_price() {
        let band = band();
        for raw in [
            r#"{"reply":"ok","concession":"free_forever"}"#,
            r#"{"reply":"ok","concession":{"code":"student","centsOff":1200}}"#,
            r#"{"reply":"ok","concession":99}"#,
        ] {
            let suggestion = parse_suggestion(&band, &[], raw).unwrap();
            assert!(suggestion.concession.is_none(), "should ignore {raw}");
            assert_eq!(price_for_grants(&band, &[]), band.standard_cents);
        }
        for raw in [
            "",
            "no json here",
            r#"{"reply":"   "}"#,
            r#"{"reply":7}"#,
            "}{",
        ] {
            assert!(
                parse_suggestion(&band, &[], raw).is_none(),
                "should reject {raw:?}"
            );
        }
    }

    #[test]
    fn a_reply_is_trimmed_and_bounded() {
        let band = band();
        let long = "a".repeat(2_000);
        let raw = format!(r#"{{"reply":"  {long}  "}}"#);
        let suggestion = parse_suggestion(&band, &[], &raw).unwrap();
        assert_eq!(suggestion.reply.chars().count(), MAXIMUM_MESSAGE_CHARACTERS);
    }

    #[test]
    fn sanitize_replaces_every_figure_the_model_slipped_in() {
        assert_eq!(
            sanitize_reply("I can do $5 or even $ 4.50 for you.", 900),
            "I can do $9.00 or even $9.00 for you."
        );
        assert_eq!(
            sanitize_reply("A 30% discount, 7.5 % off.", 900),
            "A a bit discount, a bit off."
        );
        assert_eq!(sanitize_reply("$1,299", 700), "$7.00");
        // Bare numbers that are neither prices nor percentages are untouched.
        assert_eq!(sanitize_reply("You get 3 seats.", 900), "You get 3 seats.");
        assert_eq!(sanitize_reply("", 900), "");
    }

    #[test]
    fn system_prompt_only_offers_ungranted_concessions() {
        let band = band();
        let prompt = system_prompt(&band, &["student".to_string()]);
        assert!(!prompt.contains("- student:"));
        assert!(prompt.contains("- case_study:"));
        let exhausted: Vec<String> = band
            .concessions
            .iter()
            .map(|c| c.code.to_string())
            .collect();
        assert!(system_prompt(&band, &exhausted).contains("(none left"));
    }

    #[test]
    fn message_validation_bounds_the_input() {
        assert_eq!(
            validate_message(Some(&json!({ "message": "  I am a student " }))).as_deref(),
            Some("I am a student")
        );
        for body in [
            json!({ "message": "   " }),
            json!({ "message": 7 }),
            json!({}),
            json!({ "message": "x".repeat(601) }),
        ] {
            assert!(
                validate_message(Some(&body)).is_none(),
                "should reject {body}"
            );
        }
        assert!(validate_message(None).is_none());
    }

    #[test]
    fn the_opening_line_quotes_the_standard_price() {
        let opening = opening_entry(&band());
        assert_eq!(opening.role, "omi");
        assert!(opening.content.contains("$12.00"));
    }
}
