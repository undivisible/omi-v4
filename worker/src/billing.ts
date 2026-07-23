import { Hono } from "hono";
import { byokPriceCents } from "./entitlement";
import type { AppEnv } from "./types";

const billing = new Hono<AppEnv>();

const stripeVersion = "2026-02-25.clover";

const stripeRequest = async (
  secret: string,
  path: string,
  parameters: URLSearchParams,
) => {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${secret}`,
      "content-type": "application/x-www-form-urlencoded",
      "stripe-version": stripeVersion,
    },
    body: parameters,
  });
  const body = (await response.json()) as {
    error?: unknown;
    id?: unknown;
    url?: unknown;
  };
  if (
    !response.ok ||
    typeof body.id !== "string" ||
    typeof body.url !== "string"
  )
    return null;
  return { id: body.id, url: body.url };
};

// The shape of the configured recurring price, read back from Stripe so a
// negotiated charge can be rebuilt as an inline `price_data` line item that
// keeps the product, currency, and billing interval of the standard price and
// changes only the amount.
const stripePrice = async (secret: string, priceId: string) => {
  const response = await fetch(
    `https://api.stripe.com/v1/prices/${encodeURIComponent(priceId)}`,
    {
      headers: {
        authorization: `Bearer ${secret}`,
        "stripe-version": stripeVersion,
      },
    },
  );
  const body = (await response.json()) as {
    currency?: unknown;
    product?: unknown;
    unit_amount?: unknown;
    recurring?: { interval?: unknown; interval_count?: unknown } | null;
  };
  if (!response.ok) return null;
  const interval = body.recurring?.interval;
  if (
    typeof body.currency !== "string" ||
    typeof body.product !== "string" ||
    typeof interval !== "string"
  )
    return null;
  const intervalCount = Number(body.recurring?.interval_count ?? 1);
  return {
    currency: body.currency,
    product: body.product,
    interval,
    intervalCount:
      Number.isSafeInteger(intervalCount) && intervalCount > 0
        ? intervalCount
        : 1,
    unitAmount: typeof body.unit_amount === "number" ? body.unit_amount : null,
  };
};

billing.post("/checkout", async (context) => {
  const secret = context.env.STRIPE_SECRET_KEY;
  const priceId = context.env.STRIPE_PRO_PRICE_ID;
  const appUrl = context.env.APP_URL;
  if (!secret || !priceId || !appUrl)
    return context.json({ error: "Billing unavailable" }, 503);
  const auth = context.get("auth");
  const entitlement = await context.env.DB.prepare(
    "SELECT stripe_customer_id FROM entitlements WHERE uid = ?1",
  )
    .bind(auth.uid)
    .first();
  // What the user agreed to is what Stripe must bill. The figure comes from
  // the stored negotiation record via `byokPriceCents`, which re-clamps into
  // the band in force today; the client never supplies it.
  const agreed = await byokPriceCents(context.env, auth.uid);
  const parameters = new URLSearchParams({
    mode: "subscription",
    "line_items[0][quantity]": "1",
    client_reference_id: auth.uid,
    "metadata[firebase_uid]": auth.uid,
    "subscription_data[metadata][firebase_uid]": auth.uid,
    success_url: `${appUrl}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${appUrl}/billing`,
  });
  if (agreed.negotiated) {
    const price = await stripePrice(secret, priceId);
    if (!price)
      return context.json({ error: "Billing provider unavailable" }, 502);
    if (price.unitAmount === agreed.priceCents) {
      parameters.set("line_items[0][price]", priceId);
    } else {
      parameters.set("line_items[0][price_data][currency]", price.currency);
      parameters.set("line_items[0][price_data][product]", price.product);
      parameters.set(
        "line_items[0][price_data][unit_amount]",
        String(agreed.priceCents),
      );
      parameters.set(
        "line_items[0][price_data][recurring][interval]",
        price.interval,
      );
      parameters.set(
        "line_items[0][price_data][recurring][interval_count]",
        String(price.intervalCount),
      );
    }
  } else {
    parameters.set("line_items[0][price]", priceId);
  }
  if (typeof entitlement?.stripe_customer_id === "string")
    parameters.set("customer", entitlement.stripe_customer_id);
  else if (auth.email) parameters.set("customer_email", auth.email);
  const session = await stripeRequest(secret, "checkout/sessions", parameters);
  return session
    ? context.json(session, 201)
    : context.json({ error: "Billing provider unavailable" }, 502);
});

billing.post("/portal", async (context) => {
  const secret = context.env.STRIPE_SECRET_KEY;
  const appUrl = context.env.APP_URL;
  if (!secret || !appUrl)
    return context.json({ error: "Billing unavailable" }, 503);
  const entitlement = await context.env.DB.prepare(
    "SELECT stripe_customer_id FROM entitlements WHERE uid = ?1",
  )
    .bind(context.get("auth").uid)
    .first();
  if (typeof entitlement?.stripe_customer_id !== "string")
    return context.json({ error: "Billing account not found" }, 404);
  const session = await stripeRequest(
    secret,
    "billing_portal/sessions",
    new URLSearchParams({
      customer: entitlement.stripe_customer_id,
      return_url: `${appUrl}/billing`,
    }),
  );
  return session
    ? context.json(session, 201)
    : context.json({ error: "Billing provider unavailable" }, 502);
});

export default billing;
