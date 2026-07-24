//! Pure helpers from `worker/src/currents-refresh.ts`.
//!
//! The full AI refresh pipeline (`refreshCurrents`, OpenRouter drafts,
//! `POST /v1/currents/refresh`) is **not** wired yet — see PORT_STATUS.md.
//! This module ports the host-testable decision surface so the route glue can
//! land without re-deriving heuristics.

pub const MIN_CHECK_INTERVAL_MS: i64 = 15 * 60 * 1000;
pub const MIN_REGENERATE_INTERVAL_MS: i64 = 4 * 60 * 60 * 1000;
pub const STALE_CURRENT_AGE_MS: i64 = 6 * 60 * 60 * 1000;
pub const REFRESH_BATCH_SIZE: usize = 5;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CurrentContentKind {
    AgentAction,
    HumanAction,
    Awareness,
}

impl CurrentContentKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::AgentAction => "agent_action",
            Self::HumanAction => "human_action",
            Self::Awareness => "awareness",
        }
    }
}

/// `normalizeContentKind` — unknown values collapse to `human_action`.
pub fn normalize_content_kind(value: &str) -> CurrentContentKind {
    match value {
        "agent_action" => CurrentContentKind::AgentAction,
        "human_action" => CurrentContentKind::HumanAction,
        "awareness" => CurrentContentKind::Awareness,
        _ => CurrentContentKind::HumanAction,
    }
}

#[derive(Debug, Clone)]
pub struct RefreshContext {
    pub surfaced_count: usize,
    pub newest_updated_at: Option<i64>,
    pub memory_watermark: i64,
}

#[derive(Debug, Clone)]
pub struct RefreshState {
    pub last_checked_at: i64,
    pub last_regenerated_at: i64,
    pub memory_watermark: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeuristicDecision {
    pub refresh: bool,
    pub reason: &'static str,
}

/// `heuristicNeedsRefresh` — pure gate before the AI confirm/draft path.
pub fn heuristic_needs_refresh(
    context: &RefreshContext,
    state: &RefreshState,
    now: i64,
    force: bool,
) -> HeuristicDecision {
    if force {
        return HeuristicDecision {
            refresh: true,
            reason: "forced",
        };
    }
    if context.surfaced_count == 0 {
        return HeuristicDecision {
            refresh: true,
            reason: "no_surfaced_currents",
        };
    }
    if context
        .newest_updated_at
        .is_some_and(|updated| now - updated >= STALE_CURRENT_AGE_MS)
    {
        return HeuristicDecision {
            refresh: true,
            reason: "currents_stale",
        };
    }
    if context.memory_watermark > state.memory_watermark {
        return HeuristicDecision {
            refresh: true,
            reason: "new_memory",
        };
    }
    if state.last_regenerated_at > 0
        && now - state.last_regenerated_at >= MIN_REGENERATE_INTERVAL_MS
    {
        return HeuristicDecision {
            refresh: true,
            reason: "regenerate_ttl",
        };
    }
    HeuristicDecision {
        refresh: false,
        reason: "fresh",
    }
}

/// `check_ttl` short-circuit used by `refreshCurrents` before heuristics.
pub fn within_check_ttl(state: &RefreshState, now: i64, force: bool) -> bool {
    !force && state.last_checked_at > 0 && now - state.last_checked_at < MIN_CHECK_INTERVAL_MS
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_mixed_content_kinds() {
        assert_eq!(
            normalize_content_kind("agent_action"),
            CurrentContentKind::AgentAction
        );
        assert_eq!(
            normalize_content_kind("human_action"),
            CurrentContentKind::HumanAction
        );
        assert_eq!(
            normalize_content_kind("awareness"),
            CurrentContentKind::Awareness
        );
        assert_eq!(
            normalize_content_kind("review"),
            CurrentContentKind::HumanAction
        );
    }

    #[test]
    fn heuristic_triggers_when_currents_stale() {
        let now = 1_000_000;
        let outcome = heuristic_needs_refresh(
            &RefreshContext {
                surfaced_count: 2,
                newest_updated_at: Some(now - STALE_CURRENT_AGE_MS - 1),
                memory_watermark: 500,
            },
            &RefreshState {
                last_checked_at: 0,
                last_regenerated_at: now - MIN_REGENERATE_INTERVAL_MS - 1,
                memory_watermark: 400,
            },
            now,
            false,
        );
        assert!(outcome.refresh);
        assert_eq!(outcome.reason, "currents_stale");
    }

    #[test]
    fn heuristic_skips_fresh_currents() {
        let now = 2_000_000;
        let outcome = heuristic_needs_refresh(
            &RefreshContext {
                surfaced_count: 1,
                newest_updated_at: Some(now - 60_000),
                memory_watermark: 500,
            },
            &RefreshState {
                last_checked_at: now - 1_000,
                last_regenerated_at: now - 60_000,
                memory_watermark: 500,
            },
            now,
            false,
        );
        assert!(!outcome.refresh);
        assert_eq!(outcome.reason, "fresh");
    }

    #[test]
    fn check_ttl_honours_force() {
        let state = RefreshState {
            last_checked_at: 1_000,
            last_regenerated_at: 0,
            memory_watermark: 0,
        };
        assert!(within_check_ttl(
            &state,
            1_000 + MIN_CHECK_INTERVAL_MS - 1,
            false
        ));
        assert!(!within_check_ttl(
            &state,
            1_000 + MIN_CHECK_INTERVAL_MS - 1,
            true
        ));
    }
}
