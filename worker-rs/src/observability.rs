use serde_json::json;
use url::Url;

pub struct SentryEnvelope {
    pub endpoint: String,
    pub body: String,
}

#[allow(clippy::too_many_arguments)]
pub fn foglamp_trace(
    trace_id: &str,
    name: &str,
    provider: &str,
    model: &str,
    start_time: i64,
    end_time: i64,
    status: &str,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    environment: &str,
) -> serde_json::Value {
    let mut usage = serde_json::Map::new();
    if let Some(value) = input_tokens.filter(|value| *value >= 0) {
        usage.insert("inputTokens".into(), json!(value));
    }
    if let Some(value) = output_tokens.filter(|value| *value >= 0) {
        usage.insert("outputTokens".into(), json!(value));
    }
    if let (Some(input), Some(output)) = (input_tokens, output_tokens) {
        if input >= 0 && output >= 0 {
            usage.insert("totalTokens".into(), json!(input + output));
        }
    }
    let mut span = json!({
        "spanId": format!("{trace_id}-llm"),
        "spanType": "llm",
        "name": name,
        "startTime": start_time,
        "endTime": end_time.max(start_time),
        "status": status,
        "provider": provider,
        "modelId": model,
        "metadata": { "environment": environment },
    });
    if !usage.is_empty() {
        span["usage"] = serde_json::Value::Object(usage);
    }
    json!({
        "version": "v1",
        "traces": [{
            "traceId": trace_id,
            "traceName": name,
            "metadata": { "environment": environment },
            "spans": [span],
        }],
    })
}

pub fn sentry_envelope(
    dsn: &str,
    environment: &str,
    release: Option<&str>,
    error: &str,
) -> Option<SentryEnvelope> {
    let mut endpoint = Url::parse(dsn).ok()?;
    if !matches!(endpoint.scheme(), "http" | "https") || endpoint.username().is_empty() {
        return None;
    }

    let mut segments = endpoint
        .path_segments()?
        .filter(|segment| !segment.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    let project = segments.pop()?;
    if project.is_empty() {
        return None;
    }

    let prefix = if segments.is_empty() {
        String::new()
    } else {
        format!("{}/", segments.join("/"))
    };
    let public_key = endpoint.username().to_string();
    endpoint.set_username("").ok()?;
    endpoint.set_password(None).ok()?;
    endpoint.set_path(&format!("/{prefix}api/{project}/envelope/"));
    {
        let mut query = endpoint.query_pairs_mut();
        query.clear();
        query.append_pair("sentry_key", &public_key);
        query.append_pair("sentry_version", "7");
    }

    let mut event = json!({
        "environment": environment,
        "exception": { "values": [{ "type": "Error", "value": error }] },
        "level": "error",
        "platform": "rust",
    });
    if let Some(release) = release.filter(|release| !release.is_empty()) {
        event["release"] = json!(release);
    }

    Some(SentryEnvelope {
        endpoint: endpoint.into(),
        body: format!(
            "{}\n{}\n{}\n",
            json!({ "dsn": dsn, "sdk": { "name": "omi-v4-api-rs", "version": "0.1.0" } }),
            json!({ "content_type": "application/json", "type": "event" }),
            event,
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::{foglamp_trace, sentry_envelope};
    use serde_json::Value;

    #[test]
    fn builds_a_sentry_envelope_without_request_data() {
        let envelope = sentry_envelope(
            "https://public@example.ingest.betterstack.com/42",
            "production",
            Some("abc123"),
            "database failed",
        )
        .expect("valid DSN");

        assert_eq!(
            envelope.endpoint,
            "https://example.ingest.betterstack.com/api/42/envelope/?sentry_key=public&sentry_version=7"
        );
        let mut lines = envelope.body.lines();
        let header: Value = serde_json::from_str(lines.next().expect("header")).expect("JSON");
        let item: Value = serde_json::from_str(lines.next().expect("item")).expect("JSON");
        let event: Value = serde_json::from_str(lines.next().expect("event")).expect("JSON");
        assert_eq!(
            header["dsn"],
            "https://public@example.ingest.betterstack.com/42"
        );
        assert_eq!(item["type"], "event");
        assert_eq!(event["release"], "abc123");
        assert!(event.get("request").is_none());
    }

    #[test]
    fn preserves_a_dsn_path_prefix() {
        let envelope = sentry_envelope(
            "https://public@example.com/sentry/42",
            "development",
            None,
            "failed",
        )
        .expect("valid DSN");

        assert_eq!(
            envelope.endpoint,
            "https://example.com/sentry/api/42/envelope/?sentry_key=public&sentry_version=7"
        );
    }

    #[test]
    fn rejects_dsns_without_a_public_key_or_project() {
        assert!(sentry_envelope("https://example.com/42", "production", None, "failed").is_none());
        assert!(
            sentry_envelope("https://public@example.com/", "production", None, "failed").is_none()
        );
    }

    #[test]
    fn builds_a_private_foglamp_trace() {
        let trace = foglamp_trace(
            "request-1",
            "managed-chat",
            "openrouter",
            "perplexity/sonar",
            100,
            125,
            "ok",
            Some(10),
            Some(5),
            "production",
        );

        assert_eq!(trace["version"], "v1");
        assert_eq!(trace["traces"][0]["spans"][0]["usage"]["totalTokens"], 15);
        assert!(trace["traces"][0]["spans"][0].get("input").is_none());
        assert!(trace["traces"][0]["spans"][0].get("output").is_none());
    }
}
