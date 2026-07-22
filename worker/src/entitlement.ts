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
