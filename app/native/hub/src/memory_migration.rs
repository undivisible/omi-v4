//! Folds the memory captured while nobody was signed in into the account that
//! signs in afterwards.
//!
//! Signed-out capture lands in a database keyed by a fixed local person id;
//! sign-in opens a database keyed by the account uid and points the sync pump
//! at that one. Nothing bridged the two, so everything remembered before the
//! account existed stayed in a file no reader ever opens again.
//!
//! The bridge is the export/apply pair the cloud sync already rides on, which
//! carries claims together with the sources and evidence they stand on — a
//! claim moved without its evidence would be an unsupported claim, which is
//! worse than a claim left behind. Records are exported whole-commit, their
//! scope is rewritten from the offline id to the account id, and `apply`
//! dedupes them by `(record kind, record id, payload hash)`, so a retry after
//! a half-finished run completes it instead of doubling it.
//!
//! The offline database is never deleted or emptied. Absorption is recorded by
//! a marker file beside it naming the account that took it, which is also what
//! stops a second account from absorbing memory the first one already owns.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex as StdMutex};

use tokio::task::spawn_blocking;
use tokio_util::sync::CancellationToken;
use zkr::{
    ApplyInput, EXPORT_FORMAT_VERSION, ExportCommit, ExportInput, ExportRecord, MemoryDb, PersonId,
    TenantId,
};

use crate::runtime::MemoryContext;
use crate::signals::{NativeError, NativeEvent, ToolProgress, ToolStatus};

const TOOL: &str = "local-memory";
const EXPORT_PAGE_LIMIT: u32 = 100;
/// Commits are applied in batches rather than one transaction over the whole
/// database so a very large offline history does not hold a write lock for the
/// length of the migration. Every batch is transactional on its own and the
/// marker is only written once the last one lands, so an interrupted run is
/// always resumable.
const APPLY_BATCH_COMMITS: usize = 64;

#[derive(Debug, Eq, PartialEq)]
pub(crate) struct Absorbed {
    pub(crate) claims: u64,
    pub(crate) records_applied: u64,
    pub(crate) records_skipped: u64,
}

/// Where the "this offline database has already been taken" marker lives. It
/// sits beside the database rather than inside it so the record survives even
/// if the database is later replaced or repaired.
fn marker_path(database_path: &str) -> PathBuf {
    let path = Path::new(database_path);
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(".absorbed");
    path.with_file_name(name)
}

/// Reads which account already absorbed this database, if any.
pub(crate) fn absorbed_by(database_path: &str) -> Option<String> {
    fs::read_to_string(marker_path(database_path))
        .ok()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
}

