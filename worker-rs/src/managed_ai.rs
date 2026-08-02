//! Pure port of the request-shaping, pricing, and usage-accounting logic in
//! `worker/src/assistant.ts`. Tier defaults are generated from
//! `config/model-tiers.json` via `scripts/sync-model-tiers.ts`.

use serde_json::{Map, Value};
use url::Url;

use crate::jsnum::{is_safe_integer, number_from_str};

pub const MAXIMUM_BODY_BYTES: usize = 64 * 1024;
pub const MAXIMUM_MESSAGES: usize = 64;
pub const MAXIMUM_INPUT_CHARACTERS: usize = 32_000;
pub const MAXIMUM_OUTPUT_TOKENS: i64 = 4096;
pub const DEFAULT_OUTPUT_TOKENS: i64 = 1024;
/// How many tools one managed request may put in front of a model. The hub's
/// whole catalogue is five; the cap exists so an arbitrary client cannot spend
/// this user's context on a tool list.
pub const MAXIMUM_TOOLS: usize = 16;
pub const REQUEST_FRAMING_TOKEN_RESERVE: i64 = 64;
pub const MESSAGE_FRAMING_TOKEN_RESERVE: i64 = 16;
pub const STALE_REQUEST_MS: i64 = 120_000;
pub const WORKER_COMPLETION_MAX_OUTPUT_TOKENS: i64 = 1024;

pub const XIAOMI_COMPLETION_ENDPOINT: &str =
    "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions";
pub const XIAOMI_HOSTNAME: &str = "token-plan-sgp.xiaomimimo.com";
pub const OPENROUTER_COMPLETION_ENDPOINT: &str = "https://openrouter.ai/api/v1/chat/completions";
pub const OPENROUTER_HOSTNAME: &str = "openrouter.ai";

/// Which managed tier a completion request is forwarded on. The BALANCED tier
/// is pinned to the MiMo endpoint; the SEARCH tier is pinned to OpenRouter,
/// which resolves the search model (perplexity/sonar) and returns its sources
/// as `url_citation` annotations the client surfaces. A request whose model is
/// neither tier's model is rejected.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ManagedCompletionTier {
    Balanced,
    Search,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AiGatewayRoute {
    pub url: String,
    pub token: Option<String>,
}

/// The provider the AI Gateway compat endpoint routes to when the model id
/// does not already name one. Overridable with `CF_AI_GATEWAY_PROVIDER`.
pub const DEFAULT_GATEWAY_PROVIDER: &str = "openrouter";

/// The model id as the AI Gateway compat endpoint wants it: `provider/model`.
///
/// This is the difference between the compat endpoint and a provider-specific
/// one. `/openrouter/v1/chat/completions` is already scoped to a provider, so a
/// bare `inception/mercury-2` is unambiguous there; `/compat/chat/completions`
/// is not scoped to anything, and reads the first path segment of the model id
/// as the provider — so the same string would be sent looking for a provider
/// called `inception`, which does not exist.
///
/// A model that already carries the provider prefix is left alone, so setting
/// `OMI_MODEL_SPEED` to a fully-qualified id keeps working.
pub fn gateway_model(model: &str, provider: &str) -> String {
    let provider = provider.trim();
    if provider.is_empty() {
        return model.to_string();
    }
    if model.starts_with(&format!("{provider}/")) {
        return model.to_string();
    }
    format!("{provider}/{model}")
}

pub fn ai_gateway_route(
    value: impl Fn(&str) -> Option<String>,
) -> Result<Option<AiGatewayRoute>, &'static str> {
    let account = value("CF_AI_GATEWAY_ACCOUNT_ID")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let gateway = value("CF_AI_GATEWAY_ID")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    let (account, gateway) = match (account, gateway) {
        (None, None) => return Ok(None),
        (Some(account), Some(gateway)) => (account, gateway),
        _ => return Err("Cloudflare AI Gateway configuration is incomplete"),
    };
    if account.len() != 32
        || !account
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        || gateway.is_empty()
        || gateway.len() > 64
        || !gateway.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || (index > 0 && byte == b'-')
        })
    {
        return Err("Cloudflare AI Gateway configuration is invalid");
    }
    let token = value("CF_AI_GATEWAY_TOKEN")
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty());
    if token.as_deref().is_some_and(|value| {
        value.len() > 4096 || value.bytes().any(|byte| byte.is_ascii_control())
    }) {
        return Err("Cloudflare AI Gateway token is invalid");
    }
    Ok(Some(AiGatewayRoute {
        url: format!(
            "https://gateway.ai.cloudflare.com/v1/{account}/{gateway}/compat/chat/completions"
        ),
        token,
    }))
}

/// Resolves the tier a request's `model` names, or `None` when it matches
/// neither the balanced nor the search model. The search tier only applies
/// when its model differs from the balanced one, so a deployment that has not
/// configured a distinct search model never routes there.
pub fn completion_tier_for_model(
    model: &str,
    value: impl Fn(&str) -> Option<String>,
) -> Option<ManagedCompletionTier> {
    let balanced = model_for_tier(ModelTier::Balanced, &value);
    if model == balanced {
        return Some(ManagedCompletionTier::Balanced);
    }
    let search = model_for_tier(ModelTier::Search, &value);
    if model == search && search != balanced {
        return Some(ManagedCompletionTier::Search);
    }
    None
}

