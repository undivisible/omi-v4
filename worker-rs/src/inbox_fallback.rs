//! Pure inbox-fallback logic ported from `worker/src/inbox-fallback.ts`.
//!
//! The inbox responder answers channel messages. It began life as a fallback
//! for an offline desktop and is now the primary answer path: the Worker is
//! what a Telegram or iMessage user is actually talking to, and it answers as
//! soon as the message lands rather than waiting to see whether some desktop
//! shows up to take the item first. The lease-claim fencing, D1 reads, Pro
//! completion, and delivery live in `routes_channels.rs`; this module holds the
//! pure pieces: the claim-delay threshold, the responder flag gate, prompt
//! assembly, and the reply-finalization (trim + cap + empty fallback).

/// The default claim delay: none. A desktop that wants an item still gets it —
/// it claims the same row through the same fenced UPDATE and whoever gets there
/// first wins — but nobody is made to sit in silence for two minutes on the
/// chance that a desktop which may not exist is about to answer for us.
///
/// The historical value was `fallbackClaimDelayMs` = 2 minutes, from when this
/// was a fallback. Set `CHANNEL_RESPONDER_CLAIM_DELAY_MS` to restore a grace
/// window without a code change; see [`claim_delay_ms`].
pub const DEFAULT_CLAIM_DELAY_MS: i64 = 0;

/// `CHANNEL_RESPONDER_CLAIM_DELAY_MS` — how old an inbox item must be before
/// the Worker will claim and answer it, in milliseconds.
///
/// Anything unparseable or negative falls back to [`DEFAULT_CLAIM_DELAY_MS`]
/// rather than erroring: a typo in a var should not be able to stop the bot
/// from replying, and "0" is the value that keeps replies flowing.
pub fn claim_delay_ms(flag: Option<&str>) -> i64 {
    flag.map(str::trim)
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse::<i64>().ok())
        .filter(|value| *value >= 0)
        .unwrap_or(DEFAULT_CLAIM_DELAY_MS)
}

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

/// What to say when there is no plan behind the account, so no assistant to
/// run. The old text here promised an answer "when your desktop is back
/// online", which was never true for these users: no desktop was coming, and
/// the answer never arrived. Saying what is actually in the way, and the one
/// thing that clears it, is the only honest reply.
pub const NO_PLAN_TEXT: &str =
    "Answering here needs an active Omi plan. Send /subscribe and I'll set that up.";

/// What to say when the model could not be reached and the attempts are spent.
/// This is a real failure, so it reads as one — an acknowledgement that quietly
/// promises a later answer would be a second lie on top of the first.
pub const MODEL_UNAVAILABLE_TEXT: &str =
    "I couldn't reach my model just now. Send that again and I'll pick it up.";

/// `systemPrompt` base. The channel command list is appended at build time
/// (see [`system_prompt`]) so the model can point at a real command instead of
/// inventing one — parity with `worker/src/inbox-fallback.ts`.
///
/// The prompt used to open with "while their desktop is offline", which told
/// the model it was standing in for the real assistant. It is not: the memory
/// it answers from lives in the cloud, and a phone with a chat app in it is a
/// first-class way to reach that memory. A model told it is a stand-in hedges
/// like one, so the wording is load-bearing, not cosmetic.
pub const SYSTEM_PROMPT_BASE: &str = "You are Omi, the user's personal assistant, replying over a messaging channel. You run in the cloud and answer from the user's synced memory, so this chat is a complete way to reach them — never suggest they check another device. Answer the user's latest message directly and concisely in plain text.";

