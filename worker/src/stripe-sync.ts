import { stripeGet } from "./billing";
import { completeChannelCheckout } from "./channel-checkout";
import { applySubscriptionState } from "./stripe-entitlement";
import type { Bindings } from "./types";

const periodEnd = (subscription: Record<string, unknown>): number | null => {
  const value = subscription.current_period_end;
  return typeof value === "number" && Number.isSafeInteger(value)
    ? value * 1_000
    : null;
};

const priceOf = (subscription: Record<string, unknown>): string | null => {
  const items = subscription.items as
    | { data?: Array<{ price?: { id?: unknown } }> }
    | undefined;
  const id = items?.data?.[0]?.price?.id;
  return typeof id === "string" ? id : null;
};

// How stale an entitlement has to look before the cron re-reads it from
// Stripe, and how many are re-read per tick. Both keep the sweep bounded:
// this is a safety net for lost webhooks, not a polling loop over every
// customer.
const staleEntitlementMs = 6 * 60 * 60_000;
const entitlementBatch = 10;
const checkoutBatch = 5;
const checkoutSettleMs = 10 * 60_000;
// Stripe expires an unpaid session within a day, so a session older than this
// can never turn into a payment and is not worth re-reading.
const checkoutWindowMs = 24 * 60 * 60_000;

const reconcileEntitlement = async (
  env: Bindings,
  secret: string,
  row: { uid: string; stripe_subscription_id: string },
  now: number,
): Promise<void> => {
  const subscription = await stripeGet(
    secret,
    `subscriptions/${encodeURIComponent(row.stripe_subscription_id)}`,
  );
  if (!subscription) return;
  const customer =
    typeof subscription.customer === "string" ? subscription.customer : null;
  if (!customer) return;
  await applySubscriptionState(
    env,
    {
      uid: row.uid,
      status:
        typeof subscription.status === "string" ? subscription.status : null,
      validUntil: periodEnd(subscription),
      customer,
      subscriptionId: row.stripe_subscription_id,
      priceId: priceOf(subscription),
      // Reconciliation speaks for "now", so it wins over anything already
      // applied but is itself overtaken by any later real event.
      eventCreated: Math.floor(now / 1_000),
    },
    now,
  ).run();
};

// A checkout whose webhook never arrived: the person paid and, without this,
// would silently get nothing. The session is read back from Stripe and, if it
// really is paid, run through exactly the same completion path the webhook
// uses — including its single-shot confirmation message.
const reconcileChannelCheckout = async (
  env: Bindings,
  secret: string,
  sessionId: string,
  now: number,
): Promise<void> => {
  const session = await stripeGet(
    secret,
    `checkout/sessions/${encodeURIComponent(sessionId)}`,
  );
  if (!session) return;
  if (session.status === "expired") {
    await env.DB.prepare(
      "UPDATE channel_checkout_sessions SET expires_at = ?1 WHERE session_id = ?2 AND completed_at IS NULL",
    )
      .bind(now, sessionId)
      .run();
    return;
  }
  await completeChannelCheckout(
    env,
    {
      sessionId,
      uid:
        typeof session.client_reference_id === "string"
          ? session.client_reference_id
          : null,
      customer: typeof session.customer === "string" ? session.customer : null,
      subscription:
        typeof session.subscription === "string" ? session.subscription : null,
      paid:
        session.payment_status === "paid" ||
        session.payment_status === "no_payment_required",
      email:
        typeof (session.customer_details as { email?: unknown } | undefined)
          ?.email === "string"
          ? ((session.customer_details as { email: string }).email ?? null)
          : null,
      eventCreated: Math.floor(now / 1_000),
    },
    now,
  );
};

export const reconcileStripeSubscriptions = async (
  env: Bindings,
  now = Date.now(),
): Promise<void> => {
  const secret = env.STRIPE_SECRET_KEY;
  if (!secret) return;
  const stale = await env.DB.prepare(
    `SELECT uid, stripe_subscription_id FROM entitlements
     WHERE stripe_subscription_id IS NOT NULL
       AND (updated_at <= ?1 OR (status = 'active' AND valid_until IS NOT NULL AND valid_until <= ?2))
     ORDER BY updated_at ASC LIMIT ?3`,
  )
    .bind(now - staleEntitlementMs, now, entitlementBatch)
    .all<{ uid: string; stripe_subscription_id: string }>();
  const pending = await env.DB.prepare(
    `SELECT session_id FROM channel_checkout_sessions
     WHERE completed_at IS NULL AND created_at <= ?1 AND created_at > ?2
     ORDER BY created_at ASC LIMIT ?3`,
  )
    .bind(now - checkoutSettleMs, now - checkoutWindowMs, checkoutBatch)
    .all<{ session_id: string }>();
  await Promise.all([
    ...(stale.results ?? []).map((row) =>
      reconcileEntitlement(env, secret, row, now).catch(() => undefined),
    ),
    ...(pending.results ?? []).map((row) =>
      reconcileChannelCheckout(env, secret, String(row.session_id), now).catch(
        () => undefined,
      ),
    ),
  ]);
};
