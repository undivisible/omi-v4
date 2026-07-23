//! Pure port of the request-shaping, pricing, and usage-accounting logic in
//! `worker/src/assistant.ts`. The streaming proxy itself is I/O and lives in
//! the wasm glue (`routes_ai`); everything that decides *whether* and *how* a
//! request is forwarded, plus the cost/token math, is here and host-tested.

use serde_json::{Map, Value};
use url::Url;

use crate::jsnum::{is_safe_integer, number_from_str};

pub const MAXIMUM_BODY_BYTES: usize = 64 * 1024;
pub const MAXIMUM_MESSAGES: usize = 64;
pub const MAXIMUM_INPUT_CHARACTERS: usize = 32_000;
pub const MAXIMUM_OUTPUT_TOKENS: i64 = 4096;
pub const DEFAULT_OUTPUT_TOKENS: i64 = 1024;
pub const REQUEST_FRAMING_TOKEN_RESERVE: i64 = 64;
pub const MESSAGE_FRAMING_TOKEN_RESERVE: i64 = 16;
pub const STALE_REQUEST_MS: i64 = 120_000;
pub const WORKER_COMPLETION_MAX_OUTPUT_TOKENS: i64 = 1024;

pub const XIAOMI_COMPLETION_ENDPOINT: &str =
    "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions";
pub const XIAOMI_HOSTNAME: &str = "token-plan-sgp.xiaomimimo.com";

const ALLOWED_KEYS: &[&str] = &[
    "messages",
    "model",
    "stream",
    "max_tokens",
    "temperature",
    "top_p",
    "stream_options",
];

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub role: String,
    pub content: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CompletionRequest {
    pub model: String,
    pub messages: Vec<Message>,
    pub max_tokens: i64,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
}

/// Port of `validatePinnedEndpoint`. Returns the parsed URL only when the
/// candidate is byte-identical to the pinned endpoint and free of any
/// userinfo/query/fragment, on the expected host over https.
pub fn validate_pinned_endpoint(endpoint: &str, pinned: &str, hostname: &str) -> Option<Url> {
    if endpoint != pinned {
        return None;
    }
    let parsed = Url::parse(endpoint).ok()?;
    if parsed.as_str() != pinned
        || parsed.scheme() != "https"
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
        || parsed.host_str() != Some(hostname)
    {
        return None;
    }
    Some(parsed)
}

/// Port of `price`: a positive safe-integer micro-USD price, or `None`.
pub fn price(value: Option<&str>) -> Option<i64> {
    let raw = value?;
    let parsed = number_from_str(raw);
    if is_safe_integer(parsed) && parsed > 0.0 {
        Some(parsed as i64)
    } else {
        None
    }
}

/// Port of `costFor`: `ceil((in*inPrice + out*outPrice) / 1_000_000)`.
pub fn cost_for(input_tokens: i64, output_tokens: i64, input_price: i64, output_price: i64) -> i64 {
    let numerator =
        input_tokens as i128 * input_price as i128 + output_tokens as i128 * output_price as i128;
    let denom = 1_000_000i128;
    // ceil division for non-negative numerator.
    ((numerator + denom - 1) / denom) as i64
}

/// Port of `inputTokenReservation`: framing overhead plus UTF-8 byte lengths.
pub fn input_token_reservation(messages: &[Message]) -> i64 {
    messages.iter().fold(REQUEST_FRAMING_TOKEN_RESERVE, |total, m| {
        total + MESSAGE_FRAMING_TOKEN_RESERVE + m.role.len() as i64 + m.content.len() as i64
    })
}

fn object_keys_all_allowed(obj: &Map<String, Value>, allowed: &[&str]) -> bool {
    obj.keys().all(|k| allowed.contains(&k.as_str()))
}