pub(crate) fn absorb(
    destination: &mut MemoryContext,
    source_database_path: &str,
    source_tenant_id: &TenantId,
    source_person_id: &PersonId,
) -> Result<Option<Absorbed>, String> {
    // Absorbing a database into itself would rewrite nothing and re-append
    // every record as a fresh commit, so refuse it outright rather than rely
    // on the dedupe to swallow it.
    if source_person_id == &destination.person_id && source_tenant_id == &destination.tenant_id {
        return Ok(None);
    }
    if !Path::new(source_database_path).exists() {
        return Ok(None);
    }
    if absorbed_by(source_database_path).is_some() {
        return Ok(None);
    }
    let mut source = MemoryDb::open(source_database_path).map_err(|error| error.to_string())?;
    let mut absorbed = Absorbed {
        claims: 0,
        records_applied: 0,
        records_skipped: 0,
    };
    let mut after_commit = 0;
    let mut after_event_index = -1;
    let mut high_water_mark = None;
    // Commits can be split across pages when a page hits its record or byte
    // limit, and `apply` refuses a partial commit, so pages are reassembled
    // into whole commits before anything is applied.
    let mut partial: BTreeMap<i64, ExportCommit> = BTreeMap::new();
    let mut ready: Vec<ExportCommit> = Vec::new();
    loop {
        let page = source
            .export(ExportInput {
                export_format: EXPORT_FORMAT_VERSION,
                tenant_id: source_tenant_id.clone(),
                person_id: source_person_id.clone(),
                after_commit,
                after_event_index,
                high_water_mark,
                limit: EXPORT_PAGE_LIMIT,
            })
            .map_err(|error| error.to_string())?;
        high_water_mark = Some(page.high_water_mark);
        after_commit = page.next_after_commit;
        after_event_index = page.next_after_event_index;
        for commit in page.commits {
            let event_count = commit.event_count;
            let entry = partial.entry(commit.sequence).or_insert(ExportCommit {
                sequence: commit.sequence,
                recorded_at: commit.recorded_at,
                event_count,
                first_event_index: 0,
                records: Vec::new(),
            });
            entry.records.extend(commit.records);
            if entry.records.len() as i64 >= event_count {
                let Some(complete) = partial.remove(&commit.sequence) else {
                    continue;
                };
                ready.push(complete);
            }
        }
        if ready.len() >= APPLY_BATCH_COMMITS {
            apply_batch(
                destination,
                std::mem::take(&mut ready),
                source_tenant_id,
                source_person_id,
                &mut absorbed,
            )?;
        }
        if page.complete {
            break;
        }
    }
    if !partial.is_empty() {
        return Err("the offline memory export ended mid-commit".to_owned());
    }
    if !ready.is_empty() {
        apply_batch(
            destination,
            ready,
            source_tenant_id,
            source_person_id,
            &mut absorbed,
        )?;
    }
    // Only now, with every record confirmed in the destination, is the offline
    // database marked as taken. Written after the applies so a crash halfway
    // leaves it unmarked and therefore retried.
    fs::write(marker_path(source_database_path), &destination.person_id.0)
        .map_err(|error| error.to_string())?;
    Ok(Some(absorbed))
}

fn apply_batch(
    destination: &mut MemoryContext,
    commits: Vec<ExportCommit>,
    source_tenant_id: &TenantId,
    source_person_id: &PersonId,
    absorbed: &mut Absorbed,
) -> Result<(), String> {
    let mut rewritten = Vec::with_capacity(commits.len());
    let mut claims = 0;
    for commit in commits {
        let mut records = Vec::with_capacity(commit.records.len());
        for record in commit.records {
            if matches!(record, ExportRecord::Claim(_)) {
                claims += 1;
            }
            records.push(rescope(
                record,
                source_tenant_id,
                source_person_id,
                &destination.tenant_id,
                &destination.person_id,
            )?);
        }
        rewritten.push(ExportCommit {
            sequence: commit.sequence,
            recorded_at: commit.recorded_at,
            event_count: records.len() as i64,
            first_event_index: 0,
            records,
        });
    }
    let applied = destination
        .database
        .apply(ApplyInput {
            export_format: EXPORT_FORMAT_VERSION,
            database_schema_version: None,
            tenant_id: destination.tenant_id.clone(),
            person_id: destination.person_id.clone(),
            commits: rewritten,
        })
        .map_err(|error| error.to_string())?;
    absorbed.claims += claims;
    absorbed.records_applied += applied.records_applied;
    absorbed.records_skipped += applied.records_skipped;
    Ok(())
}

/// Rewrites the offline scope on a record to the account scope.
///
/// Every record kind carries its own `tenant_id`/`person_id`, nested at
/// different depths, and `apply` rejects any record whose scope disagrees with
/// the commit. Rewriting over the serialized form covers all of them, and
/// every record kind zkr adds later, without a match arm per shape. Only
/// values that actually are the offline scope are replaced, so a record that
/// somehow carries a foreign scope fails the apply instead of being silently
/// reassigned.
fn rescope(
    record: ExportRecord,
    source_tenant_id: &TenantId,
    source_person_id: &PersonId,
    tenant_id: &TenantId,
    person_id: &PersonId,
) -> Result<ExportRecord, String> {
    let mut value = serde_json::to_value(record).map_err(|error| error.to_string())?;
    rewrite_scope(
        &mut value,
        &source_tenant_id.0,
        &source_person_id.0,
        &tenant_id.0,
        &person_id.0,
    );
    serde_json::from_value(value).map_err(|error| error.to_string())
}

