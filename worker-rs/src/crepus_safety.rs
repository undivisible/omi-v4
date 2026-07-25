//! Defense-in-depth for AI-authored `.crepus` stored by the worker. The client
//! renderer is the primary boundary; this rejects hostile sources early: a
//! closed set of action verbs on event attributes, and image `src` URLs that
//! must be public `http(s)` with no credentials.

use url::Url;

pub const CREPUS_MAX_LEN: usize = 8000;

const CREPUS_IMAGE_URL_MAX_LEN: usize = 2000;

const BLOCKED_IMAGE_HOSTS: &[&str] = &["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"];

/// The event attribute names scanned for an action value: `onclick`,
/// `onchange`, `onlongpress`, `onlong-press`, `onlong_press`.
const EVENT_NAMES: &[&str] = &["click", "change", "long-press", "long_press", "longpress"];

/// Outcome of [`validate_crepus`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CrepusValidation {
    Ok(String),
    Err(String),
}

impl CrepusValidation {
    pub fn is_ok(&self) -> bool {
        matches!(self, CrepusValidation::Ok(_))
    }

    pub fn value(&self) -> Option<&str> {
        match self {
            CrepusValidation::Ok(value) => Some(value),
            CrepusValidation::Err(_) => None,
        }
    }

    pub fn error(&self) -> Option<&str> {
        match self {
            CrepusValidation::Ok(_) => None,
            CrepusValidation::Err(message) => Some(message),
        }
    }
}

fn decode_braced(inner: &str) -> String {
    let trimmed = inner.trim();
    if trimmed.len() >= 2 && trimmed.starts_with('{') && trimmed.ends_with('}') {
        return trimmed[1..trimmed.len() - 1].trim().to_string();
    }
    trimmed.to_string()
}

fn decode_bare(raw: &str) -> String {
    if raw.len() >= 2 && raw.starts_with('"') && raw.ends_with('"') {
        return raw[1..raw.len() - 1]
            .replace("\\\"", "\"")
            .replace("\\\\", "\\")
            .trim()
            .to_string();
    }
    raw.trim().to_string()
}

/// The closed action set: `complete`, `accept`, a non-empty `prompt:` or
/// `compute:` payload, and `open:` with a public `http(s)` URL.
pub fn is_allowed_crepus_action(action: &str) -> bool {
    if action == "complete" || action == "accept" {
        return true;
    }
    if let Some(rest) = action.strip_prefix("prompt:") {
        return !rest.trim().is_empty();
    }
    if let Some(rest) = action.strip_prefix("compute:") {
        return !rest.trim().is_empty();
    }
    if let Some(rest) = action.strip_prefix("open:") {
        return match Url::parse(rest.trim()) {
            Ok(url) => {
                (url.scheme() == "http" || url.scheme() == "https")
                    && url.host_str().is_some_and(|host| !host.is_empty())
            }
            Err(_) => false,
        };
    }
    false
}

fn is_private_or_local_host(hostname: &str) -> bool {
    let host = hostname
        .to_lowercase()
        .trim_start_matches('[')
        .trim_end_matches(']')
        .to_string();
    if BLOCKED_IMAGE_HOSTS.contains(&host.as_str()) {
        return true;
    }
    if host.ends_with(".local") || host.ends_with(".internal") {
        return true;
    }
    if host.contains(':')
        && (host == "::1"
            || host.starts_with("fc")
            || host.starts_with("fd")
            || host.starts_with("fe80"))
    {
        return true;
    }
    let parts: Vec<&str> = host.split('.').collect();
    if parts.len() != 4 {
        return false;
    }
    let mut octets = [0u32; 4];
    for (index, part) in parts.iter().enumerate() {
        if part.is_empty() || part.len() > 3 || !part.bytes().all(|b| b.is_ascii_digit()) {
            return false;
        }
        match part.parse::<u32>() {
            Ok(value) => octets[index] = value,
            Err(_) => return false,
        }
    }
    if octets.iter().any(|value| *value > 255) {
        return true;
    }
    let (a, b) = (octets[0], octets[1]);
    if a == 10 || a == 127 || a == 0 {
        return true;
    }
    if a == 169 && b == 254 {
        return true;
    }
    if a == 172 && (16..=31).contains(&b) {
        return true;
    }
    a == 192 && b == 168
}

