import { priceBand } from "./byok-pricing";
import type { AppEnv } from "./types";

// DEV_FAKE_PRO short-circuits the Stripe-backed entitlement so local and
// testing deployments work with billing stubbed out; never set it in
// production. As a hard safety net, ENVIRONMENT === "production" always
// refuses the short-circuit even if DEV_FAKE_PRO was mistakenly set.
export const hasActivePro = async (
  env: AppEnv["Bindings"],
  uid: string,
): Promise<boolean> => {
  if (env.DEV_FAKE_PRO === "true") {
    if (env.ENVIRONMENT === "production") {
      console.warn(
        "DEV_FAKE_PRO is set but ENVIRONMENT is production; ignoring DEV_FAKE_PRO.",
      );
    } else {
      return true;
    }
  }
  const row = await env.DB.prepare(
    "SELECT plan, status, valid_until FROM entitlements WHERE uid = ?1",
  )
    .bind(uid)
    .first();
  return (
    row?.plan === "pro" &&
    row.status === "active" &&
    (row.valid_until === null || Number(row.valid_until) > Date.now())
  );
};

// The BYOK entitlement price. It is read from the negotiation audit record
// rather than recomputed or trusted from the client, and clamped into the
// price band in force today so a record written under an older, wider band
// can never undercut the current floor.
export const byokPriceCents = async (
  env: AppEnv["Bindings"],
  uid: string,
): Promise<{ priceCents: number; negotiated: boolean }> => {
  const band = priceBand(env);
  const row = await env.DB.prepare(
    "SELECT price_cents, outcome FROM byok_price_agreements WHERE uid = ?1",
  )
    .bind(uid)
    .first<{ price_cents: number; outcome: string }>();
  if (!row) return { priceCents: band.standardCents, negotiated: false };
  const priceCents = Math.min(
    band.standardCents,
    Math.max(band.floorCents, Number(row.price_cents)),
  );
  return { priceCents, negotiated: row.outcome === "negotiated" };
};
