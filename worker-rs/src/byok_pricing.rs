//! Pure parity port of `worker/src/byok-pricing.ts`.
//!
//! Server-side price band for the BYOK negotiation. This module is the single
//! source of truth for what a BYOK subscription may cost: the standard price,
//! the hard floor, and the finite set of concessions the negotiator is allowed
//! to grant. Nothing here is reachable from the client, and no price value is
//! ever accepted from a request body or from raw model output.
//!
//! Every value is env-overridable so pricing can move without a code change,
//! but a misconfigured override is rejected rather than applied.

use serde_json::Value;

use crate::jsnum::{is_safe_integer, number_from_str};

#[derive(Clone, Debug, PartialEq)]
pub struct Concession {
    pub code: &'static str,
    pub cents_off: i64,
    pub label: &'static str,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PriceBand {
    pub standard_cents: i64,
    pub floor_cents: i64,
    pub max_turns: i64,
    pub cooldown_ms: i64,
    pub concessions: Vec<Concession>,
}

/// The concessions the negotiator may grant, and what each is worth. A code
/// that is not in this table can never move the price, whatever the model
/// returns.
pub const DEFAULT_CONCESSIONS: &[Concession] = &[
    Concession {
        code: "own_inference",
        cents_off: 150,
        label: "you pay for your own inference",
    },
    Concession {
        code: "annual_commitment",
        cents_off: 200,
        label: "you commit for a year",
    },
    Concession {
        code: "case_study",
        cents_off: 100,
        label: "you are happy to be written about",
    },
    Concession {
        code: "student",
        cents_off: 150,
        label: "you are a student",
    },
    Concession {
        code: "early_adopter",
        cents_off: 100,
        label: "you joined early and report bugs",
    },
];

pub const DEFAULT_STANDARD_CENTS: i64 = 1_200;
pub const DEFAULT_FLOOR_CENTS: i64 = 700;
pub const DEFAULT_MAX_TURNS: i64 = 6;
pub const DEFAULT_COOLDOWN_MS: i64 = 30 * 24 * 60 * 60_000;

/// `integer(value, minimum, maximum)` over an env string.
fn integer(value: Option<&str>, minimum: i64, maximum: i64) -> Option<i64> {
    let parsed = number_from_str(value?.trim());
    (is_safe_integer(parsed) && parsed >= minimum as f64 && parsed <= maximum as f64)
        .then_some(parsed as i64)
}

/// Per-concession overrides arrive as a JSON object of known code -> cents.
/// Unknown codes are dropped rather than honoured, so an override can never
/// invent a new lever for the model to pull.
fn overridden_concessions(raw: Option<&str>) -> Vec<Concession> {
    let defaults = || DEFAULT_CONCESSIONS.to_vec();
    let Some(raw) = raw else { return defaults() };
    if raw.trim().is_empty() {
        return defaults();
    }
    let Ok(parsed) = serde_json::from_str::<Value>(raw) else {
        return defaults();
    };
    let Some(overrides) = parsed.as_object() else {
        return defaults();
    };
    DEFAULT_CONCESSIONS
        .iter()
        .map(|concession| {
            let candidate = overrides
                .get(concession.code)
                .and_then(Value::as_f64)
                .filter(|value| is_safe_integer(*value) && *value >= 0.0 && *value <= 100_000.0);
            match candidate {
                Some(cents) => Concession {
                    cents_off: cents as i64,
                    ..concession.clone()
                },
                None => concession.clone(),
            }
        })
        .collect()
}

/// `priceBand(env)` — `get` reads a binding by name (var, then secret).
pub fn price_band(get: impl Fn(&str) -> Option<String>) -> PriceBand {
    let standard_cents = integer(get("BYOK_STANDARD_PRICE_CENTS").as_deref(), 1, 1_000_000)
        .unwrap_or(DEFAULT_STANDARD_CENTS);
    let floor_candidate = integer(get("BYOK_FLOOR_PRICE_CENTS").as_deref(), 1, 1_000_000)
        .unwrap_or(DEFAULT_FLOOR_CENTS);
    // A floor above the standard price is a misconfiguration, not a discount
    // ceiling; refuse it and keep the band closed.
    let floor_cents = if floor_candidate <= standard_cents {
        floor_candidate
    } else {
        standard_cents
    };
    let cooldown_hours = integer(
        get("BYOK_NEGOTIATION_COOLDOWN_HOURS").as_deref(),
        0,
        24 * 365,
    );
    PriceBand {
        standard_cents,
        floor_cents,
        max_turns: integer(get("BYOK_NEGOTIATION_MAX_TURNS").as_deref(), 1, 24)
            .unwrap_or(DEFAULT_MAX_TURNS),
        cooldown_ms: match cooldown_hours {
            None => DEFAULT_COOLDOWN_MS,
            Some(hours) => hours * 3_600_000,
        },
        concessions: overridden_concessions(get("BYOK_NEGOTIATION_CONCESSIONS").as_deref()),
    }
}

/// `concessionFor(band, code)`.
pub fn concession_for<'a>(band: &'a PriceBand, code: Option<&str>) -> Option<&'a Concession> {
    let code = code?;
    band.concessions.iter().find(|entry| entry.code == code)
}

/// The one function that turns granted concessions into money. Grants are
/// de-duplicated and the result is clamped into the band, so no combination of
/// grants — including a replayed or forged list — can land below the floor.
pub fn price_for_grants(band: &PriceBand, grants: &[String]) -> i64 {
    let mut applied: Vec<&str> = Vec::new();
    let mut price = band.standard_cents;
    for grant in grants {
        let Some(concession) = concession_for(band, Some(grant.as_str())) else {
            continue;
        };
        if applied.contains(&concession.code) {
            continue;
        }
        applied.push(concession.code);
        price -= concession.cents_off;
    }
    band.standard_cents.min(band.floor_cents.max(price))
}