/// A crepus `image`/`img` `src` must be a bounded, public `http(s)` URL that
/// carries no userinfo.
pub fn is_safe_crepus_image_url(url: &str) -> bool {
    if url.is_empty() || url.len() > CREPUS_IMAGE_URL_MAX_LEN {
        return false;
    }
    let Ok(parsed) = Url::parse(url) else {
        return false;
    };
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return false;
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return false;
    }
    let Some(host) = parsed.host_str() else {
        return false;
    };
    if host.is_empty() {
        return false;
    }
    !is_private_or_local_host(host)
}

fn is_ident_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-'
}

/// Reads `[_-]?=` then the value starting at `start`, returning the decoded
/// value and the byte index to resume scanning from.
fn read_attribute_value(source: &str, start: usize) -> Option<(String, usize)> {
    let bytes = source.as_bytes();
    let mut index = start;
    if index < bytes.len() && (bytes[index] == b'_' || bytes[index] == b'-') {
        index += 1;
    }
    if index >= bytes.len() || bytes[index] != b'=' {
        return None;
    }
    index += 1;
    while index < bytes.len() && (bytes[index] as char).is_whitespace() {
        index += 1;
    }
    if index >= bytes.len() {
        return Some((String::new(), index));
    }
    match bytes[index] {
        b'"' => {
            let mut cursor = index + 1;
            let mut escaped = false;
            while cursor < bytes.len() {
                if escaped {
                    escaped = false;
                } else if bytes[cursor] == b'\\' {
                    escaped = true;
                } else if bytes[cursor] == b'"' {
                    break;
                }
                cursor += 1;
            }
            if cursor >= bytes.len() {
                return None;
            }
            Some((decode_bare(&source[index + 1..cursor]), cursor + 1))
        }
        b'{' => {
            let mut cursor = index + 1;
            while cursor < bytes.len() && bytes[cursor] != b'}' {
                cursor += 1;
            }
            if cursor >= bytes.len() {
                return None;
            }
            Some((decode_braced(&source[index..=cursor]), cursor + 1))
        }
        _ => {
            let mut cursor = index;
            while cursor < bytes.len() && !(bytes[cursor] as char).is_whitespace() {
                cursor += 1;
            }
            Some((decode_bare(&source[index..cursor]), cursor))
        }
    }
}

/// Returns the first disallowed action found on an `on*` event attribute.
pub fn find_disallowed_crepus_action(source: &str) -> Option<String> {
    let lower = source.to_lowercase();
    let bytes = lower.as_bytes();
    let mut index = 0usize;
    while let Some(offset) = lower[index..].find("on") {
        let at = index + offset;
        index = at + 2;
        if at > 0 && is_ident_byte(bytes[at - 1]) {
            continue;
        }
        let Some(name) = EVENT_NAMES
            .iter()
            .find(|name| lower[at + 2..].starts_with(**name))
        else {
            continue;
        };
        let Some((action, resume)) = read_attribute_value(source, at + 2 + name.len()) else {
            continue;
        };
        index = resume;
        if action.is_empty() || is_allowed_crepus_action(&action) {
            continue;
        }
        return Some(format!("Invalid crepus action: {action}"));
    }
    None
}

/// Returns the first unsafe image `src` found on an `image`/`img` line.
pub fn find_unsafe_crepus_image_url(source: &str) -> Option<String> {
    let lower = source.to_lowercase();
    let mut line_start = 0usize;
    while line_start <= lower.len() {
        let line_end = lower[line_start..]
            .find('\n')
            .map(|offset| line_start + offset)
            .unwrap_or(lower.len());
        if let Some(found) = unsafe_image_url_in_line(source, &lower, line_start, line_end) {
            return Some(found);
        }
        if line_end >= lower.len() {
            break;
        }
        line_start = line_end + 1;
    }
    None
}

