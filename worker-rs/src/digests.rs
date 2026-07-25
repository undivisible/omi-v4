//! Daily and nightly digests — parity with `worker/src/digests.ts`.
//!
//! Two framings of memory the user already has:
//!
//!   * DAILY ("what you need to do") — a morning brief of what is ahead, drawn
//!     from the same surfaced Currents the hub leads with, most important first.
//!   * NIGHTLY ("what you did") — an evening recap of what was captured or
//!     completed during the local day, drawn from the day's accepted claims.
//!
//! Both are stored as `memory_daily_reviews` rows (migration 0031): a digest is
//! a review with a `kind`. The pre-existing UNIQUE (uid, local_date,
//! input_revision) is what makes generation idempotent — a fixed input_revision
//! per kind means re-running the cron inside the same local day inserts nothing.
//! Delivery, when the user has a linked channel, is enqueued exactly once
//! through the same `channel_deliveries` queue every other outbound message uses.
//!
//! The cron fires every minute for every user, so the whole design rests on the
//! local clock: a digest is due only while the user's own wall clock sits inside
//! one hour-wide window. Getting that wrong means duplicate digests or none at
//! all, so the clock, the window test and the body assembly are pure functions
//! tested here; only the D1 reads and writes are wasm glue.

use crate::currents_refresh::collapse;

/// Local hour of the morning brief.
pub const DAILY_HOUR: i64 = 7;
/// Local hour of the evening recap.
pub const NIGHTLY_HOUR: i64 = 21;
/// Fixed `input_revision` of a daily digest — the idempotency key, with the
/// local date, behind UNIQUE (uid, local_date, input_revision).
pub const DAILY_REVISION: &str = "worker-daily";
/// Fixed `input_revision` of a nightly digest.
pub const NIGHTLY_REVISION: &str = "worker-nightly";
/// Users considered per cron tick (`usersPerTick`).
pub const USERS_PER_TICK: usize = 200;
/// Row cap on the morning brief.
pub const DAILY_ITEMS: i64 = 6;
/// Row cap on the evening recap.
pub const NIGHTLY_ITEMS: i64 = 12;
const MAX_BODY_CHARACTERS: usize = 4_096;
const DAY_MS: i64 = 24 * 60 * 60 * 1000;
const HOUR_MS: i64 = 60 * 60 * 1000;
const MINUTE_MS: i64 = 60_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DigestKind {
    Daily,
    Nightly,
}

impl DigestKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Daily => "daily",
            Self::Nightly => "nightly",
        }
    }

    pub fn input_revision(self) -> &'static str {
        match self {
            Self::Daily => DAILY_REVISION,
            Self::Nightly => NIGHTLY_REVISION,
        }
    }
}

/// The user's wall clock, from UTC plus their stored offset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalClock {
    /// Local calendar date, `YYYY-MM-DD`. This is the per-day idempotency key.
    pub date: String,
    /// Local hour, 0–23.
    pub hour: i64,
    /// The UTC instant of local midnight, so the nightly window is
    /// `[day_start_ms, +1 day)`.
    pub day_start_ms: i64,
}

/// `localClock` — shift UTC by the stored offset, then read the calendar date,
/// the hour and the UTC instant of local midnight off the shifted value.
///
/// Euclidean division is load-bearing: offsets west of UTC push the shifted
/// instant before the epoch-day boundary (and, for pre-1970 instants, negative),
/// where truncating division would round the wrong way and put a user on the
/// following local day for the whole of their morning.
pub fn local_clock(now: i64, offset_minutes: i64) -> LocalClock {
    let shifted = now + offset_minutes * MINUTE_MS;
    LocalClock {
        date: crate::channel_commands::iso_date(shifted),
        hour: shifted.rem_euclid(DAY_MS) / HOUR_MS,
        day_start_ms: shifted.div_euclid(DAY_MS) * DAY_MS - offset_minutes * MINUTE_MS,
    }
}

/// The digest due at this local hour, if any. The two windows are an hour wide
/// and disjoint, so at most one kind is ever due on a tick.
pub fn due_kind(hour: i64) -> Option<DigestKind> {
    match hour {
        DAILY_HOUR => Some(DigestKind::Daily),
        NIGHTLY_HOUR => Some(DigestKind::Nightly),
        _ => None,
    }
}