// Model-tier routing config. Defaults live in config/model-tiers.json; the TS
// worker imports the same JSON. Env overrides use the same OMI_MODEL_* names.
//
// | Tier       | When                                                      | Default model         | Provider |
// |------------|-----------------------------------------------------------|-----------------------|----------|
// | speed      | latency-sensitive: live insights, classification, answers | inception/mercury-2 | Inception   |
// | balanced   | default (~80%): meeting notes, general chat               | xiaomi/mimo-v2.5          | MiMo     |
// | smart      | hard reasoning                                            | xiaomi/mimo-v2.5-pro           | MiMo     |
// | multimodal | vision / visual computer-use                              | google/gemini-3.6-flash         | Gemini   |
// | search     | web-grounded answers (live search)                        | perplexity/sonar                | Perplexity |
// | transcribe | server-side speech-to-text (no hub on the caller)         | google/gemini-3.5-flash-lite    | Gemini   |
// | speak      | server-side text-to-speech                                | openai/gpt-audio-mini           | OpenAI   |
//
// The default ids are best-effort and may need correcting against the real
// provider APIs; that is why they are env-overridable rather than hardcoded.
//
// Tiers say how much a workload is worth paying for. Capabilities say what a
// model can carry, and a call site that needs audio or images resolves through
// `model_for_capability` / `select_model_for` so an incapable model — table
// default or env override — is refused rather than silently handed the input.

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelTier {
    Speed,
    Balanced,
    Smart,
    Multimodal,
    Search,
    Transcribe,
    Speak,
}

#[path = "model_tier_defaults.rs"]
mod model_tier_defaults;
use model_tier_defaults::{MODEL_CAPABILITIES, *};

impl ModelTier {
    /// The env var that overrides this tier's model id.
    pub fn env_var(self) -> &'static str {
        match self {
            ModelTier::Speed => "OMI_MODEL_SPEED",
            ModelTier::Balanced => "OMI_MODEL_BALANCED",
            ModelTier::Smart => "OMI_MODEL_SMART",
            ModelTier::Multimodal => "OMI_MODEL_MULTIMODAL",
            ModelTier::Search => "OMI_MODEL_SEARCH",
            ModelTier::Transcribe => "OMI_MODEL_TRANSCRIBE",
            ModelTier::Speak => "OMI_MODEL_SPEAK",
        }
    }

    /// The tier slug, used in the capability-error message.
    pub fn slug(self) -> &'static str {
        match self {
            ModelTier::Speed => "speed",
            ModelTier::Balanced => "balanced",
            ModelTier::Smart => "smart",
            ModelTier::Multimodal => "multimodal",
            ModelTier::Search => "search",
            ModelTier::Transcribe => "transcribe",
            ModelTier::Speak => "speak",
        }
    }

    /// The fallback model id when nothing is configured.
    pub fn default_model(self) -> &'static str {
        match self {
            ModelTier::Speed => DEFAULT_SPEED_MODEL,
            ModelTier::Balanced => DEFAULT_BALANCED_MODEL,
            ModelTier::Smart => DEFAULT_SMART_MODEL,
            ModelTier::Multimodal => DEFAULT_MULTIMODAL_MODEL,
            ModelTier::Search => DEFAULT_SEARCH_MODEL,
            ModelTier::Transcribe => DEFAULT_TRANSCRIBE_MODEL,
            ModelTier::Speak => DEFAULT_SPEAK_MODEL,
        }
    }
}

/// What a model can actually carry. A tier says how much a workload is worth
/// paying for; a capability says whether the model can accept the request at
/// all, which is the part a tier slug alone never encoded.
///
/// `Realtime` is deliberately declared by nothing in the built-in table: a
/// bidirectional live conversation runs over Gemini Live (`voice_logic`), not
/// over OpenRouter chat completions, so any caller asking the tier table for a
/// realtime model is asking the wrong layer and is refused.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ModelCapability {
    Text,
    AudioIn,
    AudioOut,
    ImageIn,
    Realtime,
}

impl ModelCapability {
    pub fn slug(self) -> &'static str {
        match self {
            ModelCapability::Text => "text",
            ModelCapability::AudioIn => "audioIn",
            ModelCapability::AudioOut => "audioOut",
            ModelCapability::ImageIn => "imageIn",
            ModelCapability::Realtime => "realtime",
        }
    }

    fn from_slug(value: &str) -> Option<Self> {
        match value {
            "text" => Some(ModelCapability::Text),
            "audioIn" => Some(ModelCapability::AudioIn),
            "audioOut" => Some(ModelCapability::AudioOut),
            "imageIn" => Some(ModelCapability::ImageIn),
            "realtime" => Some(ModelCapability::Realtime),
            _ => None,
        }
    }
}

/// Asynchronous audio (voice notes on a channel, WAL uploads, API uploads)
/// prefers the balanced model: it accepts audio input at $0.14/M, half the
/// transcribe tier's price, and the transcribe tier remains the fallback when
/// an override leaves balanced text-only.
pub const ASYNC_AUDIO_TIER_PREFERENCE: &[ModelTier] = &[
    ModelTier::Transcribe,
    ModelTier::Balanced,
    ModelTier::Multimodal,
];

/// An env override names a model the built-in table has never seen, so the
/// override has to be able to declare what it can do: `OMI_MODEL_CAPABILITIES`
/// is a JSON object of model id to capability list, merged over the built-in
/// table. A malformed value declares nothing rather than throwing, so a typo
/// degrades to "this model is unverified" and the capability check refuses it
/// loudly at use.
fn declared_capabilities(raw: Option<&str>) -> Option<Map<String, Value>> {
    let raw = raw.map(str::trim).filter(|value| !value.is_empty())?;
    let parsed: Value = serde_json::from_str(raw).ok()?;
    parsed.as_object().cloned()
}

/// The capabilities of a model id, empty when nothing has verified it.
pub fn capabilities_of(
    value: impl Fn(&str) -> Option<String>,
    model: &str,
) -> Vec<ModelCapability> {
    if let Some(declared) = declared_capabilities(value("OMI_MODEL_CAPABILITIES").as_deref()) {
        // An entry present but not an array declares nothing for that model,
        // and shadows the built-in table exactly as `?? ` does in TS.
        if let Some(entry) = declared.get(model) {
            return match entry.as_array() {
                Some(list) => list
                    .iter()
                    .filter_map(Value::as_str)
                    .filter_map(ModelCapability::from_slug)
                    .collect(),
                None => Vec::new(),
            };
        }
    }
    MODEL_CAPABILITIES
        .iter()
        .find(|(id, _)| *id == model)
        .map(|(_, caps)| caps.to_vec())
        .unwrap_or_default()
}

