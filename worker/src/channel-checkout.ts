import { createCheckoutSession } from "./billing";
import { formatPrice } from "./byok-pricing";
import { sendChannelText } from "./delivery";
import { hasActivePro } from "./entitlement";
import { consumeRateLimit } from "./rate-limit";
import { applySubscriptionState } from "./stripe-entitlement";
import type { Bindings, Channel } from "./types";

// Stripe refuses an expiry closer than 30 minutes or further than 24 hours,
// and an hour is long enough to tap a link and short enough that a forwarded
// screenshot is usually already dead.
export const checkoutTtlMs = 60 * 60_000;

export type ChannelCheckout =
  | { status: "issued" | "reused"; url: string; priceCents: number }
  | { status: "subscribed" | "rate-limited" | "unavailable" | "unconfigured" };

// Issuing a checkout link is reachable from an unauthenticated inbound
// message, so it is capped per sender and across the worker, exactly like
// signup itself.
const checkoutAllowed = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
): Promise<boolean> => {
  const perSender = await consumeRateLimit(
    env,
    `channel-checkout:${channel}:${channelUserId}`,
    3,
    60 * 60_000,
  );
  if (!perSender.allowed) return false;
  const global = await consumeRateLimit(
    env,
    "channel-checkout:global",
    300,
    60 * 60_000,
  );
  return global.allowed;
};

// The link handed to a chat is the Stripe-hosted URL and nothing else: it is
// unguessable, Stripe expires it, and the account it will bill was fixed
// server-side when the session was created. Forwarding it to someone else
// therefore pays for *this* account, never theirs.
export const issueChannelCheckout = async (
  env: Bindings,
  uid: string,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now = Date.now(),
): Promise<ChannelCheckout> => {
  // A deployment with billing switched off says nothing about money at all,
  // rather than apologising for a subscription it was never going to sell.
  if (!env.APP_URL || !env.STRIPE_SECRET_KEY || !env.STRIPE_PRO_PRICE_ID)
    return { status: "unconfigured" };
  if (await hasActivePro(env, uid)) return { status: "subscribed" };
  // A second tap must not create a second subscription: an outstanding link
  // for this account is quoted back rather than replaced.
  const live = await env.DB.prepare(
    `SELECT url, price_cents FROM channel_checkout_sessions
     WHERE uid = ?1 AND completed_at IS NULL AND expires_at > ?2
     ORDER BY created_at DESC LIMIT 1`,
  )
    .bind(uid, now)
    .first<{ url: string; price_cents: number }>();
  if (live)
    return {
      status: "reused",
      url: String(live.url),
      priceCents: Number(live.price_cents),
    };
  if (!(await checkoutAllowed(env, channel, channelUserId)))
    return { status: "rate-limited" };
  const expiresAt = now + checkoutTtlMs;
  const session = await createCheckoutSession(env, {
    uid,
    successUrl: `${env.APP_URL}/billing/success?session_id={CHECKOUT_SESSION_ID}`,
    cancelUrl: `${env.APP_URL}/billing`,
    expiresAt,
    idempotencyKey: `channel-checkout:${channel}:${channelUserId}:${Math.floor(
      now / checkoutTtlMs,
    )}`,
    metadata: {
      channel,
      channel_user_id: channelUserId,
      channel_chat_id: channelChatId,
    },
  });
  if (!session.ok)
    return {
      status:
        session.reason === "unconfigured" ? "unconfigured" : "unavailable",
    };
  await env.DB.prepare(
    `INSERT INTO channel_checkout_sessions
       (session_id, uid, channel, channel_user_id, channel_chat_id,
        price_cents, url, created_at, expires_at)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
     ON CONFLICT DO NOTHING`,
  )
    .bind(
      session.id,
      uid,
      channel,
      channelUserId,
      channelChatId,
      session.priceCents,
      session.url,
      now,
      expiresAt,
    )
    .run();
  return { status: "issued", url: session.url, priceCents: session.priceCents };
};

// An abandoned session frees the account to be offered a fresh link.
export const expireChannelCheckout = async (
  env: Bindings,
  sessionId: string,
  now = Date.now(),
): Promise<void> => {
  await env.DB.prepare(
    `UPDATE channel_checkout_sessions SET expires_at = ?1
     WHERE session_id = ?2 AND completed_at IS NULL`,
  )
    .bind(now, sessionId)
    .run();
};

export const checkoutOfferText = (url: string, priceCents: number): string =>
  [
    `Omi is ${formatPrice(priceCents)} a month. Tap here to subscribe — it ` +
      "opens Stripe's own payment page, and you'll be set up here the moment " +
      "it goes through:",
    url,
    "The link is for this chat's account only and expires in an hour. I will " +
      "never ask you for card details in a message.",
  ].join("\n\n");

export const checkoutUnavailableText =
  "I can't start a subscription right now. Try again in a little while.";

