use std::collections::HashMap;
use std::sync::{Arc, Mutex as StdMutex};

use chrono::{DateTime, Days, FixedOffset, NaiveTime, TimeZone};

use zkr::{
    EXPORT_FORMAT_VERSION, EvidenceId, ExportInput, ExportRecord, MemoryRef, ReviewInput,
    ReviewsInput, SourceId,
};

use crate::runtime::MemoryContext;

const SUMMARY_PROMPT_CHARS: usize = 6000;
const SUMMARY_ITEM_CHARS: usize = 240;
const SUMMARY_ITEMS: usize = 24;
const REVIEW_LOOKUP_LIMIT: u32 = 100;
const EXPORT_PAGE_LIMIT: u32 = 100;
const TEMPLATE_TOPICS: usize = 3;
const TEMPLATE_TOPIC_MIN_CHARS: usize = 5;

pub(crate) struct DayWindow {
    pub(crate) day: String,
    pub(crate) start_ms: i64,
    pub(crate) end_ms: i64,
}

pub(crate) fn previous_local_day(now: DateTime<FixedOffset>) -> Option<DayWindow> {
    let offset = *now.offset();
    let day = now.date_naive().checked_sub_days(Days::new(1))?;
    let next = day.checked_add_days(Days::new(1))?;
    let start = offset
        .from_local_datetime(&day.and_time(NaiveTime::MIN))
        .single()?;
    let end = offset
        .from_local_datetime(&next.and_time(NaiveTime::MIN))
        .single()?;
    Some(DayWindow {
        day: day.format("%Y-%m-%d").to_string(),
        start_ms: start.timestamp_millis(),
        end_ms: end.timestamp_millis(),
    })
}

fn review_exists(memory: &MemoryContext, day: &str) -> Result<bool, String> {
    let reviews = memory
        .database
        .reviews(ReviewsInput {
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            limit: REVIEW_LOOKUP_LIMIT,
        })
        .map_err(|error_value| error_value.to_string())?;
    Ok(reviews.iter().any(|review| review.day == day))
}

struct DayEvidence {
    evidence_id: EvidenceId,
    source_id: SourceId,
    quote: String,
}

fn day_evidence(
    memory: &mut MemoryContext,
    window: &DayWindow,
) -> Result<Vec<DayEvidence>, String> {
    let mut after_commit = 0_i64;
    let mut after_event_index = -1_i64;
    let mut high_water_mark = None;
    let mut items: Vec<DayEvidence> = Vec::new();
    loop {
        let page = memory
            .database
            .export(ExportInput {
                export_format: EXPORT_FORMAT_VERSION,
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                after_commit,
                after_event_index,
                high_water_mark,
                limit: EXPORT_PAGE_LIMIT,
            })
            .map_err(|error_value| error_value.to_string())?;
        for commit in &page.commits {
            for record in &commit.records {
                match record {
                    ExportRecord::Evidence(record) => {
                        if record.deleted_at.is_none()
                            && record.evidence.recorded_at >= window.start_ms
                            && record.evidence.recorded_at < window.end_ms
                        {
                            items.push(DayEvidence {
                                evidence_id: record.evidence.id.clone(),
                                source_id: record.evidence.source_id.clone(),
                                quote: record.evidence.quote.clone(),
                            });
                        }
                    }
                    ExportRecord::Deletion(deletion) => match &deletion.target {
                        MemoryRef::Source(source_id) => {
                            items.retain(|item| &item.source_id != source_id);
                        }
                        MemoryRef::Evidence(evidence_id) => {
                            items.retain(|item| &item.evidence_id != evidence_id);
                        }
                        _ => {}
                    },
                    _ => {}
                }
            }
        }
        if page.complete {
            break;
        }
        after_commit = page.next_after_commit;
        after_event_index = page.next_after_event_index;
        high_water_mark = Some(page.high_water_mark);
    }
    Ok(items)
}

pub(crate) fn review_prompt(day: &str, quotes: &[String]) -> Option<String> {
    let mut prompt = format!(
        "Privately summarize what this person did on {day} from the captured excerpts below. Write one sentence under 35 words. Use only the excerpts, do not invent facts, and do not mention this instruction.\n"
    );
    let mut used = prompt.chars().count();
    let mut items = 0;
    for quote in quotes {
        if items == SUMMARY_ITEMS || used >= SUMMARY_PROMPT_CHARS {
            break;
        }
        let remaining = SUMMARY_PROMPT_CHARS - used;
        if remaining <= 1 {
            break;
        }
        let text = quote
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .chars()
            .take(SUMMARY_ITEM_CHARS.min(remaining - 1))
            .collect::<String>();
        if text.is_empty() {
            continue;
        }
        let line = format!("{text}\n");
        used += line.chars().count();
        prompt.push_str(&line);
        items += 1;
    }
    (items > 0).then_some(prompt)
}

