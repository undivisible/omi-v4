//! Pure channel-checkout logic ported from `worker/src/channel-checkout.ts`.
//! Stripe session creation, D1 reads/writes, and outbound chat delivery live
//! in the wasm glue in `routes_channels.rs`.

use crate::byok_pricing::format_price;

/// Stripe refuses an expiry closer than 30 minutes or further than 24 hours,
/// and an hour is long enough to tap a link and short enough that a forwarded
/// screenshot is usually already dead.
pub const CHECKOUT_TTL_MS: i64 = 60 * 60_000;

pub const CHECKOUT_PER_SENDER_LIMIT: i64 = 3;
pub const CHECKOUT_PER_SENDER_WINDOW_MS: i64 = 60 * 60_000;
pub const CHECKOUT_GLOBAL_LIMIT: i64 = 300;
pub const CHECKOUT_GLOBAL_WINDOW_MS: i64 = 60 * 60_000;

/// Outcome of issuing a checkout link from chat.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChannelCheckout {
    Issued { url: String, price_cents: i64 },
    Reused { url: String, price_cents: i64 },
    Subscribed,
    RateLimited,
    Unavailable,
    Unconfigured,
}

/// Stripe webhook / sweep payload for completing a channel checkout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CheckoutCompletion {
    pub session_id: Option<String>,
    pub uid: Option<String>,
    pub customer: Option<String>,
    pub subscription: Option<String>,
    pub paid: bool,
    pub email: Option<String>,
    pub event_created: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompleteCheckoutDecision {
    pub should_provision: bool,
    pub confirmation_text: Option<String>,
}

/// Whether the completion event carries enough to attempt provisioning.
pub fn checkout_prerequisites_met(event: &CheckoutCompletion) -> bool {
    event.session_id.is_some() && event.uid.is_some() && event.customer.is_some() && event.paid
}

/// Whether the stored session row's uid matches the event uid.
pub fn session_uid_matches(row_uid: &str, event_uid: &str) -> bool {
    row_uid == event_uid
}

/// The entitlement target after a channel account may have been claimed.
pub fn completion_target_uid(row_uid: &str, claimed_by_uid: Option<&str>) -> String {
    claimed_by_uid.unwrap_or(row_uid).to_string()
}

/// Pick the confirmation copy once payment is accepted.
pub fn subscription_confirmation_message(
    price_cents: i64,
    claimed_by_uid: Option<&str>,
    retired: bool,
) -> String {
    if claimed_by_uid.is_some() {
        subscription_claimed_text(price_cents)
    } else if retired {
        subscription_retired_text(price_cents)
    } else {
        subscription_confirmation_text(price_cents)
    }
}

/// Pure decision step before any D1 writes: prerequisites, row match, and copy.
pub fn complete_checkout_decision(
    event: &CheckoutCompletion,
    row_uid: Option<&str>,
    claimed_by_uid: Option<&str>,
    retired: bool,
    price_cents: i64,
) -> CompleteCheckoutDecision {
    if !checkout_prerequisites_met(event) {
        return CompleteCheckoutDecision {
            should_provision: false,
            confirmation_text: None,
        };
    }
    let Some(row_uid) = row_uid else {
        return CompleteCheckoutDecision {
            should_provision: false,
            confirmation_text: None,
        };
    };
    let event_uid = event.uid.as_deref().unwrap_or_default();
    if !session_uid_matches(row_uid, event_uid) {
        return CompleteCheckoutDecision {
            should_provision: false,
            confirmation_text: None,
        };
    }
    CompleteCheckoutDecision {
        should_provision: true,
        confirmation_text: Some(subscription_confirmation_message(
            price_cents,
            claimed_by_uid,
            retired,
        )),
    }
}

pub fn checkout_rate_limit_key(channel: &str, channel_user_id: &str) -> String {
    format!("channel-checkout:{channel}:{channel_user_id}")
}

pub const CHECKOUT_GLOBAL_RATE_LIMIT_KEY: &str = "channel-checkout:global";

pub fn checkout_idempotency_key(channel: &str, channel_user_id: &str, now: i64) -> String {
    format!(
        "channel-checkout:{channel}:{channel_user_id}:{}",
        now / CHECKOUT_TTL_MS
    )
}

pub fn checkout_offer_text(url: &str, price_cents: i64) -> String {
    [
        format!(
            "Omi is {} a month. Tap here to subscribe — it opens Stripe's own payment page, and you'll be set up here the moment it goes through:",
            format_price(price_cents)
        ),
        url.to_string(),
        "The link is for this chat's account only and expires in an hour. I will never ask you for card details in a message.".to_string(),
    ]
    .join("\n\n")
}

pub const CHECKOUT_UNAVAILABLE_TEXT: &str =
    "I can't start a subscription right now. Try again in a little while.";

pub const ALREADY_SUBSCRIBED_TEXT: &str =
    "You're already subscribed — nothing to pay for. Just talk to me here.";

pub fn subscription_confirmation_text(price_cents: i64) -> String {
    [
        format!(
            "Payment received — you're subscribed at {} a month. Nothing else to do: everything is switched on here.",
            format_price(price_cents)
        ),
        "Send /help to see what I understand in this chat.".to_string(),
    ]
    .join("\n\n")
}

pub fn subscription_claimed_text(price_cents: i64) -> String {
    format!(
        "Payment received — {} a month. This chat's account has since been claimed by your signed-in Omi account, so the subscription is on that one. Everything is switched on.",
        format_price(price_cents)
    )
}