/// `systemPromptForChannel` — base, the channel style rules, then the channel
/// command injection.
pub fn system_prompt_for_channel(channel: &str) -> String {
    format!(
        "{SYSTEM_PROMPT_BASE}\n\n{}\n\n{}",
        crate::channel_style::channel_style_prompt(channel),
        crate::channel_commands::channel_command_prompt()
    )
}

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
    channel: &str,
    memory_context: Option<&str>,
    history: &[Message],
    inbound: &str,
) -> Vec<Message> {
    let base = system_prompt_for_channel(channel);
    let system_content = match memory_context {
        None => base,
        Some(context) => format!("{base}\n\n{context}"),
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

/// Final reply: trim, cap at `maxReplyCharacters`, and fall back to the
/// model-unavailable text when the result is empty. An empty completion is the
/// model failing to say anything, so it gets the failure wording rather than a
/// cheerful promise of a later reply that nothing will ever send.
pub fn finalize_reply(channel: &str, reply: &str) -> String {
    let sanitized = crate::channel_style::sanitize_channel_reply(channel, reply);
    let trimmed = sanitized.trim();
    let capped: String = trimmed.chars().take(MAX_REPLY_CHARACTERS).collect();
    if capped.is_empty() {
        MODEL_UNAVAILABLE_TEXT.to_string()
    } else {
        capped
    }
}

/// The `WHERE` fragment that picks inbox items this Worker may answer.
/// `?1` is `maxAttempts`, `?2` is the claim cutoff (`now - claim_delay_ms`).
///
/// Shared by the inline pass the inbound webhook kicks off and by the cron
/// sweep, for the same reason the delivery predicate is shared: two definitions
/// of "answerable" that drift apart is how one message becomes two replies.
/// `status = 'pending'` is the load-bearing term — the moment anyone claims an
/// item it becomes `processing` and drops out of this set for both of them.
pub const CLAIMABLE_ITEM_PREDICATE_SQL: &str =
    "status = 'pending' AND attempts < ?1 AND received_at <= ?2";

/// The cron sweep's scan: the oldest claimable items across every user.
pub fn claimable_items_sql() -> String {
    format!(
        "SELECT id, uid FROM channel_inbox\n     WHERE {CLAIMABLE_ITEM_PREDICATE_SQL}\n     ORDER BY received_at, id LIMIT ?3"
    )
}

/// The inline pass's scan: the same rows, narrowed to the one user whose
/// message just arrived (`?4`).
pub fn claimable_items_for_uid_sql() -> String {
    format!(
        "SELECT id, uid FROM channel_inbox\n     WHERE uid = ?4 AND {CLAIMABLE_ITEM_PREDICATE_SQL}\n     ORDER BY received_at, id LIMIT ?3"
    )
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
        let out = build_messages("telegram", None, &history, "latest");
        assert_eq!(out.len(), 4);
        assert_eq!(out[0].role, "system");
        assert_eq!(out[0].content, system_prompt_for_channel("telegram"));
        assert!(out[0].content.contains("/logout"));
        assert_eq!(out[3], Message::new("user", "latest"));
    }

    #[test]
    fn build_messages_with_memory_context() {
        let out = build_messages("imessage", Some("MEMORY"), &[], "q");
        assert_eq!(
            out[0].content,
            format!("{}\n\nMEMORY", system_prompt_for_channel("imessage"))
        );
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn the_prompt_carries_the_channel_style_rules() {
        let telegram = system_prompt_for_channel("telegram");
        let imessage = system_prompt_for_channel("imessage");
        assert!(telegram.contains("Delivery channel: Telegram."));
        assert!(imessage.contains("Delivery channel: iMessage/SMS."));
        for prompt in [&telegram, &imessage] {
            assert!(prompt.starts_with(SYSTEM_PROMPT_BASE));
            assert!(prompt.contains("no markdown"));
            assert!(prompt.contains("/logout"));
        }
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
        assert_eq!(finalize_reply("telegram", "  hello  "), "hello");
        assert_eq!(finalize_reply("telegram", "   "), MODEL_UNAVAILABLE_TEXT);
        assert_eq!(finalize_reply("telegram", ""), MODEL_UNAVAILABLE_TEXT);
        let long: String = "x".repeat(5_000);
        assert_eq!(
            finalize_reply("telegram", &long).chars().count(),
            MAX_REPLY_CHARACTERS
        );
    }

    #[test]
    fn finalize_strips_markdown_before_capping() {
        assert_eq!(
            finalize_reply("telegram", "**bold** and `code`"),
            "bold and code"
        );
        assert_eq!(
            finalize_reply("imessage", "```\ntext \"hi\"\n```"),
            MODEL_UNAVAILABLE_TEXT
        );
        let long: String = "x".repeat(5_000);
        assert_eq!(
            finalize_reply("imessage", &long).chars().count(),
            crate::channel_style::IMESSAGE_REPLY_LIMIT
        );
    }

    #[test]
    fn the_worker_answers_without_waiting_by_default() {
        // The product is a brain you can reach from a phone. Anything above
        // zero here is time a user spends staring at a chat that has not
        // replied yet, so the shipped default is no wait at all.
        assert_eq!(DEFAULT_CLAIM_DELAY_MS, 0);
        assert_eq!(claim_delay_ms(None), 0);
        assert_eq!(claim_delay_ms(Some("")), 0);
        assert_eq!(claim_delay_ms(Some("   ")), 0);
    }

    #[test]
    fn the_claim_delay_is_tunable_without_a_redeploy() {
        assert_eq!(claim_delay_ms(Some("120000")), 120_000);
        assert_eq!(claim_delay_ms(Some("  5000 ")), 5_000);
        assert_eq!(claim_delay_ms(Some("0")), 0);
        // A typo must not be able to wedge the responder into never claiming.
        assert_eq!(claim_delay_ms(Some("soon")), DEFAULT_CLAIM_DELAY_MS);
        assert_eq!(claim_delay_ms(Some("-1")), DEFAULT_CLAIM_DELAY_MS);
        assert_eq!(claim_delay_ms(Some("1e6")), DEFAULT_CLAIM_DELAY_MS);
    }

    #[test]
    fn inline_and_cron_claim_the_same_set_of_items() {
        let sweep = claimable_items_sql();
        let inline = claimable_items_for_uid_sql();
        assert!(sweep.contains(CLAIMABLE_ITEM_PREDICATE_SQL));
        assert!(inline.contains(CLAIMABLE_ITEM_PREDICATE_SQL));
        assert!(inline.contains("uid = ?4"));
        assert!(!sweep.contains("uid = ?4"));
        // Only 'pending' items are up for grabs, so an item already claimed —
        // by the other pass, or by a desktop that got there first — is invisible
        // to both scans and cannot be answered twice.
        assert!(CLAIMABLE_ITEM_PREDICATE_SQL.contains("status = 'pending'"));
        assert!(!CLAIMABLE_ITEM_PREDICATE_SQL.contains("processing"));
        assert!(CLAIMABLE_ITEM_PREDICATE_SQL.contains("attempts < ?1"));
    }

    #[test]
    fn nothing_promises_an_answer_from_another_device() {
        // The two texts a user can receive instead of a real answer, and the
        // prompt the model reads, all used to point at a desktop. None of them
        // may again: for a chat-only user there is no desktop to point at.
        for text in [
            NO_PLAN_TEXT,
            MODEL_UNAVAILABLE_TEXT,
            SYSTEM_PROMPT_BASE,
            &system_prompt_for_channel("telegram"),
            &system_prompt_for_channel("imessage"),
        ] {
            let lowered = text.to_lowercase();
            assert!(
                !lowered.contains("desktop"),
                "still mentions a desktop: {text}"
            );
            assert!(
                !lowered.contains("offline"),
                "still mentions offline: {text}"
            );
        }
        // The no-plan reply names the one command that clears the obstacle.
        assert!(NO_PLAN_TEXT.contains("/subscribe"));
        // And the prompt says where the assistant actually runs and what it
        // answers from, because that is what makes this a brain and not a bot.
        assert!(SYSTEM_PROMPT_BASE.contains("cloud"));
        assert!(SYSTEM_PROMPT_BASE.contains("synced memory"));
    }

    #[test]
    fn release_status_transitions() {
        assert_eq!(release_status(1), "pending");
        assert_eq!(release_status(MAX_ATTEMPTS - 1), "pending");
        assert_eq!(release_status(MAX_ATTEMPTS), "failed");
    }
}
