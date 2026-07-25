//! Everything the user has decided about Rewind, and the file it lives in.
//!
//! Rewind's settings live in a file rather than in shared preferences on
//! purpose: the macOS settings window is a second Flutter engine with its own
//! isolate and its own preference cache, so a toggle flipped there has to be
//! visible to the engine that is actually capturing. A file is the one place
//! both can see, and it stays a file now that the engine is in Rust for the
//! same reason — whichever process is holding the capture loop is not
//! necessarily the one the user clicked in.

use serde_json::{Map, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use super::models::Retention;
use super::privacy::PrivacySettings;

/// Recording is opt-in: the default is off, and it stays off until the user
/// turns it on in settings.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct Settings {
    /// Master switch. Off by default — continuous screen capture is never
    /// something the app starts doing on its own.
    pub enabled: bool,
    /// The one-click pause. Distinct from [`Self::enabled`] so pausing does not
    /// lose the configuration, and so the indicator can say "paused" rather
    /// than vanishing.
    pub paused: bool,
    pub retention: Retention,
    pub privacy: PrivacySettings,
}

impl Settings {
    pub fn recording(&self) -> bool {
        self.enabled && !self.paused
    }

    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("enabled".into(), Value::from(self.enabled));
        map.insert("paused".into(), Value::from(self.paused));
        map.insert("retention".into(), self.retention.to_json());
        map.insert("privacy".into(), self.privacy.to_json());
        Value::Object(map)
    }

    /// Anything unreadable reads as "off" for the two switches and as the
    /// defaults for everything else, so a damaged settings file can only ever
    /// record less than the user asked for, never more.
    pub fn from_json(value: &Value) -> Self {
        let Value::Object(map) = value else {
            return Self::default();
        };
        Self {
            enabled: map
                .get("enabled")
                .and_then(Value::as_bool)
                .unwrap_or_default(),
            paused: map
                .get("paused")
                .and_then(Value::as_bool)
                .unwrap_or_default(),
            retention: Retention::from_json(map.get("retention")),
            privacy: PrivacySettings::from_json(map.get("privacy")),
        }
    }
}

/// The settings file, plus the modification time the engine last read, so a
/// polling reader can skip the decode when nothing has changed.
pub struct SettingsFile {
    path: PathBuf,
    seen_modified: Option<SystemTime>,
}

impl SettingsFile {
    pub fn new(root: &Path) -> Self {
        Self {
            path: root.join("settings.json"),
            seen_modified: None,
        }
    }

    pub fn read(&mut self) -> Settings {
        self.seen_modified = self.last_modified();
        let Ok(contents) = fs::read_to_string(&self.path) else {
            return Settings::default();
        };
        match serde_json::from_str::<Value>(&contents) {
            Ok(value) => Settings::from_json(&value),
            Err(_) => Settings::default(),
        }
    }

    /// Re-reads only when someone else has written the file since this engine
    /// last touched it. That is the polling half of the two-engine story: the
    /// settings window writes, the capture loop notices on its next tick.
    pub fn read_if_changed(&mut self) -> Option<Settings> {
        let current = self.last_modified();
        if current == self.seen_modified {
            return None;
        }
        Some(self.read())
    }

    pub fn write(&mut self, settings: &Settings) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&self.path, settings.to_json().to_string())?;
        self.seen_modified = self.last_modified();
        Ok(())
    }

    fn last_modified(&self) -> Option<SystemTime> {
        fs::metadata(&self.path)
            .ok()
            .and_then(|meta| meta.modified().ok())
    }
}

#[cfg(test)]
mod tests {
    use super::{Settings, SettingsFile};
    use crate::rewind::models::Retention;
    use std::time::Duration;

    fn scratch(name: &str) -> std::path::PathBuf {
        let root =
            std::env::temp_dir().join(format!("rewind_settings_{name}_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let _ = std::fs::create_dir_all(&root);
        root
    }

    #[test]
    fn recording_is_off_until_the_user_turns_it_on() {
        let settings = Settings::default();
        assert!(!settings.enabled);
        assert!(!settings.recording());
    }

    #[test]
    fn pausing_is_not_the_same_as_turning_it_off() {
        let settings = Settings {
            enabled: true,
            paused: true,
            ..Settings::default()
        };
        assert!(!settings.recording());
        assert!(settings.enabled);
    }

    #[test]
    fn settings_round_trip_through_the_file() {
        let root = scratch("round_trip");
        let mut file = SettingsFile::new(&root);
        assert_eq!(file.read(), Settings::default());

        let mut settings = Settings {
            enabled: true,
            paused: false,
            retention: Retention {
                max_age: Duration::from_secs(24 * 60 * 60),
                max_bytes: 512 * 1024 * 1024,
            },
            ..Settings::default()
        };
        settings.privacy.deny("com.example.app");
        assert!(file.write(&settings).is_ok());

        let mut reopened = SettingsFile::new(&root);
        assert_eq!(reopened.read(), settings);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_corrupt_settings_file_reads_as_off_rather_than_as_on() {
        let root = scratch("corrupt");
        assert!(std::fs::write(root.join("settings.json"), "not json").is_ok());
        let mut file = SettingsFile::new(&root);
        assert_eq!(file.read(), Settings::default());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_untouched_file_is_not_re_read() {
        let root = scratch("unchanged");
        let mut file = SettingsFile::new(&root);
        let settings = Settings {
            enabled: true,
            ..Settings::default()
        };
        assert!(file.write(&settings).is_ok());
        assert_eq!(file.read_if_changed(), None);

        // Another engine writing the same file is what the polling read is
        // there to notice.
        let mut other = SettingsFile::new(&root);
        let flipped = Settings {
            enabled: true,
            paused: true,
            ..Settings::default()
        };
        std::thread::sleep(Duration::from_millis(20));
        assert!(other.write(&flipped).is_ok());
        assert_eq!(file.read_if_changed(), Some(flipped));
        let _ = std::fs::remove_dir_all(&root);
    }
}