/// The `channel_deliveries` id *and* idempotency key of a digest delivery. It is
/// derived from the local date rather than the instant, so every tick inside the
/// window resolves to the same key and the queue can hold only one.
pub fn delivery_id(kind: DigestKind, uid: &str, local_date: &str) -> String {
    format!("digest:{}:{uid}:{local_date}", kind.as_str())
}

/// A rendered digest: the message body and the evidence it cites.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DigestBody {
    pub body: String,
    pub citations: Vec<String>,
}

/// One surfaced or accepted Current, as the morning brief reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DailyItem {
    pub title: String,
    pub instruction: Option<String>,
    pub evidence_id: String,
}

/// One accepted claim recorded during the local day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NightlyItem {
    pub content: String,
    pub evidence_id: String,
}

fn cap_body(value: String) -> String {
    if value.chars().count() > MAX_BODY_CHARACTERS {
        value.chars().take(MAX_BODY_CHARACTERS).collect()
    } else {
        value
    }
}

fn push_citation(citations: &mut Vec<String>, evidence_id: &str) {
    if !citations.iter().any(|seen| seen == evidence_id) {
        citations.push(evidence_id.to_string());
    }
}

/// `dailyDigest` body assembly — a numbered list of what is ahead, in the order
/// the caller supplied (the query orders by confidence). `None` when there is
/// nothing to say, which is what keeps a quiet day from producing an empty brief.
pub fn daily_body(items: &[DailyItem]) -> Option<DigestBody> {
    if items.is_empty() {
        return None;
    }
    let mut lines = Vec::with_capacity(items.len());
    let mut citations = Vec::new();
    for (index, item) in items.iter().enumerate() {
        let title = collapse(&item.title);
        let instruction = item
            .instruction
            .as_deref()
            .map(collapse)
            .unwrap_or_default();
        lines.push(if instruction.is_empty() {
            format!("{}. {title}", index + 1)
        } else {
            format!("{}. {title} — {instruction}", index + 1)
        });
        push_citation(&mut citations, &item.evidence_id);
    }
    Some(DigestBody {
        body: cap_body(format!("What you need to do today:\n{}", lines.join("\n"))),
        citations,
    })
}

/// `nightlyDigest` body assembly — the day's captures, de-duplicated by their
/// collapsed text. A claim whose text repeats or collapses to nothing still
/// counts as cited evidence: the recap line is a summary, the citation is the
/// provenance, and dropping the latter would understate what the digest was
/// built from.
pub fn nightly_body(items: &[NightlyItem]) -> Option<DigestBody> {
    if items.is_empty() {
        return None;
    }
    let mut seen: Vec<String> = Vec::new();
    let mut lines: Vec<String> = Vec::new();
    let mut citations = Vec::new();
    for item in items {
        let content = collapse(&item.content);
        if !content.is_empty() && !seen.iter().any(|value| value == &content) {
            seen.push(content.clone());
            lines.push(format!("- {content}"));
        }
        push_citation(&mut citations, &item.evidence_id);
    }
    let count = lines.len();
    let noun = if count == 1 { "thing" } else { "things" };
    Some(DigestBody {
        body: cap_body(format!(
            "What you did today — {count} {noun} captured:\n{}",
            lines.join("\n")
        )),
        citations,
    })
}

#[cfg(target_arch = "wasm32")]
pub(crate) mod wasm_glue {
    use serde_json::Value;
    use worker::{D1Database, Env, Result};

    use crate::cron_cursor::scan_onboarded_users;
    use crate::routes_memory::wasm_glue::{d1_all, d1_run, n, s, stmt, str_field};
    use crate::worker_util::{changes, now_ms, uuid_v4};

    use super::*;

    fn opt_str_field(row: &Value, key: &str) -> Option<String> {
        match row.get(key) {
            Some(Value::Null) | None => None,
            Some(Value::String(value)) => Some(value.clone()),
            Some(other) => Some(other.to_string()),
        }
    }

    /// `dailyDigest` — the currents the hub would lead with, most important first.
    async fn daily_digest(db: &D1Database, uid: &str) -> Result<Option<DigestBody>> {
        let rows = d1_all(
            db,
            "SELECT c.title, json_extract(c.proposed_action, '$.instruction') AS instruction,\n                    c.evidence_id\n             FROM currents c\n             JOIN memory_evidence e ON e.id = c.evidence_id AND e.uid = c.uid\n             JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n             JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n             WHERE c.uid = ?1 AND c.status IN ('surfaced', 'accepted')\n               AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL\n             ORDER BY c.confidence_basis_points DESC, c.updated_at DESC, c.id ASC\n             LIMIT ?2",
            &[s(uid), n(DAILY_ITEMS)],
        )
        .await?;
        let items: Vec<DailyItem> = rows
            .iter()
            .map(|row| DailyItem {
                title: str_field(row, "title"),
                instruction: opt_str_field(row, "instruction"),
                evidence_id: str_field(row, "evidence_id"),
            })
            .collect();
        Ok(daily_body(&items))
    }

