//! Keyset rotation over onboarded users — parity with `worker/src/cron-cursor.ts`.
//!
//! A minute tick can only afford a bounded page of users, so a cron that always
//! read from the head of uid order would serve the same first page for ever and
//! starve every user behind it once the base outgrows one page. Each named cron
//! therefore owns a row in `cron_cursors`: the scan resumes strictly *after* the
//! last uid it saw, and wraps back to the head once the tail is exhausted. The
//! cursor name is what keeps the digests and currents crons rotating
//! independently rather than fighting over one shared position.
//!
//! The rotation decisions are pure and live here; the D1 reads and the cursor
//! write are the thin wasm glue at the bottom of the file.

/// One onboarded user as the cron scan sees them (`OnboardedUserRow`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OnboardedUser {
    pub uid: String,
    pub digest_utc_offset_minutes: i64,
}

/// Whether an exhausted page should be re-queried from the head of uid order.
///
/// Only an empty page *behind a cursor* proves the tail was reached. An empty
/// page at the head means there are no onboarded users at all, and re-querying
/// would just repeat that read for nothing.
pub fn should_wrap(page_len: usize, cursor: &str) -> bool {
    page_len == 0 && !cursor.is_empty()
}

/// The cursor to persist after a page has been read.
///
/// The last uid of the page resumes the scan there on the next tick. An empty
/// page stores `""`, and that is precisely what returns the next tick to the
/// head of the order instead of leaving the cursor parked past the tail for
/// ever — the wrap is completed by the *write*, not only by the re-query.
pub fn cursor_after_page(page: &[OnboardedUser]) -> &str {
    page.last().map(|user| user.uid.as_str()).unwrap_or("")
}

#[cfg(target_arch = "wasm32")]
pub(crate) mod wasm_glue {
    use worker::{D1Database, Result};

    use crate::glue::json_to_i64;
    use crate::routes_memory::wasm_glue::{d1_all, d1_first, d1_run, n, s, str_field};

    use super::{cursor_after_page, should_wrap, OnboardedUser};

    /// `loadCronCursor` — the stored resume point, `""` when this cron has never
    /// run (or wrapped on its last tick).
    pub(crate) async fn load_cron_cursor(db: &D1Database, name: &str) -> Result<String> {
        let row = d1_first(
            db,
            "SELECT last_uid FROM cron_cursors WHERE name = ?1",
            &[s(name)],
        )
        .await?;
        Ok(row
            .as_ref()
            .map(|row| str_field(row, "last_uid"))
            .unwrap_or_default())
    }

    /// `saveCronCursor` — upsert the resume point for the next tick.
    pub(crate) async fn save_cron_cursor(
        db: &D1Database,
        name: &str,
        last_uid: &str,
        now: i64,
    ) -> Result<()> {
        d1_run(
            db,
            "INSERT INTO cron_cursors (name, last_uid, updated_at)\n             VALUES (?1, ?2, ?3)\n             ON CONFLICT(name) DO UPDATE SET\n               last_uid = excluded.last_uid,\n               updated_at = excluded.updated_at",
            &[s(name), s(last_uid), n(now)],
        )
        .await?;
        Ok(())
    }

    async fn select_onboarded_users(
        db: &D1Database,
        after_uid: &str,
        limit: usize,
    ) -> Result<Vec<OnboardedUser>> {
        let rows = d1_all(
            db,
            "SELECT uid, digest_utc_offset_minutes FROM users\n             WHERE onboarding_completed_at IS NOT NULL AND uid > ?1\n             ORDER BY uid LIMIT ?2",
            &[s(after_uid), n(limit as i64)],
        )
        .await?;
        Ok(rows
            .iter()
            .map(|row| OnboardedUser {
                uid: str_field(row, "uid"),
                // `Number(row.digest_utc_offset_minutes) || 0` — a missing or
                // unreadable offset is UTC, never a skipped user.
                digest_utc_offset_minutes: row
                    .get("digest_utc_offset_minutes")
                    .and_then(json_to_i64)
                    .unwrap_or(0),
            })
            .collect())
    }

    /// `scanOnboardedUsers` — one page of onboarded users for the named cron,
    /// advancing (and, at the tail, wrapping) the cursor as a side effect.
    pub(crate) async fn scan_onboarded_users(
        db: &D1Database,
        cursor_name: &str,
        limit: usize,
        now: i64,
    ) -> Result<Vec<OnboardedUser>> {
        let cursor = load_cron_cursor(db, cursor_name).await?;
        let mut rows = select_onboarded_users(db, &cursor, limit).await?;
        if should_wrap(rows.len(), &cursor) {
            rows = select_onboarded_users(db, "", limit).await?;
        }
        save_cron_cursor(db, cursor_name, cursor_after_page(&rows), now).await?;
        Ok(rows)
    }
}

