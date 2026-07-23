//! Pure port of the `RateLimiter` Durable Object (`worker/src/rate-limit.ts`):
//! a fixed-window request counter plus a short-lived refresh mutex. This module
//! is canonical for the crate — kept self-contained so it can back both the AI
//! routes (voice/asr rate limits) and any other consumer without coupling.

use serde_json::Value;

use crate::assistant_admission::Outcome;

/// Persisted counter window: `{ count, windowStart }` in the TS storage.
#[derive(Default)]
pub struct RateLimiter {
    window: Option<(i64, i64)>, // (count, window_start)
    lock_until: Option<i64>,
}

pub struct ConsumeResult {
    pub allowed: bool,
    pub retry_after: i64,
}

impl RateLimiter {
    pub fn new() -> Self {
        Self::default()
    }

    /// Port of `consume`: increments the fixed-window counter, rolling the
    /// window when `windowMs` has elapsed.
    pub fn consume(&mut self, now: i64, limit: i64, window_ms: i64) -> ConsumeResult {
        let start_new = match self.window {
            None => true,
            Some((_, window_start)) => now - window_start >= window_ms,
        };
        let window_start = if start_new {
            now
        } else {
            self.window.unwrap().1
        };
        let count = if start_new {
            1
        } else {
            self.window.unwrap().0 + 1
        };
        self.window = Some((count, window_start));
        let allowed = count <= limit;
        let retry_after = (((window_start + window_ms - now) as f64 / 1000.0).ceil() as i64).max(1);
        ConsumeResult {
            allowed,
            retry_after,
        }
    }

    /// Port of `acquireLock`: succeeds only when no unexpired lock is held.
    pub fn acquire_lock(&mut self, now: i64, ttl_ms: i64) -> bool {
        if let Some(until) = self.lock_until {
            if until > now {
                return false;
            }
        }
        self.lock_until = Some(now + ttl_ms);
        true
    }

    pub fn release_lock(&mut self) {
        self.lock_until = None;
    }

    /// Route dispatch mirroring the DO `fetch` handler, including the default
    /// `limit=60`/`windowMs=60000`/`ttlMs=15000` fallbacks.
    pub fn dispatch(&mut self, now: i64, method: &str, path: &str, body: &Value) -> Outcome {
        if method != "POST" {
            return Outcome {
                status: 405,
                body: Value::Null,
                retry_after: None,
            };
        }
        match path {
            "/consume" => {
                let limit = positive_number(body.get("limit")).unwrap_or(60);
                let window_ms = positive_number(body.get("windowMs")).unwrap_or(60_000);
                let result = self.consume(now, limit, window_ms);
                Outcome {
                    status: if result.allowed { 200 } else { 429 },
                    body: serde_json::json!({
                        "allowed": result.allowed,
                        "retryAfter": result.retry_after,
                    }),
                    retry_after: if result.allowed {
                        None
                    } else {
                        Some(result.retry_after.to_string())
                    },
                }
            }
            "/acquire-lock" => {
                let ttl_ms = positive_number(body.get("ttlMs")).unwrap_or(15_000);
                let acquired = self.acquire_lock(now, ttl_ms);
                Outcome {
                    status: if acquired { 200 } else { 409 },
                    body: serde_json::json!({ "acquired": acquired }),
                    retry_after: None,
                }
            }
            "/release-lock" => {
                self.release_lock();
                Outcome {
                    status: 200,
                    body: serde_json::json!({ "released": true }),
                    retry_after: None,
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

/// `typeof value === "number" && value > 0 ? value : fallback` — only accepts
/// a JSON number (not a numeric string), matching the TS type guard.
fn positive_number(value: Option<&Value>) -> Option<i64> {
    let n = value?.as_f64()?;
    if n > 0.0 {
        Some(n as i64)
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn fixed_window_allows_up_to_limit_then_refuses() {
        let mut r = RateLimiter::new();
        for i in 1..=10 {
            let res = r.consume(1000, 10, 60_000);
            assert!(res.allowed, "call {i} should be allowed");
        }
        let over = r.consume(1000, 10, 60_000);
        assert!(!over.allowed);
        assert!(over.retry_after >= 1);
        // Window rolls after windowMs.
        let rolled = r.consume(1000 + 60_000, 10, 60_000);
        assert!(rolled.allowed);
    }

    #[test]
    fn lock_is_exclusive_until_ttl() {
        let mut r = RateLimiter::new();
        assert!(r.acquire_lock(1000, 15_000));
        assert!(!r.acquire_lock(1000, 15_000));
        // After the TTL, it can be re-acquired.
        assert!(r.acquire_lock(1000 + 15_000, 15_000));
        r.release_lock();
        assert!(r.acquire_lock(1000 + 15_000, 15_000));
    }

    #[test]
    fn dispatch_defaults_and_statuses() {
        let mut r = RateLimiter::new();
        let consume = r.dispatch(1000, "POST", "/consume", &json!({}));
        assert_eq!(consume.status, 200);
        assert_eq!(consume.body["allowed"], json!(true));
        assert_eq!(r.dispatch(1000, "GET", "/consume", &json!({})).status, 405);
        assert_eq!(r.dispatch(1000, "POST", "/nope", &json!({})).status, 404);
        let lock = r.dispatch(1000, "POST", "/acquire-lock", &json!({}));
        assert_eq!(lock.status, 200);
        let again = r.dispatch(1000, "POST", "/acquire-lock", &json!({}));
        assert_eq!(again.status, 409);
    }
}
