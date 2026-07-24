//! Provider-hosted web search for the SEARCH tier, spoken directly rather than
//! through `rs_ai`.
//!
//! `rs_ai` cannot express a hosted provider tool. `chatgpt()` and `xai()` both
//! resolve to `rs_ai_providers::openai_compatible`, whose request URL is
//! `format!("{base}/chat/completions")` (`openai_compatible/model.rs`) and whose
//! tool conversion writes `tool_type: "function"` unconditionally
//! (`openai_compatible/convert.rs`), with no passthrough for a foreign tool
//! shape. `{"type": "web_search"}` is therefore unemittable through that crate,
//! and its stream parser reads only the text delta and the tool-call delta, so
//! the `url_citation` annotations that carry the sources are discarded before
//! they reach us.
//!
//! Both OpenAI and xAI host the same `web_search` tool on their Responses API
//! (`POST /v1/responses`), so the SEARCH tier for those two providers is
//! dispatched here instead: one streaming HTTPS request, an SSE reader, and a
//! citation collector. The managed worker's SEARCH tier speaks OpenAI-shaped
//! chat completions against `perplexity/sonar`, which returns its sources in
//! the same `url_citation` annotation shape (plus Perplexity's top-level
//! `citations` array), so it reads through the same collector.
//!
//! Citations are surfaced, never dropped: OpenAI's web-search documentation
//! requires that "inline citations must be made clearly visible and clickable
//! in your user interface", so every collected source is emitted as a trailing
//! Markdown link list on the same stream as the answer.

use std::collections::BTreeMap;
use std::time::Duration;

use serde_json::{Value, json};

/// Where a SEARCH-tier turn is dispatched, and in which request shape.
#[derive(Clone, Eq, PartialEq)]
pub(crate) enum SearchBackend {
    /// OpenAI's Responses API with the hosted `web_search` tool.
    OpenAiResponses,
    /// xAI's Responses API with the hosted `web_search` tool.
    XaiResponses,
    /// OpenAI's ChatGPT-subscription Codex Responses endpoint, authenticated by
    /// an OAuth bearer rather than an API key. Chat Completions is retired for
    /// this surface, so it is the transport for every tier on the OAuth path,
    /// not just SEARCH — `web_search` toggles the hosted tool for the SEARCH
    /// tier while the same request shape carries plain turns for the rest.
    /// `account_id` is the `chatgpt-account-id` header the endpoint requires,
    /// decoded from the bearer's own JWT claims.
    CodexResponses {
        base_url: String,
        account_id: Option<String>,
        web_search: bool,
    },
    /// The managed worker's OpenAI-shaped chat completions, which resolve the
    /// SEARCH tier to Perplexity Sonar server-side.
    ManagedChat { endpoint: String },
}

impl SearchBackend {
    fn url(&self) -> String {
        match self {
            Self::OpenAiResponses => "https://api.openai.com/v1/responses".to_owned(),
            Self::XaiResponses => "https://api.x.ai/v1/responses".to_owned(),
            Self::CodexResponses { base_url, .. } => {
                format!("{}/responses", base_url.trim_end_matches('/'))
            }
            Self::ManagedChat { endpoint } => {
                format!("{}/chat/completions", endpoint.trim_end_matches('/'))
            }
        }
    }

    fn body(&self, model: &str, prompt: &str) -> Value {
        match self {
            Self::OpenAiResponses | Self::XaiResponses => json!({
                "model": model,
                "input": prompt,
                "tools": [{"type": "web_search"}],
                "stream": true,
            }),
            Self::CodexResponses { web_search, .. } => {
                let mut body = json!({
                    "model": model,
                    "input": prompt,
                    "stream": true,
                    // The Codex surface rejects server-side response storage for
                    // subscription bearers; Zed sends `store: false` on every
                    // turn (openai_subscribed.rs) and so do we.
                    "store": false,
                });
                if *web_search {
                    body["tools"] = json!([{"type": "web_search"}]);
                }
                body
            }
            Self::ManagedChat { .. } => json!({
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "stream": true,
                "max_tokens": 1024,
                // The managed worker's completions route requires the usage
                // request shape it validates every managed turn against.
                "stream_options": {"include_usage": true},
            }),
        }
    }

    /// Extra request headers this backend needs beyond bearer auth. The Codex
    /// Responses endpoint requires the Codex originator, the Responses beta
    /// opt-in, and the account id; everything else needs none.
    fn extra_headers(&self) -> Vec<(&'static str, String)> {
        match self {
            Self::CodexResponses { account_id, .. } => {
                let mut headers = vec![
                    ("originator", "omi".to_owned()),
                    ("openai-beta", "responses=experimental".to_owned()),
                ];
                if let Some(id) = account_id.as_deref().filter(|id| !id.is_empty()) {
                    headers.push(("chatgpt-account-id", id.to_owned()));
                }
                headers
            }
            _ => Vec::new(),
        }
    }
}