fn rewrite_scope(
    value: &mut serde_json::Value,
    source_tenant_id: &str,
    source_person_id: &str,
    tenant_id: &str,
    person_id: &str,
) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, item) in map.iter_mut() {
                let replacement = match (key.as_str(), item.as_str()) {
                    ("tenant_id", Some(current)) if current == source_tenant_id => Some(tenant_id),
                    ("person_id", Some(current)) if current == source_person_id => Some(person_id),
                    _ => None,
                };
                match replacement {
                    Some(replacement) => {
                        *item = serde_json::Value::String(replacement.to_owned());
                    }
                    None => rewrite_scope(
                        item,
                        source_tenant_id,
                        source_person_id,
                        tenant_id,
                        person_id,
                    ),
                }
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                rewrite_scope(
                    item,
                    source_tenant_id,
                    source_person_id,
                    tenant_id,
                    person_id,
                );
            }
        }
        _ => {}
    }
}

pub(crate) async fn absorb_local_memory(
    request_id: &str,
    memory: Option<Arc<StdMutex<MemoryContext>>>,
    database_path: String,
    tenant_id: String,
    person_id: String,
    cancellation: &CancellationToken,
) {
    let Some(memory) = memory else {
        failed(
            request_id,
            "memory_unavailable",
            "configure memory before absorbing the offline database",
        );
        return;
    };
    if database_path.trim().is_empty() {
        failed(
            request_id,
            "invalid_local_memory",
            "database_path must not be empty",
        );
        return;
    }
    let (tenant_id, person_id) = match (TenantId::new(tenant_id), PersonId::new(person_id)) {
        (Ok(tenant_id), Ok(person_id)) => (tenant_id, person_id),
        (Err(error), _) | (_, Err(error)) => {
            failed(request_id, "invalid_local_memory", &error.to_string());
            return;
        }
    };
    let mut task = spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        absorb(&mut memory, &database_path, &tenant_id, &person_id)
    });
    let outcome = tokio::select! {
        biased;
        () = cancellation.cancelled() => {
            // The absorb itself is not interruptible mid-batch, and must not
            // be: abandoning it between applies would leave the destination
            // holding half a graph with no marker to say so. Wait it out and
            // report the cancellation instead.
            let _ = (&mut task).await;
            progress(request_id, ToolStatus::Cancelled, None);
            return;
        }
        result = &mut task => result,
    };
    match outcome {
        Ok(Ok(Some(absorbed))) => progress(
            request_id,
            ToolStatus::Complete,
            (absorbed.claims > 0).then(|| describe(absorbed.claims)),
        ),
        Ok(Ok(None)) => progress(request_id, ToolStatus::Complete, None),
        Ok(Err(message)) => failed(request_id, "local_memory_absorb_failed", &message),
        Err(join_error) => failed(
            request_id,
            "local_memory_absorb_failed",
            &join_error.to_string(),
        ),
    }
}

fn describe(claims: u64) -> String {
    let plural = if claims == 1 { "memory" } else { "memories" };
    format!("Moved {claims} {plural} you recorded before signing in into your account.")
}

fn progress(request_id: &str, status: ToolStatus, detail: Option<String>) {
    NativeEvent::ToolProgress(ToolProgress {
        request_id: request_id.to_owned(),
        tool: TOOL.to_owned(),
        status,
        detail,
    })
    .send();
}