/// `normalizeGrants(band, grants)` — keeps only known codes, once each, in
/// order.
pub fn normalize_grants(band: &PriceBand, grants: &[Value]) -> Vec<String> {
    let mut applied: Vec<String> = Vec::new();
    for grant in grants {
        if let Some(concession) = concession_for(band, grant.as_str()) {
            if !applied.iter().any(|code| code == concession.code) {
                applied.push(concession.code.to_string());
            }
        }
    }
    applied
}

/// `formatPrice(cents)` — `$12.00`.
pub fn format_price(cents: i64) -> String {
    format!("${:.2}", cents as f64 / 100.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_band() -> PriceBand {
        price_band(|_| None)
    }

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        }
    }

    fn grants(codes: &[&str]) -> Vec<String> {
        codes.iter().map(|c| c.to_string()).collect()
    }

    #[test]
    fn defaults_match_the_compiled_band() {
        let band = default_band();
        assert_eq!(band.standard_cents, 1_200);
        assert_eq!(band.floor_cents, 700);
        assert_eq!(band.max_turns, 6);
        assert_eq!(band.cooldown_ms, 30 * 24 * 3_600_000);
        assert_eq!(band.concessions.len(), 5);
    }

    #[test]
    fn clamps_any_combination_of_grants_to_the_floor() {
        let band = default_band();
        // Every concession at once is 700 off standard, which is exactly the
        // floor; repeating them cannot go lower.
        let everything = grants(&[
            "own_inference",
            "annual_commitment",
            "case_study",
            "student",
            "early_adopter",
        ]);
        assert_eq!(price_for_grants(&band, &everything), 700);
        let mut replayed = everything.clone();
        replayed.extend(everything.clone());
        replayed.extend(everything);
        assert_eq!(price_for_grants(&band, &replayed), 700);
        assert_eq!(price_for_grants(&band, &[]), 1_200);
        assert_eq!(price_for_grants(&band, &grants(&["student"])), 1_050);
        // De-duplicated: the same lever twice is one discount.
        assert_eq!(
            price_for_grants(&band, &grants(&["student", "student"])),
            1_050
        );
    }

    #[test]
    fn a_generous_override_still_cannot_breach_the_floor() {
        let band = price_band(env(&[(
            "BYOK_NEGOTIATION_CONCESSIONS",
            r#"{"student":100000,"case_study":100000}"#,
        )]));
        assert_eq!(
            price_for_grants(&band, &grants(&["student"])),
            band.floor_cents
        );
        assert_eq!(
            price_for_grants(&band, &grants(&["student", "case_study"])),
            band.floor_cents
        );
    }

    #[test]
    fn ignores_unknown_concession_codes() {
        let band = default_band();
        assert_eq!(
            price_for_grants(&band, &grants(&["free", "admin", "__proto__"])),
            1_200
        );
        assert_eq!(
            normalize_grants(
                &band,
                &[
                    Value::from("student"),
                    Value::from("free"),
                    Value::from("student"),
                    Value::from(7),
                    Value::Null,
                ]
            ),
            vec!["student".to_string()]
        );
        assert!(concession_for(&band, Some("free")).is_none());
        assert!(concession_for(&band, None).is_none());
    }

    #[test]
    fn refuses_a_floor_above_the_standard_price() {
        let band = price_band(env(&[
            ("BYOK_STANDARD_PRICE_CENTS", "500"),
            ("BYOK_FLOOR_PRICE_CENTS", "900"),
        ]));
        assert_eq!(band.standard_cents, 500);
        assert_eq!(band.floor_cents, 500);
        assert_eq!(price_for_grants(&band, &grants(&["student"])), 500);
    }

    #[test]
    fn rejects_misconfigured_overrides_and_keeps_the_defaults() {
        for value in ["0", "-5", "1.5", "", "   ", "abc", "1000001"] {
            let band = price_band(env(&[("BYOK_STANDARD_PRICE_CENTS", value)]));
            assert_eq!(
                band.standard_cents, DEFAULT_STANDARD_CENTS,
                "should reject {value:?}"
            );
        }
        for raw in [
            "not json",
            "[]",
            "null",
            r#""x""#,
            r#"{"student":-1}"#,
            r#"{"student":1.5}"#,
        ] {
            let band = price_band(env(&[("BYOK_NEGOTIATION_CONCESSIONS", raw)]));
            assert_eq!(
                concession_for(&band, Some("student")).unwrap().cents_off,
                150,
                "should reject {raw:?}"
            );
        }
        // An unknown code in the override object cannot invent a new lever.
        let band = price_band(env(&[("BYOK_NEGOTIATION_CONCESSIONS", r#"{"free":900}"#)]));
        assert_eq!(band.concessions.len(), 5);
        assert!(concession_for(&band, Some("free")).is_none());
    }

    #[test]
    fn cooldown_and_turn_overrides_apply_within_bounds() {
        let band = price_band(env(&[
            ("BYOK_NEGOTIATION_COOLDOWN_HOURS", "0"),
            ("BYOK_NEGOTIATION_MAX_TURNS", "3"),
        ]));
        assert_eq!(band.cooldown_ms, 0);
        assert_eq!(band.max_turns, 3);
        let out_of_range = price_band(env(&[("BYOK_NEGOTIATION_MAX_TURNS", "25")]));
        assert_eq!(out_of_range.max_turns, DEFAULT_MAX_TURNS);
    }

    #[test]
    fn format_price_is_two_decimal_dollars() {
        assert_eq!(format_price(1_200), "$12.00");
        assert_eq!(format_price(705), "$7.05");
        assert_eq!(format_price(0), "$0.00");
    }
}
