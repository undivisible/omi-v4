#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TurnClass {
    Core,
    Serious,
}

const SERIOUS_CHARACTER_THRESHOLD: usize = 400;

const SERIOUS_PHRASES: &[&str] = &[
    "write code",
    "write a script",
    "write a program",
    "write an essay",
    "write a report",
    "implement",
    "refactor",
    "debug",
    "stack trace",
    "compile",
    "regex",
    "sql",
    "algorithm",
    "step by step",
    "in detail",
    "detailed",
    "analyze",
    "analysis",
    "research",
    "compare and contrast",
    "pros and cons",
    "long form",
    "draft an email",
    "draft a",
    "click",
    "open the",
    "launch",
    "press",
    "type into",
    "set the value",
    "computer",
    "use the online model",
    "use the cloud model",
    "think hard",
];

const CODE_MARKERS: &[&str] = &["```", "fn ", "def ", "class ", "#include", "=>", "();"];

pub fn classify(text: &str) -> TurnClass {
    let trimmed = text.trim();
    if trimmed.chars().count() > SERIOUS_CHARACTER_THRESHOLD {
        return TurnClass::Serious;
    }
    if CODE_MARKERS.iter().any(|marker| trimmed.contains(marker)) {
        return TurnClass::Serious;
    }
    let lowered = trimmed.to_lowercase();
    if SERIOUS_PHRASES
        .iter()
        .any(|phrase| lowered.contains(phrase))
    {
        return TurnClass::Serious;
    }
    TurnClass::Core
}

pub fn should_route_local(local_available: bool, text: &str) -> bool {
    local_available && classify(text) == TurnClass::Core
}

const NAME_REPLACEMENT: &str = "the user";
const EMAIL_REPLACEMENT: &str = "[email]";
const PHONE_REPLACEMENT: &str = "[phone]";
const PHONE_MINIMUM_DIGITS: usize = 7;

pub fn deidentify(context: &str, names: &[String]) -> String {
    let mut value = redact_emails(context);
    value = redact_phone_numbers(&value);
    for name in names {
        let name = name.trim();
        if name.chars().count() < 2 {
            continue;
        }
        value = replace_name(&value, name);
    }
    value
}

fn replace_name(value: &str, name: &str) -> String {
    let lowered_value = value.to_lowercase();
    let lowered_name = name.to_lowercase();
    let mut result = String::with_capacity(value.len());
    let mut cursor = 0;
    while let Some(offset) = lowered_value[cursor..].find(&lowered_name) {
        let start = cursor + offset;
        let end = start + lowered_name.len();
        let boundary_before = value[..start]
            .chars()
            .next_back()
            .is_none_or(|character| !character.is_alphanumeric());
        let boundary_after = value[end..]
            .chars()
            .next()
            .is_none_or(|character| !character.is_alphanumeric());
        result.push_str(&value[cursor..start]);
        if boundary_before && boundary_after {
            result.push_str(NAME_REPLACEMENT);
        } else {
            result.push_str(&value[start..end]);
        }
        cursor = end;
    }
    result.push_str(&value[cursor..]);
    result
}

fn redact_emails(value: &str) -> String {
    value
        .split_inclusive('\n')
        .map(redact_emails_in_line)
        .collect()
}

fn redact_emails_in_line(line: &str) -> String {
    line.split(' ')
        .map(|token| {
            let core = token
                .trim_matches(|character: char| !character.is_alphanumeric() && character != '@');
            if looks_like_email(core) {
                token.replacen(core, EMAIL_REPLACEMENT, 1)
            } else {
                token.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn looks_like_email(token: &str) -> bool {
    let Some((local, domain)) = token.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && domain
            .chars()
            .all(|character| character.is_alphanumeric() || character == '.' || character == '-')
}

fn redact_phone_numbers(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let characters: Vec<char> = value.chars().collect();
    let mut index = 0;
    while index < characters.len() {
        let character = characters[index];
        if character.is_ascii_digit() || character == '+' {
            let mut end = index;
            let mut digits = 0;
            while end < characters.len()
                && (characters[end].is_ascii_digit()
                    || matches!(characters[end], '+' | '-' | ' ' | '(' | ')' | '.'))
            {
                if characters[end].is_ascii_digit() {
                    digits += 1;
                }
                end += 1;
            }
            while end > index && !characters[end - 1].is_ascii_digit() && characters[end - 1] != ')'
            {
                end -= 1;
            }
            if digits >= PHONE_MINIMUM_DIGITS {
                result.push_str(PHONE_REPLACEMENT);
            } else {
                result.extend(&characters[index..end]);
            }
            index = end.max(index + 1);
        } else {
            result.push(character);
            index += 1;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_personal_questions_are_core() {
        assert_eq!(classify("what do you know about me"), TurnClass::Core);
        assert_eq!(classify("hi"), TurnClass::Core);
        assert_eq!(classify("What's my name?"), TurnClass::Core);
        assert_eq!(
            classify("remind me what I like for breakfast"),
            TurnClass::Core
        );
    }

    #[test]
    fn long_or_technical_turns_are_serious() {
        assert_eq!(
            classify("please implement a parser for this grammar"),
            TurnClass::Serious
        );
        assert_eq!(classify("```rust\nfn main() {}\n```"), TurnClass::Serious);
        assert_eq!(
            classify("analyze the pros and cons of these options"),
            TurnClass::Serious
        );
        assert_eq!(classify(&"word ".repeat(120)), TurnClass::Serious);
        assert_eq!(classify("click the submit button"), TurnClass::Serious);
        assert_eq!(
            classify("use the online model for this one"),
            TurnClass::Serious
        );
    }

    #[test]
    fn routing_requires_local_availability() {
        assert!(should_route_local(true, "what do you know about me"));
        assert!(!should_route_local(false, "what do you know about me"));
        assert!(!should_route_local(true, "implement quicksort"));
    }

    #[test]
    fn deidentify_replaces_profile_names_with_word_boundaries() {
        let context = "- Sam prefers espresso\n- Sampling is unrelated to Sam.";
        let redacted = deidentify(context, &["Sam".to_owned()]);
        assert_eq!(
            redacted,
            "- the user prefers espresso\n- Sampling is unrelated to the user."
        );
    }

    #[test]
    fn deidentify_is_case_insensitive_for_names() {
        let redacted = deidentify("sam and SAM and Sam", &["Sam".to_owned()]);
        assert_eq!(redacted, "the user and the user and the user");
    }

    #[test]
    fn deidentify_redacts_emails() {
        let redacted = deidentify("Reach them at sam.jones@example.com today.", &[]);
        assert_eq!(redacted, "Reach them at [email] today.");
        assert_eq!(
            deidentify("mention @handle here", &[]),
            "mention @handle here"
        );
    }

    #[test]
    fn deidentify_redacts_phone_numbers() {
        let redacted = deidentify("Call +1 (555) 123-4567 anytime.", &[]);
        assert_eq!(redacted, "Call [phone] anytime.");
        assert_eq!(deidentify("room 42 on floor 3", &[]), "room 42 on floor 3");
        assert_eq!(
            deidentify("the year 2026 was good", &[]),
            "the year 2026 was good"
        );
    }

    #[test]
    fn deidentify_skips_single_character_names() {
        assert_eq!(
            deidentify("A is a letter", &["A".to_owned()]),
            "A is a letter"
        );
    }
}