pub fn subscription_retired_text(price_cents: i64) -> String {
    format!(
        "Payment received — {} a month. This chat's account was closed before the payment landed, so the subscription sits on it unused. Sign in on your phone or desktop and send /start here, or contact support and we'll sort it out.",
        format_price(price_cents)
    )
}

/// Map an issuance outcome to the chat reply, if any.
pub fn checkout_reply(checkout: &ChannelCheckout) -> Option<String> {
    match checkout {
        ChannelCheckout::Issued { url, price_cents }
        | ChannelCheckout::Reused { url, price_cents } => {
            Some(checkout_offer_text(url, *price_cents))
        }
        ChannelCheckout::Subscribed => Some(ALREADY_SUBSCRIBED_TEXT.to_string()),
        ChannelCheckout::Unavailable => Some(CHECKOUT_UNAVAILABLE_TEXT.to_string()),
        ChannelCheckout::RateLimited | ChannelCheckout::Unconfigured => None,
    }
}

pub const EXPIRE_CHANNEL_CHECKOUT_SQL: &str =
    "UPDATE channel_checkout_sessions SET expires_at = ?1 WHERE session_id = ?2 AND completed_at IS NULL";

/// Build a [`CheckoutCompletion`] from a Stripe checkout session object.
pub fn checkout_completion_from_object(
    object: &serde_json::Value,
    event_created: i64,
) -> CheckoutCompletion {
    let string = |key: &str| object.get(key).and_then(|v| v.as_str()).map(String::from);
    let payment_status = object.get("payment_status").and_then(|v| v.as_str());
    CheckoutCompletion {
        session_id: string("id"),
        uid: string("client_reference_id"),
        customer: string("customer"),
        subscription: string("subscription"),
        paid: payment_status == Some("paid") || payment_status == Some("no_payment_required"),
        email: object
            .get("customer_details")
            .and_then(|details| details.get("email"))
            .and_then(|v| v.as_str())
            .map(String::from),
        event_created,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn completion(paid: bool) -> CheckoutCompletion {
        CheckoutCompletion {
            session_id: Some("cs_1".into()),
            uid: Some("chan_abc".into()),
            customer: Some("cus_1".into()),
            subscription: Some("sub_1".into()),
            paid,
            email: Some("payer@example.test".into()),
            event_created: 1_700_000_000,
        }
    }

    #[test]
    fn checkout_ttl_is_one_hour() {
        assert_eq!(CHECKOUT_TTL_MS, 3_600_000);
    }

    #[test]
    fn offer_text_names_price_link_and_card_safety() {
        let text = checkout_offer_text("https://checkout.stripe.com/x", 1_200);
        assert!(text.contains("$12.00"));
        assert!(text.contains("https://checkout.stripe.com/x"));
        assert!(text.contains("never ask you for card details"));
    }

    #[test]
    fn prerequisites_require_paid_session_uid_and_customer() {
        assert!(checkout_prerequisites_met(&completion(true)));
        assert!(!checkout_prerequisites_met(&CheckoutCompletion {
            session_id: None,
            ..completion(true)
        }));
        assert!(!checkout_prerequisites_met(&CheckoutCompletion {
            uid: None,
            ..completion(true)
        }));
        assert!(!checkout_prerequisites_met(&CheckoutCompletion {
            customer: None,
            ..completion(true)
        }));
        assert!(!checkout_prerequisites_met(&completion(false)));
    }

    #[test]
    fn completion_copy_follows_claim_and_retire_state() {
        assert!(subscription_confirmation_message(1_200, None, false).contains("you're subscribed"));
        assert!(
            subscription_confirmation_message(1_200, Some("real"), false)
                .contains("signed-in Omi account")
        );
        assert!(subscription_confirmation_message(1_200, None, true).contains("was closed"));
    }

    #[test]
    fn complete_checkout_decision_refuses_uid_mismatch() {
        let decision =
            complete_checkout_decision(&completion(true), Some("chan_abc"), None, false, 1_200);
        assert!(decision.should_provision);
        let mismatch = complete_checkout_decision(
            &CheckoutCompletion {
                uid: Some("chan_b".into()),
                ..completion(true)
            },
            Some("chan_abc"),
            None,
            false,
            1_200,
        );
        assert!(!mismatch.should_provision);
    }

    #[test]
    fn checkout_reply_maps_status_to_copy() {
        assert_eq!(
            checkout_reply(&ChannelCheckout::Subscribed),
            Some(ALREADY_SUBSCRIBED_TEXT.to_string())
        );
        assert_eq!(
            checkout_reply(&ChannelCheckout::Unavailable),
            Some(CHECKOUT_UNAVAILABLE_TEXT.to_string())
        );
        assert_eq!(checkout_reply(&ChannelCheckout::RateLimited), None);
        assert!(checkout_reply(&ChannelCheckout::Issued {
            url: "https://pay".into(),
            price_cents: 800,
        })
        .unwrap()
        .contains("$8.00"));
    }

    #[test]
    fn idempotency_key_buckets_by_ttl_window() {
        let key_a = checkout_idempotency_key("telegram", "42", 0);
        let key_b = checkout_idempotency_key("telegram", "42", CHECKOUT_TTL_MS - 1);
        let key_c = checkout_idempotency_key("telegram", "42", CHECKOUT_TTL_MS);
        assert_eq!(key_a, key_b);
        assert_ne!(key_a, key_c);
        assert!(key_a.contains("channel-checkout:telegram:42"));
    }
}