    /// `nightlyDigest` — accepted claims recorded inside the user's local day.
    async fn nightly_digest(
        db: &D1Database,
        uid: &str,
        day_start_ms: i64,
    ) -> Result<Option<DigestBody>> {
        let rows = d1_all(
            db,
            "SELECT c.content, e.id AS evidence_id\n             FROM memory_claims c\n             JOIN memory_claim_evidence ce ON ce.claim_id = c.id AND ce.uid = c.uid\n               AND ce.relation = 'supports'\n             JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid\n             JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid\n             JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid\n             WHERE c.uid = ?1 AND c.status = 'accepted' AND c.retracted_at IS NULL\n               AND c.recorded_at >= ?2 AND c.recorded_at < ?3\n               AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')\n               AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')\n               AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL\n             ORDER BY c.recorded_at DESC, c.id ASC\n             LIMIT ?4",
            &[
                s(uid),
                n(day_start_ms),
                n(day_start_ms + DAY_MS),
                n(NIGHTLY_ITEMS),
            ],
        )
        .await?;
        let items: Vec<NightlyItem> = rows
            .iter()
            .map(|row| NightlyItem {
                content: str_field(row, "content"),
                evidence_id: str_field(row, "evidence_id"),
            })
            .collect();
        Ok(nightly_body(&items))
    }

    /// `storeDigest` — store the digest once and, only when it was newly
    /// created, enqueue a single channel delivery for whichever channel the user
    /// has linked. Returns whether a new row was written, so the cron can account
    /// for its work; a duplicate insert is a silent no-op with no second send.
    async fn store_digest(
        db: &D1Database,
        uid: &str,
        kind: DigestKind,
        local_date: &str,
        digest: &DigestBody,
        now: i64,
    ) -> Result<bool> {
        let id = uuid_v4();
        let inserted = d1_run(
            db,
            "INSERT OR IGNORE INTO memory_daily_reviews\n               (id, uid, local_date, input_revision, body, kind, created_at, updated_at)\n             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
            &[
                s(&id),
                s(uid),
                s(local_date),
                s(kind.input_revision()),
                s(&digest.body),
                s(kind.as_str()),
                n(now),
            ],
        )
        .await?;
        if changes(&inserted) != 1 {
            return Ok(false);
        }
        let mut statements = Vec::with_capacity(digest.citations.len() + 1);
        for evidence_id in &digest.citations {
            statements.push(stmt(
                db,
                "INSERT OR IGNORE INTO memory_daily_review_citations (uid, review_id, evidence_id)\n                 SELECT ?1, ?2, e.id FROM memory_evidence e\n                 WHERE e.id = ?3 AND e.uid = ?1",
                &[s(uid), s(&id), s(evidence_id)],
            )?);
        }
        let delivery = delivery_id(kind, uid, local_date);
        statements.push(stmt(
            db,
            "INSERT OR IGNORE INTO channel_deliveries\n                 (id, uid, channel, idempotency_key, channel_chat_id, text, next_attempt_at, created_at, updated_at)\n               SELECT ?1, b.uid, b.channel, ?2, COALESCE(b.channel_chat_id, b.channel_user_id), ?3, ?4, ?4, ?4\n               FROM channel_bindings b\n               WHERE b.uid = ?5 AND b.revoked_at IS NULL\n               ORDER BY b.verified_at DESC LIMIT 1",
            &[s(&delivery), s(&delivery), s(&digest.body), n(now), s(uid)],
        )?);
        db.batch(statements).await?;
        Ok(true)
    }

    async fn generate_for_user(
        db: &D1Database,
        uid: &str,
        clock: &LocalClock,
        now: i64,
    ) -> Result<()> {
        match due_kind(clock.hour) {
            Some(DigestKind::Daily) => {
                if let Some(digest) = daily_digest(db, uid).await? {
                    store_digest(db, uid, DigestKind::Daily, &clock.date, &digest, now).await?;
                }
            }
            Some(DigestKind::Nightly) => {
                if let Some(digest) = nightly_digest(db, uid, clock.day_start_ms).await? {
                    store_digest(db, uid, DigestKind::Nightly, &clock.date, &digest, now).await?;
                }
            }
            None => {}
        }
        Ok(())
    }

