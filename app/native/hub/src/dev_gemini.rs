//! Dev-only direct Gemini access.
//!
//! When no assistant provider is configured (no account, no worker), the hub
//! can fall back to calling Gemini directly with a developer-supplied API key.
//! The key is resolved, in order, from:
//!   1. the `GEMINI_API_KEY` environment variable
//!   2. `~/.config/omi/dev.env` (`KEY=value` lines)
//!   3. `~/Library/Application Support/omi/dev.env` (macOS; the stable
//!      location the Dart side persists a discovered key to, so launches via
//!      Finder/`open` — empty shell env, `cwd=/` — still find it)
//!   4. `worker/.dev.vars` or `../worker/.dev.vars` relative to the working
//!      directory (the same file the Worker uses in dev)
//!
//! This path is for local development only. The key is never logged and is
//! redacted from Debug output.

use std::path::{Path, PathBuf};
use std::time::Duration;

pub(crate) const DEV_GEMINI_MODEL: &str = "gemini-3.1-flash-lite";
const GENERATE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct DevGeminiKey(pub(crate) String);

impl std::fmt::Debug for DevGeminiKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DevGeminiKey([redacted])")
    }
}

pub(crate) fn api_key() -> Option<DevGeminiKey> {
    if let Ok(value) = std::env::var("GEMINI_API_KEY")
        && let Some(key) = valid_key(&value)
    {
        return Some(key);
    }
    for path in candidate_files() {
        if let Ok(contents) = std::fs::read_to_string(&path)
            && let Some(key) =
                parse_env_value(&contents, "GEMINI_API_KEY").and_then(|v| valid_key(&v))
        {
            return Some(key);
        }
    }
    None
}

fn candidate_files() -> Vec<PathBuf> {
    candidate_files_for_home(std::env::var_os("HOME").as_deref())
}

fn candidate_files_for_home(home: Option<&std::ffi::OsStr>) -> Vec<PathBuf> {
    let mut files = Vec::new();
    if let Some(home) = home {
        files.push(Path::new(home).join(".config/omi/dev.env"));
        if cfg!(target_os = "macos") {
            files.push(Path::new(home).join("Library/Application Support/omi/dev.env"));
        }
    }
    files.push(PathBuf::from("worker/.dev.vars"));
    files.push(PathBuf::from("../worker/.dev.vars"));
    files
}

fn valid_key(value: &str) -> Option<DevGeminiKey> {
    let value = value.trim();
    if value.is_empty()
        || value.len() > 256
        || value.contains("your-")
        || value
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
    {
        return None;
    }
    Some(DevGeminiKey(value.to_owned()))
}

pub(crate) fn parse_env_value(contents: &str, name: &str) -> Option<String> {
    for line in contents.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim() != name {
            continue;
        }
        let value = value.trim().trim_matches('"').trim_matches('\'');
        if !value.is_empty() {
            return Some(value.to_owned());
        }
    }
    None
}

/// One-shot text generation against the Gemini `generateContent` REST API.
/// Returns `None` on any failure; failures never include the key.
pub(crate) async fn generate(key: &DevGeminiKey, prompt: &str) -> Option<String> {
    let url = format!(
        "https://generativelanguage.googleapis.com/v1beta/models/{DEV_GEMINI_MODEL}:generateContent"
    );
    let body = serde_json::json!({
        "contents": [{ "parts": [{ "text": prompt }] }],
        "generationConfig": { "temperature": 0.2, "maxOutputTokens": 512 },
    });
    let client = reqwest::Client::builder()
        .timeout(GENERATE_TIMEOUT)
        .build()
        .ok()?;
    let response = client
        .post(&url)
        .header("x-goog-api-key", &key.0)
        .json(&body)
        .send()
        .await
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    let value: serde_json::Value = response.json().await.ok()?;
    let text = value
        .get("candidates")?
        .get(0)?
        .get("content")?
        .get("parts")?
        .get(0)?
        .get("text")?
        .as_str()?
        .trim()
        .to_owned();
    (!text.is_empty()).then_some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn debug_redacts_the_key() {
        let debug = format!("{:?}", DevGeminiKey("secret-key".to_owned()));
        assert!(!debug.contains("secret-key"));
        assert!(debug.contains("[redacted]"));
    }

    #[test]
    fn env_files_are_parsed_as_key_value_lines() {
        let contents = "# comment\nOTHER=1\nGEMINI_API_KEY=\"abc123\"\n";
        assert_eq!(
            parse_env_value(contents, "GEMINI_API_KEY").as_deref(),
            Some("abc123")
        );
        assert_eq!(parse_env_value("GEMINI_API_KEY=", "GEMINI_API_KEY"), None);
        assert_eq!(parse_env_value("", "GEMINI_API_KEY"), None);
    }

    #[test]
    fn candidate_files_include_stable_absolute_locations() {
        let files = candidate_files_for_home(Some(std::ffi::OsStr::new("/home/dev")));
        assert_eq!(
            files.first(),
            Some(&PathBuf::from("/home/dev/.config/omi/dev.env"))
        );
        if cfg!(target_os = "macos") {
            assert!(files.contains(&PathBuf::from(
                "/home/dev/Library/Application Support/omi/dev.env"
            )));
        }
        assert!(files.contains(&PathBuf::from("worker/.dev.vars")));
        assert!(files.contains(&PathBuf::from("../worker/.dev.vars")));

        let no_home = candidate_files_for_home(None);
        assert_eq!(no_home.first(), Some(&PathBuf::from("worker/.dev.vars")));
    }

    #[test]
    fn placeholder_and_malformed_keys_are_rejected() {
        assert!(valid_key("your-gemini-api-key-here").is_none());
        assert!(valid_key("").is_none());
        assert!(valid_key("bad key").is_none());
        assert!(valid_key("bad\nkey").is_none());
        assert_eq!(
            valid_key("AIzaGood").map(|key| key.0),
            Some("AIzaGood".to_owned())
        );
    }
}
