#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
use std::time::Duration;

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const SUMMARY_TIMEOUT: Duration = Duration::from_secs(12);
#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(20);
#[cfg(any(all(target_os = "macos", target_arch = "aarch64"), test))]
const SUMMARY_CHARS: usize = 280;

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
            temperature: Some(0.2),
            max_tokens: Some(96),
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

#[cfg(any(all(target_os = "macos", target_arch = "aarch64"), test))]
fn clean_summary(value: &str) -> Option<String> {
    let value = value.split_whitespace().collect::<Vec<_>>().join(" ");
    let value = value.chars().take(SUMMARY_CHARS).collect::<String>();
    (!value.is_empty()).then_some(value)
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
}