fn failed(request_id: &str, code: &str, message: &str) {
    NativeEvent::Error(NativeError {
        request_id: Some(request_id.to_owned()),
        code: code.to_owned(),
        message: message.to_owned(),
        // Retryable: the offline database is left unmarked, so the next
        // sign-in picks up exactly where this run stopped.
        retryable: true,
    })
    .send();
}

#[cfg(test)]
mod tests {
    use super::*;
    use zkr::{
        ClaimInput, ClaimKind, MemoryProcessingState, MemoryTier, RememberInput, SourceKind,
    };

    struct TempDirectory(PathBuf);

    impl TempDirectory {
        fn new(label: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "omi-memory-migration-{label}-{}-{:?}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            ));
            fs::create_dir_all(&path)
                .unwrap_or_else(|error_value| panic!("temp directory: {error_value}"));
            Self(path)
        }

        fn path(&self, name: &str) -> String {
            self.0.join(name).to_string_lossy().into_owned()
        }
    }

    impl Drop for TempDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn context(path: &str, scope: &str) -> MemoryContext {
        MemoryContext {
            database: MemoryDb::open(path)
                .unwrap_or_else(|error_value| panic!("memory database: {error_value}")),
            tenant_id: TenantId::new(scope)
                .unwrap_or_else(|error_value| panic!("tenant id: {error_value}")),
            person_id: PersonId::new(scope)
                .unwrap_or_else(|error_value| panic!("person id: {error_value}")),
        }
    }

