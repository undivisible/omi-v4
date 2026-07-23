//! Pure port of the `AssistantAdmission` Durable Object state machine
//! (`worker/src/assistant-admission.ts`). The DO glue is a thin SQLite wrapper
//! around this logic; the reservations ledger is modelled here as an in-memory
//! table so the admit/release/settle semantics — including the overrun and
//! window-roll races the TS suite asserts — are exercised by `cargo test`.

use serde_json::Value;

use crate::jsnum::{
    non_negative_integer_value, number_from_str, positive_integer_str, positive_integer_value,
};

/// Budget limits, resolved from the bound env vars with the same defaults as
/// `limitsFrom` in the TypeScript source.
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub window_ms: i64,
    pub uid_in_flight: i64,
    pub global_in_flight: i64,
    pub uid_tokens: i64,
    pub global_tokens: i64,
    pub uid_cost_microusd: i64,
    pub global_cost_microusd: i64,
}

impl Limits {
    /// `env` maps var name -> value, matching the env bindings the DO reads.
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Self {
        let window_seconds = positive_integer_str(get("MIMO_BUDGET_WINDOW_SECONDS").as_deref());
        Limits {
            window_ms: window_seconds.map(|s| s * 1000).unwrap_or(3_600_000),
            uid_in_flight: positive_integer_str(get("MIMO_UID_IN_FLIGHT_LIMIT").as_deref())
                .unwrap_or(2),
            global_in_flight: positive_integer_str(get("MIMO_GLOBAL_IN_FLIGHT_LIMIT").as_deref())
                .unwrap_or(32),
            uid_tokens: positive_integer_str(get("MIMO_UID_TOKEN_BUDGET").as_deref())
                .unwrap_or(100_000),
            global_tokens: positive_integer_str(get("MIMO_GLOBAL_TOKEN_BUDGET").as_deref())
                .unwrap_or(2_000_000),
            uid_cost_microusd: positive_integer_str(get("MIMO_UID_COST_BUDGET_MICROUSD").as_deref())
                .unwrap_or(1_000_000),
            global_cost_microusd: positive_integer_str(
                get("MIMO_GLOBAL_COST_BUDGET_MICROUSD").as_deref(),
            )
            .unwrap_or(20_000_000),
        }
    }
}

#[derive(Clone, Debug)]
struct Reservation {
    request_id: String,
    uid: String,
    created_at: i64,
    token_budget: i64,
    cost_budget_microusd: i64,
    in_flight: i64,
}

/// The outcome of a DO command: an HTTP status plus the JSON body and, for a
/// refusal, the `retry-after` header value.
#[derive(Debug, PartialEq, Eq)]
pub struct Outcome {
    pub status: u16,
    pub body: Value,
    pub retry_after: Option<String>,
}

impl Outcome {
    fn json(status: u16, body: Value) -> Self {
        Outcome {
            status,
            body,
            retry_after: None,
        }
    }
}

#[derive(Default)]
pub struct AssistantAdmission {
    reservations: Vec<Reservation>,
}

impl AssistantAdmission {
    pub fn new() -> Self {
        Self::default()
    }

    /// POST /admit
    pub fn admit(
        &mut self,
        limits: Limits,
        now: i64,
        request_id: &str,
        uid: &str,
        token_budget: i64,
        cost_budget_microusd: i64,
    ) -> Outcome {
        self.reservations
            .retain(|r| r.created_at > now - limits.window_ms);

        if let Some(existing) = self.reservations.iter().find(|r| r.request_id == request_id) {
            let admitted = existing.in_flight == 1;
            return Outcome::json(
                if admitted { 200 } else { 429 },
                serde_json::json!({ "admitted": admitted, "retryAfter": 1 }),
            );
        }

        let mut global_in_flight = 0i64;
        let mut uid_in_flight = 0i64;
        let mut global_tokens = 0i64;
        let mut uid_tokens = 0i64;
        let mut global_cost = 0i64;
        let mut uid_cost = 0i64;
        let mut oldest: Option<i64> = None;
        for r in &self.reservations {
            global_in_flight += r.in_flight;
            global_tokens += r.token_budget;
            global_cost += r.cost_budget_microusd;
            if r.uid == uid {
                uid_in_flight += r.in_flight;
                uid_tokens += r.token_budget;
                uid_cost += r.cost_budget_microusd;
            }
            oldest = Some(oldest.map_or(r.created_at, |o| o.min(r.created_at)));
        }

        let exceeds = global_in_flight >= limits.global_in_flight
            || uid_in_flight >= limits.uid_in_flight
            || global_tokens + token_budget > limits.global_tokens
            || uid_tokens + token_budget > limits.uid_tokens
            || global_cost + cost_budget_microusd > limits.global_cost_microusd
            || uid_cost + cost_budget_microusd > limits.uid_cost_microusd;

        let retry_after = (((oldest.unwrap_or(now) + limits.window_ms - now) as f64 / 1000.0).ceil()
            as i64)
            .max(1);

        if exceeds {
            return Outcome {
                status: 429,
                body: serde_json::json!({ "admitted": false, "retryAfter": retry_after }),
                retry_after: Some(retry_after.to_string()),
            };
        }

        self.reservations.push(Reservation {
            request_id: request_id.to_string(),
            uid: uid.to_string(),
            created_at: now,
            token_budget,
            cost_budget_microusd,
            in_flight: 1,
        });
        Outcome::json(
            200,
            serde_json::json!({ "admitted": true, "retryAfter": 0 }),
        )
    }