#[cfg(target_arch = "wasm32")]
pub(crate) use wasm_glue::scan_onboarded_users;

#[cfg(test)]
mod tests {
    use super::*;

    fn user(uid: &str) -> OnboardedUser {
        OnboardedUser {
            uid: uid.to_string(),
            digest_utc_offset_minutes: 0,
        }
    }

    fn roster() -> Vec<OnboardedUser> {
        ["a-user", "b-user", "c-user", "d-user", "e-user"]
            .into_iter()
            .map(user)
            .collect()
    }

    /// The `uid > ?1 ORDER BY uid LIMIT ?2` keyset page, in memory.
    fn page(users: &[OnboardedUser], after_uid: &str, limit: usize) -> Vec<OnboardedUser> {
        users
            .iter()
            .filter(|row| row.uid.as_str() > after_uid)
            .take(limit)
            .cloned()
            .collect()
    }

    /// `scanOnboardedUsers` with the D1 reads replaced by `page`, so the
    /// rotation and the cursor write are exercised exactly as the glue runs them.
    fn scan(users: &[OnboardedUser], cursor: &mut String, limit: usize) -> Vec<String> {
        let mut rows = page(users, cursor, limit);
        if should_wrap(rows.len(), cursor) {
            rows = page(users, "", limit);
        }
        *cursor = cursor_after_page(&rows).to_string();
        rows.into_iter().map(|row| row.uid).collect()
    }

    #[test]
    fn advances_past_the_first_page_and_wraps_after_the_tail() {
        let users = roster();
        let mut cursor = String::new();

        assert_eq!(scan(&users, &mut cursor, 2), ["a-user", "b-user"]);
        assert_eq!(cursor, "b-user");
        assert_eq!(scan(&users, &mut cursor, 2), ["c-user", "d-user"]);
        assert_eq!(cursor, "d-user");
        // The tail page is short, and its last uid is still what is stored.
        assert_eq!(scan(&users, &mut cursor, 2), ["e-user"]);
        assert_eq!(cursor, "e-user");
        // Past the tail: the empty page wraps to the head within the same tick,
        // so no tick is wasted on an empty scan.
        assert_eq!(scan(&users, &mut cursor, 2), ["a-user", "b-user"]);
        assert_eq!(cursor, "b-user");
    }

    #[test]
    fn each_named_cursor_rotates_independently() {
        let users = roster();
        let mut digests = String::new();
        let mut currents = String::new();
        assert_eq!(scan(&users, &mut digests, 2), ["a-user", "b-user"]);
        assert_eq!(
            scan(&users, &mut currents, 3),
            ["a-user", "b-user", "c-user"]
        );
        assert_eq!(digests, "b-user");
        assert_eq!(currents, "c-user");
    }

    #[test]
    fn a_page_larger_than_the_roster_wraps_on_the_next_tick() {
        let users = roster();
        let mut cursor = String::new();
        assert_eq!(scan(&users, &mut cursor, 200).len(), 5);
        assert_eq!(cursor, "e-user");
        assert_eq!(scan(&users, &mut cursor, 200).len(), 5);
        assert_eq!(cursor, "e-user");
    }

    #[test]
    fn wrap_with_no_onboarded_users_clears_the_cursor() {
        let empty: Vec<OnboardedUser> = Vec::new();
        let mut cursor = "e-user".to_string();
        assert!(scan(&empty, &mut cursor, 2).is_empty());
        assert_eq!(cursor, "");
        // Still empty at the head: the cursor stays cleared rather than being
        // parked on a uid that no longer qualifies.
        assert!(scan(&empty, &mut cursor, 2).is_empty());
        assert_eq!(cursor, "");
    }

    #[test]
    fn wrap_is_only_attempted_from_behind_a_cursor() {
        assert!(should_wrap(0, "b-user"));
        // An empty head page means there is nobody to serve; re-querying the
        // same head would be a wasted read.
        assert!(!should_wrap(0, ""));
        assert!(!should_wrap(2, "b-user"));
        assert!(!should_wrap(2, ""));
    }

    #[test]
    fn cursor_after_page_takes_the_last_uid_or_clears() {
        assert_eq!(cursor_after_page(&[]), "");
        assert_eq!(cursor_after_page(&[user("a-user")]), "a-user");
        assert_eq!(
            cursor_after_page(&[user("a-user"), user("b-user")]),
            "b-user"
        );
    }
}
