use serde_json::json;
use url::Url;

pub struct SentryEnvelope {
    pub endpoint: String,
    pub body: String,
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
    use super::sentry_envelope;
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
}