pub fn model_supports(
    value: impl Fn(&str) -> Option<String>,
    model: &str,
    required: &[ModelCapability],
) -> bool {
    let capabilities = capabilities_of(value, model);
    required.iter().all(|need| capabilities.contains(need))
}

/// Raised when the model a tier resolves to cannot carry the request.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ModelCapabilityError {
    pub tier: ModelTier,
    pub model: String,
    pub missing: Vec<ModelCapability>,
}

impl ModelCapabilityError {
    pub fn message(&self) -> String {
        let missing = self
            .missing
            .iter()
            .map(|capability| capability.slug())
            .collect::<Vec<_>>()
            .join(", ");
        format!(
            "Model {} (tier {}) lacks required capability: {missing}",
            self.model,
            self.tier.slug()
        )
    }
}

fn missing_capabilities(
    value: &impl Fn(&str) -> Option<String>,
    model: &str,
    required: &[ModelCapability],
) -> Vec<ModelCapability> {
    let capabilities = capabilities_of(value, model);
    required
        .iter()
        .filter(|need| !capabilities.contains(need))
        .copied()
        .collect()
}

/// Resolves a tier the same way `model_for_tier` does, then validates the
/// result — override included — against the capabilities the call site needs.
pub fn model_for_capability(
    value: impl Fn(&str) -> Option<String>,
    tier: ModelTier,
    required: &[ModelCapability],
) -> Result<String, ModelCapabilityError> {
    let model = model_for_tier(tier, &value);
    let missing = missing_capabilities(&value, &model, required);
    if missing.is_empty() {
        Ok(model)
    } else {
        Err(ModelCapabilityError {
            tier,
            model,
            missing,
        })
    }
}

/// Picks the first tier in `preference` whose model can carry `required`, so a
/// workload states what it needs and what it would rather pay, and the table
/// decides. Errors when no preferred tier qualifies rather than falling back to
/// a model that cannot take the input.
pub fn select_model_for(
    value: impl Fn(&str) -> Option<String>,
    required: &[ModelCapability],
    preference: &[ModelTier],
) -> Result<(ModelTier, String), ModelCapabilityError> {
    let mut last: Option<ModelCapabilityError> = None;
    for tier in preference {
        let model = model_for_tier(*tier, &value);
        let missing = missing_capabilities(&value, &model, required);
        if missing.is_empty() {
            return Ok((*tier, model));
        }
        last = Some(ModelCapabilityError {
            tier: *tier,
            model,
            missing,
        });
    }
    Err(last.unwrap_or_else(|| ModelCapabilityError {
        tier: ModelTier::Balanced,
        model: model_for_tier(ModelTier::Balanced, &value),
        missing: required.to_vec(),
    }))
}

/// Resolves a tier to its model id from a value lookup, falling back to the
/// tier default. BALANCED additionally accepts the legacy `MIMO_MODEL` name so
/// the existing managed-AI configuration keeps working as the balanced default.
pub fn model_for_tier(tier: ModelTier, value: impl Fn(&str) -> Option<String>) -> String {
    let nonempty = |name: &str| value(name).filter(|candidate| !candidate.trim().is_empty());
    nonempty(tier.env_var())
        .or_else(|| match tier {
            ModelTier::Balanced => nonempty("MIMO_MODEL"),
            _ => None,
        })
        .unwrap_or_else(|| tier.default_model().to_string())
}

/// Every key a managed completion body may carry. Anything else is rejected
/// outright rather than stripped, so a client cannot smuggle a parameter past
/// the accounting by spelling it differently.
///
/// `tools` and `tool_choice` are here because withholding them is what actually
/// broke the desktop assistant: the hub attaches its catalogue to a turn, this
/// list did not admit the key, and the whole request came back `400 Invalid
/// request` — which the client could only report as "assistant provider stream
/// failed". It was read as the model refusing tools. No model was ever asked.
const ALLOWED_KEYS: &[&str] = &[
    "messages",
    "model",
    "stream",
    "max_tokens",
    "temperature",
    "top_p",
    "stream_options",
    "tools",
    "tool_choice",
];

/// The keys one message may carry. The two tool fields are what make a tool
/// round trip expressible at all: the assistant turn that asked to call
/// something carries `tool_calls`, and each answer comes back as a `tool`
/// message naming the call it answers.
const ALLOWED_MESSAGE_KEYS: &[&str] = &["role", "content", "tool_calls", "tool_call_id"];

/// A chat message on the way to a completion.
///
/// `tool_calls` and `tool_call_id` are what make a tool round trip expressible:
/// the assistant turn that asked to call something carries the calls, and each
/// answer comes back as a `tool` message naming the call it answers. Both are
/// `None` for every message on the strict `/v1/chat/completions` path, which
/// does not accept tools at all — see [`parse_request`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Message {
    pub role: String,
    pub content: String,
    pub tool_calls: Option<Value>,
    pub tool_call_id: Option<String>,
}

impl Message {
    pub fn new(role: &str, content: impl Into<String>) -> Message {
        Message {
            role: role.to_string(),
            content: content.into(),
            ..Message::default()
        }
    }

    /// The assistant turn that requested tools. The upstream wants the original
    /// `tool_calls` array echoed back verbatim, so it is carried rather than
    /// rebuilt — a re-serialized approximation is how ids stop matching.
    pub fn tool_request(tool_calls: Value) -> Message {
        Message {
            role: "assistant".to_string(),
            content: String::new(),
            tool_calls: Some(tool_calls),
            tool_call_id: None,
        }
    }

    /// One tool's result, answering the call with that id.
    pub fn tool_result(tool_call_id: &str, content: impl Into<String>) -> Message {
        Message {
            role: "tool".to_string(),
            content: content.into(),
            tool_calls: None,
            tool_call_id: Some(tool_call_id.to_string()),
        }
    }

