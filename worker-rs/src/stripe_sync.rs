//! Stripe reconciliation sweep — parity port of `worker/src/stripe-sync.ts`.
//!
//! Stripe webhooks are the primary path by which a payment becomes an
//! entitlement. A webhook that never arrives would otherwise leave a paying
//! customer with nothing, silently and permanently: no later event repairs it,
//! because the event that would have repaired it is the one that was lost.
//! This sweep is that safety net. It re-reads a bounded handful of the oldest
//! and soonest-expiring subscription rows from the Stripe API each tick and
//! writes the answer through the same entitlement statement the webhook uses.
//!
//! The module follows the crate's pure/glue split: every decision — which rows
//! are worth re-reading, what a Stripe response means, and which of those
//! meanings is allowed to move an entitlement — lives in host-testable
//! functions here. The wasm glue below is only D1 and `fetch`.
//!
//! Two properties are load-bearing and are the reason for the shapes chosen:
//!
//! * **Silence is never a downgrade.** Every path where Stripe fails to give a
//!   usable answer — network error, non-2xx, unparseable body, a body missing
//!   the fields that identify a subscription — resolves to
//!   [`ReconcileOutcome::LeaveUntouched`], which issues no statement at all.
//!   Only a well-formed subscription payload can move a row, and then only to
//!   the state Stripe itself reports. A reconciliation failure therefore cannot
//!   revoke access that was paid for.
//! * **Reconciliation cannot overwrite fresher truth.** The write carries
//!   `stripe_event_created = floor(now / 1000)` through the same monotonic
//!   guard the webhook handler uses, so it wins over anything already applied
//!   but is itself overtaken by any later real event.

use serde_json::Value;

use crate::webhooks::StripeSubscription;

// ---------------------------------------------------------------------------
// Sweep bounds
// ---------------------------------------------------------------------------

/// How stale an entitlement has to look before the cron re-reads it from
/// Stripe, and how many are re-read per tick. Both keep the sweep bounded:
/// this is a safety net for lost webhooks, not a polling loop over every
/// customer.
pub const STALE_ENTITLEMENT_MS: i64 = 6 * 60 * 60_000;
pub const ENTITLEMENT_BATCH: i64 = 10;

/// Stripe API version pinned for the reconciliation reads. Matches the version
/// the billing glue sends, so a field that changes shape between versions
/// cannot mean one thing on the checkout path and another here.
pub const STRIPE_VERSION: &str = "2026-02-25.clover";

// ---------------------------------------------------------------------------
// Row selection
// ---------------------------------------------------------------------------

/// The `entitlements` columns the sweep reads back for each candidate row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StaleEntitlementRow {
    pub uid: String,
    pub stripe_subscription_id: String,
}

/// The candidate-selection query. Ordering is oldest-`updated_at`-first so the
/// sweep is a fair rotation rather than a set of rows it can starve: a row it
/// touches moves to the back of the queue by virtue of its new `updated_at`.
/// Backed by the partial `entitlements_reconcile` index from migration 0028.
///
/// Binds: `?1` = `now - STALE_ENTITLEMENT_MS`, `?2` = `now`,
/// `?3` = `ENTITLEMENT_BATCH` (see [`stale_entitlements_binds`]).
pub const STALE_ENTITLEMENTS_SQL: &str = "SELECT uid, stripe_subscription_id FROM entitlements\n     WHERE stripe_subscription_id IS NOT NULL\n       AND (updated_at <= ?1 OR (status = 'active' AND valid_until IS NOT NULL AND valid_until <= ?2))\n     ORDER BY updated_at ASC LIMIT ?3";

/// The three bind values for [`STALE_ENTITLEMENTS_SQL`], in order.
pub fn stale_entitlements_binds(now_ms: i64) -> [i64; 3] {
    [now_ms - STALE_ENTITLEMENT_MS, now_ms, ENTITLEMENT_BATCH]
}

/// An `entitlements` row as the selection predicate sees it.
#[derive(Debug, Clone, Default)]
pub struct EntitlementSweepRow {
    pub stripe_subscription_id: Option<String>,
    pub status: Option<String>,
    /// Unix milliseconds; `None` means "no expiry".
    pub valid_until: Option<i64>,
    /// Unix milliseconds.
    pub updated_at: i64,
}

/// Whether a row is a reconciliation candidate at all — the executable
/// statement of the [`STALE_ENTITLEMENTS_SQL`] `WHERE` clause.
///
/// D1 does the filtering in production; this exists so the intent behind that
/// clause is pinned by tests rather than by reading SQL. Two disjoint reasons
/// qualify a row: it has not been confirmed in a long time, or it claims to be
/// active while its paid-through instant has already passed — the shape a
/// renewal whose `invoice.paid` webhook was lost leaves behind. A row with no
/// Stripe subscription is not reconcilable at all: there is nothing to read.
pub fn should_reconcile(row: &EntitlementSweepRow, now_ms: i64) -> bool {
    if row.stripe_subscription_id.is_none() {
        return false;
    }
    let unconfirmed = row.updated_at <= now_ms - STALE_ENTITLEMENT_MS;
    let lapsed = row.status.as_deref() == Some("active")
        && matches!(row.valid_until, Some(valid_until) if valid_until <= now_ms);
    unconfirmed || lapsed
}

