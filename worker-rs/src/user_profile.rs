//! The "about the user" block injected into memory context: a stable set of
//! soul sections, folded into prose alongside the user's name and languages.

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

const STABLE_SOUL_SECTIONS: &[&str] =
    &["Identity", "Goals", "Preferences", "Beliefs", "Constraints"];

pub fn is_soul_section_key(key: &str) -> bool {
    let key = key.trim();
    SOUL_SECTIONS
        .iter()
        .any(|section| section.eq_ignore_ascii_case(key))
}

pub fn soul_section_stability(section: &str) -> &'static str {
    if STABLE_SOUL_SECTIONS.contains(&section) {
        "stable"
    } else {
        "current"
    }
}

/// `formatAboutUser` — `None` when there is nothing to say.
pub fn format_about_user(
    name: Option<&str>,
    languages: &[String],
    soul: &dyn Fn(&str) -> Option<String>,
) -> Option<String> {
    let mut facts: Vec<String> = Vec::new();
    if let Some(name) = name.map(str::trim).filter(|value| !value.is_empty()) {
        facts.push(format!("The user's name is {name}."));
    }
    let languages: Vec<&str> = languages
        .iter()
        .map(|value| value.as_str())
        .filter(|value| !value.trim().is_empty())
        .collect();
    if !languages.is_empty() {
        facts.push(format!(
            "The user's preferred languages: {}.",
            languages.join(", ")
        ));
    }
    for section in SOUL_SECTIONS {
        let Some(text) = soul(section) else { continue };
        let text = text.trim();
        if text.is_empty() {
            continue;
        }
        facts.push(format!("User context — {section}:\n{text}"));
    }
    if facts.is_empty() {
        return None;
    }
    Some(format!("About the user:\n{}", facts.join("\n")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn soul<'a>(
        entries: &'a [(&'static str, &'static str)],
    ) -> impl Fn(&str) -> Option<String> + 'a {
        move |key: &str| {
            entries
                .iter()
                .find(|(name, _)| *name == key)
                .map(|(_, value)| (*value).to_string())
        }
    }

    #[test]
    fn formats_beliefs_and_goals_into_an_about_the_user_block() {
        let entries = [("Goals", "  Ship v4.  "), ("Beliefs", "Evidence first.")];
        let block = format_about_user(
            Some("  Ada  "),
            &["en".into(), "  ".into()],
            &soul(&entries),
        )
        .expect("a block");
        assert!(block.starts_with("About the user:\n"));
        assert!(block.contains("The user's name is Ada."));
        assert!(block.contains("The user's preferred languages: en."));
        assert!(block.contains("User context — Goals:\nShip v4."));
        assert!(block.contains("User context — Beliefs:\nEvidence first."));
        // Sections are emitted in declaration order, not insertion order.
        assert!(block.find("Goals").unwrap() < block.find("Beliefs").unwrap());
    }

    #[test]
    fn nothing_to_say_is_none() {
        assert_eq!(format_about_user(None, &[], &soul(&[])), None);
        assert_eq!(format_about_user(Some("   "), &[], &soul(&[])), None);
        let blank = [("Goals", "   ")];
        assert_eq!(format_about_user(None, &[], &soul(&blank)), None);
    }

    #[test]
    fn recognizes_soul_section_keys_case_insensitively() {
        assert!(is_soul_section_key("Goals"));
        assert!(is_soul_section_key("goals"));
        assert!(is_soul_section_key("  BELIEFS  "));
        assert!(!is_soul_section_key("name"));
        assert!(!is_soul_section_key(""));
    }

    #[test]
    fn stable_sections_are_the_slow_moving_ones() {
        for section in ["Identity", "Goals", "Preferences", "Beliefs", "Constraints"] {
            assert_eq!(soul_section_stability(section), "stable");
        }
        for section in ["Work", "Routines", "People", "Health", "Context"] {
            assert_eq!(soul_section_stability(section), "current");
        }
    }
}
