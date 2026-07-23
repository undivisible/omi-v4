//! Self-improvement wiring: records a lesson after each online assistant turn
//! and augments the next prompt with accumulated lessons. Everything degrades
//! to a no-op when the memory database is unavailable, mirroring the runtime's
//! `memory_unavailable` path so the hot path never blocks on it.

use rx4::model_router::{ModelRouter, ProactiveMonitor};
use rx4::self_improve::SelfImprove;
use zkr::{MemoryDb, PersonId, TenantId};

/// The most lessons folded into a single augmented prompt; bounds the extra
/// tokens the self-improvement layer can add on the latency-critical path.
pub(crate) const LESSON_LIMIT: u32 = 3;

/// Opens a self-improvement handle on its own connection to the memory
/// database. Returns `None` (a clean no-op) when the connection can't be
/// opened, so callers gate on the `Option` exactly like `memory_unavailable`.
pub(crate) fn open(
    database_path: &str,
    tenant_id: TenantId,
    person_id: PersonId,
) -> Option<SelfImprove> {
    MemoryDb::open(database_path)
        .ok()
        .map(|database| SelfImprove::new(database, tenant_id, person_id))
}

/// Enriches `base` with at most [`LESSON_LIMIT`] lessons relevant to `query`,
/// falling back to `base` unchanged if retrieval fails or finds nothing. The
/// explicit limit is what keeps the added prompt text bounded.
pub(crate) async fn augment(self_improve: &SelfImprove, query: &str, base: &str) -> String {
    let lessons = match self_improve.lessons(query, LESSON_LIMIT).await {
        Ok(lessons) if !lessons.is_empty() => lessons,
        _ => return base.to_owned(),
    };
    let mut augmented = String::from(base);
    augmented.push_str("\n\nLessons from past turns:\n");
    for lesson in lessons.iter().take(LESSON_LIMIT as usize) {
        augmented.push_str("- ");
        augmented.push_str(lesson);
        augmented.push('\n');
    }
    augmented
}

/// Records the outcome of a completed turn as a reflection. A lesson is derived
/// from the prompt/response via the proactive monitor; a generic note is used
/// when no specific learning is detectable. Errors are swallowed so a failed
/// write never surfaces on the user's turn.
pub(crate) async fn record_turn(self_improve: SelfImprove, prompt: String, reply: String) {
    let monitor = ProactiveMonitor::new(ModelRouter::new());
    let classification = monitor.classify_turn(&prompt, &reply);
    let lesson = monitor
        .extract_learning(&[prompt.clone(), reply.clone()])
        .map(|learning| learning.summary)
        .unwrap_or_else(|| "Answered the user's request online.".to_owned());
    let outcome = if classification.success {
        "success"
    } else {
        "failure"
    };
    let _ = self_improve
        .record(&prompt, "online assistant reply", outcome, &lesson)
        .await;
}

#[cfg(test)]
mod tests {
    use super::{LESSON_LIMIT, SelfImprove, augment, open};
    use zkr::{PersonId, TenantId};

    fn scoped(label: &str) -> (std::path::PathBuf, SelfImprove) {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-{label}-{}-{}.sqlite3",
            std::process::id(),
            crate::approval::unix_time_ms()
        ));
        let tenant = TenantId::new("tenant-1")
            .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}"));
        let person = PersonId::new("person-1")
            .unwrap_or_else(|error_value| panic!("valid person: {error_value}"));
        let handle = open(&path.to_string_lossy(), tenant, person)
            .unwrap_or_else(|| panic!("self-improve opens"));
        (path, handle)
    }

    #[tokio::test]
    async fn record_then_augment_round_trips_a_lesson() {
        let (path, handle) = scoped("self-improve-round-trip");

        handle
            .record(
                "deploying the hub",
                "pinned the image tag",
                "success",
                "pin image tags before deploying",
            )
            .await
            .unwrap_or_else(|error_value| panic!("record succeeds: {error_value}"));

        let lessons = handle
            .lessons("deploying the hub", LESSON_LIMIT)
            .await
            .unwrap_or_else(|error_value| panic!("lessons retrieve: {error_value}"));
        assert!(!lessons.is_empty(), "recorded lesson should be retrievable");

        let augmented = augment(&handle, "deploying the hub", "BASE PROMPT").await;
        assert!(augmented.starts_with("BASE PROMPT"));
        assert!(augmented.contains("Lessons from past turns:"));

        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn augment_returns_the_base_prompt_when_nothing_is_recorded() {
        let (path, handle) = scoped("self-improve-empty");
        assert_eq!(augment(&handle, "nothing here", "BASE").await, "BASE");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn unopenable_database_degrades_to_none() {
        let tenant = TenantId::new("tenant-1")
            .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}"));
        let person = PersonId::new("person-1")
            .unwrap_or_else(|error_value| panic!("valid person: {error_value}"));
        assert!(open("/nonexistent-directory/memory.db", tenant, person).is_none());
    }
}