/// Port of `parseRequest`. Validates the strict managed-completion contract and
/// returns the normalized request, or `None` for any deviation.
pub fn parse_request(body: &Value, model: &str) -> Option<CompletionRequest> {
    let obj = body.as_object()?;
    if !object_keys_all_allowed(obj, ALLOWED_KEYS) {
        return None;
    }
    if obj.get("model").and_then(Value::as_str) != Some(model) {
        return None;
    }
    if obj.get("stream") != Some(&Value::Bool(true)) {
        return None;
    }
    let messages_val = obj.get("messages")?.as_array()?;
    if messages_val.len() > MAXIMUM_MESSAGES {
        return None;
    }
    let mut messages = Vec::with_capacity(messages_val.len());
    let mut input_characters = 0usize;
    for candidate in messages_val {
        let value = candidate.as_object()?;
        if value
            .keys()
            .any(|k| k != "role" && k != "content")
        {
            return None;
        }
        let role = value.get("role").and_then(Value::as_str)?;
        if role != "assistant" && role != "system" && role != "user" {
            return None;
        }
        let content = value.get("content").and_then(Value::as_str)?;
        if content.is_empty() {
            return None;
        }
        input_characters += content.encode_utf16().count();
        if input_characters > MAXIMUM_INPUT_CHARACTERS {
            return None;
        }
        messages.push(Message {
            role: role.to_string(),
            content: content.to_string(),
        });
    }
    if messages.is_empty() {
        return None;
    }
    let stream_options = obj.get("stream_options")?.as_object()?;
    if stream_options.len() != 1
        || stream_options.get("include_usage") != Some(&Value::Bool(true))
    {
        return None;
    }
    let max_tokens = match obj.get("max_tokens") {
        None => DEFAULT_OUTPUT_TOKENS,
        Some(v) => {
            let n = crate::jsnum::number_from_value(v);
            if !is_safe_integer(n) {
                return None;
            }
            n as i64
        }
    };
    if !(1..=MAXIMUM_OUTPUT_TOKENS).contains(&max_tokens) {
        return None;
    }
    let temperature = match obj.get("temperature") {
        None => None,
        Some(v) => {
            let n = v.as_f64()?;
            if !(0.0..=2.0).contains(&n) {
                return None;
            }
            Some(n)
        }
    };
    let top_p = match obj.get("top_p") {
        None => None,
        Some(v) => {
            let n = v.as_f64()?;
            if n <= 0.0 || n > 1.0 {
                return None;
            }
            Some(n)
        }
    };
    Some(CompletionRequest {
        model: model.to_string(),
        messages,
        max_tokens,
        temperature,
        top_p,
    })
}

/// The upstream body sent for a parsed managed request: the request plus the
/// forced `stream_options.include_usage`.
pub fn upstream_body(request: &CompletionRequest) -> Value {
    let mut messages = Vec::with_capacity(request.messages.len());
    for m in &request.messages {
        messages.push(serde_json::json!({ "role": m.role, "content": m.content }));
    }
    let mut body = serde_json::json!({
        "model": request.model,
        "messages": messages,
        "stream": true,
        "max_tokens": request.max_tokens,
        "stream_options": { "include_usage": true },
    });
    let obj = body.as_object_mut().unwrap();
    if let Some(t) = request.temperature {
        obj.insert("temperature".into(), serde_json::json!(t));
    }
    if let Some(p) = request.top_p {
        obj.insert("top_p".into(), serde_json::json!(p));
    }
    body
}

/// Port of `usageFrom`: scan SSE `data:` lines for the last valid
/// `usage.prompt_tokens` / `usage.completion_tokens` non-negative safe ints.
pub fn usage_from(text: &str) -> (Option<i64>, Option<i64>) {
    let mut input_tokens = None;
    let mut output_tokens = None;
    for line in text.split('\n') {
        if !line.starts_with("data: ") || line == "data: [DONE]" {
            continue;
        }
        let Ok(value) = serde_json::from_str::<Value>(&line[6..]) else {
            continue;
        };
        if let Some(usage) = value.get("usage") {
            if let Some(pt) = usage.get("prompt_tokens").and_then(Value::as_f64) {
                if is_safe_integer(pt) && pt >= 0.0 {
                    input_tokens = Some(pt as i64);
                }
            }
            if let Some(ct) = usage.get("completion_tokens").and_then(Value::as_f64) {
                if is_safe_integer(ct) && ct >= 0.0 {
                    output_tokens = Some(ct as i64);
                }
            }
        }
    }
    (input_tokens, output_tokens)
}

