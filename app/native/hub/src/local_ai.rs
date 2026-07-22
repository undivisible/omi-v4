#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
use std::time::Duration;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const SUMMARY_TIMEOUT: Duration = Duration::from_secs(12);
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(20);
const SUMMARY_CHARS: usize = 420;

pub fn is_available() -> bool {
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        rs_ai_local::foundationmodels::is_available()
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        false
    }
}

pub async fn summarize(prompt: &str) -> Option<String> {
    if !is_available() {
        return None;
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let options = rs_ai_local::foundationmodels::GenerationOptions {
            temperature: Some(0.1),
            max_tokens: Some(160),
        };
        tokio::time::timeout(
            SUMMARY_TIMEOUT,
            rs_ai_local::foundationmodels::respond_with_options(prompt, &options),
        )
        .await
        .ok()?
        .ok()
        .and_then(|value| clean_summary(&value))
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        let _ = prompt;
        None
    }
}

pub async fn respond(prompt: &str) -> Option<String> {
    if !is_available() {
        return None;
    }
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let options = rs_ai_local::foundationmodels::GenerationOptions {
            temperature: Some(0.2),
            max_tokens: Some(512),
        };
        tokio::time::timeout(
            RESPONSE_TIMEOUT,
            rs_ai_local::foundationmodels::respond_with_options(prompt, &options),
        )
        .await
        .ok()?
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    }
    #[cfg(not(all(target_os = "macos", target_arch = "aarch64")))]
    {
        let _ = prompt;
        None
    }
}

/// Summarize with the on-device model, falling back to the dev-only direct
/// Gemini path when local AI is unavailable and a developer key is present.
/// The fallback prompt is a redacted variant (no document gists) because it
/// leaves the device; see scan::SummaryPrompts.
pub async fn summarize_with_dev_fallback(
    local_prompt: &str,
    fallback_prompt: &str,
) -> Option<String> {
    if let Some(value) = summarize(local_prompt).await {
        return Some(value);
    }
    let key = crate::dev_gemini::api_key()?;
    crate::dev_gemini::generate(&key, fallback_prompt)
        .await
        .and_then(|value| clean_summary(&value))
}

/// Emphasis markers: `**name**` spans are a machine protocol the renderer
/// turns into full-opacity text, so balanced double asterisks survive
/// cleanup while every other markdown character is stripped. Unbalanced or
/// excessive (> MAX_EMPHASIS_SPANS) markers are stripped entirely so stray
/// asterisks never reach the screen.
const MAX_EMPHASIS_SPANS: usize = 5;
const EMPHASIS_PLACEHOLDER: char = '\u{1f}';

fn clean_summary(value: &str) -> Option<String> {
    let value = value.replace("**", &EMPHASIS_PLACEHOLDER.to_string());
    let value = value
        .replace(['*', '`', '#'], "")
        .split_whitespace()
        .map(|word| word.trim_matches('_'))
        .collect::<Vec<_>>()
        .join(" ");
    let markers = value.matches(EMPHASIS_PLACEHOLDER).count();
    let keep_markers =
        markers > 0 && markers.is_multiple_of(2) && markers / 2 <= MAX_EMPHASIS_SPANS;
    let value = if keep_markers {
        value.replace(EMPHASIS_PLACEHOLDER, "**")
    } else {
        value.replace(EMPHASIS_PLACEHOLDER, "")
    };
    let value = truncate_at_sentence(&value, SUMMARY_CHARS);
    let trailing = value.matches("**").count();
    let value = if trailing.is_multiple_of(2) {
        value
    } else {
        value.replace("**", "")
    };
    (!value.is_empty()).then_some(value)
}

fn truncate_at_sentence(value: &str, limit: usize) -> String {
    if value.chars().count() <= limit {
        return value.to_owned();
    }
    let bounded = value.chars().take(limit).collect::<String>();
    let end = bounded
        .char_indices()
        .filter(|(_, character)| matches!(character, '.' | '!' | '?'))
        .map(|(index, character)| index + character.len_utf8())
        .next_back();
    match end {
        Some(end) => bounded[..end].to_owned(),
        None => bounded
            .rsplit_once(' ')
            .map_or(bounded.clone(), |(head, _)| head.to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn summaries_are_single_line_and_bounded() {
        let summary =
            clean_summary(&format!("  first\nsecond  {}", "x".repeat(400))).unwrap_or_default();
        assert!(summary.starts_with("first second"));
        assert!(!summary.contains('\n'));
        assert!(summary.chars().count() <= SUMMARY_CHARS);
    }

    #[test]
    fn summaries_drop_markdown_but_keep_emphasis_protocol() {
        let summary =
            clean_summary("**Quote Stage** and `code` with _emphasis_ # done").unwrap_or_default();
        assert_eq!(summary, "**Quote Stage** and code with emphasis done");
        let stray = clean_summary("a * lone marker `x`").unwrap_or_default();
        assert_eq!(stray, "a lone marker x");
    }

    #[test]
    fn unbalanced_or_excessive_emphasis_markers_are_stripped() {
        let unbalanced = clean_summary("You ship **omi-v4 daily").unwrap_or_default();
        assert_eq!(unbalanced, "You ship omi-v4 daily");
        let excessive = (0..7)
            .map(|index| format!("**word{index}**"))
            .collect::<Vec<_>>()
            .join(" ");
        let cleaned = clean_summary(&excessive).unwrap_or_default();
        assert!(!cleaned.contains('*'));
        assert!(cleaned.contains("word0"));
    }

    #[test]
    fn summaries_truncate_at_sentence_boundaries() {
        let long = format!("First sentence. Second sentence! {}", "word ".repeat(120));
        let summary = clean_summary(&long).unwrap_or_default();
        assert_eq!(summary, "First sentence. Second sentence!");
        let unbroken = "word ".repeat(120);
        let summary = clean_summary(&unbroken).unwrap_or_default();
        assert!(summary.chars().count() <= SUMMARY_CHARS);
        assert!(summary.ends_with("word"));
    }
}