    /// POST /release
    pub fn release(&mut self, request_id: &str) -> Outcome {
        for r in &mut self.reservations {
            if r.request_id == request_id {
                r.in_flight = 0;
            }
        }
        Outcome::json(200, serde_json::json!({ "released": true }))
    }

    /// POST /settle
    pub fn settle(
        &mut self,
        request_id: &str,
        token_budget: i64,
        cost_budget_microusd: i64,
    ) -> Outcome {
        for r in &mut self.reservations {
            if r.request_id == request_id {
                r.token_budget = token_budget;
                r.cost_budget_microusd = cost_budget_microusd;
                r.in_flight = 0;
            }
        }
        Outcome::json(200, serde_json::json!({ "settled": true }))
    }

    /// Dispatch a raw JSON body against one of the three DO routes, applying
    /// the same 400/404/405 validation the TS `handle` method performs. The
    /// caller supplies the HTTP method and path.
    pub fn dispatch(
        &mut self,
        limits: Limits,
        now: i64,
        method: &str,
        path: &str,
        body: &Value,
    ) -> Outcome {
        if method != "POST" {
            return Outcome::json(405, Value::Null);
        }
        let request_id = body.get("requestId").and_then(Value::as_str);
        let Some(request_id) = request_id else {
            if path == "/admit" || path == "/release" || path == "/settle" {
                return Outcome::json(400, serde_json::json!({ "error": "Invalid request" }));
            }
            return Outcome::json(404, Value::Null);
        };
        match path {
            "/release" => self.release(request_id),
            "/settle" => {
                let token_budget = body.get("tokenBudget").and_then(non_negative_integer_value);
                let cost = body
                    .get("costBudgetMicrousd")
                    .and_then(non_negative_integer_value);
                match (token_budget, cost) {
                    (Some(t), Some(c)) => self.settle(request_id, t, c),
                    _ => Outcome::json(400, serde_json::json!({ "error": "Invalid request" })),
                }
            }
            "/admit" => {
                let uid = body.get("uid").and_then(Value::as_str);
                let token_budget = body.get("tokenBudget").and_then(positive_integer_value);
                let cost = body
                    .get("costBudgetMicrousd")
                    .and_then(positive_integer_value);
                match (uid, token_budget, cost) {
                    (Some(uid), Some(t), Some(c)) => {
                        self.admit(limits, now, request_id, uid, t, c)
                    }
                    _ => Outcome::json(400, serde_json::json!({ "error": "Invalid request" })),
                }
            }
            _ => Outcome::json(404, Value::Null),
        }
    }
}

/// Convenience: `Number(env.X) * 1000` window used by the reconcile cron's
/// staleness check lives in the assistant module; exposed here so the DO glue
/// and the route share the same parse.
pub fn window_ms_from_seconds(value: Option<&str>) -> i64 {
    positive_integer_str(value)
        .map(|s| s * 1000)
        .unwrap_or(3_600_000)
}