/// Read a `StaleEntitlementRow` out of a D1 result row, dropping any row whose
/// two required columns are not both strings.
pub fn stale_row(row: &Value) -> Option<StaleEntitlementRow> {
    Some(StaleEntitlementRow {
        uid: row.get("uid")?.as_str()?.to_string(),
        stripe_subscription_id: row.get("stripe_subscription_id")?.as_str()?.to_string(),
    })
}

// ---------------------------------------------------------------------------
// Subscription payload reading
// ---------------------------------------------------------------------------

/// `current_period_end` in unix milliseconds, mirroring the TS `periodEnd`:
/// a `Number.isSafeInteger` unix-seconds value scaled to milliseconds, and
/// `None` for anything else.
pub fn period_end_ms(subscription: &Value) -> Option<i64> {
    let value = subscription.get("current_period_end")?.as_f64()?;
    if value.fract() != 0.0 || value.abs() > 9_007_199_254_740_991.0 {
        return None;
    }
    Some((value as i64) * 1_000)
}

/// The first line item's price id, mirroring the TS `priceOf`.
pub fn price_of(subscription: &Value) -> Option<String> {
    subscription
        .get("items")?
        .get("data")?
        .as_array()?
        .first()?
        .get("price")?
        .get("id")?
        .as_str()
        .map(String::from)
}

/// Active only for the statuses Stripe considers paid-up. `past_due`,
/// `unpaid`, `canceled` and `incomplete` all read as inactive, so a card that
/// starts failing loses access without waiting for a separate revocation.
/// Identical to the classification `webhooks::parse_stripe` applies to a
/// `customer.subscription.*` event, so the two paths cannot disagree about what
/// "paid up" means.
pub fn subscription_active(status: Option<&str>) -> bool {
    status == Some("active") || status == Some("trialing")
}

/// Why a candidate row was left exactly as it was found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkipReason {
    /// Stripe gave no usable answer: a transport error, a non-2xx status, or a
    /// body that did not parse. The TS `stripeGet` collapses all three to
    /// `null` and returns without writing; so does this.
    NoAnswer,
    /// The body parsed but carries no string `customer`, so it is not a
    /// subscription object — an error envelope returned with a 200, most
    /// likely. Writing from it would invent state out of a non-answer.
    MissingCustomer,
    /// The body carries a customer but no string `status`. The TS would treat
    /// the absent status as "not active" and write `inactive`; this port
    /// refuses to move the row instead. A malformed payload must not be able
    /// to revoke access, and no correct Stripe subscription omits `status`.
    MissingStatus,
}

/// What the sweep should do with one candidate row, given whatever Stripe
/// returned for it.
#[derive(Debug, PartialEq)]
pub enum ReconcileOutcome {
    /// Issue no statement. The row keeps whatever state it already had.
    LeaveUntouched(SkipReason),
    /// Write this state through [`APPLY_SUBSCRIPTION_STATE_SQL`].
    Apply(StripeSubscription),
}

/// Decide what a Stripe `GET /subscriptions/{id}` response means for a
/// candidate row. `subscription` is `None` when the read failed in any way.
///
/// The result is a [`StripeSubscription`] — the very type
/// `webhooks::parse_stripe` produces for a `customer.subscription.*` event —
/// so reconciliation feeds the existing entitlement transition rather than a
/// second, parallel notion of subscription state.
///
/// The subscription id written is the one already on the row, not one read
/// back from the payload: the row is what we are reconciling, and a payload
/// that named a different subscription would be answering a question we did
/// not ask.
///
/// `event_created` is `floor(now / 1000)` because reconciliation speaks for
/// "now": it therefore wins over anything already applied, and is itself
/// overtaken by any later real event.
pub fn reconcile_outcome(
    row: &StaleEntitlementRow,
    subscription: Option<&Value>,
    now_ms: i64,
) -> ReconcileOutcome {
    let Some(subscription) = subscription else {
        return ReconcileOutcome::LeaveUntouched(SkipReason::NoAnswer);
    };
    let Some(customer) = subscription.get("customer").and_then(Value::as_str) else {
        return ReconcileOutcome::LeaveUntouched(SkipReason::MissingCustomer);
    };
    let Some(status) = subscription.get("status").and_then(Value::as_str) else {
        return ReconcileOutcome::LeaveUntouched(SkipReason::MissingStatus);
    };
    ReconcileOutcome::Apply(StripeSubscription {
        uid: row.uid.clone(),
        customer: customer.to_string(),
        subscription: Some(row.stripe_subscription_id.clone()),
        active: subscription_active(Some(status)),
        valid_until: period_end_ms(subscription),
        price_id: price_of(subscription),
        event_created: now_ms.div_euclid(1_000),
    })
}

// ---------------------------------------------------------------------------
// The entitlement transition
// ---------------------------------------------------------------------------