    /// `generateDueDigests` — one cron pass: for each user in this tick's page
    /// whose local clock is inside a digest window and who has no digest of that
    /// kind for the local day yet, generate and store it. Idempotent — outside
    /// the window, or once written, this is a no-op.
    pub async fn generate_due_digests(env: &Env) -> Result<()> {
        let db = env.d1("DB")?;
        let now = now_ms();
        let users = scan_onboarded_users(&db, "digests", USERS_PER_TICK, now).await?;
        for user in users {
            let clock = local_clock(now, user.digest_utc_offset_minutes);
            // Per-user error isolation (the TS `try {} catch {}`): one user's
            // failed digest must not cost every later user in the page its turn.
            let _ = generate_for_user(&db, &user.uid, &clock, now).await;
        }
        Ok(())
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) use wasm_glue::generate_due_digests;

#[cfg(test)]
mod tests {
    use super::*;

    /// Milliseconds since the epoch for a UTC calendar instant, without pulling
    /// in a date crate: the tests state the instant they mean and this converts.
    fn utc(year: i64, month: i64, day: i64, hour: i64, minute: i64) -> i64 {
        // Days-from-civil (Howard Hinnant), the inverse of `iso_date`.
        let y = if month <= 2 { year - 1 } else { year };
        let era = y.div_euclid(400);
        let yoe = y - era * 400;
        let mp = if month > 2 { month - 3 } else { month + 9 };
        let doy = (153 * mp + 2) / 5 + day - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        let days = era * 146_097 + doe - 719_468;
        days * DAY_MS + hour * HOUR_MS + minute * MINUTE_MS
    }

    #[test]
    fn utc_helper_agrees_with_iso_date() {
        assert_eq!(utc(1970, 1, 1, 0, 0), 0);
        assert_eq!(
            crate::channel_commands::iso_date(utc(2026, 7, 20, 7, 30)),
            "2026-07-20"
        );
        assert_eq!(
            crate::channel_commands::iso_date(utc(2024, 2, 29, 0, 0)),
            "2024-02-29"
        );
    }

    #[test]
    fn utc_offset_zero_reads_the_utc_wall_clock() {
        let clock = local_clock(utc(2026, 7, 20, 7, 30), 0);
        assert_eq!(clock.date, "2026-07-20");
        assert_eq!(clock.hour, 7);
        assert_eq!(clock.day_start_ms, utc(2026, 7, 20, 0, 0));
        assert_eq!(due_kind(clock.hour), Some(DigestKind::Daily));

        let evening = local_clock(utc(2026, 7, 20, 21, 30), 0);
        assert_eq!(evening.hour, 21);
        assert_eq!(due_kind(evening.hour), Some(DigestKind::Nightly));
    }

    #[test]
    fn a_positive_offset_rolls_the_local_date_forward() {
        // 23:30 UTC + 60 min is 00:30 the next local day, and local midnight is
        // an hour *before* the instant that produced it.
        let clock = local_clock(utc(2026, 7, 20, 23, 30), 60);
        assert_eq!(clock.date, "2026-07-21");
        assert_eq!(clock.hour, 0);
        assert_eq!(clock.day_start_ms, utc(2026, 7, 20, 23, 0));
    }

    #[test]
    fn a_negative_offset_rolls_the_local_date_backward() {
        // UTC-8: 07:30 UTC is still 23:30 the previous local day, so this user
        // is nowhere near their morning window even though UTC says 07.
        let clock = local_clock(utc(2026, 7, 20, 7, 30), -480);
        assert_eq!(clock.date, "2026-07-19");
        assert_eq!(clock.hour, 23);
        assert_eq!(clock.day_start_ms, utc(2026, 7, 19, 8, 0));
        assert_eq!(due_kind(clock.hour), None);

        // Their own 07:00 local is 15:00 UTC.
        let morning = local_clock(utc(2026, 7, 20, 15, 0), -480);
        assert_eq!(morning.date, "2026-07-20");
        assert_eq!(morning.hour, 7);
        assert_eq!(due_kind(morning.hour), Some(DigestKind::Daily));
    }