    /// The wire shape: the optional fields are omitted rather than sent null,
    /// because a null `tool_calls` is rejected by some providers that accept
    /// its absence.
    pub fn to_json(&self) -> Value {
        let mut value = serde_json::json!({ "role": self.role, "content": self.content });
        let obj = value.as_object_mut().expect("object");
        if let Some(calls) = &self.tool_calls {
            obj.insert("tool_calls".into(), calls.clone());
        }
        if let Some(id) = &self.tool_call_id {
            obj.insert("tool_call_id".into(), Value::String(id.clone()));
        }
        value
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct CompletionRequest {
    pub model: String,
    pub messages: Vec<Message>,
    pub max_tokens: i64,
    pub temperature: Option<f64>,
    pub top_p: Option<f64>,
    /// Carried through to the upstream verbatim. The worker has no opinion
    /// about what a tool is; it only bounds how many there may be.
    pub tools: Option<Value>,
    pub tool_choice: Option<Value>,
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
    messages
        .iter()
        .fold(REQUEST_FRAMING_TOKEN_RESERVE, |total, m| {
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
        if !object_keys_all_allowed(value, ALLOWED_MESSAGE_KEYS) {
            return None;
        }
        let role = value.get("role").and_then(Value::as_str)?;
        if role != "assistant" && role != "system" && role != "user" && role != "tool" {
            return None;
        }
        let tool_calls = value.get("tool_calls").cloned();
        let tool_call_id = match value.get("tool_call_id") {
            None => None,
            Some(id) => Some(id.as_str()?.to_string()),
        };
        if let Some(calls) = &tool_calls {
            if role != "assistant" || calls.as_array().is_none_or(Vec::is_empty) {
                return None;
            }
        }
        // A `tool` message answers a call, so it must name one; nothing else
        // may claim to.
        if (role == "tool") != tool_call_id.is_some() {
            return None;
        }
        // The turn that asks to call something says nothing while it does, so
        // an empty content is only allowed there. Everywhere else an empty
        // message is a client bug that costs the user a request.
        let content = match value.get("content") {
            None => String::new(),
            Some(Value::Null) => String::new(),
            Some(content) => content.as_str()?.to_string(),
        };
        if content.is_empty() && tool_calls.is_none() {
            return None;
        }
        input_characters += content.encode_utf16().count();
        if input_characters > MAXIMUM_INPUT_CHARACTERS {
            return None;
        }
        messages.push(Message {
            role: role.to_string(),
            content,
            tool_calls,
            tool_call_id,
        });
    }
    if messages.is_empty() {
        return None;
    }
    let stream_options = obj.get("stream_options")?.as_object()?;
    if stream_options.len() != 1 || stream_options.get("include_usage") != Some(&Value::Bool(true))
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
    let tools = match obj.get("tools") {
        None => None,
        Some(tools) => {
            let listed = tools.as_array()?;
            if listed.is_empty() || listed.len() > MAXIMUM_TOOLS {
                return None;
            }
            if !listed.iter().all(Value::is_object) {
                return None;
            }
            Some(tools.clone())
        }
    };
    // A tool choice without tools is a request the upstream cannot honour, and
    // the shape is left to the upstream beyond that: naming the tool to call is
    // an object, and the three standing answers are strings.
    let tool_choice = match obj.get("tool_choice") {
        None => None,
        Some(_) if tools.is_none() => return None,
        Some(choice) => match choice {
            Value::String(named) => {
                if named != "auto" && named != "none" && named != "required" {
                    return None;
                }
                Some(choice.clone())
            }
            Value::Object(_) => Some(choice.clone()),
            _ => return None,
        },
    };
    Some(CompletionRequest {
        model: model.to_string(),
        messages,
        max_tokens,
        temperature,
        top_p,
        tools,
        tool_choice,
    })
}

/// The upstream body sent for a parsed managed request: the request plus the
/// forced `stream_options.include_usage`.
pub fn upstream_body(request: &CompletionRequest) -> Value {
    // `to_json` rather than a fresh role/content pair: a tool round trip only
    // works if the call ids the assistant turn quoted survive to the upstream
    // unchanged, and rebuilding the message is how they stop matching.
    let messages: Vec<Value> = request.messages.iter().map(Message::to_json).collect();
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
    if let Some(tools) = &request.tools {
        obj.insert("tools".into(), tools.clone());
    }
    if let Some(choice) = &request.tool_choice {
        obj.insert("tool_choice".into(), choice.clone());
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

#[derive(Default)]
pub struct UsageTail {
    bytes: Vec<u8>,
}

impl UsageTail {
    pub fn push(&mut self, chunk: &[u8]) {
        self.bytes.extend_from_slice(chunk);
        if self.bytes.len() > 16_384 {
            self.bytes.drain(..self.bytes.len() - 16_384);
        }
    }

    pub fn usage(&self) -> (Option<i64>, Option<i64>) {
        usage_from(&String::from_utf8_lossy(&self.bytes))
    }
}

/// One tool the model asked to run.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    /// The raw `arguments` string. Left as the model wrote it: it is JSON by
    /// convention and not by guarantee, so each caller parses what it needs and
    /// decides for itself what a malformed argument means.
    pub arguments: String,
}

/// The `tool_calls` the first choice asked for, if any, alongside the array
/// exactly as it arrived.
///
/// The verbatim array is returned because it has to be echoed back in the
/// follow-up request: rebuilding it from the parsed calls would drop provider
/// fields and risks ids that no longer line up with the `tool` messages
/// answering them.
pub fn parse_tool_calls(value: &Value) -> Option<(Value, Vec<ToolCall>)> {
    let raw = value
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("tool_calls"))?;
    let entries = raw.as_array()?;
    let calls: Vec<ToolCall> = entries
        .iter()
        .filter_map(|entry| {
            let function = entry.get("function")?;
            Some(ToolCall {
                id: entry.get("id").and_then(Value::as_str)?.to_string(),
                name: function.get("name").and_then(Value::as_str)?.to_string(),
                arguments: function
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("{}")
                    .to_string(),
            })
        })
        .collect();
    // An empty or wholly unparseable array is not a tool round: reporting one
    // would send the caller back to the model with nothing to answer, forever.
    if calls.is_empty() {
        return None;
    }
    Some((raw.clone(), calls))
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

    fn completion_with_calls(calls: Value) -> Value {
        serde_json::json!({ "choices": [{ "message": { "content": null, "tool_calls": calls } }] })
    }

    #[test]
    fn tool_calls_are_read_off_the_first_choice() {
        let value = completion_with_calls(serde_json::json!([{
            "id": "call_1",
            "type": "function",
            "function": { "name": "get_signin_code", "arguments": "{}" },
        }]));
        let (raw, calls) = parse_tool_calls(&value).expect("tool calls");
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].id, "call_1");
        assert_eq!(calls[0].name, "get_signin_code");
        assert_eq!(calls[0].arguments, "{}");
        // The array is carried verbatim, provider fields and all, because it
        // has to be echoed back with ids the tool results will name.
        assert_eq!(raw[0]["type"], serde_json::json!("function"));
    }

    #[test]
    fn a_call_with_no_arguments_field_still_parses() {
        // Providers omit `arguments` for a no-argument tool often enough that
        // treating it as malformed would drop real calls on the floor.
        let value = completion_with_calls(serde_json::json!([{
            "id": "call_1", "function": { "name": "list_commands" },
        }]));
        let (_, calls) = parse_tool_calls(&value).expect("tool calls");
        assert_eq!(calls[0].arguments, "{}");
    }

    #[test]
    fn nothing_to_call_is_reported_as_no_tool_round() {
        // Each of these would otherwise send the caller back to the model with
        // no results to supply, which is a loop that never ends.
        for value in [
            serde_json::json!({ "choices": [{ "message": { "content": "hi" } }] }),
            completion_with_calls(serde_json::json!([])),
            completion_with_calls(serde_json::json!([{ "id": "call_1" }])),
            completion_with_calls(serde_json::json!([{ "function": { "name": "x" } }])),
            serde_json::json!({}),
        ] {
            assert_eq!(parse_tool_calls(&value), None, "{value}");
        }
    }

    #[test]
    fn the_wire_shape_omits_tool_fields_rather_than_nulling_them() {
        let plain = Message::new("user", "hi").to_json();
        assert_eq!(
            plain,
            serde_json::json!({ "role": "user", "content": "hi" })
        );
        assert!(plain.get("tool_calls").is_none());

        let request = Message::tool_request(serde_json::json!([{ "id": "c1" }])).to_json();
        assert_eq!(request["role"], serde_json::json!("assistant"));
        assert_eq!(request["tool_calls"][0]["id"], serde_json::json!("c1"));

        let result = Message::tool_result("c1", "{\"ok\":true}").to_json();
        assert_eq!(result["role"], serde_json::json!("tool"));
        assert_eq!(result["tool_call_id"], serde_json::json!("c1"));
        assert!(result.get("tool_calls").is_none());
    }

    #[test]
    fn ai_gateway_route_rejects_path_smuggling_and_carries_its_token() {
        assert!(ai_gateway_route(|name| match name {
            "CF_AI_GATEWAY_ACCOUNT_ID" => Some("../evil".into()),
            "CF_AI_GATEWAY_ID" => Some("default".into()),
            _ => None,
        })
        .is_err());
        assert!(ai_gateway_route(|name| match name {
            "CF_AI_GATEWAY_ACCOUNT_ID" => Some("f".repeat(32)),
            "CF_AI_GATEWAY_ID" => Some("a/../../b".into()),
            _ => None,
        })
        .is_err());
        assert!(ai_gateway_route(|name| match name {
            "CF_AI_GATEWAY_ACCOUNT_ID" => Some("f".repeat(32)),
            _ => None,
        })
        .is_err());
        assert!(ai_gateway_route(|name| match name {
            "CF_AI_GATEWAY_ACCOUNT_ID" => Some("f".repeat(32)),
            "CF_AI_GATEWAY_ID" => Some("default".into()),
            "CF_AI_GATEWAY_TOKEN" => Some("bad\nvalue".into()),
            _ => None,
        })
        .is_err());
        assert_eq!(ai_gateway_route(|_| None), Ok(None));
        let route = ai_gateway_route(|name| match name {
            "CF_AI_GATEWAY_ACCOUNT_ID" => Some("f".repeat(32)),
            "CF_AI_GATEWAY_ID" => Some("default".into()),
            "CF_AI_GATEWAY_TOKEN" => Some("gateway-token".into()),
            _ => None,
        })
        .unwrap()
        .unwrap();
        assert_eq!(
            route.url,
            format!(
                "https://gateway.ai.cloudflare.com/v1/{}/default/compat/chat/completions",
                "f".repeat(32)
            )
        );
        assert_eq!(route.token.as_deref(), Some("gateway-token"));
    }

    #[test]
    fn the_compat_endpoint_gets_a_provider_qualified_model() {
        // Verified against the live gateway: `openrouter/xiaomi/mimo-v2.5`
        // answers 200, a bare `xiaomi/mimo-v2.5` does not, because the compat
        // endpoint reads the first segment as the provider.
        assert_eq!(
            gateway_model("xiaomi/mimo-v2.5", "openrouter"),
            "openrouter/xiaomi/mimo-v2.5"
        );
        assert_eq!(
            gateway_model("inception/mercury-2", "openrouter"),
            "openrouter/inception/mercury-2"
        );
    }

    #[test]
    fn a_model_that_already_names_its_provider_is_left_alone() {
        // Otherwise overriding OMI_MODEL_SPEED with a fully-qualified id would
        // double the prefix and 404.
        assert_eq!(
            gateway_model("openrouter/openai/gpt-5.6-luna", "openrouter"),
            "openrouter/openai/gpt-5.6-luna"
        );
        // An empty provider means "send it as written" rather than "/model".
        assert_eq!(gateway_model("xiaomi/mimo-v2.5", ""), "xiaomi/mimo-v2.5");
        assert_eq!(gateway_model("xiaomi/mimo-v2.5", "   "), "xiaomi/mimo-v2.5");
    }
    use serde_json::json;

    fn valid() -> Value {
        json!({
            "model": "xiaomi/mimo-v2.5-pro",
            "messages": [{ "role": "user", "content": "Remember this safely." }],
            "stream": true,
            "max_tokens": 256,
            "stream_options": { "include_usage": true }
        })
    }

    #[test]
    fn completion_tier_routes_balanced_and_search_by_model() {
        // No overrides: balanced and search resolve to their defaults, and the
        // two tiers are distinct.
        assert_eq!(
            completion_tier_for_model(DEFAULT_BALANCED_MODEL, |_| None),
            Some(ManagedCompletionTier::Balanced)
        );
        assert_eq!(
            completion_tier_for_model(DEFAULT_SEARCH_MODEL, |_| None),
            Some(ManagedCompletionTier::Search)
        );
        assert_eq!(
            completion_tier_for_model("some/other-model", |_| None),
            None
        );
    }

    #[test]
    fn search_tier_is_ignored_when_it_collapses_onto_balanced() {
        // An override that points search at the balanced model must not create a
        // second route: the balanced tier wins and search never applies.
        let value = |name: &str| match name {
            "OMI_MODEL_SEARCH" => Some(DEFAULT_BALANCED_MODEL.to_owned()),
            _ => None,
        };
        assert_eq!(
            completion_tier_for_model(DEFAULT_BALANCED_MODEL, value),
            Some(ManagedCompletionTier::Balanced)
        );
    }

    #[test]
    fn price_matches_js() {
        assert_eq!(price(Some("435000")), Some(435000));
        for invalid in [
            None,
            Some(""),
            Some("0"),
            Some("-1"),
            Some("1.5"),
            Some("NaN"),
        ] {
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
            "model": "xiaomi/mimo-v2.5-pro",
            "messages": [{ "role": "user", "content": "hello" }],
            "stream": true,
            "stream_options": { "include_usage": true }
        });
        let parsed = parse_request(&body, "xiaomi/mimo-v2.5-pro").unwrap();
        assert_eq!(parsed.max_tokens, DEFAULT_OUTPUT_TOKENS);
        let upstream = upstream_body(&parsed);
        assert_eq!(upstream["max_tokens"], json!(1024));
        assert_eq!(upstream["stream_options"]["include_usage"], json!(true));
    }

