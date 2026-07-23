import { stripeGet } from "./billing";
import type { Bindings } from "./types";

export type SubscriptionState = {
  uid: string;
  status: string | null;
  validUntil: number | null;
  customer: string;
  subscriptionId: string | null;
  priceId: string | null;
  eventCreated: number;
};

// Active only for the statuses Stripe considers paid-up. `past_due`,
// `unpaid`, `canceled` and `incomplete` all read as inactive, so a card that
// starts failing loses access without waiting for a separate revocation.
export const subscriptionActive = (status: unknown): boolean =>
  status === "active" || status === "trialing";

// `entitlements.stripe_customer_id` is uniquely indexed, and Stripe reuses one
// customer across two Omi accounts that share an email address. Writing the id
// unconditionally therefore threw on the second account, taking the whole
// webhook down with it, so the id is written only when no other account holds
// it: the entitlement is still granted, it simply is not addressable by that
// customer id. The paid-for access lands either way.
const unclaimedCustomer = (customer: string, uid: string) =>
  `CASE WHEN EXISTS (SELECT 1 FROM entitlements other
                     WHERE other.stripe_customer_id = ${customer} AND other.uid <> ${uid})
     THEN NULL ELSE ${customer} END`;

// Checkout completing tells us which Stripe customer an account is, and
// nothing more: the plan stays where it was until a subscription event (or
// the channel completion path) actually activates it.
export const claimStripeCustomer = (
  env: Bindings,
  uid: string,
  customer: string,
  now = Date.now(),
): D1PreparedStatement =>
  env.DB.prepare(
    `INSERT INTO entitlements (uid, plan, status, stripe_customer_id, updated_at)
     SELECT uid, 'byok', 'inactive', ${unclaimedCustomer("?1", "?3")}, ?2
     FROM users WHERE uid = ?3
     ON CONFLICT(uid) DO UPDATE SET
       stripe_customer_id = COALESCE(excluded.stripe_customer_id, entitlements.stripe_customer_id),
       updated_at = excluded.updated_at`,
  ).bind(customer, now, uid);

// The one statement that moves a paid entitlement. `stripe_event_created` is
// the monotonic guard: an event that is older than what we already applied —
// a late retry, a reconciliation racing a webhook — cannot regress newer
// state.
export const applySubscriptionState = (
  env: Bindings,
  state: SubscriptionState,
  now = Date.now(),
): D1PreparedStatement =>
  env.DB.prepare(
    `INSERT INTO entitlements
       (uid, plan, status, valid_until, stripe_customer_id, updated_at,
        stripe_subscription_id, stripe_price_id, stripe_event_created)
     SELECT uid, 'pro', ?1, ?2, ${unclaimedCustomer("?3", "?8")}, ?4, ?5, ?6, ?7
     FROM users WHERE uid = ?8
     ON CONFLICT(uid) DO UPDATE SET
       plan = 'pro', status = excluded.status, valid_until = excluded.valid_until,
       stripe_customer_id = COALESCE(excluded.stripe_customer_id, entitlements.stripe_customer_id),
       stripe_subscription_id = COALESCE(excluded.stripe_subscription_id, entitlements.stripe_subscription_id),
       stripe_price_id = COALESCE(excluded.stripe_price_id, entitlements.stripe_price_id),
       stripe_event_created = excluded.stripe_event_created,
       updated_at = excluded.updated_at
     WHERE excluded.stripe_event_created >= entitlements.stripe_event_created`,
  ).bind(
    subscriptionActive(state.status) ? "active" : "inactive",
    state.validUntil,
    state.customer,
    now,
    state.subscriptionId,
    state.priceId,
    state.eventCreated,
    state.uid,
  );

// A failed payment or a chargeback revokes access against the customer id,
// because neither event carries our uid. The monotonic guard still applies.
export const deactivateForCustomer = (
  env: Bindings,
  customer: string,
  eventCreated: number,
  now = Date.now(),
): D1PreparedStatement =>
  env.DB.prepare(
    `UPDATE entitlements
     SET status = 'inactive', stripe_event_created = ?1, updated_at = ?2
     WHERE stripe_customer_id = ?3 AND stripe_event_created <= ?1`,
  ).bind(eventCreated, now, customer);

// A dispute names a charge, not a customer, so the customer is read back from
// Stripe rather than guessed.
export const customerForDispute = async (
  env: Bindings,
  object: Record<string, unknown>,
): Promise<string | null> => {
  if (typeof object.customer === "string") return object.customer;
  const secret = env.STRIPE_SECRET_KEY;
  const charge = typeof object.charge === "string" ? object.charge : null;
  if (!secret || !charge) return null;
  const body = await stripeGet(secret, `charges/${encodeURIComponent(charge)}`);
  return typeof body?.customer === "string" ? body.customer : null;
};
