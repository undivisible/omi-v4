// Ported from worker/src/entitlement.ts. The DB read lives in the worker glue;
// this module holds the pure decision logic so it can be exercised by
// `cargo test`.

/// The entitlements row shape relevant to the Pro check.
#[derive(Debug, Clone, Default)]
pub struct EntitlementRow {
    pub plan: Option<String>,
    pub status: Option<String>,
    /// Unix milliseconds; `None` means "no expiry".
    pub valid_until: Option<i64>,
}

/// Result of the DEV_FAKE_PRO short-circuit evaluation.
pub enum DevFakePro {
    /// Grant Pro immediately (non-production with the flag set).
    ForcePro,
    /// The flag was set but ENVIRONMENT is production; log a warning and fall
    /// through to the real check.
    IgnoredInProduction,
    /// The flag was not set; proceed to the real check.
    NotSet,
}

/// Evaluate the DEV_FAKE_PRO / ENVIRONMENT guard exactly as the TS does.
/// Whether plans are being enforced at all.
///
/// Before launch there is nothing to sell and nobody to bill, so refusing to
/// answer until someone subscribes is a wall in front of an empty shop. This is
/// a deliberate env switch rather than [`dev_fake_pro`], which is ignored in
/// production precisely so a stray dev flag cannot give away a real product —
/// turning enforcement off for everyone is a decision, and it should have to be
/// made on purpose.
pub fn plan_enforced(flag: Option<&str>) -> bool {
    !matches!(
        flag.map(str::trim),
        Some("false" | "FALSE" | "0" | "off" | "OFF")
    )
}

pub fn dev_fake_pro(dev_fake_pro: Option<&str>, environment: Option<&str>) -> DevFakePro {
    if dev_fake_pro == Some("true") {
        if environment == Some("production") {
            return DevFakePro::IgnoredInProduction;
        }
        return DevFakePro::ForcePro;
    }
    DevFakePro::NotSet
}

/// Decide whether an entitlements row grants active Pro. `now_ms` is the current
/// unix time in milliseconds. Mirrors:
///   row.plan === "pro" && row.status === "active" &&
///   (row.valid_until === null || Number(row.valid_until) > Date.now())
pub fn row_grants_pro(row: &EntitlementRow, now_ms: i64) -> bool {
    row.plan.as_deref() == Some("pro")
        && row.status.as_deref() == Some("active")
        && match row.valid_until {
            None => true,
            Some(valid_until) => valid_until > now_ms,
        }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(plan: &str, status: &str, valid_until: Option<i64>) -> EntitlementRow {
        EntitlementRow {
            plan: Some(plan.to_string()),
            status: Some(status.to_string()),
            valid_until,
        }
    }

    #[test]
    fn enforcement_is_on_until_it_is_explicitly_turned_off() {
        assert!(plan_enforced(None));
        assert!(plan_enforced(Some("true")));
        assert!(plan_enforced(Some("")));
        assert!(plan_enforced(Some("yes")));
        for off in ["false", "FALSE", "0", "off", "OFF", " false "] {
            assert!(!plan_enforced(Some(off)), "{off}");
        }
    }

    #[test]
    fn dev_fake_pro_matrix() {
        assert!(matches!(
            dev_fake_pro(Some("true"), Some("staging")),
            DevFakePro::ForcePro
        ));
        assert!(matches!(
            dev_fake_pro(Some("true"), None),
            DevFakePro::ForcePro
        ));
        assert!(matches!(
            dev_fake_pro(Some("true"), Some("production")),
            DevFakePro::IgnoredInProduction
        ));
        assert!(matches!(
            dev_fake_pro(Some("false"), Some("staging")),
            DevFakePro::NotSet
        ));
        assert!(matches!(dev_fake_pro(None, None), DevFakePro::NotSet));
    }

    #[test]
    fn pro_active_no_expiry() {
        assert!(row_grants_pro(&row("pro", "active", None), 1000));
    }

    #[test]
    fn pro_active_future_expiry() {
        assert!(row_grants_pro(&row("pro", "active", Some(2000)), 1000));
    }

    #[test]
    fn pro_active_past_expiry() {
        assert!(!row_grants_pro(&row("pro", "active", Some(500)), 1000));
    }

    #[test]
    fn pro_active_exact_expiry_is_not_active() {
        // Strictly greater-than, matching `> Date.now()`.
        assert!(!row_grants_pro(&row("pro", "active", Some(1000)), 1000));
    }

    #[test]
    fn non_pro_plan_rejected() {
        assert!(!row_grants_pro(&row("byok", "active", None), 1000));
    }

    #[test]
    fn inactive_status_rejected() {
        assert!(!row_grants_pro(&row("pro", "canceled", None), 1000));
    }

    #[test]
    fn missing_row_rejected() {
        assert!(!row_grants_pro(&EntitlementRow::default(), 1000));
    }
}