    #[test]
    fn reserves_framing_for_64_tiny_messages() {
        let messages: Vec<Message> = (0..64).map(|_| Message::new("user", "x")).collect();
        // 64 * (16 + 4 + 1) + 64 = 1408, plus max_tokens 1 = 1409.
        assert_eq!(input_token_reservation(&messages), 1408);
        assert_eq!(input_token_reservation(&messages) + 1, 1409);
    }

    // The regression this pins: the desktop assistant attaches a tool
    // catalogue to a turn, and this route used to reject the whole request for
    // carrying the key. The client saw a bare stream failure and the cause was
    // read as the model refusing tools — the model was never asked.
    #[test]
    fn a_request_carrying_tools_is_forwarded_rather_than_refused() {
        let mut with_tools = valid().as_object().unwrap().clone();
        with_tools.insert(
            "tools".into(),
            json!([{
                "type": "function",
                "function": { "name": "memory_search", "parameters": { "type": "object" } }
            }]),
        );
        with_tools.insert("tool_choice".into(), json!("auto"));
        let parsed = parse_request(&Value::Object(with_tools), "xiaomi/mimo-v2.5-pro")
            .expect("a tools request parses");
        let body = upstream_body(&parsed);
        assert_eq!(
            body["tools"][0]["function"]["name"].as_str(),
            Some("memory_search")
        );
        assert_eq!(body["tool_choice"].as_str(), Some("auto"));
    }

