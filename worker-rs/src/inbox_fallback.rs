//! Pure inbox-fallback logic ported from `worker/src/inbox-fallback.ts`.
//!
//! The inbox responder answers channel messages. It began life as a fallback
//! for an offline desktop and is now the primary answer path: the Worker is
//! what a Telegram or iMessage user is actually talking to, and it answers as
//! soon as the message lands unless a desktop hub is known to be polling right
//! now, in which case that hub — which has the computer-use tools the Worker
//! does not — gets a few seconds of first refusal. The lease-claim fencing, D1
//! reads, Pro completion, and delivery live in `routes_channels.rs`; this
//! module holds the pure pieces: the claim-delay threshold, the desktop-presence
//! decision, the responder flag gate, prompt assembly, and the
//! reply-finalization (trim + cap + empty fallback).

/// The default claim delay: none. A desktop that wants an item still gets it —
/// it claims the same row through the same fenced UPDATE and whoever gets there
/// first wins, and when one is actually polling [`inline_answer_plan`] holds
/// the Worker back for a few seconds so it can — but nobody is made to sit in
/// silence for two minutes on the chance that a desktop which may not exist is
/// about to answer for us.
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

/// How recently a desktop hub must have polled the inbox for us to believe one
/// is sitting there ready to take an item. The hub polls on a fixed interval,
/// so a value comfortably above that interval tolerates a dropped request or a
/// slow network without declaring a live machine dead.
pub const DESKTOP_PRESENCE_TTL_MS: i64 = 45_000;

/// How long the Worker holds its own answer when a desktop is present, giving
/// the hub first refusal on the item. It is bounded by what a person will wait
/// in a chat app, not by what a desktop might need: if the hub does not claim
/// inside this window the Worker answers, and if the hub claims but then goes
/// silent the lease expiry and the cron sweep still bring an answer.
pub const DESKTOP_CLAIM_WINDOW_MS: i64 = 6_000;

/// How stale a recorded poll must be before a fresh poll rewrites it. Presence
/// only has to be accurate to within its own TTL, so writing on every poll
/// would be a database write every couple of seconds per signed-in desktop for
/// no gain.
pub const DESKTOP_PRESENCE_REFRESH_MS: i64 = 10_000;

/// What the inbound webhook should do with an item once it knows whether a
/// desktop is watching the inbox.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InlineAnswerPlan {
    /// Nobody else is going to answer: claim and answer with no added latency.
    AnswerNow,
    /// A desktop is polling, so wait this long before claiming. This is a
    /// delay, never a skip — whatever the desktop does or fails to do, the
    /// Worker still runs its claim afterwards.
    HoldForDesktop { wait_ms: i64 },
}

/// Whether a hub polled recently enough to count as present.
pub fn desktop_present(last_polled_at: Option<i64>, now: i64) -> bool {
    last_polled_at.is_some_and(|at| now - at < DESKTOP_PRESENCE_TTL_MS)
}

/// The plan for an item that just arrived, given the last time a desktop polled
/// this user's inbox.
pub fn inline_answer_plan(last_polled_at: Option<i64>, now: i64) -> InlineAnswerPlan {
    if desktop_present(last_polled_at, now) {
        InlineAnswerPlan::HoldForDesktop {
            wait_ms: DESKTOP_CLAIM_WINDOW_MS,
        }
    } else {
        InlineAnswerPlan::AnswerNow
    }
}

/// Record that a desktop hub polled this user's inbox. `?3` is the refresh
/// cutoff, so a hub polling every couple of seconds writes at most once per
/// [`DESKTOP_PRESENCE_REFRESH_MS`].
pub const RECORD_DESKTOP_POLL_SQL: &str = "INSERT INTO desktop_presence (uid, last_polled_at) VALUES (?1, ?2)\n     ON CONFLICT(uid) DO UPDATE SET last_polled_at = ?2\n     WHERE desktop_presence.last_polled_at <= ?3";

/// Read back the last poll, for the inbound webhook's presence check.
pub const DESKTOP_PRESENCE_SQL: &str = "SELECT last_polled_at FROM desktop_presence WHERE uid = ?1";

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
pub const SYSTEM_PROMPT_BASE: &str = "You are Omi, the user's personal assistant, replying over a messaging channel. You run in the cloud and answer from the user's synced memory, so this chat is a complete way to reach them — never suggest they check another device. Answer the user's latest message directly and concisely in plain text.\n\nTheir memory reaches you here: what is relevant to the message is included below when there is any. So when they ask about themselves, answer from it. Never tell them you have no access to their memories, their profile or what you know about them, and never send them to a tab in the app to look it up themselves — if nothing relevant came through, say you have nothing on that yet and ask them for it. Actions on their own machine are proposed there and approved there, so never claim you have done something on a machine.";

