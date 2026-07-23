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
}