#[allow(dead_code)]
fn _number_from_str_reexport(v: &str) -> f64 {
    number_from_str(v)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn limits() -> Limits {
        Limits::from_env(|k| {
            match k {
                "MIMO_BUDGET_WINDOW_SECONDS" => Some("3600"),
                "MIMO_UID_IN_FLIGHT_LIMIT" => Some("2"),
                "MIMO_GLOBAL_IN_FLIGHT_LIMIT" => Some("10"),
                "MIMO_UID_TOKEN_BUDGET" => Some("100000"),
                "MIMO_GLOBAL_TOKEN_BUDGET" => Some("1000000"),
                "MIMO_UID_COST_BUDGET_MICROUSD" => Some("100000"),
                "MIMO_GLOBAL_COST_BUDGET_MICROUSD" => Some("1000000"),
                _ => None,
            }
            .map(str::to_string)
        })
    }

    fn admit(a: &mut AssistantAdmission, l: Limits, now: i64, id: &str, uid: &str) -> u16 {
        a.dispatch(
            l,
            now,
            "POST",
            "/admit",
            &json!({ "requestId": id, "uid": uid, "tokenBudget": 1, "costBudgetMicrousd": 1 }),
        )
        .status
    }

    #[test]
    fn enforces_per_uid_and_global_in_flight_limits() {
        let l = Limits { uid_in_flight: 2, ..limits() };
        let mut a = AssistantAdmission::new();
        let mut ok = 0;
        let mut refused = 0;
        for i in 0..24 {
            match admit(&mut a, l, 1000, &format!("uid-{i}"), "same-user") {
                200 => ok += 1,
                429 => refused += 1,
                other => panic!("unexpected {other}"),
            }
        }
        assert_eq!(ok, 2);
        assert_eq!(refused, 22);

        let l = Limits { uid_in_flight: 10, global_in_flight: 3, ..limits() };
        let mut a = AssistantAdmission::new();
        let mut ok = 0;
        let mut refused = 0;
        for i in 0..24 {
            match admit(&mut a, l, 1000, &format!("global-{i}"), &format!("user-{i}")) {
                200 => ok += 1,
                429 => refused += 1,
                other => panic!("unexpected {other}"),
            }
        }
        assert_eq!(ok, 3);
        assert_eq!(refused, 21);
    }

    #[test]
    fn duplicate_release_idempotent_and_window_rolls() {
        let l = Limits {
            window_ms: 1000,
            uid_tokens: 2,
            ..limits()
        };
        let mut a = AssistantAdmission::new();
        let body = json!({ "requestId": "duplicate", "uid": "user", "tokenBudget": 2, "costBudgetMicrousd": 1 });
        let t0 = 1000;
        assert_eq!(a.dispatch(l, t0, "POST", "/admit", &body).status, 200);
        assert_eq!(a.dispatch(l, t0, "POST", "/admit", &body).status, 200);
        assert_eq!(
            a.dispatch(l, t0, "POST", "/release", &json!({ "requestId": "duplicate" }))
                .status,
            200
        );
        assert_eq!(
            a.dispatch(l, t0, "POST", "/release", &json!({ "requestId": "duplicate" }))
                .status,
            200
        );
        assert_eq!(a.dispatch(l, t0, "POST", "/admit", &body).status, 429);
        // Advance beyond the window: the stale reservation is pruned and the
        // budget rolls over.
        let t1 = t0 + 1100;
        assert_eq!(a.dispatch(l, t1, "POST", "/admit", &body).status, 200);
    }

    #[test]
    fn settles_to_overrun_and_blocks_dense_traffic() {
        let l = Limits {
            uid_in_flight: 100,
            global_in_flight: 100,
            uid_tokens: 12,
            global_tokens: 12,
            uid_cost_microusd: 12,
            global_cost_microusd: 12,
            ..limits()
        };
        let mut a = AssistantAdmission::new();
        assert_eq!(
            a.dispatch(
                l,
                1000,
                "POST",
                "/admit",
                &json!({ "requestId": "overrun", "uid": "user", "tokenBudget": 1, "costBudgetMicrousd": 1 })
            )
            .status,
            200
        );
        assert_eq!(
            a.dispatch(
                l,
                1000,
                "POST",
                "/settle",
                &json!({ "requestId": "overrun", "tokenBudget": 12, "costBudgetMicrousd": 12 })
            )
            .status,
            200
        );
        for i in 0..12 {
            assert_eq!(admit(&mut a, l, 1000, &format!("dense-{i}"), "user"), 429);
        }
    }

    #[test]
    fn invalid_bodies_yield_400_and_wrong_method_405() {
        let mut a = AssistantAdmission::new();
        let l = limits();
        assert_eq!(
            a.dispatch(l, 1, "GET", "/admit", &json!({})).status,
            405
        );
        assert_eq!(
            a.dispatch(l, 1, "POST", "/admit", &json!({ "uid": "u" })).status,
            400
        );
        assert_eq!(
            a.dispatch(l, 1, "POST", "/admit", &json!({ "requestId": "x", "uid": "u", "tokenBudget": 0, "costBudgetMicrousd": 1 })).status,
            400
        );
        assert_eq!(
            a.dispatch(l, 1, "POST", "/unknown", &json!({ "requestId": "x" })).status,
            404
        );
    }

    #[test]
    fn window_helper() {
        assert_eq!(window_ms_from_seconds(Some("1")), 1000);
        assert_eq!(window_ms_from_seconds(None), 3_600_000);
    }
}