/// Port of the non-streaming inbox completion's response parse: the trimmed
/// first-choice content plus bounded usage.
pub fn parse_completion(value: &Value) -> (Option<String>, Option<i64>, Option<i64>) {
    let content = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string);
    let (input_tokens, output_tokens) = match value.get("usage") {
        Some(usage) => {
            let pt = usage
                .get("prompt_tokens")
                .and_then(Value::as_f64)
                .filter(|n| is_safe_integer(*n) && *n >= 0.0)
                .map(|n| n as i64);
            let ct = usage
                .get("completion_tokens")
                .and_then(Value::as_f64)
                .filter(|n| is_safe_integer(*n) && *n >= 0.0)
                .map(|n| n as i64);
            (pt, ct)
        }
        None => (None, None),
    };
    (content, input_tokens, output_tokens)
}

/// Port of `boundedJson` operating on the already-buffered bytes plus the
/// declared `content-length`. Returns the object, or `None` when the body is
/// oversized, missing, or not a JSON object.
pub fn bounded_json(
    declared_content_length: Option<&str>,
    body: Option<&[u8]>,
    limit: usize,
) -> Option<Value> {
    if let Some(declared) = declared_content_length {
        let n = number_from_str(declared);
        if n.is_finite() && n > limit as f64 {
            return None;
        }
    }
    let bytes = body?;
    if bytes.len() > limit {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    let parsed: Value = serde_json::from_str(text).ok()?;
    if parsed.is_object() {
        Some(parsed)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn valid() -> Value {
        json!({
            "model": "mimo-v2.5-pro",
            "messages": [{ "role": "user", "content": "Remember this safely." }],
            "stream": true,
            "max_tokens": 256,
            "stream_options": { "include_usage": true }
        })
    }

    #[test]
    fn price_matches_js() {
        assert_eq!(price(Some("435000")), Some(435000));
        for invalid in [None, Some(""), Some("0"), Some("-1"), Some("1.5"), Some("NaN")] {
            assert_eq!(price(invalid), None);
        }
    }

    #[test]
    fn validates_and_rejects_non_canonical_endpoints() {
        assert!(validate_pinned_endpoint(
            XIAOMI_COMPLETION_ENDPOINT,
            XIAOMI_COMPLETION_ENDPOINT,
            XIAOMI_HOSTNAME
        )
        .is_some());
        for endpoint in [
            "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions?debug=1",
            "https://user@token-plan-sgp.xiaomimimo.com/v1/chat/completions",
            "https://127.0.0.1/v1/chat/completions",
            "https://token-plan-sgp.xiaomimimo.com.evil.test/v1/chat/completions",
        ] {
            assert!(
                validate_pinned_endpoint(endpoint, XIAOMI_COMPLETION_ENDPOINT, XIAOMI_HOSTNAME)
                    .is_none(),
                "should reject {endpoint}"
            );
        }
    }

    #[test]
    fn parses_the_captured_streaming_shape_and_defaults_max_tokens() {
        let body = json!({
            "model": "mimo-v2.5-pro",
            "messages": [{ "role": "user", "content": "hello" }],
            "stream": true,
            "stream_options": { "include_usage": true }
        });
        let parsed = parse_request(&body, "mimo-v2.5-pro").unwrap();
        assert_eq!(parsed.max_tokens, DEFAULT_OUTPUT_TOKENS);
        let upstream = upstream_body(&parsed);
        assert_eq!(upstream["max_tokens"], json!(1024));
        assert_eq!(upstream["stream_options"]["include_usage"], json!(true));
    }

    #[test]
    fn reserves_framing_for_64_tiny_messages() {
        let messages: Vec<Message> = (0..64)
            .map(|_| Message {
                role: "user".into(),
                content: "x".into(),
            })
            .collect();
        // 64 * (16 + 4 + 1) + 64 = 1408, plus max_tokens 1 = 1409.
        assert_eq!(input_token_reservation(&messages), 1408);
        assert_eq!(input_token_reservation(&messages) + 1, 1409);
    }

    #[test]
    fn rejects_byok_unknown_model_non_streaming_and_excess() {
        let base = valid();
        let mut with_api_key = base.as_object().unwrap().clone();
        with_api_key.insert("api_key".into(), json!("user-key"));
        assert!(parse_request(&Value::Object(with_api_key), "mimo-v2.5-pro").is_none());

        let mut base_url = base.as_object().unwrap().clone();
        base_url.insert("base_url".into(), json!("https://user.example"));
        assert!(parse_request(&Value::Object(base_url), "mimo-v2.5-pro").is_none());

        let mut other_model = base.as_object().unwrap().clone();
        other_model.insert("model".into(), json!("other"));
        assert!(parse_request(&Value::Object(other_model), "mimo-v2.5-pro").is_none());

        let mut not_stream = base.as_object().unwrap().clone();
        not_stream.insert("stream".into(), json!(false));
        assert!(parse_request(&Value::Object(not_stream), "mimo-v2.5-pro").is_none());

        let mut too_many = base.as_object().unwrap().clone();
        too_many.insert("max_tokens".into(), json!(4097));
        assert!(parse_request(&Value::Object(too_many), "mimo-v2.5-pro").is_none());

        let mut no_usage = base.as_object().unwrap().clone();
        no_usage.insert("stream_options".into(), json!({ "include_usage": false }));
        assert!(parse_request(&Value::Object(no_usage), "mimo-v2.5-pro").is_none());

        let mut extra_opt = base.as_object().unwrap().clone();
        extra_opt.insert(
            "stream_options".into(),
            json!({ "include_usage": true, "extra": true }),
        );
        assert!(parse_request(&Value::Object(extra_opt), "mimo-v2.5-pro").is_none());

        let mut tool_role = base.as_object().unwrap().clone();
        tool_role.insert("messages".into(), json!([{ "role": "tool", "content": "unsafe" }]));
        assert!(parse_request(&Value::Object(tool_role), "mimo-v2.5-pro").is_none());
    }

    #[test]
    fn usage_and_cost_accounting() {
        let (input, output) = usage_from(
            "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: {\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n",
        );
        assert_eq!(input, Some(7));
        assert_eq!(output, Some(2));
        // With 1_000_000 micro-USD/M-token prices: ceil((7+2)/1) micro = 9.
        assert_eq!(cost_for(7, 2, 1_000_000, 1_000_000), 9);
        // estimated_cost for the streaming test: reservation(256 max) with
        // input reservation for "Remember this safely." (21 bytes) + framing.
        let messages = vec![Message {
            role: "user".into(),
            content: "Remember this safely.".into(),
        }];
        let est_input = input_token_reservation(&messages);
        // 64 + 16 + 4 + 21 = 105.
        assert_eq!(est_input, 105);
        assert_eq!(cost_for(est_input, 256, 1_000_000, 1_000_000), 361);
    }

    #[test]
    fn bounded_json_enforces_limits() {
        assert_eq!(
            bounded_json(Some("2"), Some(b"{}"), MAXIMUM_BODY_BYTES),
            Some(json!({}))
        );
        assert_eq!(bounded_json(Some("999999999"), Some(b"{}"), 4), None);
        assert_eq!(bounded_json(None, Some(b"[1,2]"), MAXIMUM_BODY_BYTES), None);
        assert_eq!(bounded_json(None, Some(b"not json"), MAXIMUM_BODY_BYTES), None);
        assert_eq!(bounded_json(None, None, MAXIMUM_BODY_BYTES), None);
    }
}
