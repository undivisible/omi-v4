//! Pure channel-signup logic ported from `worker/src/channel-signup.ts`.
//! D1 reads/writes for account creation live in the wasm glue in
//! `routes_channels.rs`.
//!
//! This module used to also hold a first-contact interview: a canned greeting,
//! a yes/no question about whether the sender already had an account, and a
//! phrase table for reading the answer off a phone keyboard. All of it is gone.
//! A new sender is now given an account and handed straight to the assistant,
//! so there is no question to ask and nothing to parse — see
//! `routes_channels::unrecognized_sender`.

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

/// Where a signed-out sender is pointed when they ask how to get the app.
///
/// It no longer describes creating an account, because by the time anyone can
/// read this they already have one: the account is made on their first message.
/// What is left is the one thing they cannot do from a chat — install Omi and
/// sign into it — and the code that does it.
pub const SIGNUP_GUIDE_TEXT: &str = "You already have an Omi account — I made one the moment you messaged me, and everything you've told me is saved to it.\n\
To get it on a device:\n\
1. Download Omi for desktop or mobile: https://omi.me/download\n\
2. Ask me for a sign-in code and type it into the app\n\
That signs you into this same memory, so nothing here is lost.\n\
Send /help to see everything I understand here.";

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
    fn the_guide_points_at_the_app_and_the_code_not_at_a_signup_form() {
        assert!(SIGNUP_GUIDE_TEXT.contains("https://omi.me/download"));
        assert!(SIGNUP_GUIDE_TEXT.contains("sign-in code"));
        let lowered = SIGNUP_GUIDE_TEXT.to_lowercase();
        // Accounts are not created anywhere a sender can be sent to, and the
        // providers this used to name are no longer wired up at all.
        for stale in ["google", "apple", "portal", "create"] {
            assert!(!lowered.contains(stale), "still mentions {stale}");
        }
    }

    #[test]
    fn a_sender_may_only_mint_so_many_accounts() {
        // The per-sender ceiling is what stops one number from provisioning
        // users in a loop; it is not a cap on conversation, which is unmetered.
        assert_eq!(SIGNUP_PER_SENDER_LIMIT, 3);
        assert_eq!(
            signup_rate_limit_key("telegram", "42"),
            "channel-signup:telegram:42"
        );
    }
}