export const alreadySubscribedText =
  "You're already subscribed — nothing to pay for. Just talk to me here.";

export const subscriptionConfirmationText = (priceCents: number): string =>
  [
    `Payment received — you're subscribed at ${formatPrice(priceCents)} a ` +
      "month. Nothing else to do: everything is switched on here.",
    "Send /help to see what I understand in this chat.",
  ].join("\n\n");

export const subscriptionClaimedText = (priceCents: number): string =>
  `Payment received — ${formatPrice(priceCents)} a month. This chat's account ` +
  "has since been claimed by your signed-in Omi account, so the subscription " +
  "is on that one. Everything is switched on.";

export const subscriptionRetiredText = (priceCents: number): string =>
  `Payment received — ${formatPrice(priceCents)} a month. This chat's account ` +
  "was closed before the payment landed, so the subscription sits on it " +
  "unused. Sign in on your phone or desktop and send /start here, or contact " +
  "support and we'll sort it out.";

export type CheckoutCompletion = {
  sessionId: string | null;
  uid: string | null;
  customer: string | null;
  subscription: string | null;
  paid: boolean;
  // The address Stripe collected on its own hosted page, so a chat-created
  // account has somewhere for a receipt to go. It is never asked for in chat.
  email: string | null;
  eventCreated: number;
};

// Called from the Stripe webhook after signature verification. The account to
// provision comes from the stored session row, not from anything in the event
// body beyond the session id — and the row's uid must match the uid Stripe
// echoes back, so a doctored payload cannot redirect an entitlement.
export const completeChannelCheckout = async (
  env: Bindings,
  event: CheckoutCompletion,
  now = Date.now(),
): Promise<{ provisioned: boolean; uid: string | null }> => {
  if (!event.sessionId || !event.uid || !event.customer || !event.paid)
    return { provisioned: false, uid: null };
  const row = await env.DB.prepare(
    `SELECT uid, channel, channel_chat_id, price_cents
     FROM channel_checkout_sessions
     WHERE session_id = ?1 AND completed_at IS NULL`,
  )
    .bind(event.sessionId)
    .first<{
      uid: string;
      channel: Channel;
      channel_chat_id: string;
      price_cents: number;
    }>();
  if (!row || String(row.uid) !== event.uid)
    return { provisioned: false, uid: null };
  const account = await env.DB.prepare(
    "SELECT claimed_by_uid, retired_at FROM channel_accounts WHERE uid = ?1",
  )
    .bind(row.uid)
    .first<{ claimed_by_uid: string | null; retired_at: number | null }>();
  // A sign-in that claimed this placeholder owns it now, so the entitlement
  // follows the claim rather than stranding a paid subscription on a uid
  // nobody can reach.
  const claimedBy =
    typeof account?.claimed_by_uid === "string" ? account.claimed_by_uid : null;
  const target = claimedBy ?? String(row.uid);
  const results = await env.DB.batch([
    env.DB.prepare(
      `UPDATE channel_checkout_sessions SET completed_at = ?1
       WHERE session_id = ?2 AND completed_at IS NULL`,
    ).bind(now, event.sessionId),
    // The same statement every other subscription goes through, monotonic
    // guard included. `valid_until` stays null until a subscription event
    // carries a real period end.
    applySubscriptionState(
      env,
      {
        uid: target,
        status: "active",
        validUntil: null,
        customer: event.customer,
        subscriptionId: event.subscription,
        priceId: null,
        eventCreated: event.eventCreated,
      },
      now,
    ),
    env.DB.prepare(
      "UPDATE channel_accounts SET billing_email = ?1 WHERE uid = ?2 AND billing_email IS NULL",
    ).bind(event.email, String(row.uid)),
    env.DB.prepare(
      `INSERT INTO audit_events
         (id, uid, actor_type, action, target_type, target_id, details, created_at)
       VALUES (?1, ?2, 'system', 'channel.subscription_activated', 'channel', ?3, ?4, ?5)`,
    ).bind(
      crypto.randomUUID(),
      target,
      row.channel,
      JSON.stringify({
        sessionId: event.sessionId,
        placeholderUid: String(row.uid),
        priceCents: Number(row.price_cents),
      }),
      now,
    ),
  ]);
  // The single-row claim on `completed_at` is what makes a replayed webhook
  // silent: the entitlement write is idempotent anyway, the confirmation
  // message is not.
  if (results[0].meta.changes !== 1) return { provisioned: false, uid: null };
  const priceCents = Number(row.price_cents);
  const text = claimedBy
    ? subscriptionClaimedText(priceCents)
    : account?.retired_at
      ? subscriptionRetiredText(priceCents)
      : subscriptionConfirmationText(priceCents);
  await sendChannelText(env, row.channel, String(row.channel_chat_id), text);
  return { provisioned: true, uid: target };
};