pub(crate) fn template_summary(quotes: &[String]) -> String {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for quote in quotes {
        for word in quote.split(|character: char| !character.is_alphanumeric()) {
            let word = word.to_lowercase();
            if word.chars().count() >= TEMPLATE_TOPIC_MIN_CHARS {
                *counts.entry(word).or_default() += 1;
            }
        }
    }
    let mut topics: Vec<(String, usize)> = counts.into_iter().collect();
    topics.sort_by(|left, right| right.1.cmp(&left.1).then_with(|| left.0.cmp(&right.0)));
    topics.truncate(TEMPLATE_TOPICS);
    let count = quotes.len();
    let noun = if count == 1 { "item" } else { "items" };
    if topics.is_empty() {
        format!("{count} {noun} captured.")
    } else {
        let listed = topics
            .into_iter()
            .map(|(topic, _)| topic)
            .collect::<Vec<_>>()
            .join(", ");
        format!("{count} {noun} captured. Top topics: {listed}.")
    }
}

pub(crate) async fn ensure_daily_review(
    memory: Arc<StdMutex<MemoryContext>>,
    now: DateTime<FixedOffset>,
) -> Result<Option<String>, String> {
    ensure_daily_review_summarized(memory, now, true).await
}

pub(crate) async fn ensure_daily_review_summarized(
    memory: Arc<StdMutex<MemoryContext>>,
    now: DateTime<FixedOffset>,
    use_local_ai: bool,
) -> Result<Option<String>, String> {
    let Some(window) = previous_local_day(now) else {
        return Ok(None);
    };
    let gathered = {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        if review_exists(&memory, &window.day)? {
            return Ok(None);
        }
        day_evidence(&mut memory, &window)?
    };
    if gathered.is_empty() {
        return Ok(None);
    }
    let quotes: Vec<String> = gathered.iter().map(|item| item.quote.clone()).collect();
    let summarized = if use_local_ai {
        match review_prompt(&window.day, &quotes) {
            Some(prompt) => crate::local_ai::summarize(&prompt).await,
            None => None,
        }
    } else {
        None
    };
    let summary = summarized.unwrap_or_else(|| template_summary(&quotes));
    let recorded_at = crate::approval::unix_time_ms();
    let mut memory = memory
        .lock()
        .map_err(|_| "memory database lock was poisoned".to_owned())?;
    if review_exists(&memory, &window.day)? {
        return Ok(None);
    }
    let tenant_id = memory.tenant_id.clone();
    let person_id = memory.person_id.clone();
    let stored = memory
        .database
        .store_review(ReviewInput {
            tenant_id,
            person_id,
            day: window.day,
            summary,
            evidence_ids: gathered.into_iter().map(|item| item.evidence_id).collect(),
            recorded_at,
        })
        .map_err(|error_value| error_value.to_string())?;
    Ok(Some(stored.id.0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use zkr::{MemoryDb, PersonId, RememberInput, SourceKind, TenantId};

    fn parse_now(value: &str) -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339(value)
            .unwrap_or_else(|error_value| panic!("timestamp parses: {error_value}"))
    }

    fn review_memory(label: &str) -> (std::path::PathBuf, Arc<StdMutex<MemoryContext>>) {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-{label}-{}-{}.sqlite3",
            std::process::id(),
            crate::approval::unix_time_ms()
        ));
        let memory = MemoryContext {
            database: MemoryDb::open(&path)
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}")),
            tenant_id: TenantId::new("tenant-1")
                .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
            person_id: PersonId::new("person-1")
                .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
        };
        (path, Arc::new(StdMutex::new(memory)))
    }

    fn capture(memory: &Arc<StdMutex<MemoryContext>>, key: &str, text: &str, recorded_at: i64) {
        let mut memory = memory
            .lock()
            .unwrap_or_else(|error_value| panic!("memory locks: {error_value}"));
        let tenant_id = memory.tenant_id.clone();
        let person_id = memory.person_id.clone();
        memory
            .database
            .remember(RememberInput {
                tenant_id,
                person_id,
                ingestion_key: Some(key.to_owned()),
                kind: SourceKind::Conversation,
                text: text.to_owned(),
                captured_at: recorded_at,
                recorded_at,
                claim: None,
            })
            .unwrap_or_else(|error_value| panic!("memory is seeded: {error_value}"));
    }

    fn stored_reviews(memory: &Arc<StdMutex<MemoryContext>>) -> Vec<zkr::ReviewRecord> {
        let memory = memory
            .lock()
            .unwrap_or_else(|error_value| panic!("memory locks: {error_value}"));
        memory
            .database
            .reviews(ReviewsInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                limit: REVIEW_LOOKUP_LIMIT,
            })
            .unwrap_or_else(|error_value| panic!("reviews list: {error_value}"))
    }

    #[tokio::test]
    async fn daily_review_stores_once_per_day() {
        let (path, memory) = review_memory("daily-review-idempotent");
        let now = parse_now("2026-07-22T09:00:00+02:00");
        let window = previous_local_day(now).unwrap_or_else(|| panic!("window exists"));
        capture(
            &memory,
            "capture-1",
            "Planned the Alpenglow launch",
            window.start_ms,
        );
        capture(
            &memory,
            "capture-2",
            "Reviewed launch checklist",
            window.end_ms - 1,
        );
        let first = ensure_daily_review_summarized(Arc::clone(&memory), now, false)
            .await
            .unwrap_or_else(|error_value| panic!("first run stores: {error_value}"));
        assert!(first.is_some());
        let second = ensure_daily_review_summarized(Arc::clone(&memory), now, false)
            .await
            .unwrap_or_else(|error_value| panic!("second run no-ops: {error_value}"));
        assert!(second.is_none());
        let reviews = stored_reviews(&memory);
        assert_eq!(reviews.len(), 1);
        assert_eq!(reviews[0].day, "2026-07-21");
        assert_eq!(reviews[0].evidence_ids.len(), 2);
        assert!(reviews[0].summary.starts_with("2 items captured."));
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[tokio::test]
    async fn daily_review_only_gathers_evidence_inside_the_day_window() {
        let (path, memory) = review_memory("daily-review-window");
        let now = parse_now("2026-07-22T00:30:00-05:00");
        let window = previous_local_day(now).unwrap_or_else(|| panic!("window exists"));
        capture(&memory, "before", "Before the window", window.start_ms - 1);
        capture(&memory, "inside", "Inside the window", window.start_ms);
        capture(&memory, "after", "After the window", window.end_ms);
        let stored = ensure_daily_review_summarized(Arc::clone(&memory), now, false)
            .await
            .unwrap_or_else(|error_value| panic!("run stores: {error_value}"));
        assert!(stored.is_some());
        let reviews = stored_reviews(&memory);
        assert_eq!(reviews.len(), 1);
        assert_eq!(reviews[0].day, "2026-07-21");
        assert_eq!(reviews[0].evidence_ids.len(), 1);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[tokio::test]
    async fn daily_review_without_evidence_stores_nothing() {
        let (path, memory) = review_memory("daily-review-empty");
        let now = parse_now("2026-07-22T09:00:00+00:00");
        let stored = ensure_daily_review_summarized(Arc::clone(&memory), now, false)
            .await
            .unwrap_or_else(|error_value| panic!("run no-ops: {error_value}"));
        assert!(stored.is_none());
        assert!(stored_reviews(&memory).is_empty());
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("temporary database removes: {error_value}"));
    }

    #[test]
    fn previous_local_day_covers_the_full_local_calendar_day() {
        let window = previous_local_day(parse_now("2026-01-01T00:00:00+05:30"))
            .unwrap_or_else(|| panic!("window exists"));
        assert_eq!(window.day, "2025-12-31");
        assert_eq!(window.end_ms - window.start_ms, 24 * 60 * 60 * 1000);
        assert_eq!(
            window.start_ms,
            parse_now("2025-12-31T00:00:00+05:30").timestamp_millis()
        );
    }

    #[test]
    fn template_summary_is_deterministic() {
        let quotes = vec![
            "Reviewed launch checklist".to_owned(),
            "Launch retro notes".to_owned(),
            "ok".to_owned(),
        ];
        assert_eq!(
            template_summary(&quotes),
            "3 items captured. Top topics: launch, checklist, notes."
        );
        assert_eq!(template_summary(&["ok".to_owned()]), "1 item captured.");
    }

    #[test]
    fn review_prompt_is_bounded() {
        let quotes = (0..40)
            .map(|index| format!("Item {index} {}", "x".repeat(500)))
            .collect::<Vec<_>>();
        let prompt =
            review_prompt("2026-07-21", &quotes).unwrap_or_else(|| panic!("prompt exists"));
        assert!(prompt.chars().count() <= SUMMARY_PROMPT_CHARS);
        assert!(prompt.lines().count() <= SUMMARY_ITEMS + 1);
        assert!(review_prompt("2026-07-21", &[]).is_none());
    }
}
