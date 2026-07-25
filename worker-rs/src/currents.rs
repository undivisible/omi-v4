//! Currents `.crepus` metadata handling — parity with the TypeScript worker
//! (`worker/src/currents.ts`).
//!
//! A current may carry an AI-authored `.crepus` widget description in its
//! metadata. The real safety boundary is the Dart renderer in the app
//! (`crepuscularity_flutter` is generic; the omi app whitelists actions). The
//! worker only applies cheap defense-in-depth: a hard length cap so an oversized
//! or hostile blob never reaches the client. Both workers MUST agree on this cap
//! — keep [`CREPUS_MAX_LEN`] in step with the TS `crepusMaxLen`.

/// Maximum accepted length of a current's `.crepus` source, in characters.
/// Mirrors `crepusMaxLen` in `worker/src/currents.ts` and
/// `CrepusLimits.maxSourceLength` in the Flutter package.
pub const CREPUS_MAX_LEN: usize = crate::crepus_safety::CREPUS_MAX_LEN;

/// Trim and length-check a candidate `.crepus` string. Returns the trimmed
/// source when non-empty and within the cap, otherwise `None` (pass-through
/// rejection — no lowering, no parsing).
pub fn sanitize_crepus(value: &str) -> Option<String> {
    crate::crepus_safety::sanitize_crepus(value)
}

// ---------------------------------------------------------------------------
// Daily Currents cron (`generateDueCurrents` in `worker/src/currents.ts`)
// ---------------------------------------------------------------------------

/// Same local morning hour as digests — one wall-clock window for everyone.
/// Aliased rather than repeated so the two can never drift apart.
pub const CURRENTS_DAILY_HOUR: i64 = crate::digests::DAILY_HOUR;
/// Users considered per cron tick (`currentsUsersPerTick`).
pub const CURRENTS_USERS_PER_TICK: usize = 200;
/// How many Currents one user may be minted in one local day.
pub const CURRENTS_PER_USER_PER_DAY: usize = 3;

/// Whether a user's local clock is inside the daily Currents window.
///
/// The cron ticks every minute, so this hour-wide gate — together with the
/// `currents_daily_batches` row keyed on the *local* calendar date — is the
/// whole of the "once a day, in their morning" contract: without the gate every
/// tick would mint, and without the local date a user west of UTC would be
/// minted twice as the UTC date rolled under them.
pub fn is_currents_daily_hour(hour: i64) -> bool {
    hour == CURRENTS_DAILY_HOUR
}

#[cfg(target_arch = "wasm32")]
pub(crate) mod wasm_glue {
    use worker::{D1Database, Env, Result};

    use crate::cron_cursor::scan_onboarded_users;
    use crate::digests::local_clock;
    use crate::routes_memory::wasm_glue::{
        d1_first, d1_run, generate_one_current, n, s, GenerateOutcomeKind,
    };
    use crate::worker_util::now_ms;

    use super::{is_currents_daily_hour, CURRENTS_PER_USER_PER_DAY, CURRENTS_USERS_PER_TICK};

    /// Mint up to `currentsPerUserPerDay` Currents, then record the batch. The
    /// batch row is written even when nothing was minted: it is the marker that
    /// this user has had their turn today, not a count of successes.
    async fn mint_daily_batch(
        db: &D1Database,
        uid: &str,
        local_date: &str,
        now: i64,
    ) -> Result<()> {
        let mut created = 0i64;
        for _ in 0..CURRENTS_PER_USER_PER_DAY {
            match generate_one_current(db, uid, now).await? {
                GenerateOutcomeKind::Created => created += 1,
                _ => break,
            }
        }
        d1_run(
            db,
            "INSERT OR IGNORE INTO currents_daily_batches\n               (uid, local_date, created_count, created_at)\n             VALUES (?1, ?2, ?3, ?4)",
            &[s(uid), s(local_date), n(created), n(now)],
        )
        .await?;
        Ok(())
    }

    /// `generateDueCurrents` — morning cron: for every onboarded user in this
    /// tick's page whose local clock is in the daily hour, mint up to a few
    /// Currents once per local calendar day. Batched like digests so all users
    /// refresh on the same schedule without each client having to call
    /// `/generate`.
    pub async fn generate_due_currents(env: &Env) -> Result<()> {
        let db = env.d1("DB")?;
        let now = now_ms();
        let users = scan_onboarded_users(&db, "currents", CURRENTS_USERS_PER_TICK, now).await?;
        for user in users {
            let clock = local_clock(now, user.digest_utc_offset_minutes);
            if !is_currents_daily_hour(clock.hour) {
                continue;
            }
            let already = d1_first(
                &db,
                "SELECT 1 AS ok FROM currents_daily_batches WHERE uid = ?1 AND local_date = ?2",
                &[s(&user.uid), s(&clock.date)],
            )
            .await?;
            if already.is_some() {
                continue;
            }
            // One user must not stall the rest of the cron tick.
            let _ = mint_daily_batch(&db, &user.uid, &clock.date, now).await;
        }
        Ok(())
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) use wasm_glue::generate_due_currents;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::digests::{due_kind, local_clock, DigestKind};

    #[test]
    fn currents_share_the_daily_digest_window() {
        assert_eq!(CURRENTS_DAILY_HOUR, crate::digests::DAILY_HOUR);
        for hour in 0..24 {
            assert_eq!(
                is_currents_daily_hour(hour),
                due_kind(hour) == Some(DigestKind::Daily),
                "hour {hour}"
            );
        }
    }

    #[test]
    fn the_window_follows_the_users_own_clock_not_utc() {
        // 15:00 UTC is 07:00 for a user at UTC-8 and 20:00 for one at UTC+5,
        // so the same tick mints for the first and skips the second.
        let now = 1_784_559_600_000; // 2026-07-20T15:00:00Z
        assert!(is_currents_daily_hour(local_clock(now, -480).hour));
        assert!(!is_currents_daily_hour(local_clock(now, 300).hour));
        // The batch key is the user's local date, which at UTC-8 is still the
        // 20th while a user at UTC+14 has already rolled into the 21st.
        assert_eq!(local_clock(now, -480).date, "2026-07-20");
        assert_eq!(local_clock(now, 840).date, "2026-07-21");
    }

    #[test]
    fn accepts_normal_source() {
        assert_eq!(
            sanitize_crepus("  text \"hi\"  "),
            Some("text \"hi\"".to_string())
        );
    }

    #[test]
    fn rejects_blank() {
        assert_eq!(sanitize_crepus("   \n  "), None);
    }

    #[test]
    fn rejects_oversized() {
        let huge = "a".repeat(CREPUS_MAX_LEN + 1);
        assert_eq!(sanitize_crepus(&huge), None);
    }

    #[test]
    fn accepts_at_the_cap() {
        let exact = "a".repeat(CREPUS_MAX_LEN);
        assert_eq!(sanitize_crepus(&exact), Some(exact));
    }
}
