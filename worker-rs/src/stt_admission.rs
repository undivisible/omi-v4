//! Pure port of the `SttAdmission` Durable Object state machine
//! (`worker/src/stt-admission.ts`): a reservation ledger with in-flight,
//! seconds and cost budgets, plus the acquisition-token claim/release protocol
//! and the deadline alarm. Modelled over an in-memory table so the race
//! assertions from the TS suite run under `cargo test`.

use serde_json::Value;

use crate::assistant_admission::Outcome;
use crate::jsnum::positive_integer_str;

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub window_ms: i64,
    pub uid_in_flight: i64,
    pub global_in_flight: i64,
    pub uid_seconds: i64,
    pub global_seconds: i64,
    pub uid_cost_microusd: i64,
    pub global_cost_microusd: i64,
    pub claim_deadline_ms: i64,
}

impl Limits {
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Self {
        let claim_deadline_seconds =
            positive_integer_str(get("STT_CLAIM_DEADLINE_SECONDS").as_deref()).unwrap_or(60);
        Limits {
            window_ms: positive_integer_str(get("STT_BUDGET_WINDOW_SECONDS").as_deref())
                .unwrap_or(3600)
                * 1000,
            uid_in_flight: positive_integer_str(get("STT_UID_IN_FLIGHT_LIMIT").as_deref())
                .unwrap_or(2),
            global_in_flight: positive_integer_str(get("STT_GLOBAL_IN_FLIGHT_LIMIT").as_deref())
                .unwrap_or(64),
            uid_seconds: positive_integer_str(get("STT_UID_SECONDS_BUDGET").as_deref())
                .unwrap_or(3600),
            global_seconds: positive_integer_str(get("STT_GLOBAL_SECONDS_BUDGET").as_deref())
                .unwrap_or(115_200),
            uid_cost_microusd: positive_integer_str(get("STT_UID_COST_BUDGET_MICROUSD").as_deref())
                .unwrap_or(300_000),
            global_cost_microusd: positive_integer_str(
                get("STT_GLOBAL_COST_BUDGET_MICROUSD").as_deref(),
            )
            .unwrap_or(9_600_000),
            claim_deadline_ms: claim_deadline_seconds.min(300) * 1000,
        }
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
struct Reservation {
    session_id: String,
    uid: String,
    created_at: i64,
    reserved_seconds: i64,
    cost_budget_microusd: i64,
    in_flight: i64,
    claim_by: Option<i64>,
    acquisition_token: String,
}

#[derive(Default, serde::Serialize, serde::Deserialize)]
pub struct SttAdmission {
    reservations: Vec<Reservation>,
}

impl SttAdmission {
    pub fn new() -> Self {
        Self::default()
    }

    /// The earliest pending claim deadline, used by the DO glue to schedule
    /// the next storage alarm (mirrors `scheduleNextAlarm`'s MIN query).
    pub fn next_alarm(&self) -> Option<i64> {
        self.reservations
            .iter()
            .filter(|r| r.in_flight == 1 && r.claim_by.is_some())
            .filter_map(|r| r.claim_by)
            .min()
    }

    /// Deadline alarm: expire in-flight reservations whose claim window has
    /// lapsed. Mirrors the DO `alarm()` UPDATE.
    pub fn alarm(&mut self, now: i64) {
        for r in &mut self.reservations {
            if r.in_flight == 1 && r.claim_by.map(|c| c <= now).unwrap_or(false) {
                r.in_flight = 0;
                r.claim_by = None;
            }
        }
    }

    fn release(&mut self, session_id: &str, uid: &str, token: &str) -> Outcome {
        for r in &mut self.reservations {
            if r.session_id == session_id && r.uid == uid && r.acquisition_token == token {
                r.in_flight = 0;
                r.claim_by = None;
            }
        }
        Outcome {
            status: 200,
            body: serde_json::json!({ "released": true }),
            retry_after: None,
        }
    }

    fn claim(&mut self, session_id: &str, uid: &str, token: &str, now: i64) -> Outcome {
        let mut written = 0;
        for r in &mut self.reservations {
            if r.session_id == session_id
                && r.uid == uid
                && r.acquisition_token == token
                && r.in_flight == 1
                && r.claim_by.map(|c| c > now).unwrap_or(false)
            {
                r.claim_by = None;
                written += 1;
            }
        }
        if written != 1 {
            for r in &mut self.reservations {
                if r.session_id == session_id
                    && r.uid == uid
                    && r.acquisition_token == token
                    && r.in_flight == 1
                    && r.claim_by.map(|c| c <= now).unwrap_or(false)
                {
                    r.in_flight = 0;
                    r.claim_by = None;
                }
            }
        }
        Outcome {
            status: 200,
            body: serde_json::json!({ "claimed": written == 1 }),
            retry_after: None,
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn admit(
        &mut self,
        limits: Limits,
        now: i64,
        session_id: &str,
        uid: &str,
        reserved_seconds: i64,
        cost_budget_microusd: i64,
        new_token: &str,
    ) -> Outcome {
        self.reservations
            .retain(|r| r.created_at > now - limits.window_ms);

        let duplicate = self
            .reservations
            .iter()
            .find(|r| r.session_id == session_id)
            .cloned();

        if let Some(dup) = &duplicate {
            if dup.uid != uid
                || dup.reserved_seconds != reserved_seconds
                || dup.cost_budget_microusd != cost_budget_microusd
            {
                return Outcome {
                    status: 409,
                    body: serde_json::json!({ "error": "Admission conflict" }),
                    retry_after: None,
                };
            }
        }

        let mut global_in_flight = 0i64;
        let mut uid_in_flight = 0i64;
        let mut global_seconds = 0i64;
        let mut uid_seconds = 0i64;
        let mut global_cost = 0i64;
        let mut uid_cost = 0i64;
        let mut oldest: Option<i64> = None;
        for r in &self.reservations {
            global_in_flight += r.in_flight;
            global_seconds += r.reserved_seconds;
            global_cost += r.cost_budget_microusd;
            if r.uid == uid {
                uid_in_flight += r.in_flight;
                uid_seconds += r.reserved_seconds;
                uid_cost += r.cost_budget_microusd;
            }
            oldest = Some(oldest.map_or(r.created_at, |o| o.min(r.created_at)));
        }

        let exceeds = global_in_flight >= limits.global_in_flight
            || uid_in_flight >= limits.uid_in_flight
            || global_seconds + reserved_seconds > limits.global_seconds
            || uid_seconds + reserved_seconds > limits.uid_seconds
            || global_cost + cost_budget_microusd > limits.global_cost_microusd
            || uid_cost + cost_budget_microusd > limits.uid_cost_microusd;

        let retry_after =
            (((oldest.unwrap_or(now) + limits.window_ms - now) as f64 / 1000.0).ceil() as i64)
                .max(1);

        if let Some(dup) = duplicate {
            if dup.in_flight == 1 {
                return Outcome {
                    status: 200,
                    body: serde_json::json!({
                        "admitted": true,
                        "duplicate": true,
                        "acquisitionToken": dup.acquisition_token,
                    }),
                    retry_after: None,
                };
            }
            if global_in_flight >= limits.global_in_flight || uid_in_flight >= limits.uid_in_flight
            {
                return Outcome {
                    status: 429,
                    body: serde_json::json!({ "admitted": false, "retryAfter": retry_after }),
                    retry_after: Some(retry_after.to_string()),
                };
            }
            for r in &mut self.reservations {
                if r.session_id == session_id && r.uid == uid && r.in_flight == 0 {
                    r.in_flight = 1;
                    r.claim_by = Some(now + limits.claim_deadline_ms);
                    r.acquisition_token = new_token.to_string();
                }
            }
            return Outcome {
                status: 200,
                body: serde_json::json!({
                    "admitted": true,
                    "duplicate": true,
                    "reacquired": true,
                    "acquisitionToken": new_token,
                }),
                retry_after: None,
            };
        }

        if exceeds {
            return Outcome {
                status: 429,
                body: serde_json::json!({ "admitted": false, "retryAfter": retry_after }),
                retry_after: Some(retry_after.to_string()),
            };
        }

        self.reservations.push(Reservation {
            session_id: session_id.to_string(),
            uid: uid.to_string(),
            created_at: now,
            reserved_seconds,
            cost_budget_microusd,
            in_flight: 1,
            claim_by: Some(now + limits.claim_deadline_ms),
            acquisition_token: new_token.to_string(),
        });
        Outcome {
            status: 200,
            body: serde_json::json!({
                "admitted": true,
                "retryAfter": 0,
                "acquisitionToken": new_token,
            }),
            retry_after: None,
        }
    }

    /// Dispatch a DO request. `new_token` is consumed only by the admit paths
    /// that mint a fresh acquisition token (matching `crypto.randomUUID()`).
    pub fn dispatch(
        &mut self,
        limits: Limits,
        now: i64,
        method: &str,
        path: &str,
        body: &Value,
        new_token: &str,
    ) -> Outcome {
        if method != "POST" {
            return Outcome {
                status: 405,
                body: Value::Null,
                retry_after: None,
            };
        }
        let session_id = body.get("sessionId").and_then(Value::as_str);
        let invalid = || Outcome {
            status: 400,
            body: serde_json::json!({ "error": "Invalid request" }),
            retry_after: None,
        };
        match path {
            "/release" => {
                let uid = body.get("uid").and_then(Value::as_str);
                let token = body.get("acquisitionToken").and_then(Value::as_str);
                match (session_id, uid, token) {
                    (Some(s), Some(u), Some(t)) => self.release(s, u, t),
                    _ => invalid(),
                }
            }
            "/claim" => {
                let uid = body.get("uid").and_then(Value::as_str);
                let token = body.get("acquisitionToken").and_then(Value::as_str);
                match (session_id, uid, token) {
                    (Some(s), Some(u), Some(t)) => self.claim(s, u, t, now),
                    _ => invalid(),
                }
            }
            "/admit" => {
                let uid = body.get("uid").and_then(Value::as_str);
                let reserved = body
                    .get("reservedSeconds")
                    .and_then(crate::jsnum::positive_integer_value);
                let cost = body
                    .get("costBudgetMicrousd")
                    .and_then(crate::jsnum::positive_integer_value);
                match (session_id, uid, reserved, cost) {
                    (Some(s), Some(u), Some(r), Some(c)) => {
                        self.admit(limits, now, s, u, r, c, new_token)
                    }
                    _ => invalid(),
                }
            }
            _ => Outcome {
                status: 404,
                body: Value::Null,
                retry_after: None,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn limits() -> Limits {
        Limits::from_env(|k| {
            match k {
                "STT_BUDGET_WINDOW_SECONDS" => Some("3600"),
                "STT_UID_IN_FLIGHT_LIMIT" => Some("2"),
                "STT_GLOBAL_IN_FLIGHT_LIMIT" => Some("10"),
                "STT_UID_SECONDS_BUDGET" => Some("1800"),
                "STT_GLOBAL_SECONDS_BUDGET" => Some("9000"),
                "STT_UID_COST_BUDGET_MICROUSD" => Some("150000"),
                "STT_GLOBAL_COST_BUDGET_MICROUSD" => Some("750000"),
                "STT_CLAIM_DEADLINE_SECONDS" => Some("60"),
                _ => None,
            }
            .map(str::to_string)
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn admit(
        a: &mut SttAdmission,
        l: Limits,
        now: i64,
        session: &str,
        uid: &str,
        seconds: i64,
        cost: i64,
        token: &str,
    ) -> Outcome {
        a.dispatch(
            l,
            now,
            "POST",
            "/admit",
            &json!({ "sessionId": session, "uid": uid, "reservedSeconds": seconds, "costBudgetMicrousd": cost }),
            token,
        )
    }

    #[test]
    fn enforces_per_user_reservations() {
        let l = Limits {
            uid_in_flight: 1,
            ..limits()
        };
        let mut a = SttAdmission::new();
        let first = admit(&mut a, l, 1000, "one", "alpha", 900, 75000, "t1");
        let second = admit(&mut a, l, 1000, "two", "alpha", 900, 75000, "t2");
        assert_eq!(first.status, 200);
        assert_eq!(second.status, 429);
        assert!(second.retry_after.is_some());
    }

    #[test]
    fn duplicate_admission_is_idempotent() {
        let l = limits();
        let mut a = SttAdmission::new();
        assert_eq!(
            admit(&mut a, l, 1000, "same", "alpha", 900, 75000, "t1").status,
            200
        );
        let dup = admit(&mut a, l, 1000, "same", "alpha", 900, 75000, "t2");
        assert_eq!(dup.status, 200);
        assert_eq!(dup.body["admitted"], json!(true));
        assert_eq!(dup.body["duplicate"], json!(true));
        // The duplicate returns the ORIGINAL token, not the freshly-minted one.
        assert_eq!(dup.body["acquisitionToken"], json!("t1"));
        assert_eq!(
            admit(&mut a, l, 1000, "next", "alpha", 900, 75000, "t3").status,
            200
        );
        assert_eq!(
            admit(&mut a, l, 1000, "over", "beta", 900, 75000, "t4").status,
            200
        );
    }

    #[test]
    fn release_is_idempotent_and_retains_budget_then_reacquires() {
        let l = Limits {
            uid_in_flight: 1,
            ..limits()
        };
        let mut a = SttAdmission::new();
        assert_eq!(
            admit(&mut a, l, 1000, "released", "alpha", 900, 75000, "t1").status,
            200
        );
        // Release with the wrong uid is a no-op but still 200.
        assert_eq!(
            a.dispatch(
                l,
                1000,
                "POST",
                "/release",
                &json!({ "sessionId": "released", "uid": "beta", "acquisitionToken": "t1" }),
                ""
            )
            .status,
            200
        );
        // Budget still reserved -> a new tiny session is blocked (uid in-flight 1).
        assert_eq!(
            admit(&mut a, l, 1000, "still-blocked", "alpha", 1, 1, "t2").status,
            429
        );
        // Duplicate releases: both 200.
        for _ in 0..2 {
            assert_eq!(
                a.dispatch(
                    l,
                    1000,
                    "POST",
                    "/release",
                    &json!({ "sessionId": "released", "uid": "alpha", "acquisitionToken": "t1" }),
                    ""
                )
                .status,
                200
            );
        }
        // Reacquire the released reservation.
        let reacq = admit(&mut a, l, 1000, "released", "alpha", 900, 75000, "t5");
        assert_eq!(reacq.status, 200);
        assert_eq!(reacq.body["duplicate"], json!(true));
        assert_eq!(reacq.body["reacquired"], json!(true));
        assert_eq!(reacq.body["acquisitionToken"], json!("t5"));
        assert_eq!(
            admit(
                &mut a,
                l,
                1000,
                "blocked-by-reacquired",
                "alpha",
                1,
                1,
                "t6"
            )
            .status,
            429
        );
        // Release the reacquired one (with its new token) then admit again.
        assert_eq!(
            a.dispatch(
                l,
                1000,
                "POST",
                "/release",
                &json!({ "sessionId": "released", "uid": "alpha", "acquisitionToken": "t5" }),
                ""
            )
            .status,
            200
        );
        assert_eq!(
            admit(&mut a, l, 1000, "next", "alpha", 1, 1, "t7").status,
            200
        );
        // Over the seconds budget now (900 reserved + 900 > 1800).
        assert_eq!(
            admit(&mut a, l, 1000, "over-budget", "alpha", 900, 75000, "t8").status,
            429
        );
    }

    #[test]
    fn abandoned_claim_deadline_released_but_claimed_session_preserved() {
        let l = Limits {
            uid_in_flight: 1,
            claim_deadline_ms: 1000,
            ..limits()
        };
        let mut a = SttAdmission::new();
        assert_eq!(
            admit(&mut a, l, 1000, "abandoned", "alpha", 900, 75000, "t1").status,
            200
        );
        // Deadline lapses -> alarm expires the in-flight reservation.
        a.alarm(2200);
        assert_eq!(
            admit(&mut a, l, 2200, "after-alarm", "alpha", 1, 1, "t2").status,
            200
        );
        // Claim within the new deadline.
        let claimed = a.dispatch(
            l,
            2200,
            "POST",
            "/claim",
            &json!({ "sessionId": "after-alarm", "uid": "alpha", "acquisitionToken": "t2" }),
            "",
        );
        assert_eq!(claimed.status, 200);
        assert_eq!(claimed.body["claimed"], json!(true));
        // A later alarm must NOT expire the claimed session (claim_by cleared).
        a.alarm(3400);
        assert_eq!(
            admit(&mut a, l, 3400, "still-blocked", "alpha", 1, 1, "t3").status,
            429
        );
    }

    #[test]
    fn late_claim_rejected_and_stale_release_ignored() {
        let l = Limits {
            uid_in_flight: 1,
            claim_deadline_ms: 1000,
            ..limits()
        };
        let mut a = SttAdmission::new();
        let first = admit(&mut a, l, 1000, "generation", "alpha", 900, 75000, "gen1");
        assert_eq!(first.body["acquisitionToken"], json!("gen1"));
        // Deadline lapses.
        a.alarm(2200);
        let late = a.dispatch(
            l,
            2200,
            "POST",
            "/claim",
            &json!({ "sessionId": "generation", "uid": "alpha", "acquisitionToken": "gen1" }),
            "",
        );
        assert_eq!(late.body, json!({ "claimed": false }));
        // Reacquire mints a new generation token.
        let second = admit(&mut a, l, 2200, "generation", "alpha", 900, 75000, "gen2");
        assert_eq!(second.body["reacquired"], json!(true));
        assert_eq!(second.body["acquisitionToken"], json!("gen2"));
        // A delayed release from the OLD token must not free the new generation.
        assert_eq!(
            a.dispatch(
                l,
                2200,
                "POST",
                "/release",
                &json!({ "sessionId": "generation", "uid": "alpha", "acquisitionToken": "gen1" }),
                ""
            )
            .status,
            200
        );
        assert_eq!(
            admit(
                &mut a,
                l,
                2200,
                "still-blocked-by-new-generation",
                "alpha",
                1,
                1,
                "t9"
            )
            .status,
            429
        );
    }
}
