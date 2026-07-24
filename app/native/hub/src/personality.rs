//! Personality wiring: augments each online assistant prompt with behavioral
//! context and records the user's message and the assistant's reply as
//! turn-taking evidence. It shares the same zkr memory database as
//! self-improvement, writing under zkr's `personality` feature flag, and
//! degrades to a no-op whenever the database is unavailable so the hot path
//! never blocks on it — exactly like [`crate::self_improve`].

use rx4::{ConversationEvent, Personality, TurnAction, TurnDecision};
use zkr::{MemoryDb, PersonId, TenantId};

/// Opens a personality handle on its own connection to the memory database.
/// Returns `None` (a clean no-op) when the connection can't be opened, so
/// callers gate on the `Option` exactly like `memory_unavailable`.
pub(crate) fn open(
    database_path: &str,
    tenant_id: TenantId,
    person_id: PersonId,
) -> Option<Personality> {
    MemoryDb::open(database_path)
        .ok()
        .map(|database| Personality::new(database, tenant_id, person_id))
}

/// Enriches `base` with behavioral context relevant to `query`, falling back to
/// `base` unchanged if retrieval fails or finds nothing. rx4 owns the retrieval
/// and the bound; `query` is the user's raw message.
pub(crate) async fn augment(personality: &Personality, query: &str, base: &str) -> String {
    match personality.augment(query, base).await {
        Ok(augmented) => augmented,
        Err(_) => base.to_owned(),
    }
}

/// Records a completed turn: the user's message as a conversation event, and
/// the assistant's reply as a `Speak` turn decision. The epoch is the wall
/// clock in milliseconds, which is monotonic enough to order turns. Errors are
/// swallowed so a failed write never surfaces on the user's turn.
pub(crate) async fn record_turn(personality: Personality, prompt: String, reply: String) {
    let epoch = crate::approval::unix_time_ms().max(0) as u64;
    let _ = personality
        .record_event(&ConversationEvent {
            epoch,
            participant: "user".to_owned(),
            event_kind: "message".to_owned(),
            content: prompt,
        })
        .await;
    let _ = personality
        .record_turn(&TurnDecision {
            epoch,
            action: TurnAction::Speak,
            strategy: "assistant_reply".to_owned(),
            addressee: None,
            confidence_basis_points: 10_000,
            rationale: reply,
        })
        .await;
}

#[cfg(test)]
mod tests {
    use super::{Personality, augment, open, record_turn};
    use zkr::{PersonId, TenantId};

    fn scoped(label: &str) -> (std::path::PathBuf, Personality) {
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
            .unwrap_or_else(|| panic!("personality opens"));
        (path, handle)
    }

    #[tokio::test]
    async fn recording_a_turn_then_augmenting_does_not_error() {
        let (path, handle) = scoped("personality-round-trip");
        record_turn(
            handle.clone(),
            "can you keep it short".to_owned(),
            "Sure — short it is.".to_owned(),
        )
        .await;
        // Whatever behavioral context comes back, the base prompt is always
        // preserved at the front so augmentation can only ever add.
        let augmented = augment(&handle, "keep it short", "BASE PROMPT").await;
        assert!(augmented.starts_with("BASE PROMPT"));
        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn augment_returns_the_base_prompt_when_nothing_is_recorded() {
        let (path, handle) = scoped("personality-empty");
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
