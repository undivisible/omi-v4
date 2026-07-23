import { Hono } from "hono";
import { byokPriceCents } from "./entitlement";
import type { AppEnv, Bindings } from "./types";

const billing = new Hono<AppEnv>();

const stripeVersion = "2026-02-25.clover";

// Stripe's own failure reason, logged and never returned to the caller: the
// client gets a bare 502, and the secret never appears in either.
const logStripeFailure = (path: string, status: number, body: unknown) => {
  const error =
    body !== null && typeof body === "object"
      ? ((body as { error?: { code?: unknown; message?: unknown } }).error ??
        null)
      : null;
  console.error("Stripe request failed", {
    path,
    status,
    code: typeof error?.code === "string" ? error.code : null,
    message: typeof error?.message === "string" ? error.message : null,
  });
};

// A retried POST must not create a second Checkout Session or a second
// customer, so every mutating call carries a key derived from the logical
// operation rather than from the attempt.
const stripePost = async (
  secret: string,
  path: string,
  parameters: URLSearchParams,
  idempotencyKey?: string,
): Promise<Record<string, unknown> | null> => {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${secret}`,
      "content-type": "application/x-www-form-urlencoded",
      "stripe-version": stripeVersion,
      ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
    },
    body: parameters,
  });
  const body = (await response.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (!response.ok || !body) {
    logStripeFailure(path, response.status, body);
    return null;
  }
  return body;
};

export const stripeGet = async (
  secret: string,
  path: string,
): Promise<Record<string, unknown> | null> => {
  const response = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: {
      authorization: `Bearer ${secret}`,
      "stripe-version": stripeVersion,
    },
  });
  const body = (await response.json().catch(() => null)) as Record<
    string,
    unknown
  > | null;
  if (!response.ok || !body) {
    logStripeFailure(path, response.status, body);
    return null;
  }
  return body;
};

const stripeRequest = async (
  secret: string,
  path: string,
  parameters: URLSearchParams,
  idempotencyKey?: string,
) => {
  const body = await stripePost(secret, path, parameters, idempotencyKey);
  if (!body || typeof body.id !== "string" || typeof body.url !== "string")
    return null;
  return { id: body.id, url: body.url };
};

// A returning payer whose customer id we never stored would otherwise get a
// second Stripe customer and a split billing history, so an existing one is
// looked up by email before Checkout is allowed to create another.
const stripeCustomerByEmail = async (
  secret: string,
  email: string,
): Promise<string | null> => {
  const body = await stripeGet(
    secret,
    `customers?limit=1&email=${encodeURIComponent(email)}`,
  );
  const data = body?.data;
  if (!Array.isArray(data) || data.length === 0) return null;
  const id = (data[0] as { id?: unknown }).id;
  return typeof id === "string" ? id : null;
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

export type CheckoutRequest = {
  uid: string;
  email?: string | null;
  successUrl: string;
  cancelUrl: string;
  // Epoch milliseconds. Stripe expires the hosted page itself, so a link that
  // leaks out of a chat stops working on its own.
  expiresAt?: number;
  metadata?: Record<string, string>;
  idempotencyKey?: string;
};

export type CheckoutResult =
  | { ok: true; id: string; url: string; priceCents: number }
  | { ok: false; reason: "unconfigured" | "provider" };

// The single place a subscription checkout is built, for the web app and for
// the messaging channels alike. The amount is always read server-side from the
// stored negotiation record: no caller passes a price in.
export const createCheckoutSession = async (
  env: Bindings,
  request: CheckoutRequest,
): Promise<CheckoutResult> => {
  const secret = env.STRIPE_SECRET_KEY;
  const priceId = env.STRIPE_PRO_PRICE_ID;
  if (!secret || !priceId) return { ok: false, reason: "unconfigured" };
  const entitlement = await env.DB.prepare(
    "SELECT stripe_customer_id FROM entitlements WHERE uid = ?1",
  )
    .bind(request.uid)
    .first();
  // What the user agreed to is what Stripe must bill. The figure comes from
  // the stored negotiation record via `byokPriceCents`, which re-clamps into
  // the band in force today; the client never supplies it.
  const agreed = await byokPriceCents(env, request.uid);
  const parameters = new URLSearchParams({
    mode: "subscription",
    "line_items[0][quantity]": "1",
    client_reference_id: request.uid,
    "metadata[firebase_uid]": request.uid,
    "subscription_data[metadata][firebase_uid]": request.uid,
    success_url: request.successUrl,
    cancel_url: request.cancelUrl,
  });
  for (const [key, value] of Object.entries(request.metadata ?? {}))
    parameters.set(`metadata[${key}]`, value);
  if (typeof request.expiresAt === "number")
    parameters.set("expires_at", String(Math.floor(request.expiresAt / 1_000)));
  if (agreed.negotiated) {
    const price = await stripePrice(secret, priceId);
    if (!price) return { ok: false, reason: "provider" };
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
  // Tax has to be computed for EU customers, and Stripe only allows it on a
  // subscription when it is also allowed to save the address it computed from.
  parameters.set("automatic_tax[enabled]", "true");
  const customerId =
    typeof entitlement?.stripe_customer_id === "string"
      ? entitlement.stripe_customer_id
      : request.email
        ? await stripeCustomerByEmail(secret, request.email)
        : null;
  if (customerId) {
    parameters.set("customer", customerId);
    parameters.set("customer_update[address]", "auto");
    parameters.set("customer_update[name]", "auto");
  } else if (request.email) {
    parameters.set("customer_email", request.email);
  }
  // With neither a customer nor an email — every account created from a chat —
  // Checkout collects the email itself, which is what makes Stripe's receipt
  // and the billing portal reachable later. It is never asked for in the chat.
  const session = await stripeRequest(
    secret,
    "checkout/sessions",
    parameters,
    request.idempotencyKey,
  );
  return session
    ? {
        ok: true,
        id: session.id,
        url: session.url,
        priceCents: agreed.priceCents,
      }
    : { ok: false, reason: "provider" };
};

billing.post("/checkout", async (context) => {
  const appUrl = context.env.APP_URL;
  if (!appUrl) return context.json({ error: "Billing unavailable" }, 503);
  const auth = context.get("auth");
  const session = await createCheckoutSession(context.env, {
    uid: auth.uid,
    email: auth.email,
    successUrl: `${appUrl}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
    cancelUrl: `${appUrl}/billing`,
    idempotencyKey: `checkout:${auth.uid}:${Math.floor(Date.now() / 60_000)}`,
  });
  if (!session.ok)
    return session.reason === "unconfigured"
      ? context.json({ error: "Billing unavailable" }, 503)
      : context.json({ error: "Billing provider unavailable" }, 502);
  return context.json({ id: session.id, url: session.url }, 201);
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
