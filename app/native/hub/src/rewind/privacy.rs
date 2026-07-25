//! What Rewind refuses to photograph, and why a frame was not taken.
//!
//! Every rule here is a refusal, never a permission: the defaults deny, the
//! user may deny more, and nothing in the settings file can quietly withdraw a
//! default denial. That asymmetry is the point — a bug in the settings path
//! must cost a missing frame, never a recorded password vault.

use serde_json::{Map, Value};
use std::collections::BTreeSet;

use super::models::WindowContext;

/// The apps Rewind refuses to photograph out of the box. Password managers and
/// the system keychain are the obvious ones: a screenshot of an unlocked vault
/// is a plaintext credential dump sitting on disk, and no retention bound
/// makes that acceptable. This list is the default, not the whole story — the
/// user can add to it, and nothing removes an entry silently.
pub const DEFAULT_DENIED_BUNDLE_IDS: &[&str] = &[
    "com.1password.1password",
    "com.1password.1password7",
    "com.agilebits.onepassword7",
    "com.agilebits.onepassword-osx",
    "com.bitwarden.desktop",
    "org.keepassxc.keepassxc",
    "com.dashlane.dashlanephoenix",
    "com.lastpass.lastpassmacdesktop",
    "in.sinew.Enpass-Desktop",
    "me.proton.pass.electron",
    "com.apple.keychainaccess",
    "com.apple.Passwords",
    "com.strongbox.mac.strongbox",
    "com.nordpass.macos",
    "com.callpod.keeper",
];

/// Window-title markers that mean "this window is a private browsing session".
/// Browsers do not expose an is-private flag to other processes, and the title
/// is the only signal that crosses the process boundary, so this is a
/// heuristic — but it is a conservative one: a false positive costs a missing
/// frame, a false negative costs a recorded private session.
const PRIVATE_WINDOW_MARKERS: &[&str] = &[
    "private browsing",
    "incognito",
    "inprivate",
    "private window",
    "privé", // Safari, French locale.
];

/// Why a frame was not taken. Carried into the UI so a user who wonders "is it
/// recording right now?" gets a truthful answer instead of a spinner.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SkipReason {
    DeniedApp,
    PrivateWindow,
    ScreenLocked,
    Paused,
    Idle,
    Heartbeat,
    MinimumInterval,
    Busy,
    Unchanged,
    NoPermission,
}

/// The user-editable privacy configuration. Values are replaced wholesale
/// rather than mutated in place, so a change can never be half-applied
/// mid-capture.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PrivacySettings {
    /// A sorted set, so the settings file is stable across writes and a
    /// reordering is never mistaken for a change.
    pub denied_bundle_ids: BTreeSet<String>,
    /// Skip any window whose title looks like a private browsing session.
    pub skip_private_browsing: bool,
    /// Window titles are the most useful thing in the timeline and also the most
    /// revealing. The user can turn them off and keep only app names.
    pub record_window_titles: bool,
    /// Run Apple's Vision text recognition over each stored frame, on-device,
    /// and keep the result so the timeline is searchable. Off means the frames
    /// stay images and nothing is transcribed.
    pub read_on_screen_text: bool,
}

impl Default for PrivacySettings {
    fn default() -> Self {
        Self {
            denied_bundle_ids: default_denied(),
            skip_private_browsing: true,
            record_window_titles: true,
            read_on_screen_text: true,
        }
    }
}

fn default_denied() -> BTreeSet<String> {
    DEFAULT_DENIED_BUNDLE_IDS
        .iter()
        .map(|id| (*id).to_owned())
        .collect()
}

impl PrivacySettings {
    /// The reason this context must not be captured, or `None` when it may be.
    pub fn denial_for(&self, context: &WindowContext) -> Option<SkipReason> {
        if let Some(bundle_id) = context.bundle_id.as_ref()
            && self.denied_bundle_ids.contains(bundle_id)
        {
            return Some(SkipReason::DeniedApp);
        }
        if self.skip_private_browsing && looks_private(context.window_title.as_deref()) {
            return Some(SkipReason::PrivateWindow);
        }
        None
    }

    /// Adds one bundle id. Blank input is ignored rather than stored, so a
    /// stray return in the settings field cannot poison the list.
    pub fn deny(&mut self, bundle_id: &str) {
        let trimmed = bundle_id.trim();
        if !trimmed.is_empty() {
            self.denied_bundle_ids.insert(trimmed.to_owned());
        }
    }

    pub fn allow(&mut self, bundle_id: &str) {
        self.denied_bundle_ids.remove(bundle_id);
    }

