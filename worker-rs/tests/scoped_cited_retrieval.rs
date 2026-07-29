use omi_v4_api_rs::memory_log::{canonical_json, APPEND_SQL, READ_SQL};
use omi_v4_api_rs::routes_memory::{
    deletion_target, record_identity, relevance_basis_points, retrieve_match, scoped_record,
};
use rusqlite::{params, Connection};
use serde_json::{json, Value};

#[test]
fn scoped_cited_retrieval_only_returns_live_owned_citations() {
    let result = scoped_cited_retrieval_fixture();

    assert_eq!(
        result,
        vec![("claim-a-live".into(), "evidence-a-live".into())]
    );
}

fn scoped_cited_retrieval_fixture() -> Vec<(String, String)> {
    let db = Connection::open_in_memory().expect("open in-memory SQLite");
    db.execute_batch(
        "CREATE TABLE memory_log (
           uid TEXT NOT NULL, sequence INTEGER NOT NULL, origin_replica TEXT NOT NULL,
           record_kind TEXT NOT NULL, record_id TEXT NOT NULL, payload TEXT NOT NULL,
           recorded_at INTEGER NOT NULL, appended_at INTEGER NOT NULL,
           PRIMARY KEY (uid, sequence));
         CREATE TABLE memory_claims (
           id TEXT PRIMARY KEY, uid TEXT NOT NULL, content TEXT NOT NULL, status TEXT NOT NULL,
           retracted_at INTEGER, valid_from INTEGER, valid_to INTEGER, recorded_until INTEGER,
           zkr_tier TEXT, zkr_processing_state TEXT, recorded_at INTEGER NOT NULL);
         CREATE VIRTUAL TABLE memory_claims_fts USING fts5(
           id UNINDEXED, uid UNINDEXED, content, subject, predicate, value);
         CREATE TABLE memory_sources (id TEXT PRIMARY KEY, uid TEXT NOT NULL, tombstoned_at INTEGER);
         CREATE TABLE memory_source_revisions (id TEXT PRIMARY KEY, source_id TEXT NOT NULL, uid TEXT NOT NULL);
         CREATE TABLE memory_evidence (
           id TEXT PRIMARY KEY, uid TEXT NOT NULL, source_revision_id TEXT NOT NULL, tombstoned_at INTEGER);
         CREATE TABLE memory_claim_evidence (
           uid TEXT NOT NULL, claim_id TEXT NOT NULL, evidence_id TEXT NOT NULL, relation TEXT NOT NULL);",
    )
    .expect("create retrieval schema");

    let records = [
        record(
            "uid-a",
            "source",
            "source-a-live",
            json!({ "source": { "id": "source-a-live", "tenant_id": "uid-a", "person_id": "uid-a" } }),
        ),
        record(
            "uid-a",
            "evidence",
            "evidence-a-live",
            json!({ "evidence": { "id": "evidence-a-live", "source_id": "source-a-live", "tenant_id": "uid-a", "person_id": "uid-a" } }),
        ),
        record(
            "uid-a",
            "claim",
            "claim-a-live",
            json!({ "id": "claim-a-live", "content": "matching cited result", "status": "accepted", "tenant_id": "uid-a", "person_id": "uid-a" }),
        ),
        record(
            "uid-a",
            "claim_evidence",
            "link-a-live",
            json!({ "claim_id": "claim-a-live", "evidence_id": "evidence-a-live", "relation": "supports", "tenant_id": "uid-a", "person_id": "uid-a" }),
        ),
        record(
            "uid-a",
            "source",
            "source-a-deleted",
            json!({ "source": { "id": "source-a-deleted", "tenant_id": "uid-a", "person_id": "uid-a" } }),
        ),
        record(
            "uid-a",
            "evidence",
            "evidence-a-deleted",
            json!({ "evidence": { "id": "evidence-a-deleted", "source_id": "source-a-deleted", "tenant_id": "uid-a", "person_id": "uid-a" } }),
        ),
        record(
            "uid-a",
            "claim",
            "claim-a-deleted",
            json!({ "id": "claim-a-deleted", "content": "tombstoned matching content", "status": "accepted", "tenant_id": "uid-a", "person_id": "uid-a" }),
        ),
        record(
            "uid-a",
            "claim_evidence",
            "link-a-deleted",
            json!({ "claim_id": "claim-a-deleted", "evidence_id": "evidence-a-deleted", "relation": "supports", "tenant_id": "uid-a", "person_id": "uid-a" }),
        ),
        record(
            "uid-a",
            "deletion",
            "delete-a",
            json!({ "target": { "kind": "claim", "id": "claim-a-deleted" }, "deleted_at": 2, "tenant_id": "uid-a", "person_id": "uid-a" }),
        ),
        record(
            "uid-b",
            "source",
            "source-b",
            json!({ "source": { "id": "source-b", "tenant_id": "uid-b", "person_id": "uid-b" } }),
        ),
        record(
            "uid-b",
            "evidence",
            "evidence-b",
            json!({ "evidence": { "id": "evidence-b", "source_id": "source-b", "tenant_id": "uid-b", "person_id": "uid-b" } }),
        ),
        record(
            "uid-b",
            "claim",
            "claim-b",
            json!({ "id": "claim-b", "content": "foreign matching content", "status": "accepted", "tenant_id": "uid-b", "person_id": "uid-b" }),
        ),
        record(
            "uid-b",
            "claim_evidence",
            "link-b",
            json!({ "claim_id": "claim-b", "evidence_id": "evidence-b", "relation": "supports", "tenant_id": "uid-b", "person_id": "uid-b" }),
        ),
    ];
    for (index, record) in records.iter().enumerate() {
        db.execute(
            APPEND_SQL,
            params![
                record.uid,
                "test-replica",
                record.kind,
                record.id,
                canonical_json(&record.envelope),
                index as i64,
                index as i64
            ],
        )
        .expect("append with worker memory-log SQL");
    }

    let read = |uid| {
        let mut statement = db
            .prepare(READ_SQL)
            .expect("prepare worker memory-log read SQL");
        statement
            .query_map(params![uid, 0, 100], |row| row.get::<_, String>(4))
            .expect("read with worker memory-log SQL")
            .map(|row| serde_json::from_str::<Value>(&row.expect("payload")).expect("JSON payload"))
            .collect::<Vec<_>>()
    };
    let a_records = read("uid-a");
    assert_eq!(a_records.len(), 9);
    assert!(read("uid-b")
        .iter()
        .all(|payload| scoped_record(payload, "uid-a").is_none()));

    for payload in a_records {
        let scoped = scoped_record(&payload, "uid-a").expect("owned scope");
        let identity = record_identity(&scoped).expect("projectable record identity");
        match scoped.kind.as_str() {
            "source" => db.execute("INSERT INTO memory_sources (id, uid) VALUES (?1, ?2)", params![identity.id, "uid-a"]),
            "evidence" => db.execute("INSERT INTO memory_evidence (id, uid, source_revision_id) VALUES (?1, ?2, ?3)", params![identity.id, "uid-a", scoped.record["evidence"]["source_id"].as_str().unwrap().to_owned() + ":revision"]),
            "claim" => db.execute("INSERT INTO memory_claims (id, uid, content, status, zkr_processing_state, recorded_at) VALUES (?1, ?2, ?3, ?4, 'processed', 1)", params![identity.id, "uid-a", scoped.record["content"].as_str().unwrap(), scoped.record["status"].as_str().unwrap()]),
            "claim_evidence" => db.execute("INSERT INTO memory_claim_evidence (uid, claim_id, evidence_id, relation) VALUES (?1, ?2, ?3, ?4)", params!["uid-a", scoped.record["claim_id"].as_str().unwrap(), scoped.record["evidence_id"].as_str().unwrap(), scoped.record["relation"].as_str().unwrap()]),
            "deletion" => db.execute("UPDATE memory_claims SET retracted_at = ?1 WHERE uid = ?2 AND id = ?3", params![deletion_target(&scoped).unwrap().deleted_at, "uid-a", deletion_target(&scoped).unwrap().id]),
            _ => unreachable!(),
        }
        .expect("project owned record");
    }
    db.execute_batch("INSERT INTO memory_source_revisions (id, source_id, uid) SELECT id || ':revision', id, uid FROM memory_sources;
                      INSERT INTO memory_claims_fts (id, uid, content, subject, predicate, value)
                      SELECT id, uid, content, '', '', content FROM memory_claims
                      WHERE status = 'accepted' AND retracted_at IS NULL AND zkr_processing_state = 'processed';")
        .expect("project live claims into retrieval index");

    let matcher = retrieve_match("matching");
    let mut candidates = db
        .prepare(
            "SELECT c.id FROM memory_claims_fts
         JOIN memory_claims c ON c.id = memory_claims_fts.id AND c.uid = memory_claims_fts.uid
         WHERE memory_claims_fts.uid = ?1 AND memory_claims_fts MATCH ?2
           AND c.status = 'accepted' AND c.retracted_at IS NULL
           AND (c.zkr_tier IS NULL OR c.zkr_tier != 'archive')
           AND (c.zkr_processing_state IS NULL OR c.zkr_processing_state = 'processed')
         ORDER BY bm25(memory_claims_fts), c.recorded_at DESC LIMIT ?3",
        )
        .expect("prepare retrieval");
    candidates
        .query_map(params!["uid-a", matcher, 50], |row| row.get::<_, String>(0))
        .expect("retrieve scoped candidates")
        .enumerate()
        .filter_map(|(index, id)| {
            let id = id.expect("claim id");
            let evidence_id = db
                .query_row(
                    "SELECT ce.evidence_id FROM memory_claim_evidence ce
                 JOIN memory_evidence e ON e.id = ce.evidence_id AND e.uid = ce.uid
                 JOIN memory_source_revisions r ON r.id = e.source_revision_id AND r.uid = e.uid
                 JOIN memory_sources s ON s.id = r.source_id AND s.uid = r.uid
                 WHERE ce.claim_id = ?1 AND ce.uid = ?2 AND ce.relation = 'supports'
                   AND e.tombstoned_at IS NULL AND s.tombstoned_at IS NULL",
                    params![id, "uid-a"],
                    |row| row.get(0),
                )
                .ok()?;
            let _presentation = relevance_basis_points(index);
            Some((id, evidence_id))
        })
        .collect()
}

struct Record {
    uid: &'static str,
    kind: &'static str,
    id: &'static str,
    envelope: Value,
}

fn record(uid: &'static str, kind: &'static str, id: &'static str, record: Value) -> Record {
    Record {
        uid,
        kind,
        id,
        envelope: json!({ "kind": kind, "record": record }),
    }
}