/// Reads the `chatgpt_account_id` claim out of an OAuth bearer JWT so the Codex
/// endpoint can be addressed without plumbing the id separately. Mirrors Zed's
/// `extract_jwt_claims`: the claim sits either at the top level or inside the
/// `https://api.openai.com/auth` namespaced object. Returns `None` for a token
/// that is not a JWT or carries no such claim.
pub(crate) fn account_id_from_bearer(bearer: &str) -> Option<String> {
    use base64::Engine as _;
    let payload = bearer.split('.').nth(1)?;
    let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(payload)
        .ok()?;
    let claims: Value = serde_json::from_slice(&decoded).ok()?;
    let direct = claims
        .get("chatgpt_account_id")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty());
    if let Some(id) = direct {
        return Some(id.to_owned());
    }
    claims
        .get("https://api.openai.com/auth")
        .and_then(|auth| auth.get("chatgpt_account_id"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

/// Collects `url_citation` annotations out of whatever event shape the provider
/// happens to use.
///
/// The Responses API reports them on `response.output_text.annotation.added`
/// and again inside the completed response; chat completions carry them on the
/// message delta; Perplexity additionally sends a bare `citations` array of
/// URLs. Rather than encode three schemas, this walks each event object and
/// takes every `{"type": "url_citation", "url": ..}` it finds, plus any
/// top-level `citations` array of strings. De-duplication is by URL, and the
/// first title seen for a URL wins.
#[derive(Default)]
struct Citations {
    seen: BTreeMap<String, String>,
    order: Vec<String>,
}

impl Citations {
    fn record(&mut self, url: &str, title: Option<&str>) {
        let url = url.trim();
        if url.is_empty() || !url.starts_with("https://") && !url.starts_with("http://") {
            return;
        }
        let title = title.map(str::trim).filter(|value| !value.is_empty());
        if let Some(existing) = self.seen.get_mut(url) {
            if existing.is_empty()
                && let Some(title) = title
            {
                *existing = title.to_owned();
            }
            return;
        }
        self.seen
            .insert(url.to_owned(), title.unwrap_or_default().to_owned());
        self.order.push(url.to_owned());
    }

    fn absorb(&mut self, event: &Value) {
        if let Some(list) = event.get("citations").and_then(Value::as_array) {
            for entry in list {
                match entry {
                    Value::String(url) => self.record(url, None),
                    Value::Object(_) => {
                        if let Some(url) = entry.get("url").and_then(Value::as_str) {
                            self.record(url, entry.get("title").and_then(Value::as_str));
                        }
                    }
                    _ => {}
                }
            }
        }
        self.walk(event);
    }

    fn walk(&mut self, value: &Value) {
        match value {
            Value::Object(map) => {
                if map.get("type").and_then(Value::as_str) == Some("url_citation") {
                    // Responses API carries the fields on the annotation itself;
                    // chat completions nest them under a `url_citation` object.
                    let source = map.get("url_citation").and_then(Value::as_object);
                    let url = map
                        .get("url")
                        .or_else(|| source.and_then(|inner| inner.get("url")))
                        .and_then(Value::as_str);
                    if let Some(url) = url {
                        let title = map
                            .get("title")
                            .or_else(|| source.and_then(|inner| inner.get("title")))
                            .and_then(Value::as_str);
                        self.record(url, title);
                    }
                }
                for nested in map.values() {
                    self.walk(nested);
                }
            }
            Value::Array(items) => {
                for nested in items {
                    self.walk(nested);
                }
            }
            _ => {}
        }
    }

    /// The trailing Markdown block, empty when the answer was not grounded.
    fn block(&self) -> String {
        if self.order.is_empty() {
            return String::new();
        }
        let mut block = String::from("\n\nSources:\n");
        for (index, url) in self.order.iter().enumerate() {
            let title = self.seen.get(url).map(String::as_str).unwrap_or_default();
            let label = if title.is_empty() {
                url.as_str()
            } else {
                title
            };
            block.push_str(&format!("{}. [{}]({})\n", index + 1, label, url));
        }
        block
    }
}

/// The text a single SSE event contributes to the answer.
fn text_delta(event: &Value) -> Option<&str> {
    // Responses API: `{"type": "response.output_text.delta", "delta": "…"}`.
    if event.get("type").and_then(Value::as_str) == Some("response.output_text.delta") {
        return event.get("delta").and_then(Value::as_str);
    }
    // Chat completions: `{"choices": [{"delta": {"content": "…"}}]}`.
    event
        .get("choices")?
        .as_array()?
        .first()?
        .get("delta")?
        .get("content")?
        .as_str()
}

/// What the reader produced from one SSE line.
enum Chunk {
    Text(String),
    Done,
    Ignored,
}

fn read_event(line: &str, citations: &mut Citations) -> Chunk {
    let Some(payload) = line.strip_prefix("data:") else {
        return Chunk::Ignored;
    };
    let payload = payload.trim();
    if payload == "[DONE]" {
        return Chunk::Done;
    }
    let Ok(event) = serde_json::from_str::<Value>(payload) else {
        return Chunk::Ignored;
    };
    citations.absorb(&event);
    match text_delta(&event) {
        Some(delta) if !delta.is_empty() => Chunk::Text(delta.to_owned()),
        _ => Chunk::Ignored,
    }
}

/// The answer to a SEARCH-tier turn: the streamed text, then the sources.
pub(crate) struct SearchStream {
    response: reqwest::Response,
    buffer: String,
    citations: Citations,
    trailer: Option<String>,
    finished: bool,
}

/// Opens a grounded turn against `backend`.
pub(crate) async fn dispatch(
    backend: &SearchBackend,
    model: &str,
    credential: &str,
    prompt: &str,
    connect_timeout: Duration,
) -> Result<SearchStream, String> {
    let client = reqwest::Client::builder()
        .timeout(connect_timeout)
        .build()
        .map_err(|_| "assistant provider connection failed".to_owned())?;
    let mut request = client
        .post(backend.url())
        .bearer_auth(credential)
        .header("accept", "text/event-stream");
    for (name, value) in backend.extra_headers() {
        request = request.header(name, value);
    }
    let response = request
        .json(&backend.body(model, prompt))
        .send()
        .await
        .map_err(|_| "assistant provider connection failed".to_owned())?;
    if !response.status().is_success() {
        return Err("assistant provider stream failed".to_owned());
    }
    Ok(SearchStream {
        response,
        buffer: String::new(),
        citations: Citations::default(),
        trailer: None,
        finished: false,
    })
}

impl SearchStream {
    /// The next piece of answer text, `None` once the sources have been
    /// emitted and the turn is over.
    pub(crate) async fn next(&mut self) -> Option<Result<String, String>> {
        loop {
            if let Some(trailer) = self.trailer.take() {
                self.finished = true;
                return Some(Ok(trailer));
            }
            if self.finished {
                return None;
            }
            while let Some(index) = self.buffer.find('\n') {
                let line: String = self.buffer.drain(..=index).collect();
                match read_event(line.trim_end(), &mut self.citations) {
                    Chunk::Text(delta) => return Some(Ok(delta)),
                    Chunk::Done => {
                        self.trailer = Some(self.citations.block());
                        break;
                    }
                    Chunk::Ignored => {}
                }
            }
            if self.trailer.is_some() {
                continue;
            }
            match self.response.chunk().await {
                Ok(Some(bytes)) => match std::str::from_utf8(&bytes) {
                    Ok(text) => self.buffer.push_str(text),
                    Err(_) => {
                        self.finished = true;
                        return Some(Err("assistant provider stream failed".to_owned()));
                    }
                },
                Ok(None) => {
                    self.trailer = Some(self.citations.block());
                }
                Err(_) => {
                    self.finished = true;
                    return Some(Err("assistant provider stream failed".to_owned()));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn responses_api_carries_the_hosted_web_search_tool() {
        let body = SearchBackend::OpenAiResponses.body("gpt-5.6-terra", "who won");
        assert_eq!(body["tools"][0]["type"], "web_search");
        assert_eq!(body["stream"], true);
        assert_eq!(
            SearchBackend::OpenAiResponses.url(),
            "https://api.openai.com/v1/responses"
        );
        assert_eq!(
            SearchBackend::XaiResponses.url(),
            "https://api.x.ai/v1/responses"
        );
    }

    #[test]
    fn codex_responses_targets_the_oauth_base_and_toggles_web_search() {
        let backend = SearchBackend::CodexResponses {
            base_url: "https://chatgpt.com/backend-api/codex".to_owned(),
            account_id: Some("acct_123".to_owned()),
            web_search: true,
        };
        assert_eq!(
            backend.url(),
            "https://chatgpt.com/backend-api/codex/responses"
        );
        let body = backend.body("gpt-5.6-terra", "who won");
        assert_eq!(body["tools"][0]["type"], "web_search");
        assert_eq!(body["store"], false);
        assert_eq!(body["input"], "who won");
        let headers = backend.extra_headers();
        assert!(headers.contains(&("openai-beta", "responses=experimental".to_owned())));
        assert!(headers.contains(&("chatgpt-account-id", "acct_123".to_owned())));

        // A plain (non-search) tier keeps the Responses shape without the tool.
        let chat = SearchBackend::CodexResponses {
            base_url: "https://chatgpt.com/backend-api/codex".to_owned(),
            account_id: None,
            web_search: false,
        };
        assert!(chat.body("gpt-5.6-terra", "hi").get("tools").is_none());
        assert!(
            !chat
                .extra_headers()
                .iter()
                .any(|(name, _)| *name == "chatgpt-account-id")
        );
    }

    #[test]
    fn account_id_is_decoded_from_the_bearer_jwt() {
        use base64::Engine as _;
        let engine = base64::engine::general_purpose::URL_SAFE_NO_PAD;
        let header = engine.encode(br#"{"alg":"none"}"#);
        let top = engine.encode(br#"{"chatgpt_account_id":"acct_top"}"#);
        assert_eq!(
            account_id_from_bearer(&format!("{header}.{top}.sig")),
            Some("acct_top".to_owned())
        );
        let nested = engine
            .encode(br#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct_nested"}}"#);
        assert_eq!(
            account_id_from_bearer(&format!("{header}.{nested}.sig")),
            Some("acct_nested".to_owned())
        );
        assert_eq!(account_id_from_bearer("not-a-jwt"), None);
    }

    #[test]
    fn managed_search_speaks_chat_completions() {
        let backend = SearchBackend::ManagedChat {
            endpoint: "https://worker.example/v1".to_owned(),
        };
        assert_eq!(backend.url(), "https://worker.example/v1/chat/completions");
        let body = backend.body("perplexity/sonar", "who won");
        assert_eq!(body["messages"][0]["content"], "who won");
        assert_eq!(body["stream_options"]["include_usage"], true);
        assert!(body.get("tools").is_none());
    }

    #[test]
    fn response_text_deltas_are_read_in_both_shapes() {
        let mut citations = Citations::default();
        let responses = r#"data: {"type":"response.output_text.delta","delta":"hello"}"#;
        assert!(matches!(
            read_event(responses, &mut citations),
            Chunk::Text(delta) if delta == "hello"
        ));
        let chat = r#"data: {"choices":[{"delta":{"content":"hi"}}]}"#;
        assert!(matches!(
            read_event(chat, &mut citations),
            Chunk::Text(delta) if delta == "hi"
        ));
        assert!(matches!(
            read_event("data: [DONE]", &mut citations),
            Chunk::Done
        ));
        assert!(matches!(
            read_event(": ping", &mut citations),
            Chunk::Ignored
        ));
    }

    #[test]
    fn url_citations_survive_every_shape_the_providers_use() {
        let mut citations = Citations::default();
        // Responses API annotation event.
        citations.absorb(&json!({
            "type": "response.output_text.annotation.added",
            "annotation": {"type": "url_citation", "url": "https://a.example", "title": "A"}
        }));
        // Chat-completions message annotations.
        citations.absorb(&json!({
            "choices": [{"delta": {"annotations": [
                {"type": "url_citation", "url_citation": {"url": "https://b.example"}}
            ]}}]
        }));
        // Perplexity's bare citation list.
        citations.absorb(&json!({"citations": ["https://c.example"]}));
        // The same source arriving again does not repeat.
        citations.absorb(&json!({
            "annotation": {"type": "url_citation", "url": "https://a.example", "title": "A"}
        }));
        let block = citations.block();
        assert!(block.starts_with("\n\nSources:\n"));
        assert!(block.contains("1. [A](https://a.example)"));
        assert!(block.contains("2. [https://b.example](https://b.example)"));
        assert!(block.contains("3. [https://c.example](https://c.example)"));
        assert_eq!(
            block
                .lines()
                .filter(|line| line.contains("a.example"))
                .count(),
            1
        );
    }

    #[test]
    fn an_ungrounded_answer_gets_no_sources_block() {
        assert!(Citations::default().block().is_empty());
    }

    #[test]
    fn a_citation_that_is_not_a_web_url_is_refused() {
        let mut citations = Citations::default();
        citations.absorb(&json!({"citations": ["javascript:alert(1)", "", "  "]}));
        assert!(citations.block().is_empty());
    }
}