    #[test]
    fn a_tool_round_trip_keeps_the_call_ids_that_answer_each_other() {
        let mut round_trip = valid().as_object().unwrap().clone();
        round_trip.insert(
            "messages".into(),
            json!([
                { "role": "user", "content": "what do you know about me?" },
                {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [{
                        "id": "call_1",
                        "type": "function",
                        "function": { "name": "memory_search", "arguments": "{}" }
                    }]
                },
                { "role": "tool", "tool_call_id": "call_1", "content": "- I work at Acme" }
            ]),
        );
        let parsed = parse_request(&Value::Object(round_trip), "xiaomi/mimo-v2.5-pro")
            .expect("a tool round trip parses");
        let body = upstream_body(&parsed);
        assert_eq!(
            body["messages"][1]["tool_calls"][0]["id"].as_str(),
            Some("call_1")
        );
        assert_eq!(body["messages"][2]["tool_call_id"].as_str(), Some("call_1"));
        // The user turn keeps the shape every non-tool message always had.
        assert!(body["messages"][0].get("tool_calls").is_none());
    }

    #[test]
    fn a_malformed_tool_shape_is_still_refused() {
        let base = valid();
        let mut choice_alone = base.as_object().unwrap().clone();
        choice_alone.insert("tool_choice".into(), json!("auto"));
        assert!(parse_request(&Value::Object(choice_alone), "xiaomi/mimo-v2.5-pro").is_none());

        let mut too_many = base.as_object().unwrap().clone();
        too_many.insert(
            "tools".into(),
            json!(vec![json!({ "type": "function" }); MAXIMUM_TOOLS + 1]),
        );
        assert!(parse_request(&Value::Object(too_many), "xiaomi/mimo-v2.5-pro").is_none());

        let mut empty_tools = base.as_object().unwrap().clone();
        empty_tools.insert("tools".into(), json!([]));
        assert!(parse_request(&Value::Object(empty_tools), "xiaomi/mimo-v2.5-pro").is_none());

        // An answer to nothing, and a call from nobody.
        let mut orphan_result = base.as_object().unwrap().clone();
        orphan_result.insert(
            "messages".into(),
            json!([{ "role": "tool", "content": "anything" }]),
        );
        assert!(parse_request(&Value::Object(orphan_result), "xiaomi/mimo-v2.5-pro").is_none());

        let mut user_calls = base.as_object().unwrap().clone();
        user_calls.insert(
            "messages".into(),
            json!([{ "role": "user", "content": "hi", "tool_calls": [{ "id": "call_1" }] }]),
        );
        assert!(parse_request(&Value::Object(user_calls), "xiaomi/mimo-v2.5-pro").is_none());

        // An empty message is still a client bug everywhere it is not a turn
        // that spoke only by calling something.
        let mut empty_user = base.as_object().unwrap().clone();
        empty_user.insert(
            "messages".into(),
            json!([{ "role": "user", "content": "" }]),
        );
        assert!(parse_request(&Value::Object(empty_user), "xiaomi/mimo-v2.5-pro").is_none());
    }