fn unsafe_image_url_in_line(
    source: &str,
    lower: &str,
    line_start: usize,
    line_end: usize,
) -> Option<String> {
    let line = &lower[line_start..line_end];
    let bytes = lower.as_bytes();
    let mut cursor = 0usize;
    let mut keyword_end = None;
    while let Some(offset) = line[cursor..].find("im") {
        let at = cursor + offset;
        cursor = at + 2;
        let absolute = line_start + at;
        if absolute > 0 && is_ident_byte(bytes[absolute - 1]) {
            continue;
        }
        for keyword in ["image", "img"] {
            if line[at..].starts_with(keyword) {
                let boundary = line_start + at + keyword.len();
                if boundary >= line_end || !is_ident_byte(bytes[boundary]) {
                    keyword_end = Some(at + keyword.len());
                    break;
                }
            }
        }
        if keyword_end.is_some() {
            break;
        }
    }
    let mut search = keyword_end?;
    while let Some(offset) = line[search..].find("src=") {
        let at = search + offset;
        search = at + 4;
        let absolute = line_start + at;
        if absolute > 0 && is_ident_byte(bytes[absolute - 1]) {
            continue;
        }
        let raw = read_image_src(source, line_start + at + 3, line_end)?;
        let url = if raw.starts_with('{') {
            decode_braced(&raw)
        } else {
            decode_bare(&raw)
        };
        if is_safe_crepus_image_url(&url) {
            continue;
        }
        let shown = if url.is_empty() { "<empty>" } else { &url };
        return Some(format!("Invalid crepus image URL: {shown}"));
    }
    None
}

/// Reads the raw `src=` value: a `{…}` block or a run of non-whitespace.
fn read_image_src(source: &str, equals_at: usize, line_end: usize) -> Option<String> {
    let bytes = source.as_bytes();
    let start = equals_at + 1;
    if start >= line_end {
        return None;
    }
    if bytes[start] == b'{' {
        let mut cursor = start + 1;
        while cursor < line_end && bytes[cursor] != b'}' {
            cursor += 1;
        }
        if cursor >= line_end {
            return None;
        }
        return Some(source[start..=cursor].to_string());
    }
    let mut cursor = start;
    while cursor < line_end && !(bytes[cursor] as char).is_whitespace() {
        cursor += 1;
    }
    if cursor == start {
        return None;
    }
    Some(source[start..cursor].to_string())
}

/// Trim, bound and scan a candidate `.crepus` source.
pub fn validate_crepus(value: &str) -> CrepusValidation {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return CrepusValidation::Err("Invalid crepus: must not be blank".to_string());
    }
    if trimmed.chars().count() > CREPUS_MAX_LEN {
        return CrepusValidation::Err("Invalid crepus: exceeds maximum length".to_string());
    }
    if let Some(error) = find_disallowed_crepus_action(trimmed) {
        return CrepusValidation::Err(error);
    }
    if let Some(error) = find_unsafe_crepus_image_url(trimmed) {
        return CrepusValidation::Err(error);
    }
    CrepusValidation::Ok(trimmed.to_string())
}

