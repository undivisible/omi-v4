use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

pub const SOUL_SECTIONS: &[&str] = &[
    "Identity",
    "Goals",
    "Work",
    "Preferences",
    "Routines",
    "Beliefs",
    "Constraints",
    "People",
    "Health",
    "Context",
];

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UserProfileDocument {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub languages: Vec<String>,
    #[serde(default)]
    pub soul: HashMap<String, String>,
    #[serde(default)]
    pub custom_prompt: Option<String>,
}

pub fn user_profile_path(database_path: &str) -> PathBuf {
    Path::new(database_path).with_extension("user_profile.json")
}

pub fn read_user_profile(path: &Path) -> Option<UserProfileDocument> {
    let raw = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

pub fn is_soul_section_key(key: &str) -> bool {
    SOUL_SECTIONS
        .iter()
        .any(|section| section.eq_ignore_ascii_case(key.trim()))
}

pub fn format_about_user(document: &UserProfileDocument) -> Option<String> {
    let mut facts: Vec<String> = Vec::new();
    if let Some(name) = document
        .name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        facts.push(format!("The user's name is {name}."));
    }
    if !document.languages.is_empty() {
        facts.push(format!(
            "The user's preferred languages: {}.",
            document.languages.join(", ")
        ));
    }
    for section in SOUL_SECTIONS {
        let Some(text) = document.soul.get(*section) else {
            continue;
        };
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }
        facts.push(format!("User context — {section}:\n{trimmed}"));
    }
    if facts.is_empty() {
        None
    } else {
        Some(format!("About the user:\n{}", facts.join("\n")))
    }
}

pub fn custom_prompt(document: &UserProfileDocument) -> Option<String> {
    document
        .custom_prompt
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_name_languages_and_soul_sections() {
        let document = UserProfileDocument {
            name: Some("Alex".to_owned()),
            languages: vec!["English".to_owned(), "Spanish".to_owned()],
            soul: HashMap::from([
                ("Beliefs".to_owned(), "Honesty over comfort.".to_owned()),
                ("Goals".to_owned(), "Ship Omi.".to_owned()),
            ]),
            custom_prompt: None,
        };
        let formatted = format_about_user(&document).expect("profile block");
        assert!(formatted.starts_with("About the user:\n"));
        assert!(formatted.contains("The user's name is Alex."));
        assert!(formatted.contains("The user's preferred languages: English, Spanish."));
        assert!(formatted.contains("User context — Beliefs:\nHonesty over comfort."));
        assert!(formatted.contains("User context — Goals:\nShip Omi."));
    }

    #[test]
    fn soul_section_keys_are_detected_case_insensitively() {
        assert!(is_soul_section_key("beliefs"));
        assert!(is_soul_section_key("Goals"));
        assert!(!is_soul_section_key("name"));
    }
}
