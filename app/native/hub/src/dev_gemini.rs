//! Dev-only direct Gemini access.
//!
//! When no assistant provider is configured (no account, no worker), the hub
//! can fall back to calling Gemini directly with a developer-supplied API key.
//! The key is resolved, in order, from:
//!   1. the `GEMINI_API_KEY` environment variable
//!   2. `~/.config/omi/dev.env` (`KEY=value` lines)
//!   3. `~/Library/Application Support/omi/dev.env` (macOS; the stable
//!      location a discovered key is copied to, so launches via
//!      Finder/`open` — empty shell env, `cwd=/` — still find it)
//!   4. `worker/.dev.vars` or `../worker/.dev.vars` relative to the working
//!      directory (the same file the Worker uses in dev)
//!
//! This path is for local development only. The key is never logged and is
//! redacted from Debug output.

use std::path::{Path, PathBuf};
use std::time::Duration;

const GENERATE_TIMEOUT: Duration = Duration::from_secs(20);

/// The Gemini Live model the no-account fallback opens a session against.
pub(crate) const LIVE_MODEL: &str = "gemini-3.1-flash-live-preview";

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct DevGeminiKey(pub(crate) String);

impl std::fmt::Debug for DevGeminiKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("DevGeminiKey([redacted])")
    }
}

pub(crate) fn api_key() -> Option<DevGeminiKey> {
    resolve(
        std::env::var("GEMINI_API_KEY").ok().as_deref(),
        std::env::var_os("HOME").as_deref(),
        Path::new("."),
        true,
    )
}

/// Resolves a key from the environment first and the candidate files second,
/// then copies whatever it found to the stable per-user location so a launch
/// with no shell environment (Finder, `open`) still finds it. `persist` is off
/// in tests that only care about the lookup order.
pub(crate) fn resolve(
    environment_key: Option<&str>,
    home: Option<&std::ffi::OsStr>,
    working_directory: &Path,
    persist: bool,
) -> Option<DevGeminiKey> {
    let found = environment_key.and_then(valid_key).or_else(|| {
        candidate_files_for_home(home, working_directory)
            .into_iter()
            .find_map(|path| {
                std::fs::read_to_string(&path)
                    .ok()
                    .and_then(|contents| parse_env_value(&contents, "GEMINI_API_KEY"))
                    .as_deref()
                    .and_then(valid_key)
            })
    })?;
    if persist {
        persist_key(&found, home);
    }
    Some(found)
}

/// Stable per-user location that survives Finder/`open` launches (no shell
/// environment, `cwd=/`). A key found anywhere else is copied here.
fn persist_path_for_home(home: Option<&std::ffi::OsStr>) -> Option<PathBuf> {
    let home = home.filter(|home| !home.is_empty())?;
    Some(if cfg!(target_os = "macos") {
        Path::new(home).join("Library/Application Support/omi/dev.env")
    } else {
        Path::new(home).join(".config/omi/dev.env")
    })
}

fn persist_key(key: &DevGeminiKey, home: Option<&std::ffi::OsStr>) {
    let Some(path) = persist_path_for_home(home) else {
        return;
    };
    if std::fs::read_to_string(&path)
        .ok()
        .and_then(|contents| parse_env_value(&contents, "GEMINI_API_KEY"))
        .as_deref()
        == Some(key.0.as_str())
    {
        return;
    }
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::write(&path, format!("GEMINI_API_KEY={}\n", key.0));
}

/// Where a key may be placed, for actionable error messages. Never includes
/// key material.
pub(crate) fn missing_key_hint() -> String {
    let paths = candidate_files_for_home(std::env::var_os("HOME").as_deref(), Path::new("."))
        .iter()
        .map(|path| path.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "No developer Gemini key found. Set GEMINI_API_KEY in one of: {paths} — then relaunch Omi."
    )
}