    pub fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert(
            "deniedBundleIds".into(),
            Value::Array(
                self.denied_bundle_ids
                    .iter()
                    .map(|id| Value::from(id.clone()))
                    .collect(),
            ),
        );
        map.insert(
            "skipPrivateBrowsing".into(),
            Value::from(self.skip_private_browsing),
        );
        map.insert(
            "recordWindowTitles".into(),
            Value::from(self.record_window_titles),
        );
        map.insert(
            "readOnScreenText".into(),
            Value::from(self.read_on_screen_text),
        );
        Value::Object(map)
    }

    /// Restores the stored configuration, unioned with the defaults. The union
    /// is deliberate: an edited or truncated settings file can add exclusions
    /// but can never silently drop the ones Omi ships with.
    pub fn from_json(value: Option<&Value>) -> Self {
        let Some(Value::Object(map)) = value else {
            return Self::default();
        };
        let mut denied = default_denied();
        if let Some(Value::Array(stored)) = map.get("deniedBundleIds") {
            for entry in stored {
                if let Some(id) = entry.as_str()
                    && !id.trim().is_empty()
                {
                    denied.insert(id.to_owned());
                }
            }
        }
        Self {
            denied_bundle_ids: denied,
            skip_private_browsing: flag(map.get("skipPrivateBrowsing")),
            record_window_titles: flag(map.get("recordWindowTitles")),
            read_on_screen_text: flag(map.get("readOnScreenText")),
        }
    }
}

/// A missing or malformed flag reads as `true`, matching the Dart defaults:
/// every one of these three is a protection or an on-by-default convenience,
/// and a corrupt file must not turn a protection off.
fn flag(value: Option<&Value>) -> bool {
    value.and_then(Value::as_bool).unwrap_or(true)
}

pub fn looks_private(window_title: Option<&str>) -> bool {
    let Some(title) = window_title else {
        return false;
    };
    let lower = title.to_lowercase();
    PRIVATE_WINDOW_MARKERS
        .iter()
        .any(|marker| lower.contains(marker))
}

#[cfg(test)]
mod tests {
    use super::{PrivacySettings, SkipReason, looks_private};
    use crate::rewind::models::WindowContext;

    fn context(bundle_id: Option<&str>, window_title: Option<&str>) -> WindowContext {
        WindowContext {
            bundle_id: bundle_id.map(str::to_owned),
            app_name: bundle_id.map(str::to_owned),
            window_title: window_title.map(str::to_owned),
        }
    }

    /// Ported from `rewind_store_test.dart`, "the default exclusion list
    /// covers password managers".
    #[test]
    fn the_default_exclusion_list_covers_password_managers() {
        let privacy = PrivacySettings::default();
        assert_eq!(
            privacy.denial_for(&context(Some("com.1password.1password"), None)),
            Some(SkipReason::DeniedApp)
        );
        assert_eq!(
            privacy.denial_for(&context(Some("org.keepassxc.keepassxc"), None)),
            Some(SkipReason::DeniedApp)
        );
        assert_eq!(
            privacy.denial_for(&context(Some("com.apple.Terminal"), None)),
            None
        );
    }

    /// Ported from `rewind_store_test.dart`, "a user cannot silently lose the
    /// default exclusions".
    #[test]
    fn a_user_cannot_silently_lose_the_default_exclusions() {
        let stored = serde_json::json!({ "deniedBundleIds": ["com.example.app"] });
        let restored = PrivacySettings::from_json(Some(&stored));
        assert!(restored.denied_bundle_ids.contains("com.example.app"));
        assert!(
            restored
                .denied_bundle_ids
                .contains("com.1password.1password")
        );
    }

    #[test]
    fn a_private_looking_title_is_skipped_unless_the_user_turned_that_off() {
        let mut privacy = PrivacySettings::default();
        let window = context(Some("com.apple.Safari"), Some("Search — Private Browsing"));
        assert_eq!(privacy.denial_for(&window), Some(SkipReason::PrivateWindow));
        privacy.skip_private_browsing = false;
        assert_eq!(privacy.denial_for(&window), None);
    }

    #[test]
    fn the_private_window_heuristic_is_case_and_locale_tolerant() {
        assert!(looks_private(Some("INCOGNITO")));
        assert!(looks_private(Some("Nouvelle fenêtre privée")));
        assert!(looks_private(Some("Docs — InPrivate")));
        assert!(!looks_private(Some("Private equity returns")));
        assert!(!looks_private(None));
    }

    #[test]
    fn a_blank_exclusion_is_ignored_and_an_allowed_one_is_removed() {
        let mut privacy = PrivacySettings::default();
        let before = privacy.denied_bundle_ids.len();
        privacy.deny("   ");
        assert_eq!(privacy.denied_bundle_ids.len(), before);
        privacy.deny("  com.example.app  ");
        assert!(privacy.denied_bundle_ids.contains("com.example.app"));
        privacy.allow("com.example.app");
        assert!(!privacy.denied_bundle_ids.contains("com.example.app"));
    }

    #[test]
    fn a_corrupt_settings_file_leaves_every_protection_on() {
        let restored = PrivacySettings::from_json(Some(&serde_json::json!({
            "deniedBundleIds": "not a list",
            "skipPrivateBrowsing": "not a bool",
        })));
        assert!(restored.skip_private_browsing);
        assert!(restored.record_window_titles);
        assert!(restored.read_on_screen_text);
        assert!(
            restored
                .denied_bundle_ids
                .contains("com.1password.1password")
        );
    }

    #[test]
    fn privacy_settings_round_trip_through_the_settings_file() {
        let mut privacy = PrivacySettings::default();
        privacy.deny("com.example.app");
        privacy.read_on_screen_text = false;
        privacy.record_window_titles = false;
        assert_eq!(
            PrivacySettings::from_json(Some(&privacy.to_json())),
            privacy
        );
    }
}
