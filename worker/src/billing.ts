import { Hono } from "hono";
import type { AppEnv } from "./types";

const billing = new Hono<AppEnv>();

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
      "stripe-version": "2026-02-25.clover",
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
  const parameters = new URLSearchParams({
    mode: "subscription",
    "line_items[0][price]": priceId,
    "line_items[0][quantity]": "1",
    client_reference_id: auth.uid,
    "metadata[firebase_uid]": auth.uid,
    "subscription_data[metadata][firebase_uid]": auth.uid,
    success_url: `${appUrl}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
    cancel_url: `${appUrl}/billing`,
  });
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