    #[test]
    fn rejects_byok_unknown_model_non_streaming_and_excess() {
        let base = valid();
        let mut with_api_key = base.as_object().unwrap().clone();
        with_api_key.insert("api_key".into(), json!("user-key"));
        assert!(parse_request(&Value::Object(with_api_key), "xiaomi/mimo-v2.5-pro").is_none());

        let mut base_url = base.as_object().unwrap().clone();
        base_url.insert("base_url".into(), json!("https://user.example"));
        assert!(parse_request(&Value::Object(base_url), "xiaomi/mimo-v2.5-pro").is_none());

        let mut other_model = base.as_object().unwrap().clone();
        other_model.insert("model".into(), json!("other"));
        assert!(parse_request(&Value::Object(other_model), "xiaomi/mimo-v2.5-pro").is_none());

        let mut not_stream = base.as_object().unwrap().clone();
        not_stream.insert("stream".into(), json!(false));
        assert!(parse_request(&Value::Object(not_stream), "xiaomi/mimo-v2.5-pro").is_none());

        let mut too_many = base.as_object().unwrap().clone();
        too_many.insert("max_tokens".into(), json!(4097));
        assert!(parse_request(&Value::Object(too_many), "xiaomi/mimo-v2.5-pro").is_none());

        let mut no_usage = base.as_object().unwrap().clone();
        no_usage.insert("stream_options".into(), json!({ "include_usage": false }));
        assert!(parse_request(&Value::Object(no_usage), "xiaomi/mimo-v2.5-pro").is_none());

        let mut extra_opt = base.as_object().unwrap().clone();
        extra_opt.insert(
            "stream_options".into(),
            json!({ "include_usage": true, "extra": true }),
        );
        assert!(parse_request(&Value::Object(extra_opt), "xiaomi/mimo-v2.5-pro").is_none());

        let mut tool_role = base.as_object().unwrap().clone();
        tool_role.insert(
            "messages".into(),
            json!([{ "role": "tool", "content": "unsafe" }]),
        );
        assert!(parse_request(&Value::Object(tool_role), "xiaomi/mimo-v2.5-pro").is_none());
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
        let messages = vec![Message::new("user", "Remember this safely.")];
        let est_input = input_token_reservation(&messages);
        // 64 + 16 + 4 + 21 = 105.
        assert_eq!(est_input, 105);
        assert_eq!(cost_for(est_input, 256, 1_000_000, 1_000_000), 361);
    }

    #[test]
    fn usage_tail_keeps_split_usage_at_the_end_of_a_long_stream() {
        let mut tail = UsageTail::default();
        tail.push(&vec![b'x'; 16_000]);
        tail.push(b"\ndata: {\"usage\":{\"prompt_tokens\":7,");
        tail.push(b"\"completion_tokens\":2}}\n");
        assert_eq!(tail.usage(), (Some(7), Some(2)));
    }

    #[test]
    fn tiers_resolve_with_defaults_overrides_and_legacy_mimo_model() {
        let empty = |_: &str| None;
        assert_eq!(model_for_tier(ModelTier::Speed, empty), DEFAULT_SPEED_MODEL);
        assert_eq!(
            model_for_tier(ModelTier::Balanced, empty),
            DEFAULT_BALANCED_MODEL
        );
        assert_eq!(model_for_tier(ModelTier::Smart, empty), DEFAULT_SMART_MODEL);
        assert_eq!(
            model_for_tier(ModelTier::Multimodal, empty),
            DEFAULT_MULTIMODAL_MODEL
        );

        let overridden = |name: &str| match name {
            "OMI_MODEL_BALANCED" => Some("custom-balanced".to_string()),
            _ => None,
        };
        assert_eq!(
            model_for_tier(ModelTier::Balanced, overridden),
            "custom-balanced"
        );

        let legacy = |name: &str| match name {
            "MIMO_MODEL" => Some("mimo-configured".to_string()),
            _ => None,
        };
        assert_eq!(
            model_for_tier(ModelTier::Balanced, legacy),
            "mimo-configured"
        );
        assert_eq!(
            model_for_tier(ModelTier::Smart, legacy),
            DEFAULT_SMART_MODEL
        );

        let blank = |_: &str| Some("   ".to_string());
        assert_eq!(model_for_tier(ModelTier::Speed, blank), DEFAULT_SPEED_MODEL);
    }

    #[test]
    fn the_audio_tiers_declare_audio_and_the_text_tiers_do_not() {
        let env = |_: &str| None;
        assert!(
            capabilities_of(env, &model_for_tier(ModelTier::Balanced, env))
                .contains(&ModelCapability::AudioIn)
        );
        assert!(
            capabilities_of(env, &model_for_tier(ModelTier::Transcribe, env))
                .contains(&ModelCapability::AudioIn)
        );
        assert!(
            capabilities_of(env, &model_for_tier(ModelTier::Multimodal, env))
                .contains(&ModelCapability::ImageIn)
        );
        assert!(capabilities_of(env, &model_for_tier(ModelTier::Speak, env))
            .contains(&ModelCapability::AudioOut));
        for tier in [ModelTier::Speed, ModelTier::Smart, ModelTier::Search] {
            assert!(
                !model_supports(env, &model_for_tier(tier, env), &[ModelCapability::AudioIn]),
                "tier {} should not declare audioIn",
                tier.slug()
            );
        }
    }

