//! Pure channel-signup logic ported from `worker/src/channel-signup.ts`.
//! D1 reads/writes for first-contact state and account creation live in the
//! wasm glue in `routes_channels.rs`.

/// A first-contact answer typed on a phone: no punctuation rules, no exact
/// syntax. Anything we cannot read confidently comes back as `None` so the
/// caller can ask again rather than guess.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignupAnswer {
    HasAccount,
    NeedsAccount,
}

const HAS_ACCOUNT_PHRASES: &[&str] = &[
    "yes",
    "y",
    "ya",
    "yah",
    "yeah",
    "yep",
    "yup",
    "yes i do",
    "i do",
    "i have",
    "i have one",
    "i have an account",
    "already",
    "already have one",
    "already have an account",
    "existing",
    "existing account",
    "got one",
    "i've got one",
    "sure",
    "link",
    "link it",
    "1",
];

const NEEDS_ACCOUNT_PHRASES: &[&str] = &[
    "no",
    "n",
    "nope",
    "nah",
    "no i don't",
    "no i dont",
    "i don't",
    "i dont",
    "i do not",
    "don't have one",
    "dont have one",
    "no account",
    "not yet",
    "never",
    "new",
    "i'm new",
    "im new",
    "new here",
    "create one",
    "make one",
    "sign me up",
    "sign up",
    "signup",
    "register",
    "2",
];

fn words(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last_space = false;
    for ch in text.chars() {
        let lower = ch.to_ascii_lowercase();
        if lower.is_ascii_alphanumeric() || lower == '\'' {
            out.push(lower);
            last_space = false;
        } else if !last_space {
            out.push(' ');
            last_space = true;
        }
    }
    out.trim().to_string()
}

/// `parseSignupAnswer`.
pub fn parse_signup_answer(text: &str) -> Option<SignupAnswer> {
    let normalized = words(text);
    if normalized.is_empty() || normalized.len() > 60 {
        return None;
    }
    if NEEDS_ACCOUNT_PHRASES.contains(&normalized.as_str()) {
        return Some(SignupAnswer::NeedsAccount);
    }
    if HAS_ACCOUNT_PHRASES.contains(&normalized.as_str()) {
        return Some(SignupAnswer::HasAccount);
    }
    None
}

pub const FIRST_CONTACT_TEXT: &str = "I'm Omi — an assistant that remembers your work and your life.\n\nDo you already have an Omi account? Reply yes or no.";

pub const CLARIFY_ANSWER_TEXT: &str =
    "Reply yes if you already have an Omi account, or no and I'll walk you through signing up.";

pub const SIGNUP_GUIDE_TEXT: &str = "Omi accounts are created in the app — not in this chat.\n\
1. Download Omi for desktop or mobile: https://omi.me/download\n\
2. Sign in at https://api.omi.tsc.hk/portal (Google, Apple, or phone)\n\
3. Link this chat: Settings → Account → Link a chat, paste your code in the desktop chat box, or send /start here after you're signed in\n\
4. Connect your services (calendar, email, and more) in Settings\n\
Once linked, messages here reach your assistant with your full memory.\n\
Send /help to see everything I understand here.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FirstContact {
    pub asked_at: i64,
    pub answered_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChannelAccount {
    pub uid: String,
    pub created_at: i64,
    pub claimed_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SignupResult {
    Created { uid: String },
    Existing { uid: String },
    RateLimited,
    Conflict,
}

pub const SIGNUP_PER_SENDER_LIMIT: i64 = 3;
pub const SIGNUP_PER_SENDER_WINDOW_MS: i64 = 24 * 60 * 60_000;
pub const SIGNUP_GLOBAL_LIMIT: i64 = 500;
pub const SIGNUP_GLOBAL_WINDOW_MS: i64 = 60 * 60_000;

pub fn signup_rate_limit_key(channel: &str, channel_user_id: &str) -> String {
    format!("channel-signup:{channel}:{channel_user_id}")
}

pub const SIGNUP_GLOBAL_RATE_LIMIT_KEY: &str = "channel-signup:global";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_yes_and_no_phrases() {
        for value in ["yes", "Y", "i do", "already have one", "Sure."] {
            assert_eq!(
                parse_signup_answer(value),
                Some(SignupAnswer::HasAccount),
                "{value}"
            );
        }
        for value in ["no", "Nope!", "nah", "new", "sign me up", "i dont"] {
            assert_eq!(
                parse_signup_answer(value),
                Some(SignupAnswer::NeedsAccount),
                "{value}"
            );
        }
        for value in ["maybe", "who are you", ""] {
            assert_eq!(parse_signup_answer(value), None, "{value}");
        }
    }

    #[test]
    fn first_contact_and_guide_copy_are_stable() {
        assert!(FIRST_CONTACT_TEXT.contains("Reply yes or no"));
        assert!(SIGNUP_GUIDE_TEXT.contains("https://omi.me/download"));
        assert!(CLARIFY_ANSWER_TEXT.contains("walk you through signing up"));
    }
}
