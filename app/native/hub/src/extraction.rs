use zkr::{ClaimInput, ClaimKind, MemoryProcessingState, MemoryTier};

pub const MAX_SOURCE_CHARS: usize = 4_000;
pub const MAX_CLAIMS: usize = 5;
const MIN_SOURCE_CHARS: usize = 40;
const MAX_FIELD_CHARS: usize = 280;

pub fn extraction_prompt(text: &str) -> Option<String> {
    let trimmed = text.trim();
    if trimmed.chars().count() < MIN_SOURCE_CHARS {
        return None;
    }
    let bounded: String = trimmed.chars().take(MAX_SOURCE_CHARS).collect();
    Some(format!(
        "Extract concrete action items from this conversation as a JSON array of \
         objects with keys title, description, priority (0-9 integer), action. \
         Reply with only the JSON array, or [] when there is none.\n\n{bounded}"
    ))
}

fn bounded_field(value: &str) -> String {
    value
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(MAX_FIELD_CHARS)
        .collect()
}

pub fn candidate_claims(model_output: &str, valid_from_ms: i64) -> Vec<ClaimInput> {
    let mut claims = Vec::new();
    let mut proactive = rx4::extract_proactive_loose(model_output);
    proactive.retain(|item| !item.title.trim().is_empty());
    for item in rx4::top_n(&mut proactive, MAX_CLAIMS) {
        let subject = bounded_field(&item.title);
        let mut value = bounded_field(&format!("{} {}", item.description, item.action));
        if value.is_empty() {
            value.clone_from(&subject);
        }
        claims.push(ClaimInput {
            subject,
            predicate: "requires".to_owned(),
            value,
            kind: ClaimKind::Task,
            valid_from: valid_from_ms,
            tier: MemoryTier::ShortTerm,
            processing_state: MemoryProcessingState::Pending,
        });
    }
    if claims.len() < MAX_CLAIMS {
        for item in rx4::extract_knowledge_loose(model_output) {
            if claims.len() >= MAX_CLAIMS {
                break;
            }
            if item.topic.trim().is_empty() || item.summary.trim().is_empty() {
                continue;
            }
            claims.push(ClaimInput {
                subject: bounded_field(&item.topic),
                predicate: "summary".to_owned(),
                value: bounded_field(&item.summary),
                kind: ClaimKind::Fact,
                valid_from: valid_from_ms,
                tier: MemoryTier::ShortTerm,
                processing_state: MemoryProcessingState::Pending,
            });
        }
    }
    claims
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_text_produces_no_prompt() {
        assert!(extraction_prompt("too short").is_none());
        assert!(extraction_prompt(&" ".repeat(200)).is_none());
    }

    #[test]
    fn prompt_is_bounded() {
        let text = "word ".repeat(2_000);
        let prompt = extraction_prompt(&text).unwrap_or_default();
        assert!(prompt.chars().count() <= MAX_SOURCE_CHARS + 300);
        assert!(prompt.contains("JSON array"));
    }

    #[test]
    fn candidate_claims_rank_by_priority_and_cap() {
        let json = r#"[
            {"title":"low","description":"d","priority":1,"action":"a"},
            {"title":"top","description":"d","priority":9,"action":"a"},
            {"title":"mid1","description":"d","priority":5,"action":"a"},
            {"title":"mid2","description":"d","priority":5,"action":"a"},
            {"title":"mid3","description":"d","priority":5,"action":"a"},
            {"title":"mid4","description":"d","priority":5,"action":"a"}
        ]"#;
        let claims = candidate_claims(&format!("```json\n{json}\n```"), 42);
        assert_eq!(claims.len(), MAX_CLAIMS);
        assert_eq!(claims[0].subject, "top");
        assert_eq!(claims[0].kind, ClaimKind::Task);
        assert_eq!(claims[0].valid_from, 42);
        assert_eq!(claims[0].tier, MemoryTier::ShortTerm);
        assert_eq!(claims[0].processing_state, MemoryProcessingState::Pending);
        assert!(claims.iter().all(|claim| claim.subject != "low"));
    }

    #[test]
    fn knowledge_output_becomes_fact_claims() {
        let json = r#"[{"topic":"standup","summary":"team met daily","tags":["work"]}]"#;
        let claims = candidate_claims(json, 7);
        assert_eq!(claims.len(), 1);
        assert_eq!(claims[0].kind, ClaimKind::Fact);
        assert_eq!(claims[0].subject, "standup");
        assert_eq!(claims[0].value, "team met daily");
    }

    #[test]
    fn garbage_output_produces_nothing() {
        assert!(candidate_claims("no json here", 1).is_empty());
        assert!(candidate_claims("[not valid", 1).is_empty());
        assert!(
            candidate_claims(
                r#"[{"title":"  ","description":"","priority":1,"action":""}]"#,
                1
            )
            .is_empty()
        );
    }

    #[test]
    fn fields_are_bounded_and_flattened() {
        let long = "x".repeat(500);
        let json = format!(
            r#"[{{"title":"line one\ntwo","description":"{long}","priority":3,"action":"go"}}]"#
        );
        let claims = candidate_claims(&json, 1);
        assert_eq!(claims[0].subject, "line one two");
        assert!(claims[0].value.chars().count() <= 280);
    }
}
