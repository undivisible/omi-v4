//! Pure helpers from `worker/src/currents-refresh.ts`.
//!
//! Host-testable decision and draft parsing live here; the D1/OpenRouter pipeline
//! is wired from `routes_memory/wasm_glue.rs`.

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
pub struct MemoryLine {
    pub evidence_id: String,
    pub source_kind: Option<String>,
    pub quote: String,
    pub content: String,
    pub recorded_at: i64,
}

#[derive(Debug, Clone)]
pub struct RefreshContext {
    pub surfaced_count: usize,
    pub newest_updated_at: Option<i64>,
    pub memory_watermark: i64,
    pub existing_titles: Vec<String>,
    pub memory_lines: Vec<MemoryLine>,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeneratedDraft {
    pub content_kind: CurrentContentKind,
    pub title: String,
    pub summary: String,
    pub reason: String,
    pub instruction: String,
    pub evidence_id: String,
    pub tool: Option<String>,
}

/// `collapse` — whitespace-normalised text.
pub fn collapse(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `parseJsonObject` — accepts bare JSON or ```json fenced blocks.
pub fn parse_json_object(text: &str) -> Option<serde_json::Map<String, serde_json::Value>> {
    let trimmed = text.trim();
    let candidate = if trimmed.starts_with("```") {
        let mut inner = trimmed.strip_prefix("```").unwrap_or(trimmed);
        inner = inner.strip_prefix("json").unwrap_or(inner);
        inner = inner.trim();
        inner.strip_suffix("```").map(str::trim).unwrap_or(inner)
    } else {
        trimmed
    };
    let value: serde_json::Value = serde_json::from_str(candidate).ok()?;
    value.as_object().cloned()
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

fn infer_kind(line: &MemoryLine) -> CurrentContentKind {
    let kind = line.source_kind.as_deref().unwrap_or("").to_lowercase();
    let text = format!("{} {}", line.content, line.quote).to_lowercase();
    if kind.contains("calendar")
        || kind.contains("meeting")
        || text.contains("meeting")
        || text.contains("standup")
        || text.contains("sync")
        || text.contains("deadline")
        || text.contains("event")
        || text.contains("calendar")
    {
        return CurrentContentKind::Awareness;
    }
    if kind.contains("integration")
        || text.contains("email")
        || text.contains("send")
        || text.contains("schedule")
        || text.contains("create task")
        || text.contains("remind")
        || text.contains("notify")
    {
        return CurrentContentKind::AgentAction;
    }
    CurrentContentKind::HumanAction
}

/// `heuristicDrafts` — fallback when AI draft generation fails.
pub fn heuristic_drafts(context: &RefreshContext) -> Vec<GeneratedDraft> {
    let mut seen: std::collections::HashSet<String> = context
        .existing_titles
        .iter()
        .map(|title| title.to_lowercase())
        .collect();
    let mut drafts = Vec::new();
    for line in &context.memory_lines {
        let content = collapse(&line.content);
        let quote = collapse(&line.quote);
        if content.is_empty() || quote.is_empty() {
            continue;
        }
        let title = collapse(&content);
        let title = if title.chars().count() > 120 {
            title.chars().take(120).collect()
        } else {
            title
        };
        if seen.contains(&title.to_lowercase()) {
            continue;
        }
        seen.insert(title.to_lowercase());
        let content_kind = infer_kind(line);
        let summary = if content.chars().count() > 500 {
            content.chars().take(500).collect()
        } else {
            content.clone()
        };
        let reason = format!("Based on: {quote}");
        let reason = if reason.chars().count() > 500 {
            reason.chars().take(500).collect()
        } else {
            reason
        };
        let instruction = match content_kind {
            CurrentContentKind::AgentAction => {
                format!("Take the smallest automated step toward: {content}")
            }
            CurrentContentKind::Awareness => format!("Keep in mind for today: {content}"),
            CurrentContentKind::HumanAction => format!("Do the smallest next step: {content}"),
        };
        let instruction = if instruction.chars().count() > 500 {
            instruction.chars().take(500).collect()
        } else {
            instruction
        };
        drafts.push(GeneratedDraft {
            content_kind,
            title,
            summary,
            reason,
            instruction,
            evidence_id: line.evidence_id.clone(),
            tool: (content_kind == CurrentContentKind::AgentAction)
                .then(|| "assistant".to_string()),
        });
        if drafts.len() >= REFRESH_BATCH_SIZE {
            break;
        }
    }
    drafts
}

/// `parseDrafts` — validates AI output against allowed evidence ids.
pub fn parse_drafts(
    content: &str,
    allowed_evidence: &std::collections::HashSet<String>,
) -> Vec<GeneratedDraft> {
    let Some(parsed) = parse_json_object(content) else {
        return Vec::new();
    };
    let Some(items) = parsed.get("items").and_then(|v| v.as_array()) else {
        return Vec::new();
    };
    let mut drafts = Vec::new();
    for item in items {
        let Some(row) = item.as_object() else {
            continue;
        };
        let evidence_id = row
            .get("evidenceId")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .unwrap_or("");
        let title = row
            .get("title")
            .and_then(|v| v.as_str())
            .map(collapse)
            .unwrap_or_default();
        let summary = row
            .get("summary")
            .and_then(|v| v.as_str())
            .map(collapse)
            .unwrap_or_default();
        let reason = row
            .get("reason")
            .and_then(|v| v.as_str())
            .map(collapse)
            .unwrap_or_default();
        let instruction = row
            .get("instruction")
            .and_then(|v| v.as_str())
            .map(collapse)
            .unwrap_or_default();
        if !allowed_evidence.contains(evidence_id)
            || title.is_empty()
            || summary.is_empty()
            || reason.is_empty()
            || instruction.is_empty()
        {
            continue;
        }
        let title = if title.chars().count() > 120 {
            title.chars().take(120).collect()
        } else {
            title
        };
        let summary = if summary.chars().count() > 500 {
            summary.chars().take(500).collect()
        } else {
            summary
        };
        let reason = if reason.chars().count() > 500 {
            reason.chars().take(500).collect()
        } else {
            reason
        };
        let instruction = if instruction.chars().count() > 500 {
            instruction.chars().take(500).collect()
        } else {
            instruction
        };
        let tool = row
            .get("tool")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(|s| {
                if s.chars().count() > 120 {
                    s.chars().take(120).collect()
                } else {
                    s.to_string()
                }
            });
        drafts.push(GeneratedDraft {
            content_kind: normalize_content_kind(
                row.get("contentKind")
                    .and_then(|v| v.as_str())
                    .unwrap_or(""),
            ),
            title,
            summary,
            reason,
            instruction,
            evidence_id: evidence_id.to_string(),
            tool,
        });
        if drafts.len() >= REFRESH_BATCH_SIZE {
            break;
        }
    }
    drafts
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

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
                existing_titles: vec!["One".into(), "Two".into()],
                memory_lines: vec![],
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
                existing_titles: vec!["Fresh".into()],
                memory_lines: vec![],
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

    #[test]
    fn parse_drafts_accepts_fenced_json() {
        let allowed: HashSet<String> = ["ev-1", "ev-2"].into_iter().map(str::to_string).collect();
        let content = r#"```json
{"items":[{"contentKind":"agent_action","title":"Draft reply","summary":"s","reason":"r","instruction":"i","evidenceId":"ev-1","tool":"assistant"},{"contentKind":"awareness","title":"Standup","summary":"s","reason":"r","instruction":"i","evidenceId":"ev-2"}]}
```"#;
        let drafts = parse_drafts(content, &allowed);
        assert_eq!(drafts.len(), 2);
        assert_eq!(drafts[0].content_kind, CurrentContentKind::AgentAction);
        assert_eq!(drafts[0].title, "Draft reply");
        assert_eq!(drafts[1].content_kind, CurrentContentKind::Awareness);
    }

    #[test]
    fn heuristic_drafts_skip_duplicate_titles() {
        let context = RefreshContext {
            surfaced_count: 1,
            newest_updated_at: Some(1_000),
            memory_watermark: 500,
            existing_titles: vec!["Existing task".into()],
            memory_lines: vec![
                MemoryLine {
                    evidence_id: "ev-1".into(),
                    source_kind: Some("integration".into()),
                    quote: "please send the report".into(),
                    content: "Existing task".into(),
                    recorded_at: 400,
                },
                MemoryLine {
                    evidence_id: "ev-2".into(),
                    source_kind: None,
                    quote: "follow up with Alex".into(),
                    content: "Email Alex about the proposal".into(),
                    recorded_at: 450,
                },
            ],
        };
        let drafts = heuristic_drafts(&context);
        assert_eq!(drafts.len(), 1);
        assert_eq!(drafts[0].evidence_id, "ev-2");
        assert_eq!(drafts[0].content_kind, CurrentContentKind::AgentAction);
    }

    #[test]
    fn parses_bare_and_fenced_json_objects_only() {
        let bare = parse_json_object("  {\"title\":\"One\"}  ").expect("bare object");
        assert_eq!(
            bare.get("title").and_then(serde_json::Value::as_str),
            Some("One")
        );
        let fenced = parse_json_object("```json\n{\"title\":\"Two\"}\n```").expect("json fence");
        assert_eq!(
            fenced.get("title").and_then(serde_json::Value::as_str),
            Some("Two")
        );
        let plain = parse_json_object("```\n{\"title\":\"Three\"}\n```").expect("bare fence");
        assert_eq!(
            plain.get("title").and_then(serde_json::Value::as_str),
            Some("Three")
        );
        assert!(parse_json_object("{}").expect("empty object").is_empty());
        // Arrays, scalars, null and unparseable text are all refused.
        assert!(parse_json_object("[{\"title\":\"One\"}]").is_none());
        assert!(parse_json_object("```json\n[1,2]\n```").is_none());
        assert!(parse_json_object("null").is_none());
        assert!(parse_json_object("7").is_none());
        assert!(parse_json_object("\"One\"").is_none());
        assert!(parse_json_object("{\"title\":}").is_none());
        assert!(parse_json_object("Sorry, I cannot help.").is_none());
        assert!(parse_json_object("").is_none());
    }

    #[test]
    fn collapse_normalises_every_run_of_whitespace() {
        assert_eq!(collapse("  a\t\tb\n\nc  "), "a b c");
        assert_eq!(collapse("\n\ttrailing \t\n"), "trailing");
        assert_eq!(collapse("already one line"), "already one line");
        assert_eq!(collapse("   "), "");
        assert_eq!(collapse(""), "");
        assert_eq!(collapse("a\r\nb"), "a b");
    }
}