    fn remember(memory: &mut MemoryContext, index: usize) {
        let recorded_at = 1_700_000_000 + index as i64;
        memory
            .database
            .remember(RememberInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                ingestion_key: Some(format!("offline-{index}")),
                kind: SourceKind::Conversation,
                text: format!("note {index} about the user"),
                captured_at: recorded_at,
                recorded_at,
                feature_flag: None,
                claim: Some(ClaimInput {
                    subject: "user".to_owned(),
                    predicate: format!("noted-{index}"),
                    value: format!("value {index}"),
                    kind: ClaimKind::Fact,
                    valid_from: recorded_at,
                    tier: MemoryTier::LongTerm,
                    processing_state: MemoryProcessingState::Processed,
                }),
            })
            .unwrap_or_else(|error_value| panic!("remember: {error_value}"));
    }

    #[derive(Debug, Default, Eq, PartialEq)]
    struct Counts {
        sources: usize,
        evidence: usize,
        claims: usize,
        claim_evidence: usize,
    }

    fn counts(memory: &mut MemoryContext) -> Counts {
        let mut cursor = (0, -1);
        let mut counts = Counts::default();
        loop {
            let page = memory
                .database
                .export(ExportInput {
                    export_format: EXPORT_FORMAT_VERSION,
                    tenant_id: memory.tenant_id.clone(),
                    person_id: memory.person_id.clone(),
                    after_commit: cursor.0,
                    after_event_index: cursor.1,
                    high_water_mark: None,
                    limit: EXPORT_PAGE_LIMIT,
                })
                .unwrap_or_else(|error_value| panic!("export: {error_value}"));
            cursor = (page.next_after_commit, page.next_after_event_index);
            for commit in &page.commits {
                for record in &commit.records {
                    match record {
                        ExportRecord::Source(_) => counts.sources += 1,
                        ExportRecord::Evidence(_) => counts.evidence += 1,
                        ExportRecord::Claim(_) => counts.claims += 1,
                        ExportRecord::ClaimEvidence(_) => counts.claim_evidence += 1,
                        _ => {}
                    }
                }
            }
            if page.complete {
                return counts;
            }
        }
    }

    fn claim_count(memory: &mut MemoryContext) -> usize {
        counts(memory).claims
    }

    #[test]
    fn absorbs_offline_claims_with_their_evidence() {
        let directory = TempDirectory::new("absorb");
        let offline_path = directory.path("local-offline.sqlite3");
        let mut offline = context(&offline_path, "local-offline");
        for index in 0..70 {
            remember(&mut offline, index);
        }
        let expected = counts(&mut offline);
        drop(offline);

        let mut account = context(&directory.path("account.sqlite3"), "account-uid");
        let absorbed = absorb(
            &mut account,
            &offline_path,
            &TenantId::new("local-offline")
                .unwrap_or_else(|error_value| panic!("tenant id: {error_value}")),
            &PersonId::new("local-offline")
                .unwrap_or_else(|error_value| panic!("person id: {error_value}")),
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"))
        .unwrap_or_else(|| panic!("the offline database is absorbed"));

        assert_eq!(absorbed.claims as usize, expected.claims);
        assert!(expected.claims >= 70);
        // Claims alone would be unsupported claims; the sources, the evidence
        // and the links that tie them together have to land as well.
        assert_eq!(counts(&mut account), expected);
        assert_eq!(
            absorbed_by(&offline_path).as_deref(),
            Some("account-uid"),
            "the offline database is marked as taken, not deleted"
        );
        assert!(Path::new(&offline_path).exists());
    }

    #[test]
    fn missing_offline_database_is_a_no_op() {
        let directory = TempDirectory::new("missing");
        let mut account = context(&directory.path("account.sqlite3"), "account-uid");
        let absorbed = absorb(
            &mut account,
            &directory.path("nothing-here.sqlite3"),
            &TenantId::new("local-offline")
                .unwrap_or_else(|error_value| panic!("tenant id: {error_value}")),
            &PersonId::new("local-offline")
                .unwrap_or_else(|error_value| panic!("person id: {error_value}")),
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"));
        assert_eq!(absorbed, None);
        assert_eq!(claim_count(&mut account), 0);
    }

    #[test]
    fn absorbing_twice_does_not_duplicate() {
        let directory = TempDirectory::new("twice");
        let offline_path = directory.path("local-offline.sqlite3");
        let mut offline = context(&offline_path, "local-offline");
        for index in 0..5 {
            remember(&mut offline, index);
        }
        let expected_claims = claim_count(&mut offline);
        drop(offline);

        let offline_tenant = TenantId::new("local-offline")
            .unwrap_or_else(|error_value| panic!("tenant id: {error_value}"));
        let offline_person = PersonId::new("local-offline")
            .unwrap_or_else(|error_value| panic!("person id: {error_value}"));
        let mut account = context(&directory.path("account.sqlite3"), "account-uid");
        absorb(
            &mut account,
            &offline_path,
            &offline_tenant,
            &offline_person,
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"))
        .unwrap_or_else(|| panic!("the offline database is absorbed"));
        let repeated = absorb(
            &mut account,
            &offline_path,
            &offline_tenant,
            &offline_person,
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"));

        assert_eq!(repeated, None, "the marker stops a second pass");
        assert_eq!(claim_count(&mut account), expected_claims);

        // Even with the marker gone — a wiped preferences directory, a restored
        // backup — the record-level dedupe must hold.
        fs::remove_file(marker_path(&offline_path))
            .unwrap_or_else(|error_value| panic!("remove marker: {error_value}"));
        let forced = absorb(
            &mut account,
            &offline_path,
            &offline_tenant,
            &offline_person,
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"))
        .unwrap_or_else(|| panic!("the offline database is absorbed"));
        assert_eq!(forced.records_applied, 0);
        assert!(forced.records_skipped > 0);
        assert_eq!(claim_count(&mut account), expected_claims);
    }

    #[test]
    fn a_second_account_does_not_take_absorbed_memory() {
        let directory = TempDirectory::new("second-account");
        let offline_path = directory.path("local-offline.sqlite3");
        let mut offline = context(&offline_path, "local-offline");
        for index in 0..4 {
            remember(&mut offline, index);
        }
        drop(offline);

        let offline_tenant = TenantId::new("local-offline")
            .unwrap_or_else(|error_value| panic!("tenant id: {error_value}"));
        let offline_person = PersonId::new("local-offline")
            .unwrap_or_else(|error_value| panic!("person id: {error_value}"));
        let mut first = context(&directory.path("first.sqlite3"), "first-uid");
        absorb(&mut first, &offline_path, &offline_tenant, &offline_person)
            .unwrap_or_else(|error_value| panic!("absorb: {error_value}"))
            .unwrap_or_else(|| panic!("the offline database is absorbed"));

        let mut second = context(&directory.path("second.sqlite3"), "second-uid");
        let absorbed = absorb(&mut second, &offline_path, &offline_tenant, &offline_person)
            .unwrap_or_else(|error_value| panic!("absorb: {error_value}"));
        assert_eq!(absorbed, None);
        assert_eq!(claim_count(&mut second), 0);
        assert_eq!(absorbed_by(&offline_path).as_deref(), Some("first-uid"));
    }

    #[test]
    fn an_interrupted_absorb_completes_on_retry() {
        let directory = TempDirectory::new("interrupted");
        let offline_path = directory.path("local-offline.sqlite3");
        let mut offline = context(&offline_path, "local-offline");
        for index in 0..6 {
            remember(&mut offline, index);
        }
        let expected_claims = claim_count(&mut offline);

        // Stand in for a run that died after its first batch: apply the first
        // commits by hand, leave no marker, then let the real absorb finish.
        let partial = offline
            .database
            .export(ExportInput {
                export_format: EXPORT_FORMAT_VERSION,
                tenant_id: offline.tenant_id.clone(),
                person_id: offline.person_id.clone(),
                after_commit: 0,
                after_event_index: -1,
                high_water_mark: None,
                limit: EXPORT_PAGE_LIMIT,
            })
            .unwrap_or_else(|error_value| panic!("export: {error_value}"));
        drop(offline);

        let offline_tenant = TenantId::new("local-offline")
            .unwrap_or_else(|error_value| panic!("tenant id: {error_value}"));
        let offline_person = PersonId::new("local-offline")
            .unwrap_or_else(|error_value| panic!("person id: {error_value}"));
        let mut account = context(&directory.path("account.sqlite3"), "account-uid");
        let mut ignored = Absorbed {
            claims: 0,
            records_applied: 0,
            records_skipped: 0,
        };
        let head = partial.commits.into_iter().take(2).collect::<Vec<_>>();
        assert!(!head.is_empty());
        apply_batch(
            &mut account,
            head,
            &offline_tenant,
            &offline_person,
            &mut ignored,
        )
        .unwrap_or_else(|error_value| panic!("partial apply: {error_value}"));
        assert!(absorbed_by(&offline_path).is_none());

        let absorbed = absorb(
            &mut account,
            &offline_path,
            &offline_tenant,
            &offline_person,
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"))
        .unwrap_or_else(|| panic!("the offline database is absorbed"));
        assert!(
            absorbed.records_skipped > 0,
            "the first batch is recognised"
        );
        assert_eq!(claim_count(&mut account), expected_claims);
        assert_eq!(absorbed_by(&offline_path).as_deref(), Some("account-uid"));
    }

    #[test]
    fn absorbing_a_database_into_its_own_scope_is_refused() {
        let directory = TempDirectory::new("self");
        let offline_path = directory.path("local-offline.sqlite3");
        let mut offline = context(&offline_path, "local-offline");
        remember(&mut offline, 0);
        let before = claim_count(&mut offline);
        let absorbed = absorb(
            &mut offline,
            &offline_path,
            &TenantId::new("local-offline")
                .unwrap_or_else(|error_value| panic!("tenant id: {error_value}")),
            &PersonId::new("local-offline")
                .unwrap_or_else(|error_value| panic!("person id: {error_value}")),
        )
        .unwrap_or_else(|error_value| panic!("absorb: {error_value}"));
        assert_eq!(absorbed, None);
        assert_eq!(claim_count(&mut offline), before);
        assert!(absorbed_by(&offline_path).is_none());
    }
}