    #[test]
    fn no_model_claims_realtime_which_belongs_to_gemini_live() {
        let env = |_: &str| None;
        assert!(select_model_for(
            env,
            &[ModelCapability::Realtime],
            &[ModelTier::Balanced, ModelTier::Speed]
        )
        .is_err());
    }

    #[test]
    fn asynchronous_audio_picks_the_transcribe_model() {
        let env = |_: &str| None;
        assert_eq!(
            select_model_for(
                env,
                &[ModelCapability::AudioIn],
                ASYNC_AUDIO_TIER_PREFERENCE
            ),
            Ok((ModelTier::Transcribe, DEFAULT_TRANSCRIBE_MODEL.to_string()))
        );
    }

    #[test]
    fn selection_walks_past_a_tier_that_lost_the_capability() {
        let value = |name: &str| match name {
            "OMI_MODEL_BALANCED" => Some(DEFAULT_SPEED_MODEL.to_string()),
            _ => None,
        };
        assert_eq!(
            select_model_for(
                value,
                &[ModelCapability::AudioIn],
                ASYNC_AUDIO_TIER_PREFERENCE
            ),
            Ok((ModelTier::Transcribe, DEFAULT_TRANSCRIBE_MODEL.to_string()))
        );
    }

    #[test]
    fn selection_fails_loudly_when_no_preferred_tier_qualifies() {
        let value = |name: &str| match name {
            "OMI_MODEL_BALANCED" | "OMI_MODEL_TRANSCRIBE" | "OMI_MODEL_MULTIMODAL" => {
                Some(DEFAULT_SPEED_MODEL.to_string())
            }
            _ => None,
        };
        let error = select_model_for(
            value,
            &[ModelCapability::AudioIn],
            ASYNC_AUDIO_TIER_PREFERENCE,
        )
        .unwrap_err();
        assert_eq!(error.missing, vec![ModelCapability::AudioIn]);
        assert_eq!(error.tier, ModelTier::Multimodal);
        assert_eq!(
            error.message(),
            format!(
                "Model {DEFAULT_SPEED_MODEL} (tier multimodal) lacks required capability: audioIn"
            )
        );
    }

    #[test]
    fn an_unverified_model_satisfies_nothing_until_it_declares_itself() {
        let unverified = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some("some/unknown-model".to_string()),
            _ => None,
        };
        let error = model_for_capability(
            unverified,
            ModelTier::Transcribe,
            &[ModelCapability::AudioIn],
        )
        .unwrap_err();
        assert_eq!(error.model, "some/unknown-model");
        assert_eq!(error.missing, vec![ModelCapability::AudioIn]);

        let declared = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some("some/unknown-model".to_string()),
            "OMI_MODEL_CAPABILITIES" => {
                Some(r#"{"some/unknown-model":["text","audioIn"]}"#.to_string())
            }
            _ => None,
        };
        assert_eq!(
            model_for_capability(declared, ModelTier::Transcribe, &[ModelCapability::AudioIn]),
            Ok("some/unknown-model".to_string())
        );
    }

    #[test]
    fn a_malformed_capability_declaration_declares_nothing() {
        let malformed = |name: &str| match name {
            "OMI_MODEL_TRANSCRIBE" => Some("some/unknown-model".to_string()),
            "OMI_MODEL_CAPABILITIES" => Some("{not json".to_string()),
            _ => None,
        };
        assert!(model_for_capability(
            malformed,
            ModelTier::Transcribe,
            &[ModelCapability::AudioIn]
        )
        .is_err());
    }

    #[test]
    fn validates_and_rejects_non_canonical_openrouter_endpoints() {
        assert!(validate_pinned_endpoint(
            OPENROUTER_COMPLETION_ENDPOINT,
            OPENROUTER_COMPLETION_ENDPOINT,
            OPENROUTER_HOSTNAME
        )
        .is_some());
        for endpoint in [
            "https://openrouter.ai/api/v1/chat/completions?debug=1",
            "https://user@openrouter.ai/api/v1/chat/completions",
            "https://127.0.0.1/api/v1/chat/completions",
            "https://openrouter.ai.evil.test/api/v1/chat/completions",
        ] {
            assert!(
                validate_pinned_endpoint(
                    endpoint,
                    OPENROUTER_COMPLETION_ENDPOINT,
                    OPENROUTER_HOSTNAME
                )
                .is_none(),
                "should reject {endpoint}"
            );
        }
    }

    #[test]
    fn parses_the_non_streaming_completion_and_its_bounded_usage() {
        assert_eq!(
            parse_completion(&json!({
                "choices": [{ "message": { "content": "  answered.  " } }],
                "usage": { "prompt_tokens": 7, "completion_tokens": 2 }
            })),
            (Some("answered.".to_string()), Some(7), Some(2))
        );
        assert_eq!(
            parse_completion(&json!({
                "choices": [{ "message": { "content": "answered." } }]
            })),
            (Some("answered.".to_string()), None, None)
        );
        assert_eq!(
            parse_completion(&json!({
                "choices": [{ "message": { "content": "answered." } }],
                "usage": { "prompt_tokens": -1, "completion_tokens": 1.5 }
            })),
            (Some("answered.".to_string()), None, None)
        );
        for malformed in [
            json!({}),
            json!({ "choices": [] }),
            json!({ "choices": [{ "message": { "content": "   " } }] }),
            json!({ "choices": [{ "message": {} }] }),
        ] {
            assert_eq!(parse_completion(&malformed), (None, None, None));
        }
    }

    #[test]
    fn bounded_json_enforces_limits() {
        assert_eq!(
            bounded_json(Some("2"), Some(b"{}"), MAXIMUM_BODY_BYTES),
            Some(json!({}))
        );
        assert_eq!(bounded_json(Some("999999999"), Some(b"{}"), 4), None);
        assert_eq!(bounded_json(None, Some(b"[1,2]"), MAXIMUM_BODY_BYTES), None);
        assert_eq!(
            bounded_json(None, Some(b"not json"), MAXIMUM_BODY_BYTES),
            None
        );
        assert_eq!(bounded_json(None, None, MAXIMUM_BODY_BYTES), None);
    }
}