/// Pass-through rejection: the validated source, or `None`.
pub fn sanitize_crepus(value: &str) -> Option<String> {
    match validate_crepus(value) {
        CrepusValidation::Ok(source) => Some(source),
        CrepusValidation::Err(_) => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_the_closed_action_verb_set() {
        for action in [
            "complete",
            "accept",
            "prompt:pull up the mocks",
            "compute:summarise",
            "open:https://example.com/a",
            "open:http://example.com",
        ] {
            assert!(is_allowed_crepus_action(action), "{action} should be allowed");
        }
        for action in [
            "exec:rm -rf /",
            "open:file:///etc/passwd",
            "open:javascript:alert(1)",
            "prompt:",
            "compute:   ",
            "open:not-a-url",
            "",
        ] {
            assert!(
                !is_allowed_crepus_action(action),
                "{action} should be refused"
            );
        }
    }

    #[test]
    fn rejects_unknown_action_verbs_in_a_source_document() {
        let hostile = "stack col\n  button \"Run\" onclick={exec:rm -rf /}\n  text \"hi\"";
        assert_eq!(
            find_disallowed_crepus_action(hostile).as_deref(),
            Some("Invalid crepus action: exec:rm -rf /")
        );
        let allowed = "stack col\n  button \"Prep\" onclick={prompt:pull up the mocks}\n  button \"Done\" onclick=complete";
        assert_eq!(find_disallowed_crepus_action(allowed), None);
        assert!(validate_crepus(allowed).is_ok());
        assert_eq!(
            validate_crepus(hostile).error(),
            Some("Invalid crepus action: exec:rm -rf /")
        );
    }

    #[test]
    fn reads_every_accepted_event_attribute_spelling() {
        for source in [
            "button onclick=\"exec:boom\"",
            "button onchange=exec:boom",
            "button onlongpress={exec:boom}",
            "button onlong-press=\"exec:boom\"",
            "button onlong_press=exec:boom",
            "button onclick_=exec:boom",
        ] {
            assert_eq!(
                find_disallowed_crepus_action(source).as_deref(),
                Some("Invalid crepus action: exec:boom"),
                "{source}"
            );
        }
        // A word ending in "on" is not an event attribute, and neither is a
        // spelling the renderer does not accept.
        assert_eq!(find_disallowed_crepus_action("button icon=exec:boom"), None);
        assert_eq!(
            find_disallowed_crepus_action("button on-long-press=exec:boom"),
            None
        );
    }

    #[test]
    fn rejects_private_and_oversized_image_urls() {
        for url in [
            "http://127.0.0.1/a.png",
            "http://localhost/a.png",
            "http://10.1.2.3/a.png",
            "http://192.168.0.1/a.png",
            "http://172.16.0.1/a.png",
            "http://169.254.169.254/latest/meta-data",
            "http://box.local/a.png",
            "http://svc.internal/a.png",
            "http://[::1]/a.png",
            "https://user:pass@example.com/a.png",
            "ftp://example.com/a.png",
            "not-a-url",
            "",
        ] {
            assert!(!is_safe_crepus_image_url(url), "{url} should be refused");
        }
        assert!(is_safe_crepus_image_url("https://cdn.example.com/a.png"));
        assert!(is_safe_crepus_image_url("http://203.0.113.7/a.png"));

        let overlong = format!("https://example.com/{}", "a".repeat(CREPUS_IMAGE_URL_MAX_LEN));
        assert!(!is_safe_crepus_image_url(&overlong));
    }

    #[test]
    fn finds_the_unsafe_image_source_in_a_document() {
        assert_eq!(
            find_unsafe_crepus_image_url("stack col\n  image src=http://127.0.0.1/a.png").as_deref(),
            Some("Invalid crepus image URL: http://127.0.0.1/a.png")
        );
        assert_eq!(
            find_unsafe_crepus_image_url("img src={http://localhost/x.png}").as_deref(),
            Some("Invalid crepus image URL: http://localhost/x.png")
        );
        assert_eq!(
            find_unsafe_crepus_image_url("image src=https://cdn.example.com/a.png"),
            None
        );
        // `src=` on a line without an image keyword is not scanned.
        assert_eq!(
            find_unsafe_crepus_image_url("audio src=http://127.0.0.1/a.wav"),
            None
        );
    }

    #[test]
    fn bounds_and_trims_the_source() {
        assert_eq!(
            validate_crepus("  text \"hi\"  ").value(),
            Some("text \"hi\"")
        );
        assert_eq!(
            validate_crepus("   \n  ").error(),
            Some("Invalid crepus: must not be blank")
        );
        let huge = "a".repeat(CREPUS_MAX_LEN + 1);
        assert_eq!(
            validate_crepus(&huge).error(),
            Some("Invalid crepus: exceeds maximum length")
        );
        let exact = "a".repeat(CREPUS_MAX_LEN);
        assert_eq!(validate_crepus(&exact).value(), Some(exact.as_str()));
    }

    #[test]
    fn sanitize_drops_every_rejected_source() {
        assert_eq!(sanitize_crepus("text \"ok\""), Some("text \"ok\"".to_string()));
        assert_eq!(sanitize_crepus("button onclick={exec:boom}"), None);
        assert_eq!(sanitize_crepus("image src=http://127.0.0.1/a.png"), None);
        assert_eq!(sanitize_crepus("  "), None);
    }
}