fn candidate_files_for_home(
    home: Option<&std::ffi::OsStr>,
    working_directory: &Path,
) -> Vec<PathBuf> {
    let mut files = Vec::new();
    if let Some(home) = home.filter(|home| !home.is_empty()) {
        files.push(Path::new(home).join(".config/omi/dev.env"));
        if cfg!(target_os = "macos") {
            files.push(Path::new(home).join("Library/Application Support/omi/dev.env"));
        }
    }
    files.push(working_directory.join("worker/.dev.vars"));
    files.push(working_directory.join("../worker/.dev.vars"));
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
    let model = crate::model_tier::model_for_tier_env(crate::model_tier::ModelTier::Speed);
    let url =
        format!("https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent");
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
        let files =
            candidate_files_for_home(Some(std::ffi::OsStr::new("/home/dev")), Path::new("."));
        assert_eq!(
            files.first(),
            Some(&PathBuf::from("/home/dev/.config/omi/dev.env"))
        );
        if cfg!(target_os = "macos") {
            assert!(files.contains(&PathBuf::from(
                "/home/dev/Library/Application Support/omi/dev.env"
            )));
        }
        assert!(files.contains(&PathBuf::from("./worker/.dev.vars")));
        assert!(files.contains(&PathBuf::from("./../worker/.dev.vars")));

        let no_home = candidate_files_for_home(None, Path::new("."));
        assert_eq!(no_home.first(), Some(&PathBuf::from("./worker/.dev.vars")));
    }

    struct Sandbox {
        root: PathBuf,
    }

    impl Sandbox {
        fn new(name: &str) -> Self {
            let root =
                std::env::temp_dir().join(format!("dev-gemini-{name}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&root);
            let _ = std::fs::create_dir_all(root.join("home"));
            let _ = std::fs::create_dir_all(root.join("repo/worker"));
            Self { root }
        }

        fn home(&self) -> PathBuf {
            self.root.join("home")
        }

        fn repo(&self) -> PathBuf {
            self.root.join("repo")
        }

        fn write_key(&self, path: &Path, key: &str) {
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            let _ = std::fs::write(path, format!("GEMINI_API_KEY={key}\n"));
        }

        fn resolve(&self, environment_key: Option<&str>, persist: bool) -> Option<String> {
            let home = self.home();
            super::resolve(
                environment_key,
                Some(home.as_os_str()),
                &self.repo(),
                persist,
            )
            .map(|key| key.0)
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    #[test]
    fn environment_variable_wins_over_all_files() {
        let sandbox = Sandbox::new("environment");
        sandbox.write_key(&sandbox.home().join(".config/omi/dev.env"), "AIzaConfig");
        assert_eq!(
            sandbox.resolve(Some("AIzaEnv"), false),
            Some("AIzaEnv".to_owned())
        );
    }

    #[test]
    fn config_file_is_read_when_the_environment_has_no_key() {
        let sandbox = Sandbox::new("config-file");
        sandbox.write_key(&sandbox.home().join(".config/omi/dev.env"), "AIzaConfig");
        assert_eq!(sandbox.resolve(None, false), Some("AIzaConfig".to_owned()));
    }

    #[test]
    fn worker_dev_vars_are_the_last_resort() {
        let sandbox = Sandbox::new("dev-vars");
        sandbox.write_key(&sandbox.repo().join("worker/.dev.vars"), "AIzaWorker");
        assert_eq!(sandbox.resolve(None, false), Some("AIzaWorker".to_owned()));
    }

    #[test]
    fn a_found_key_is_copied_to_the_stable_location() {
        let sandbox = Sandbox::new("persist");
        sandbox.write_key(&sandbox.repo().join("worker/.dev.vars"), "AIzaWorker");
        assert_eq!(sandbox.resolve(None, true), Some("AIzaWorker".to_owned()));
        let stable = persist_path_for_home(Some(sandbox.home().as_os_str()));
        let contents = stable
            .as_deref()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .unwrap_or_default();
        assert_eq!(
            parse_env_value(&contents, "GEMINI_API_KEY").as_deref(),
            Some("AIzaWorker")
        );
    }

    #[test]
    fn nothing_is_written_when_no_key_is_found() {
        let sandbox = Sandbox::new("no-key");
        assert_eq!(sandbox.resolve(None, true), None);
        let stable = persist_path_for_home(Some(sandbox.home().as_os_str()));
        assert!(stable.is_some_and(|path| !path.exists()));
    }

    #[test]
    fn placeholder_keys_in_files_are_ignored() {
        let sandbox = Sandbox::new("placeholder");
        sandbox.write_key(
            &sandbox.home().join(".config/omi/dev.env"),
            "your-gemini-api-key-here",
        );
        assert_eq!(sandbox.resolve(None, false), None);
    }

    #[test]
    fn the_missing_key_hint_names_the_candidate_paths_and_no_key() {
        let hint = missing_key_hint();
        assert!(hint.contains("GEMINI_API_KEY"));
        assert!(hint.contains("worker/.dev.vars"));
        assert!(hint.contains("relaunch Omi"));
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
