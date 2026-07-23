//! Currents `.crepus` metadata handling — parity with the TypeScript worker
//! (`worker/src/currents.ts`).
//!
//! A current may carry an AI-authored `.crepus` widget description in its
//! metadata. The real safety boundary is the Dart renderer in the app
//! (`crepuscularity_flutter` is generic; the omi app whitelists actions). The
//! worker only applies cheap defense-in-depth: a hard length cap so an oversized
//! or hostile blob never reaches the client. Both workers MUST agree on this cap
//! — keep [`CREPUS_MAX_LEN`] in step with the TS `crepusMaxLen`.

/// Maximum accepted length of a current's `.crepus` source, in characters.
/// Mirrors `crepusMaxLen` in `worker/src/currents.ts` and
/// `CrepusLimits.maxSourceLength` in the Flutter package.
pub const CREPUS_MAX_LEN: usize = 8000;

/// Trim and length-check a candidate `.crepus` string. Returns the trimmed
/// source when non-empty and within the cap, otherwise `None` (pass-through
/// rejection — no lowering, no parsing).
pub fn sanitize_crepus(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() || trimmed.chars().count() > CREPUS_MAX_LEN {
        return None;
    }
    Some(trimmed.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_normal_source() {
        assert_eq!(
            sanitize_crepus("  text \"hi\"  "),
            Some("text \"hi\"".to_string())
        );
    }

    #[test]
    fn rejects_blank() {
        assert_eq!(sanitize_crepus("   \n  "), None);
    }

    #[test]
    fn rejects_oversized() {
        let huge = "a".repeat(CREPUS_MAX_LEN + 1);
        assert_eq!(sanitize_crepus(&huge), None);
    }

    #[test]
    fn accepts_at_the_cap() {
        let exact = "a".repeat(CREPUS_MAX_LEN);
        assert_eq!(sanitize_crepus(&exact), Some(exact));
    }
}