/// What the model is told when it is talking to someone who has not signed in
/// on any device yet.
///
/// Such a sender is not a stranger to be screened — they have a real account
/// already, provisioned the moment they said anything, and everything they say
/// is being remembered under it. So the model's job is to be useful first and
/// mention signing in only when there is a reason to, which is why this says
/// what the code *is* rather than instructing the model to go fishing for one.
pub const GUEST_PROMPT_ADDENDUM: &str = "This person has not signed in on a phone or desktop yet. Do not interrogate them about it and do not open with a pitch: answer what they asked. If they ask what you are or what you can do, tell them plainly. Everything they tell you is already being saved to their memory, and it carries over the moment they sign in — so nothing here is lost or provisional. If they want the app, tell them to ask you for a sign-in code and type it into Omi on their phone or desktop; that code signs them into this same memory.";

/// `systemPromptForChannel` — base, the channel style rules, then the channel
/// command injection.
pub fn system_prompt_for_channel(channel: &str) -> String {
    format!(
        "{SYSTEM_PROMPT_BASE}\n\n{}\n\n{}\n\n{}",
        crate::channel_style::channel_style_prompt(channel),
        crate::channel_commands::channel_command_prompt(),
        crate::channel_tools::TOOL_PROMPT
    )
}

/// The prompt for a given sender, which differs only in whether the guest
/// addendum is appended.
pub fn system_prompt_for(channel: &str, guest: bool) -> String {
    let base = system_prompt_for_channel(channel);
    if guest {
        format!("{base}\n\n{GUEST_PROMPT_ADDENDUM}")
    } else {
        base
    }
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
    guest: bool,
) -> Vec<Message> {
    let base = system_prompt_for(channel, guest);
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

/// Hand back items whose claimer stopped: `?1` is now, `?2` is `maxAttempts`.
///
/// A desktop that leases an item and then loses power, or is closed, leaves the
/// row `processing` with nobody working on it, and `status = 'pending'` is what
/// both scans require — so without this the user simply never hears back. The
/// `lease_until <= ?1` fence means a hub that is still working keeps its item.
pub const RELEASE_EXPIRED_LEASES_SQL: &str = "UPDATE channel_inbox\n     SET status = 'pending', lease_until = NULL, lease_token = NULL\n     WHERE status = 'processing' AND lease_until IS NOT NULL AND lease_until <= ?1\n       AND attempts < ?2";

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
        let out = build_messages("telegram", None, &history, "latest", false);
        assert_eq!(out.len(), 4);
        assert_eq!(out[0].role, "system");
        assert_eq!(out[0].content, system_prompt_for_channel("telegram"));
        assert!(out[0].content.contains("/logout"));
        assert_eq!(out[3], Message::new("user", "latest"));
    }

    #[test]
    fn build_messages_with_memory_context() {
        let out = build_messages("imessage", Some("MEMORY"), &[], "q", false);
        assert_eq!(
            out[0].content,
            format!("{}\n\nMEMORY", system_prompt_for_channel("imessage"))
        );
        assert_eq!(out.len(), 2);
    }

    #[test]
    fn a_guest_is_told_their_memory_is_already_being_kept() {
        let guest = build_messages("telegram", None, &[], "what are you", true);
        assert!(guest[0].content.contains(GUEST_PROMPT_ADDENDUM));
        // The memory context still lands after the addendum, so a guest with a
        // few turns behind them answers from them like anyone else.
        let with_memory = build_messages("telegram", Some("MEMORY"), &[], "q", true);
        assert!(with_memory[0].content.ends_with("\n\nMEMORY"));
        // And nothing is added for a signed-in sender.
        assert!(!build_messages("telegram", None, &[], "q", false)[0]
            .content
            .contains(GUEST_PROMPT_ADDENDUM));
    }

    #[test]
    fn the_guest_prompt_neither_screens_nor_pitches() {
        let lowered = GUEST_PROMPT_ADDENDUM.to_lowercase();
        // The old first-contact flow opened by demanding a yes/no about an
        // account before it would say anything at all. Whatever the model does
        // here, it must not reintroduce that.
        assert!(!lowered.contains("yes or no"));
        assert!(lowered.contains("answer what they asked"));
        // The one promise it makes is the one the code path actually keeps.
        assert!(lowered.contains("carries over"));
        assert!(lowered.contains("sign-in code"));
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
    fn a_channel_user_with_no_desktop_waits_for_nothing() {
        let now = 1_000_000;
        assert!(!desktop_present(None, now));
        assert_eq!(inline_answer_plan(None, now), InlineAnswerPlan::AnswerNow);
        // A desktop that was here yesterday is not here now.
        let stale = now - DESKTOP_PRESENCE_TTL_MS - 1;
        assert!(!desktop_present(Some(stale), now));
        assert_eq!(
            inline_answer_plan(Some(stale), now),
            InlineAnswerPlan::AnswerNow
        );
    }

    #[test]
    fn a_polling_desktop_gets_first_refusal() {
        let now = 1_000_000;
        for polled_at in [now, now - 1, now - DESKTOP_PRESENCE_TTL_MS + 1] {
            assert!(desktop_present(Some(polled_at), now));
            assert_eq!(
                inline_answer_plan(Some(polled_at), now),
                InlineAnswerPlan::HoldForDesktop {
                    wait_ms: DESKTOP_CLAIM_WINDOW_MS
                }
            );
        }
        // The window is short enough to sit through in a chat app, and long
        // enough for a hub polling on its normal interval to get there.
        const {
            assert!(DESKTOP_CLAIM_WINDOW_MS > 0 && DESKTOP_CLAIM_WINDOW_MS <= 10_000);
            assert!(DESKTOP_PRESENCE_TTL_MS > DESKTOP_CLAIM_WINDOW_MS);
            assert!(DESKTOP_PRESENCE_REFRESH_MS < DESKTOP_PRESENCE_TTL_MS);
        }
    }

    #[test]
    fn holding_for_a_desktop_is_a_delay_and_never_a_skip() {
        // A desktop that was polling when the message landed and then went
        // silent must not cost the user their answer. The only thing presence
        // can do is postpone the Worker's claim, so once the window is over the
        // item is still claimable by exactly the predicate it always was.
        let plan = inline_answer_plan(Some(0), 1);
        let InlineAnswerPlan::HoldForDesktop { wait_ms } = plan else {
            panic!("a present desktop should hold the worker");
        };
        assert_eq!(wait_ms, DESKTOP_CLAIM_WINDOW_MS);
        // Nothing in the hold touches attempts, status, or the claim cutoff.
        assert!(CLAIMABLE_ITEM_PREDICATE_SQL.contains("status = 'pending'"));
        assert_eq!(claim_delay_ms(None), DEFAULT_CLAIM_DELAY_MS);
    }

    #[test]
    fn a_desktop_that_dies_holding_an_item_hands_it_back() {
        assert!(RELEASE_EXPIRED_LEASES_SQL.contains("SET status = 'pending'"));
        // Only a lease that has actually run out, and only while there are
        // attempts left to spend on it.
        assert!(RELEASE_EXPIRED_LEASES_SQL.contains("lease_until <= ?1"));
        assert!(RELEASE_EXPIRED_LEASES_SQL.contains("attempts < ?2"));
        // And it puts rows back into exactly the set the two scans read.
        assert!(CLAIMABLE_ITEM_PREDICATE_SQL.contains("status = 'pending'"));
    }

    #[test]
    fn presence_is_written_by_the_poll_and_read_by_the_webhook() {
        // The write is throttled against its own stored value, so a hub polling
        // every couple of seconds does not write every couple of seconds.
        assert!(RECORD_DESKTOP_POLL_SQL.contains("ON CONFLICT(uid) DO UPDATE"));
        assert!(RECORD_DESKTOP_POLL_SQL.contains("desktop_presence.last_polled_at <= ?3"));
        assert!(DESKTOP_PRESENCE_SQL.contains("WHERE uid = ?1"));
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
    fn the_prompt_forbids_disclaiming_the_memory_it_was_given() {
        let lowered = SYSTEM_PROMPT_BASE.to_lowercase();
        assert!(lowered.contains("never tell them you have no access"));
        assert!(lowered.contains("look it up themselves"));
        assert!(lowered.contains("nothing on that yet"));
        // The reply that started this: "your memories live in the Omi app on
        // your device, check the Memories tab". Both halves of that are now
        // named as things the model may not say.
        assert!(lowered.contains("their profile"));
        assert!(lowered.contains("never claim you have done something"));
        for channel in ["telegram", "imessage"] {
            assert!(system_prompt_for_channel(channel).contains("nothing on that yet"));
        }
    }

    #[test]
    fn release_status_transitions() {
        assert_eq!(release_status(1), "pending");
        assert_eq!(release_status(MAX_ATTEMPTS - 1), "pending");
        assert_eq!(release_status(MAX_ATTEMPTS), "failed");
    }
}
