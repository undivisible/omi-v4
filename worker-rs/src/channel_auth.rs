//! Decision logic for signing in with a code received over a channel.
//!
//! The direction is: the user asks the bot, the bot sends a 7-character code,
//! the user types it into the app. That is friendlier than the inverse and it
//! is also weaker, and the difference is worth stating plainly.
//!
//! `handle_channel_link_redeem` already consumes these codes, but there the
//! caller is *already authenticated* and the code only binds a chat to a known
//! uid — a second factor, rate-limited per uid. Here the code is the entire
//! credential and the caller is anonymous. There is no uid to key a limit on,
//! and the keyspace is 31^7 ≈ 2.75e10: fine against one guesser, thin against
//! a distributed one when many codes are live.
//!
//! So three limits apply together, and all three are needed:
//!
//! * per-IP, which stops the naive case
//! * global, which is the only thing that stops a guesser rotating IPs
//! * per-code attempts, so a code under attack dies rather than the whole
//!   endpoint locking out every honest user
//!
//! D1 and HTTP live in the glue; everything here is pure.

/// Sign-in codes live much shorter than binding codes. A binding code is typed
/// by someone already signed in and 15 minutes is a convenience; a sign-in code
/// is a bearer credential and every extra minute is guessing time.
pub const SIGNIN_CODE_TTL_MS: i64 = 3 * 60_000;

/// Attempts a single code tolerates before it is dead. Typos need a few; a
/// guesser needs far more.
pub const MAX_CODE_ATTEMPTS: i64 = 5;

/// Per-IP budget, matching the desktop-auth precedent.
pub const EXCHANGE_PER_IP_LIMIT: i64 = 10;
pub const EXCHANGE_PER_IP_WINDOW_MS: i64 = 10 * 60_000;

/// Global failure budget. Deliberately generous enough that honest typos across
/// the whole userbase never reach it, and far below what enumeration needs.
pub const EXCHANGE_GLOBAL_FAILURE_LIMIT: i64 = 500;
pub const EXCHANGE_GLOBAL_FAILURE_WINDOW_MS: i64 = 10 * 60_000;

/// The marker written to `channel_link_codes.purpose` for a sign-in code.
pub const PURPOSE_SIGNIN: &str = "signin";
/// The default for codes that only bind a chat to an existing account.
pub const PURPOSE_LINK: &str = "link";

/// What the caller should do with a presented code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ExchangeDecision {
    /// Sign in as this uid. `is_new` distinguishes an account created by this
    /// exchange from an existing one being signed into.
    Accept { uid: String, is_new: bool },
    /// Refuse. Every variant becomes the same opaque 401 on the wire — the
    /// distinction exists for logs and for deciding whether to burn an attempt.
    Reject(RejectReason),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RejectReason {
    /// Not a plausible code at all — costs no attempt, since it cannot be a
    /// guess against any specific live code.
    Malformed,
    /// Well formed but matches nothing live. Burns global budget.
    Unknown,
    /// Matched a code that has already been spent.
    AlreadyUsed,
    /// Matched, but past its TTL.
    Expired,
    /// Matched, but this code has been guessed at too often.
    Locked,
    /// Matched a code minted only for binding, not for signing in. A binding
    /// code must never be a sign-in credential: it is issued on a longer TTL
    /// and under weaker assumptions.
    WrongPurpose,
    /// Group chats cannot own an identity — any member could sign in as it.
    GroupChat,
}

/// The stored state of a code, as the glue read it from D1.
#[derive(Debug, Clone)]
pub struct StoredCode {
    pub purpose: String,
    pub expires_at_ms: i64,
    pub consumed_at_ms: Option<i64>,
    pub attempts: i64,
    pub locked_at_ms: Option<i64>,
    pub is_group_chat: bool,
    /// The uid already bound to this sender, if any. `None` means this sender
    /// has no account and one must be created.
    pub bound_uid: Option<String>,
}

/// Whether a well-formed-but-unmatched code should count against the global
/// failure budget. Malformed input should not: it is almost always a user
/// pasting the wrong thing, and letting it consume budget would let noise
/// lock out the endpoint.
pub fn counts_against_global_budget(reason: RejectReason) -> bool {
    matches!(
        reason,
        RejectReason::Unknown | RejectReason::Expired | RejectReason::AlreadyUsed
    )
}

/// Whether this outcome should increment the code's own attempt counter. Only
/// failures against a *matched* code can, because the counter lives on the row.
pub fn burns_code_attempt(reason: RejectReason) -> bool {
    matches!(
        reason,
        RejectReason::Expired | RejectReason::AlreadyUsed | RejectReason::WrongPurpose
    )
}