    #[test]
    fn offsets_that_are_not_whole_hours_still_land_in_the_window() {
        // UTC+05:30 (India): 01:45 UTC is 07:15 local.
        let india = local_clock(utc(2026, 7, 20, 1, 45), 330);
        assert_eq!(india.date, "2026-07-20");
        assert_eq!(india.hour, 7);
        assert_eq!(india.day_start_ms, utc(2026, 7, 19, 18, 30));
        assert_eq!(due_kind(india.hour), Some(DigestKind::Daily));

        // UTC+05:45 (Nepal): 01:20 UTC is 07:05 local.
        let nepal = local_clock(utc(2026, 7, 20, 1, 20), 345);
        assert_eq!(nepal.hour, 7);
        assert_eq!(due_kind(nepal.hour), Some(DigestKind::Daily));

        // UTC-03:30 (Newfoundland): 10:45 UTC is 07:15 local.
        let newfoundland = local_clock(utc(2026, 7, 20, 10, 45), -210);
        assert_eq!(newfoundland.date, "2026-07-20");
        assert_eq!(newfoundland.hour, 7);
        assert_eq!(newfoundland.day_start_ms, utc(2026, 7, 20, 3, 30));
        assert_eq!(due_kind(newfoundland.hour), Some(DigestKind::Daily));
    }

    #[test]
    fn the_window_is_exactly_one_local_hour_wide() {
        // A fractional offset must not let the window straddle two local hours.
        for minute in 0..60 {
            let clock = local_clock(utc(2026, 7, 20, 1, 30) + minute * MINUTE_MS, 330);
            assert_eq!(clock.hour, 7, "minute {minute} should still be 07 local");
        }
        let before = local_clock(utc(2026, 7, 20, 1, 29), 330);
        assert_eq!(before.hour, 6);
        assert_eq!(due_kind(before.hour), None);
        let after = local_clock(utc(2026, 7, 20, 2, 30), 330);
        assert_eq!(after.hour, 8);
        assert_eq!(due_kind(after.hour), None);
    }

    #[test]
    fn local_midnight_rolls_the_date_and_the_day_window() {
        let last = local_clock(utc(2026, 7, 20, 23, 59) + 59_999, 0);
        assert_eq!(last.date, "2026-07-20");
        assert_eq!(last.hour, 23);
        assert_eq!(last.day_start_ms, utc(2026, 7, 20, 0, 0));

        let first = local_clock(utc(2026, 7, 21, 0, 0), 0);
        assert_eq!(first.date, "2026-07-21");
        assert_eq!(first.hour, 0);
        assert_eq!(first.day_start_ms, utc(2026, 7, 21, 0, 0));
    }

    #[test]
    fn the_nightly_window_covers_exactly_the_local_day() {
        // The recap query reads [day_start, day_start + 1 day); at 21:30 local
        // that window must be the user's own day, not the UTC day.
        let clock = local_clock(utc(2026, 7, 21, 5, 30), -480);
        assert_eq!(clock.date, "2026-07-20");
        assert_eq!(clock.hour, 21);
        assert_eq!(clock.day_start_ms, utc(2026, 7, 20, 8, 0));
        assert_eq!(clock.day_start_ms + DAY_MS, utc(2026, 7, 21, 8, 0));
    }

    #[test]
    fn month_and_year_rollovers_survive_the_offset_shift() {
        let new_year = local_clock(utc(2025, 12, 31, 23, 30), 60);
        assert_eq!(new_year.date, "2026-01-01");
        assert_eq!(new_year.hour, 0);
        assert_eq!(new_year.day_start_ms, utc(2025, 12, 31, 23, 0));

        let leap = local_clock(utc(2024, 3, 1, 1, 0), -120);
        assert_eq!(leap.date, "2024-02-29");
        assert_eq!(leap.hour, 23);
        assert_eq!(leap.day_start_ms, utc(2024, 2, 29, 2, 0));
    }

    #[test]
    fn every_tick_inside_one_local_day_shares_the_idempotency_key() {
        // The "already ran today" guard is the local date, so two instants an
        // hour apart inside one local day must produce one key, and the same
        // wall-clock hour on the next local day must produce a different one.
        let first = local_clock(utc(2026, 7, 20, 15, 0), -480);
        let later = local_clock(utc(2026, 7, 20, 23, 0), -480);
        assert_eq!(first.date, later.date);
        assert_eq!(
            delivery_id(DigestKind::Daily, "u", &first.date),
            delivery_id(DigestKind::Daily, "u", &later.date)
        );
        let tomorrow = local_clock(utc(2026, 7, 21, 15, 0), -480);
        assert_ne!(first.date, tomorrow.date);
        // The two kinds never collide inside a day either.
        assert_ne!(
            delivery_id(DigestKind::Daily, "u", &first.date),
            delivery_id(DigestKind::Nightly, "u", &first.date)
        );
        assert_eq!(
            delivery_id(DigestKind::Daily, "linked", "2026-07-20"),
            "digest:daily:linked:2026-07-20"
        );
    }

