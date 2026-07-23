//! Pure inbox-fallback logic ported from `worker/src/inbox-fallback.ts`.
//!
//! The unclaimed-inbox responder answers channel messages while the user's
//! desktop is offline. The lease-claim fencing, D1 reads, Pro completion, and
//! delivery live in `routes_channels.rs`; this module holds the pure pieces:
//! the claim-delay threshold, the responder flag gate, prompt assembly, and the
//! reply-finalization (trim + cap + empty fallback).

/// `fallbackClaimDelayMs` — an item must be at least this old before fallback
/// claims it (2 minutes).
pub const FALLBACK_CLAIM_DELAY_MS: i64 = 2 * 60_000;
/// `fallbackLeaseMs` — the claim lease duration (2 minutes).
pub const FALLBACK_LEASE_MS: i64 = 2 * 60_000;
/// `maxItemsPerRun`.
pub const MAX_ITEMS_PER_RUN: u32 = 5;
/// `maxAttempts`.
pub const MAX_ATTEMPTS: u32 = 5;
/// `historyLimit`.
pub const HISTORY_LIMIT: u32 = 12;
/// `maxReplyCharacters`.
pub const MAX_REPLY_CHARACTERS: usize = 4_096;

/// `offlineAcknowledgement`.
pub const OFFLINE_ACKNOWLEDGEMENT: &str = "Got it — I'll answer when your desktop is back online.";

/// `systemPrompt`.
pub const SYSTEM_PROMPT: &str = "You are Omi, the user's personal assistant, replying over a messaging channel while their desktop is offline. Answer the user's latest message directly and concisely in plain text.";

/// A chat message (`ManagedMessage`): role + content.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub role: String,
    pub content: String,
}

impl Message {
    pub fn new(role: &str, content: impl Into<String>) -> Message {
        Message {
            role: role.to_string(),
            content: content.into(),
        }
    }
}

/// `CHANNEL_FALLBACK_RESPONDER === "false"` disables the responder.
pub fn responder_disabled(flag: Option<&str>) -> bool {
    flag == Some("false")
}

/// `buildMessages` — system prompt (optionally augmented with memory context),
/// then history, then the inbound user message.
pub fn build_messages(
    memory_context: Option<&str>,
    history: &[Message],
    inbound: &str,
) -> Vec<Message> {
    let system_content = match memory_context {
        None => SYSTEM_PROMPT.to_string(),
        Some(context) => format!("{SYSTEM_PROMPT}\n\n{context}"),
    };
    let mut messages = Vec::with_capacity(history.len() + 2);
    messages.push(Message::new("system", system_content));
    messages.extend(history.iter().cloned());
    messages.push(Message::new("user", inbound));
    messages
}

/// Filter + shape rows from `recentHistory`: keep only user/assistant roles in
/// chronological order. Rows arrive newest-first (SQL `ORDER BY cursor DESC`),
/// so the caller passes them reversed — this mirrors `.reverse().filter(...)`.
pub fn shape_history(chronological: &[(String, String)]) -> Vec<Message> {
    chronological
        .iter()
        .filter(|(role, _)| role == "user" || role == "assistant")
        .map(|(role, text)| Message::new(role, text.clone()))
        .collect()
}

/// Final reply: trim, cap at `maxReplyCharacters`, and fall back to the offline
/// acknowledgement when the result is empty.
pub fn finalize_reply(reply: &str) -> String {
    let trimmed = reply.trim();
    let capped: String = trimmed.chars().take(MAX_REPLY_CHARACTERS).collect();
    if capped.is_empty() {
        OFFLINE_ACKNOWLEDGEMENT.to_string()
    } else {
        capped
    }
}

/// `releaseForRetry` status transition: stays `pending` while attempts remain,
/// else `failed`.
pub fn release_status(attempts: u32) -> &'static str {
    if attempts < MAX_ATTEMPTS {
        "pending"
    } else {
        "failed"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn responder_flag_gate() {
        assert!(responder_disabled(Some("false")));
        assert!(!responder_disabled(Some("true")));
        assert!(!responder_disabled(None));
    }

    #[test]
    fn build_messages_without_memory() {
        let history = vec![Message::new("user", "hi"), Message::new("assistant", "hey")];
        let out = build_messages(None, &history, "latest");
        assert_eq!(out.len(), 4);
        assert_eq!(out[0].role, "system");
        assert_eq!(out[0].content, SYSTEM_PROMPT);
        assert_eq!(out[3], Message::new("user", "latest"));
    }

    #[test]
    fn build_messages_with_memory_context() {
        let out = build_messages(Some("MEMORY"), &[], "q");
        assert_eq!(out[0].content, format!("{SYSTEM_PROMPT}\n\nMEMORY"));
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn history_filters_non_chat_roles() {
        let rows = vec![
            ("user".to_string(), "a".to_string()),
            ("tool".to_string(), "skip".to_string()),
            ("assistant".to_string(), "b".to_string()),
        ];
        let shaped = shape_history(&rows);
        assert_eq!(
            shaped,
            vec![Message::new("user", "a"), Message::new("assistant", "b")]
        );
    }

    #[test]
    fn finalize_trims_caps_and_falls_back() {
        assert_eq!(finalize_reply("  hello  "), "hello");
        assert_eq!(finalize_reply("   "), OFFLINE_ACKNOWLEDGEMENT);
        assert_eq!(finalize_reply(""), OFFLINE_ACKNOWLEDGEMENT);
        let long: String = "x".repeat(5_000);
        assert_eq!(finalize_reply(&long).chars().count(), MAX_REPLY_CHARACTERS);
    }

    #[test]
    fn release_status_transitions() {
        assert_eq!(release_status(1), "pending");
        assert_eq!(release_status(MAX_ATTEMPTS - 1), "pending");
        assert_eq!(release_status(MAX_ATTEMPTS), "failed");
    }
}