/// Decides the outcome for a code the glue has already normalized and looked
/// up. `stored` is `None` when the hash matched nothing.
pub fn decide(stored: Option<&StoredCode>, now_ms: i64) -> ExchangeDecision {
    let Some(code) = stored else {
        return ExchangeDecision::Reject(RejectReason::Unknown);
    };
    if code.locked_at_ms.is_some() || code.attempts >= MAX_CODE_ATTEMPTS {
        return ExchangeDecision::Reject(RejectReason::Locked);
    }
    if code.purpose != PURPOSE_SIGNIN {
        return ExchangeDecision::Reject(RejectReason::WrongPurpose);
    }
    if code.consumed_at_ms.is_some() {
        return ExchangeDecision::Reject(RejectReason::AlreadyUsed);
    }
    if now_ms >= code.expires_at_ms {
        return ExchangeDecision::Reject(RejectReason::Expired);
    }
    if code.is_group_chat {
        return ExchangeDecision::Reject(RejectReason::GroupChat);
    }
    match &code.bound_uid {
        // An existing user who already linked this chat signs in as themselves.
        // This is what makes the Firebase migration free: their uid is already
        // in channel_bindings, so they keep it with no mapping table.
        Some(uid) => ExchangeDecision::Accept {
            uid: uid.clone(),
            is_new: false,
        },
        None => ExchangeDecision::Accept {
            uid: String::new(),
            is_new: true,
        },
    }
}

/// The rate-limit keys the glue should consume before doing any work.
pub fn per_ip_key(ip: &str) -> String {
    format!("auth-channel-exchange:{ip}")
}

pub fn global_failure_key() -> &'static str {
    "auth-channel-exchange-failures:global"
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_700_000_000_000;

    fn live() -> StoredCode {
        StoredCode {
            purpose: PURPOSE_SIGNIN.to_owned(),
            expires_at_ms: NOW + SIGNIN_CODE_TTL_MS,
            consumed_at_ms: None,
            attempts: 0,
            locked_at_ms: None,
            is_group_chat: false,
            bound_uid: None,
        }
    }

    #[test]
    fn an_unbound_sender_gets_a_new_account() {
        assert_eq!(
            decide(Some(&live()), NOW),
            ExchangeDecision::Accept {
                uid: String::new(),
                is_new: true
            }
        );
    }

    #[test]
    fn a_bound_sender_keeps_their_existing_uid() {
        let mut code = live();
        code.bound_uid = Some("usr_existing".to_owned());
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Accept {
                uid: "usr_existing".to_owned(),
                is_new: false
            }
        );
    }

    #[test]
    fn an_unmatched_code_is_unknown() {
        assert_eq!(
            decide(None, NOW),
            ExchangeDecision::Reject(RejectReason::Unknown)
        );
    }

    #[test]
    fn a_spent_code_cannot_be_replayed() {
        let mut code = live();
        code.consumed_at_ms = Some(NOW - 1);
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::AlreadyUsed)
        );
    }

    #[test]
    fn expiry_is_enforced_at_the_boundary() {
        let mut code = live();
        code.expires_at_ms = NOW;
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::Expired)
        );
        code.expires_at_ms = NOW + 1;
        assert!(matches!(
            decide(Some(&code), NOW),
            ExchangeDecision::Accept { .. }
        ));
    }

    #[test]
    fn a_binding_code_is_not_a_sign_in_credential() {
        let mut code = live();
        code.purpose = PURPOSE_LINK.to_owned();
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::WrongPurpose)
        );
    }

    #[test]
    fn a_guessed_at_code_locks_out() {
        let mut code = live();
        code.attempts = MAX_CODE_ATTEMPTS;
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::Locked)
        );
        code.attempts = 0;
        code.locked_at_ms = Some(NOW - 1);
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::Locked)
        );
    }

    #[test]
    fn lockout_wins_over_every_other_outcome() {
        // A locked code must not leak whether it was also expired or spent.
        let mut code = live();
        code.locked_at_ms = Some(NOW - 1);
        code.consumed_at_ms = Some(NOW - 1);
        code.expires_at_ms = NOW - 1;
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::Locked)
        );
    }

    #[test]
    fn a_group_chat_cannot_own_an_identity() {
        let mut code = live();
        code.is_group_chat = true;
        assert_eq!(
            decide(Some(&code), NOW),
            ExchangeDecision::Reject(RejectReason::GroupChat)
        );
    }

    #[test]
    fn only_matched_failures_burn_the_codes_own_budget() {
        assert!(burns_code_attempt(RejectReason::Expired));
        assert!(burns_code_attempt(RejectReason::AlreadyUsed));
        assert!(burns_code_attempt(RejectReason::WrongPurpose));
        // Nothing matched, so there is no row to count against.
        assert!(!burns_code_attempt(RejectReason::Unknown));
        assert!(!burns_code_attempt(RejectReason::Malformed));
    }

    #[test]
    fn noise_cannot_exhaust_the_global_budget() {
        // Someone pasting a URL into the code box must not push the endpoint
        // toward a global lockout.
        assert!(!counts_against_global_budget(RejectReason::Malformed));
        assert!(counts_against_global_budget(RejectReason::Unknown));
    }

    #[test]
    fn sign_in_codes_are_much_shorter_lived_than_binding_codes() {
        const { assert!(SIGNIN_CODE_TTL_MS < crate::channel_link::LINK_CODE_TTL_MS) };
    }
}