/// The one statement that moves a paid entitlement, shared with the Stripe
/// webhook handler. `stripe_event_created` is the monotonic guard: an event
/// older than what we already applied — a late webhook retry, or this sweep
/// racing a webhook — cannot regress newer state.
///
/// `stripe_customer_id` is written only when no other account already holds it.
/// The column is uniquely indexed and Stripe reuses one customer across two Omi
/// accounts that share an email address, so writing it unconditionally throws
/// on the second account. In a sweep that would mean the customer whose webhook
/// was lost is also the customer this job can never repair — the exact failure
/// it exists to prevent. The entitlement is granted either way; it simply is
/// not addressable by that customer id.
///
/// Binds, in order: `?1` status, `?2` valid_until, `?3` customer, `?4` now,
/// `?5` subscription id, `?6` price id, `?7` event_created, `?8` uid.
pub const APPLY_SUBSCRIPTION_STATE_SQL: &str = "INSERT INTO entitlements\n       (uid, plan, status, valid_until, stripe_customer_id, updated_at,\n        stripe_subscription_id, stripe_price_id, stripe_event_created)\n     SELECT uid, 'pro', ?1, ?2,\n       CASE WHEN EXISTS (SELECT 1 FROM entitlements other\n                         WHERE other.stripe_customer_id = ?3 AND other.uid <> ?8)\n         THEN NULL ELSE ?3 END,\n       ?4, ?5, ?6, ?7\n     FROM users WHERE uid = ?8\n     ON CONFLICT(uid) DO UPDATE SET\n       plan = 'pro', status = excluded.status, valid_until = excluded.valid_until,\n       stripe_customer_id = COALESCE(excluded.stripe_customer_id, entitlements.stripe_customer_id),\n       stripe_subscription_id = COALESCE(excluded.stripe_subscription_id, entitlements.stripe_subscription_id),\n       stripe_price_id = COALESCE(excluded.stripe_price_id, entitlements.stripe_price_id),\n       stripe_event_created = excluded.stripe_event_created,\n       updated_at = excluded.updated_at\n     WHERE excluded.stripe_event_created >= entitlements.stripe_event_created";

/// Records which Stripe customer an account is, and nothing more: the plan
/// stays where it was until a subscription event actually activates it.
///
/// Carries the same unclaimed-customer guard as
/// [`APPLY_SUBSCRIPTION_STATE_SQL`], and for the same reason — the checkout
/// webhook is in fact the *first* place a shared customer id arrives, so
/// writing it unconditionally here throws before the subscription event is
/// ever seen.
///
/// Binds, in order: `?1` customer, `?2` now, `?3` uid.
pub const CLAIM_STRIPE_CUSTOMER_SQL: &str = "INSERT INTO entitlements (uid, plan, status, stripe_customer_id, updated_at)\n     SELECT uid, 'byok', 'inactive',\n       CASE WHEN EXISTS (SELECT 1 FROM entitlements other\n                         WHERE other.stripe_customer_id = ?1 AND other.uid <> ?3)\n         THEN NULL ELSE ?1 END,\n       ?2\n     FROM users WHERE uid = ?3\n     ON CONFLICT(uid) DO UPDATE SET\n       stripe_customer_id = COALESCE(excluded.stripe_customer_id, entitlements.stripe_customer_id),\n       updated_at = excluded.updated_at";

pub const DEACTIVATE_FOR_CUSTOMER_SQL: &str = "UPDATE entitlements\n     SET status = 'inactive', stripe_event_created = ?1, updated_at = ?2\n     WHERE stripe_customer_id = ?3 AND stripe_event_created <= ?1";

/// The `status` literal bound as `?1`: the column is constrained to
/// `('active', 'inactive')`.
pub fn status_literal(active: bool) -> &'static str {
    if active {
        "active"
    } else {
        "inactive"
    }
}

// ---------------------------------------------------------------------------
// Path encoding
// ---------------------------------------------------------------------------