    #[test]
    fn each_kind_has_its_own_fixed_input_revision() {
        assert_eq!(DigestKind::Daily.input_revision(), "worker-daily");
        assert_eq!(DigestKind::Nightly.input_revision(), "worker-nightly");
        assert_eq!(DigestKind::Daily.as_str(), "daily");
        assert_eq!(DigestKind::Nightly.as_str(), "nightly");
    }

    #[test]
    fn no_digest_is_due_outside_the_two_windows() {
        for hour in 0..24 {
            let expected = match hour {
                7 => Some(DigestKind::Daily),
                21 => Some(DigestKind::Nightly),
                _ => None,
            };
            assert_eq!(due_kind(hour), expected, "hour {hour}");
        }
    }

    fn daily(title: &str, instruction: Option<&str>, evidence: &str) -> DailyItem {
        DailyItem {
            title: title.to_string(),
            instruction: instruction.map(str::to_string),
            evidence_id: evidence.to_string(),
        }
    }

    #[test]
    fn a_quiet_day_produces_no_brief_at_all() {
        assert_eq!(daily_body(&[]), None);
        assert_eq!(nightly_body(&[]), None);
    }

    #[test]
    fn the_brief_numbers_items_in_the_order_given() {
        let digest = daily_body(&[
            daily("Reply to the launch email", Some("Handle it"), "ev-1"),
            daily("Confirm the deploy window", None, "ev-2"),
        ])
        .expect("brief");
        assert_eq!(
            digest.body,
            "What you need to do today:\n1. Reply to the launch email — Handle it\n2. Confirm the deploy window"
        );
        assert_eq!(digest.citations, ["ev-1", "ev-2"]);
    }

    #[test]
    fn the_brief_collapses_whitespace_and_drops_empty_instructions() {
        let digest = daily_body(&[
            daily("  Reply\tto   the\nemail ", Some("   "), "ev-1"),
            daily("Ship it", Some(" do\n it "), "ev-1"),
        ])
        .expect("brief");
        assert_eq!(
            digest.body,
            "What you need to do today:\n1. Reply to the email\n2. Ship it — do it"
        );
        // Two currents can cite one piece of evidence; it is stored once.
        assert_eq!(digest.citations, ["ev-1"]);
    }

    #[test]
    fn an_overlong_brief_is_capped() {
        let long = "x".repeat(MAX_BODY_CHARACTERS);
        let digest = daily_body(&[daily(&long, None, "ev-1")]).expect("brief");
        assert_eq!(digest.body.chars().count(), MAX_BODY_CHARACTERS);
        assert!(digest
            .body
            .starts_with("What you need to do today:\n1. xxx"));
    }

    fn nightly(content: &str, evidence: &str) -> NightlyItem {
        NightlyItem {
            content: content.to_string(),
            evidence_id: evidence.to_string(),
        }
    }

    #[test]
    fn the_recap_counts_and_de_duplicates_the_days_captures() {
        let digest = nightly_body(&[
            nightly("Shipped the Alpenglow build", "ev-1"),
            nightly("Reviewed the launch checklist", "ev-2"),
            nightly("  Shipped   the Alpenglow build ", "ev-3"),
        ])
        .expect("recap");
        assert_eq!(
            digest.body,
            "What you did today — 2 things captured:\n- Shipped the Alpenglow build\n- Reviewed the launch checklist"
        );
        // The repeated line still cited its own evidence.
        assert_eq!(digest.citations, ["ev-1", "ev-2", "ev-3"]);
    }

    #[test]
    fn one_capture_reads_as_a_singular_thing() {
        let digest = nightly_body(&[nightly("Shipped it", "ev-1")]).expect("recap");
        assert_eq!(
            digest.body,
            "What you did today — 1 thing captured:\n- Shipped it"
        );
    }

    #[test]
    fn blank_captures_still_cite_their_evidence() {
        let digest = nightly_body(&[nightly("   ", "ev-1"), nightly("", "ev-2")]).expect("recap");
        assert_eq!(digest.body, "What you did today — 0 things captured:\n");
        assert_eq!(digest.citations, ["ev-1", "ev-2"]);
    }
}
