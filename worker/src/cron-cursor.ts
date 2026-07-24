import type { Bindings } from "./types";

export type OnboardedUserRow = {
  uid: string;
  digest_utc_offset_minutes: number;
};

export const loadCronCursor = async (
  env: Bindings,
  name: string,
): Promise<string> => {
  const row = await env.DB.prepare(
    "SELECT last_uid FROM cron_cursors WHERE name = ?1",
  )
    .bind(name)
    .first<{ last_uid: string }>();
  return row?.last_uid ?? "";
};

export const saveCronCursor = async (
  env: Bindings,
  name: string,
  lastUid: string,
  now: number,
): Promise<void> => {
  await env.DB.prepare(
    `INSERT INTO cron_cursors (name, last_uid, updated_at)
     VALUES (?1, ?2, ?3)
     ON CONFLICT(name) DO UPDATE SET
       last_uid = excluded.last_uid,
       updated_at = excluded.updated_at`,
  )
    .bind(name, lastUid, now)
    .run();
};

const selectOnboardedUsers = (env: Bindings, afterUid: string, limit: number) =>
  env.DB.prepare(
    `SELECT uid, digest_utc_offset_minutes FROM users
     WHERE onboarding_completed_at IS NOT NULL AND uid > ?1
     ORDER BY uid LIMIT ?2`,
  )
    .bind(afterUid, limit)
    .all<OnboardedUserRow>();

// Keyset scan of onboarded users that advances a named cursor each tick and
// wraps to the start when the tail is exhausted, so every user gets a turn.
export const scanOnboardedUsers = async (
  env: Bindings,
  options: { cursorName: string; limit: number; now: number },
): Promise<OnboardedUserRow[]> => {
  const cursor = await loadCronCursor(env, options.cursorName);
  let rows =
    (await selectOnboardedUsers(env, cursor, options.limit)).results ?? [];
  if (rows.length === 0 && cursor !== "") {
    rows = (await selectOnboardedUsers(env, "", options.limit)).results ?? [];
  }
  const lastUid = rows.at(-1)?.uid ?? "";
  await saveCronCursor(env, options.cursorName, lastUid, options.now);
  return rows;
};