/// `encodeURIComponent` for a single URL path segment. A subscription id is
/// opaque to us, so it is escaped rather than interpolated: a value containing
/// `/` or `?` must not be able to reach a different Stripe endpoint.
pub fn encode_path_segment(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z'
            | b'a'..=b'z'
            | b'0'..=b'9'
            | b'-'
            | b'_'
            | b'.'
            | b'!'
            | b'~'
            | b'*'
            | b'\''
            | b'('
            | b')' => out.push(byte as char),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Channel checkout half
// ---------------------------------------------------------------------------

pub mod checkout {
    use serde_json::Value;

    use crate::channel_checkout::CheckoutCompletion;

    /// A checkout that has had time to settle but shows no completion. The
    /// lower bound exists because Stripe expires an unpaid session within a
    /// day, so a session older than that can never turn into a payment and is
    /// not worth re-reading.
    pub const CHECKOUT_BATCH: i64 = 5;
    pub const CHECKOUT_SETTLE_MS: i64 = 10 * 60_000;
    pub const CHECKOUT_WINDOW_MS: i64 = 24 * 60 * 60_000;

    /// Binds: `?1` = `now - CHECKOUT_SETTLE_MS`, `?2` = `now -
    /// CHECKOUT_WINDOW_MS`, `?3` = `CHECKOUT_BATCH`.
    pub const PENDING_CHECKOUTS_SQL: &str = "SELECT session_id FROM channel_checkout_sessions\n     WHERE completed_at IS NULL AND created_at <= ?1 AND created_at > ?2\n     ORDER BY created_at ASC LIMIT ?3";

    /// The three bind values for [`PENDING_CHECKOUTS_SQL`], in order.
    pub fn pending_checkouts_binds(now_ms: i64) -> [i64; 3] {
        [
            now_ms - CHECKOUT_SETTLE_MS,
            now_ms - CHECKOUT_WINDOW_MS,
            CHECKOUT_BATCH,
        ]
    }

    /// What a re-read `checkout/sessions/{id}` response means.
    #[derive(Debug, Clone, PartialEq, Eq)]
    pub enum CheckoutOutcome {
        /// No usable answer from Stripe; leave the session row alone.
        LeaveUntouched,
        /// Stripe reports the session expired: stamp `expires_at` so it stops
        /// being offered, without ever marking it completed.
        MarkExpired,
        /// Run the session through the same completion path the webhook uses,
        /// including its single-shot confirmation message. `paid` false still
        /// reaches that path, which is where the no-op is decided.
        Complete(Box<CheckoutCompletion>),
    }

    /// Classify a re-read checkout session. `session` is `None` when the read
    /// failed in any way.
    pub fn checkout_outcome(
        session_id: &str,
        session: Option<&Value>,
        now_ms: i64,
    ) -> CheckoutOutcome {
        let Some(session) = session else {
            return CheckoutOutcome::LeaveUntouched;
        };
        if session.get("status").and_then(Value::as_str) == Some("expired") {
            return CheckoutOutcome::MarkExpired;
        }
        let string = |key: &str| session.get(key).and_then(Value::as_str).map(String::from);
        let payment_status = session.get("payment_status").and_then(Value::as_str);
        CheckoutOutcome::Complete(Box::new(CheckoutCompletion {
            session_id: Some(session_id.to_string()),
            uid: string("client_reference_id"),
            customer: string("customer"),
            subscription: string("subscription"),
            paid: payment_status == Some("paid") || payment_status == Some("no_payment_required"),
            email: session
                .get("customer_details")
                .and_then(|details| details.get("email"))
                .and_then(Value::as_str)
                .map(String::from),
            event_created: now_ms.div_euclid(1_000),
        }))
    }
}

// ---------------------------------------------------------------------------
// wasm glue: D1 + the Stripe read
// ---------------------------------------------------------------------------

#[cfg(target_arch = "wasm32")]
mod wasm_glue {
    use serde_json::Value;
    use worker::wasm_bindgen::JsValue;
    use worker::{D1Database, Env, Fetch, Request, Response, Result, Url};

    use super::{
        checkout, encode_path_segment, reconcile_outcome, stale_entitlements_binds, stale_row,
        status_literal, ReconcileOutcome, StaleEntitlementRow, APPLY_SUBSCRIPTION_STATE_SQL,
        STALE_ENTITLEMENTS_SQL, STRIPE_VERSION,
    };
    use crate::glue::{js_opt, js_str};
    use crate::worker_util::{now_ms, secret_or_var};

    /// `GET https://api.stripe.com/v1/{path}`, returning the parsed body only
    /// when the call both succeeded and produced JSON. Every other outcome —
    /// transport failure, non-2xx, unparseable body — is `None`, which the
    /// decision logic reads as "no answer" and leaves the row untouched.
    /// Stripe's own failure detail is deliberately not surfaced to the caller;
    /// the secret appears in neither the return value nor any error.
    async fn stripe_get(secret: &str, path: &str) -> Option<Value> {
        let url = Url::parse(&format!("https://api.stripe.com/v1/{path}")).ok()?;
        let headers = worker::Headers::new();
        headers
            .set("authorization", &format!("Bearer {secret}"))
            .ok()?;
        headers.set("stripe-version", STRIPE_VERSION).ok()?;
        let mut init = worker::RequestInit::new();
        init.with_method(worker::Method::Get).with_headers(headers);
        let request = Request::new_with_init(url.as_str(), &init).ok()?;
        let mut response: Response = Fetch::Request(request).send().await.ok()?;
        if !(200..300).contains(&response.status_code()) {
            return None;
        }
        response.json::<Value>().await.ok()
    }

    /// Re-read one subscription and, if Stripe gave a usable answer, write it
    /// through the shared entitlement statement.
    async fn reconcile_entitlement(
        db: &D1Database,
        secret: &str,
        row: &StaleEntitlementRow,
        now: i64,
    ) -> Result<()> {
        let path = format!(
            "subscriptions/{}",
            encode_path_segment(&row.stripe_subscription_id)
        );
        let body = stripe_get(secret, &path).await;
        let ReconcileOutcome::Apply(state) = reconcile_outcome(row, body.as_ref(), now) else {
            return Ok(());
        };
        db.prepare(APPLY_SUBSCRIPTION_STATE_SQL)
            .bind(&[
                js_str(status_literal(state.active)),
                match state.valid_until {
                    Some(valid_until) => (valid_until as f64).into(),
                    None => JsValue::NULL,
                },
                js_str(&state.customer),
                (now as f64).into(),
                js_opt(state.subscription.as_deref()),
                js_opt(state.price_id.as_deref()),
                (state.event_created as f64).into(),
                js_str(&state.uid),
            ])?
            .run()
            .await?;
        Ok(())
    }

    /// Re-read the oldest and soonest-expiring subscription entitlements and
    /// correct any that drifted from what Stripe reports.
    ///
    /// Each row is reconciled independently and its failures are dropped, so a
    /// single bad row — one subscription Stripe will not return, one write the
    /// unique customer index rejects — cannot poison the rest of the batch.
    /// This is the `.catch(() => undefined)` the TS wraps each row in. The
    /// batch is walked in order rather than concurrently; at ten rows the
    /// latency is irrelevant and the sequencing keeps the Stripe call rate
    /// predictable.
    async fn sweep_stale_entitlements(db: &D1Database, secret: &str, now: i64) -> Result<()> {
        let binds = stale_entitlements_binds(now);
        let stale = db
            .prepare(STALE_ENTITLEMENTS_SQL)
            .bind(&[
                (binds[0] as f64).into(),
                (binds[1] as f64).into(),
                (binds[2] as f64).into(),
            ])?
            .all()
            .await?;
        for row in stale.results::<Value>()? {
            let Some(row) = stale_row(&row) else {
                continue;
            };
            let _ = reconcile_entitlement(db, secret, &row, now).await;
        }
        Ok(())
    }

    async fn reconcile_channel_checkout(
        env: &Env,
        secret: &str,
        session_id: &str,
        now: i64,
    ) -> Result<()> {
        let path = format!("checkout/sessions/{}", encode_path_segment(session_id));
        let session = stripe_get(secret, &path).await;
        match checkout::checkout_outcome(session_id, session.as_ref(), now) {
            checkout::CheckoutOutcome::LeaveUntouched => {}
            checkout::CheckoutOutcome::MarkExpired => {
                let _ = crate::routes_channels::expire_channel_checkout(env, session_id, now).await;
            }
            checkout::CheckoutOutcome::Complete(completion) => {
                let _ =
                    crate::routes_channels::complete_channel_checkout(env, *completion, now).await;
            }
        }
        Ok(())
    }

    async fn sweep_pending_checkouts(env: &Env, secret: &str, now: i64) -> Result<()> {
        let db = env.d1("DB")?;
        let binds = checkout::pending_checkouts_binds(now);
        let pending = db
            .prepare(checkout::PENDING_CHECKOUTS_SQL)
            .bind(&[
                (binds[0] as f64).into(),
                (binds[1] as f64).into(),
                (binds[2] as f64).into(),
            ])?
            .all()
            .await?;
        for row in pending.results::<Value>()? {
            let Some(session_id) = row
                .get("session_id")
                .and_then(Value::as_str)
                .map(String::from)
            else {
                continue;
            };
            let _ = reconcile_channel_checkout(env, secret, &session_id, now).await;
        }
        Ok(())
    }

    /// The scheduled Stripe reconciliation pass — `reconcileStripeSubscriptions`.
    pub async fn reconcile_stripe_subscriptions(env: &Env) -> Result<()> {
        let Some(secret) = secret_or_var(env, "STRIPE_SECRET_KEY").filter(|s| !s.is_empty()) else {
            return Ok(());
        };
        let now = now_ms();
        let db = env.d1("DB")?;
        sweep_stale_entitlements(&db, &secret, now).await?;
        let _ = sweep_pending_checkouts(env, &secret, now).await;
        Ok(())
    }
}

#[cfg(target_arch = "wasm32")]
pub use wasm_glue::reconcile_stripe_subscriptions;

#[cfg(test)]
mod tests {
    use super::checkout::{
        checkout_outcome, pending_checkouts_binds, CheckoutOutcome, CHECKOUT_BATCH,
        CHECKOUT_SETTLE_MS, CHECKOUT_WINDOW_MS,
    };
    use super::*;
    use crate::webhooks::{parse_stripe, StripePlan};
    use serde_json::json;

    const NOW: i64 = 1_700_000_000_000;

    fn row() -> StaleEntitlementRow {
        StaleEntitlementRow {
            uid: "uid-1".into(),
            stripe_subscription_id: "sub_123".into(),
        }
    }

    fn sweep_row(status: &str, valid_until: Option<i64>, updated_at: i64) -> EntitlementSweepRow {
        EntitlementSweepRow {
            stripe_subscription_id: Some("sub_123".into()),
            status: Some(status.into()),
            valid_until,
            updated_at,
        }
    }

    // -- selection predicate -------------------------------------------------

    #[test]
    fn fresh_active_row_is_not_reconciled() {
        let fresh = sweep_row("active", Some(NOW + 86_400_000), NOW - 1_000);
        assert!(!should_reconcile(&fresh, NOW));
    }

    #[test]
    fn row_without_subscription_is_never_reconciled() {
        // Nothing to read from Stripe, however stale it looks.
        let row = EntitlementSweepRow {
            stripe_subscription_id: None,
            status: Some("active".into()),
            valid_until: Some(NOW - 1),
            updated_at: 0,
        };
        assert!(!should_reconcile(&row, NOW));
    }

    #[test]
    fn unconfirmed_row_is_reconciled_at_the_boundary() {
        let exactly_stale = sweep_row("active", None, NOW - STALE_ENTITLEMENT_MS);
        assert!(should_reconcile(&exactly_stale, NOW));
        let one_ms_fresher = sweep_row("active", None, NOW - STALE_ENTITLEMENT_MS + 1);
        assert!(!should_reconcile(&one_ms_fresher, NOW));
    }

    #[test]
    fn active_row_past_its_paid_through_instant_is_reconciled() {
        // The shape a lost renewal webhook leaves behind.
        let lapsed = sweep_row("active", Some(NOW), NOW);
        assert!(should_reconcile(&lapsed, NOW));
        let future = sweep_row("active", Some(NOW + 1), NOW);
        assert!(!should_reconcile(&future, NOW));
    }

    #[test]
    fn expired_inactive_row_is_not_selected_by_expiry() {
        // Already inactive: only the staleness clause can pick it up, so a
        // fresh one is left alone and an old one is not.
        let fresh = sweep_row("inactive", Some(NOW - 1), NOW);
        assert!(!should_reconcile(&fresh, NOW));
        let old = sweep_row("inactive", Some(NOW - 1), NOW - STALE_ENTITLEMENT_MS);
        assert!(should_reconcile(&old, NOW));
    }

    #[test]
    fn active_row_without_expiry_is_only_selected_by_staleness() {
        assert!(!should_reconcile(&sweep_row("active", None, NOW), NOW));
    }

    #[test]
    fn selection_binds_and_bounds() {
        assert_eq!(
            stale_entitlements_binds(NOW),
            [NOW - STALE_ENTITLEMENT_MS, NOW, ENTITLEMENT_BATCH]
        );
        assert_eq!(STALE_ENTITLEMENT_MS, 21_600_000);
        assert_eq!(ENTITLEMENT_BATCH, 10);
        assert!(STALE_ENTITLEMENTS_SQL.contains("ORDER BY updated_at ASC LIMIT ?3"));
        assert!(STALE_ENTITLEMENTS_SQL.contains("stripe_subscription_id IS NOT NULL"));
    }

    #[test]
    fn stale_row_requires_both_columns() {
        assert_eq!(
            stale_row(&json!({"uid": "u", "stripe_subscription_id": "s"})),
            Some(StaleEntitlementRow {
                uid: "u".into(),
                stripe_subscription_id: "s".into(),
            })
        );
        assert_eq!(stale_row(&json!({"uid": "u"})), None);
        assert_eq!(
            stale_row(&json!({"uid": "u", "stripe_subscription_id": null})),
            None
        );
    }

    // -- payload readers -----------------------------------------------------

    #[test]
    fn period_end_scales_seconds_to_milliseconds() {
        assert_eq!(
            period_end_ms(&json!({"current_period_end": 1_700_000_000})),
            Some(1_700_000_000_000)
        );
        assert_eq!(period_end_ms(&json!({})), None);
        assert_eq!(period_end_ms(&json!({"current_period_end": 1.5})), None);
        assert_eq!(period_end_ms(&json!({"current_period_end": "x"})), None);
        assert_eq!(
            period_end_ms(&json!({"current_period_end": 9_007_199_254_740_993i64 as f64})),
            None
        );
    }

    #[test]
    fn price_reads_the_first_line_item() {
        let subscription = json!({"items": {"data": [
            {"price": {"id": "price_pro"}},
            {"price": {"id": "price_other"}},
        ]}});
        assert_eq!(price_of(&subscription).as_deref(), Some("price_pro"));
        assert_eq!(price_of(&json!({})), None);
        assert_eq!(price_of(&json!({"items": {"data": []}})), None);
        assert_eq!(
            price_of(&json!({"items": {"data": [{"price": {"id": 7}}]}})),
            None
        );
    }

    #[test]
    fn only_paid_up_statuses_are_active() {
        assert!(subscription_active(Some("active")));
        assert!(subscription_active(Some("trialing")));
        for status in [
            "past_due",
            "unpaid",
            "canceled",
            "incomplete",
            "incomplete_expired",
            "paused",
            "",
        ] {
            assert!(!subscription_active(Some(status)), "{status}");
        }
        assert!(!subscription_active(None));
    }

    // -- the transition decision --------------------------------------------

    #[test]
    fn no_answer_from_stripe_leaves_the_row_untouched() {
        // The single most important case: a reconciliation that cannot reach
        // Stripe must not be able to revoke a paying customer.
        assert_eq!(
            reconcile_outcome(&row(), None, NOW),
            ReconcileOutcome::LeaveUntouched(SkipReason::NoAnswer)
        );
    }

    #[test]
    fn body_without_customer_leaves_the_row_untouched() {
        let error_envelope = json!({"error": {"code": "resource_missing"}});
        assert_eq!(
            reconcile_outcome(&row(), Some(&error_envelope), NOW),
            ReconcileOutcome::LeaveUntouched(SkipReason::MissingCustomer)
        );
        // A non-string customer is equally not an answer.
        assert_eq!(
            reconcile_outcome(
                &row(),
                Some(&json!({"customer": 7, "status": "active"})),
                NOW
            ),
            ReconcileOutcome::LeaveUntouched(SkipReason::MissingCustomer)
        );
    }

    #[test]
    fn body_without_status_leaves_the_row_untouched() {
        // Deliberately stricter than the TS, which would write `inactive` here.
        assert_eq!(
            reconcile_outcome(&row(), Some(&json!({"customer": "cus_1"})), NOW),
            ReconcileOutcome::LeaveUntouched(SkipReason::MissingStatus)
        );
        assert_eq!(
            reconcile_outcome(
                &row(),
                Some(&json!({"customer": "cus_1", "status": null})),
                NOW
            ),
            ReconcileOutcome::LeaveUntouched(SkipReason::MissingStatus)
        );
    }

    #[test]
    fn active_subscription_is_applied_in_full() {
        let subscription = json!({
            "id": "sub_123",
            "customer": "cus_1",
            "status": "active",
            "current_period_end": 1_800_000_000,
            "items": {"data": [{"price": {"id": "price_pro"}}]},
        });
        let expected = StripeSubscription {
            uid: "uid-1".into(),
            customer: "cus_1".into(),
            subscription: Some("sub_123".into()),
            active: true,
            valid_until: Some(1_800_000_000_000),
            price_id: Some("price_pro".into()),
            event_created: NOW / 1_000,
        };
        assert_eq!(
            reconcile_outcome(&row(), Some(&subscription), NOW),
            ReconcileOutcome::Apply(expected)
        );
    }

    #[test]
    fn a_real_cancellation_is_applied_as_inactive() {
        // Not a failure mode: Stripe answered, and the answer is that this
        // subscription is not paid up. Silence is what must never do this.
        let subscription = json!({"customer": "cus_1", "status": "canceled"});
        match reconcile_outcome(&row(), Some(&subscription), NOW) {
            ReconcileOutcome::Apply(state) => {
                assert!(!state.active);
                assert_eq!(state.valid_until, None);
                assert_eq!(state.price_id, None);
            }
            other => panic!("expected an applied state, got {other:?}"),
        }
    }

    #[test]
    fn trialing_subscription_stays_active() {
        let subscription = json!({"customer": "cus_1", "status": "trialing"});
        match reconcile_outcome(&row(), Some(&subscription), NOW) {
            ReconcileOutcome::Apply(state) => assert!(state.active),
            other => panic!("expected an applied state, got {other:?}"),
        }
    }

    #[test]
    fn subscription_id_comes_from_the_row_not_the_payload() {
        // Reconciliation is about the row it selected; a payload naming some
        // other subscription is answering a question we did not ask.
        let subscription = json!({"id": "sub_other", "customer": "cus_1", "status": "active"});
        match reconcile_outcome(&row(), Some(&subscription), NOW) {
            ReconcileOutcome::Apply(state) => {
                assert_eq!(state.subscription.as_deref(), Some("sub_123"));
            }
            other => panic!("expected an applied state, got {other:?}"),
        }
    }

    #[test]
    fn event_created_floors_to_whole_seconds() {
        let subscription = json!({"customer": "cus_1", "status": "active"});
        match reconcile_outcome(&row(), Some(&subscription), 1_999) {
            ReconcileOutcome::Apply(state) => assert_eq!(state.event_created, 1),
            other => panic!("expected an applied state, got {other:?}"),
        }
    }

    #[test]
    fn reconciliation_and_webhook_agree_on_the_same_subscription() {
        // Both paths must produce one notion of subscription state. The only
        // intended differences are the event time (reconciliation speaks for
        // "now") and the uid/subscription id, which reconciliation takes from
        // the row rather than from the payload.
        let object = json!({
            "id": "sub_123",
            "customer": "cus_1",
            "status": "past_due",
            "current_period_end": 1_800_000_000,
            "metadata": {"firebase_uid": "uid-1"},
            "items": {"data": [{"price": {"id": "price_pro"}}]},
        });
        let event = json!({
            "id": "evt_1",
            "type": "customer.subscription.updated",
            "created": NOW / 1_000,
            "data": {"object": object},
        });
        let StripePlan::Subscription(from_webhook) = parse_stripe(&event).unwrap().plan else {
            panic!("expected a subscription event");
        };
        let ReconcileOutcome::Apply(from_sweep) = reconcile_outcome(&row(), Some(&object), NOW)
        else {
            panic!("expected an applied state");
        };
        assert_eq!(from_sweep, from_webhook);
    }

    // -- the shared statement ------------------------------------------------

    #[test]
    fn transition_statement_carries_the_monotonic_guard() {
        assert!(APPLY_SUBSCRIPTION_STATE_SQL
            .contains("WHERE excluded.stripe_event_created >= entitlements.stripe_event_created"));
    }

    #[test]
    fn transition_statement_never_steals_a_claimed_customer_id() {
        assert!(APPLY_SUBSCRIPTION_STATE_SQL.contains("other.stripe_customer_id = ?3"));
        assert!(APPLY_SUBSCRIPTION_STATE_SQL.contains(
            "stripe_customer_id = COALESCE(excluded.stripe_customer_id, entitlements.stripe_customer_id)"
        ));
    }

    /// The checkout webhook is where a shared customer id arrives first, so it
    /// needs the same guard as the subscription statement. The Rust port
    /// originally wrote the id unconditionally in both, which throws on the
    /// unique index for the second of two accounts sharing an email — the
    /// failure the TypeScript had already been fixed for.
    #[test]
    fn claim_statement_never_steals_a_claimed_customer_id() {
        assert!(CLAIM_STRIPE_CUSTOMER_SQL.contains("other.stripe_customer_id = ?1"));
        assert!(CLAIM_STRIPE_CUSTOMER_SQL.contains("other.uid <> ?3"));
        assert!(CLAIM_STRIPE_CUSTOMER_SQL.contains(
            "stripe_customer_id = COALESCE(excluded.stripe_customer_id, entitlements.stripe_customer_id)"
        ));
    }

    /// Checkout records which customer an account is and nothing more: the plan
    /// only moves when a subscription event says so.
    #[test]
    fn claim_statement_does_not_move_the_plan() {
        assert!(CLAIM_STRIPE_CUSTOMER_SQL.contains("'byok', 'inactive'"));
        assert!(!CLAIM_STRIPE_CUSTOMER_SQL.contains("plan = 'pro'"));
    }

    #[test]
    fn transition_statement_preserves_ids_it_was_not_told_about() {
        assert!(APPLY_SUBSCRIPTION_STATE_SQL.contains(
            "stripe_subscription_id = COALESCE(excluded.stripe_subscription_id, entitlements.stripe_subscription_id)"
        ));
        assert!(APPLY_SUBSCRIPTION_STATE_SQL.contains(
            "stripe_price_id = COALESCE(excluded.stripe_price_id, entitlements.stripe_price_id)"
        ));
    }

    #[test]
    fn status_literals_match_the_column_check() {
        assert_eq!(status_literal(true), "active");
        assert_eq!(status_literal(false), "inactive");
    }

    // -- path encoding -------------------------------------------------------

    #[test]
    fn path_segments_cannot_escape_their_endpoint() {
        assert_eq!(encode_path_segment("sub_123"), "sub_123");
        assert_eq!(
            encode_path_segment("../charges/ch_1"),
            "..%2Fcharges%2Fch_1"
        );
        assert_eq!(encode_path_segment("a b?c=d&e"), "a%20b%3Fc%3Dd%26e");
        assert_eq!(encode_path_segment("-_.!~*'()"), "-_.!~*'()");
        assert_eq!(encode_path_segment("é"), "%C3%A9");
    }

    // -- deferred checkout half ---------------------------------------------

    #[test]
    fn checkout_bounds_and_binds() {
        assert_eq!(
            pending_checkouts_binds(NOW),
            [
                NOW - CHECKOUT_SETTLE_MS,
                NOW - CHECKOUT_WINDOW_MS,
                CHECKOUT_BATCH
            ]
        );
        assert_eq!(CHECKOUT_SETTLE_MS, 600_000);
        assert_eq!(CHECKOUT_WINDOW_MS, 86_400_000);
        assert_eq!(CHECKOUT_BATCH, 5);
    }

    #[test]
    fn checkout_no_answer_leaves_the_session_untouched() {
        assert_eq!(
            checkout_outcome("cs_1", None, NOW),
            CheckoutOutcome::LeaveUntouched
        );
    }

    #[test]
    fn expired_checkout_is_marked_expired_not_completed() {
        assert_eq!(
            checkout_outcome("cs_1", Some(&json!({"status": "expired"})), NOW),
            CheckoutOutcome::MarkExpired
        );
    }

    #[test]
    fn paid_checkout_is_routed_to_the_completion_path() {
        let session = json!({
            "status": "complete",
            "payment_status": "paid",
            "client_reference_id": "uid-1",
            "customer": "cus_1",
            "subscription": "sub_123",
            "customer_details": {"email": "payer@example.com"},
        });
        match checkout_outcome("cs_1", Some(&session), NOW) {
            CheckoutOutcome::Complete(completion) => {
                assert_eq!(completion.session_id.as_deref(), Some("cs_1"));
                assert_eq!(completion.uid.as_deref(), Some("uid-1"));
                assert_eq!(completion.customer.as_deref(), Some("cus_1"));
                assert_eq!(completion.subscription.as_deref(), Some("sub_123"));
                assert!(completion.paid);
                assert_eq!(completion.email.as_deref(), Some("payer@example.com"));
                assert_eq!(completion.event_created, NOW / 1_000);
            }
            other => panic!("expected a completion, got {other:?}"),
        }
    }

    #[test]
    fn free_checkout_counts_as_paid_and_unpaid_does_not() {
        let free = json!({"payment_status": "no_payment_required"});
        match checkout_outcome("cs_1", Some(&free), NOW) {
            CheckoutOutcome::Complete(completion) => assert!(completion.paid),
            other => panic!("expected a completion, got {other:?}"),
        }
        let unpaid = json!({"payment_status": "unpaid"});
        match checkout_outcome("cs_1", Some(&unpaid), NOW) {
            CheckoutOutcome::Complete(completion) => assert!(!completion.paid),
            other => panic!("expected a completion, got {other:?}"),
        }
    }
}
