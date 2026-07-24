# Memory authority: cloud-first with a local mirror

Status: partially implemented. The authoritative cloud log, its read endpoint,
the device-side pull client, the log-backed cloud write paths and the retirement
of the per-replica projection namespace have landed; the remaining work is listed
in §6 in the order it should be done. Read this before changing anything in
`worker/src/memory-*.ts`, `app/lib/memory/**`, or the hub's memory modules.

## 1. What changed and why

Before this work the device was the authority. `zkr::MemoryDb` — a per-UID SQLite
file inside the Rust hub — held the record of truth, and D1 held a rebuildable
projection of it (`worker/src/memory-projection.ts`). That had three consequences
we wanted to end:

1. **Two live write authorities.** `POST /v1/memories`, `POST
   /v1/memory/sources/:id/revisions` and `DELETE /v1/memory/sources/:id` wrote
   straight into the D1 read tables, while `POST /v1/memory/zkr-sync` wrote the
   same tables from the device's zkr commit log. Neither path could see the
   other, and nothing ever travelled back down to the device. A memory created
   from the web existed only in the cloud, forever.
2. **No cross-device convergence.** The projection namespaces every row by
   `replica_id`, so a reinstall (new replica id) duplicated a user's whole
   memory, and a second device's memory was invisible to the first.
3. **Web could not work.** The hub does not build for wasm and the web target has
   no hub, so `conversation_controller.dart`, `memory_sync.dart`, `currents.dart`
   and `settings_client.dart` were pinned to Dart-side workarounds. With a
   device-authoritative store there is no way for web to read memory at all.

The inversion: **the cloud holds the authoritative, append-only memory log; every
device keeps a local mirror of that log so it works offline.**

## 2. The authority boundary, precisely

The unit of authority is the append-only `memory_log` table in D1, one ordered
stream per UID (`worker/migrations/0029_memory_authority_log.sql`,
`worker/src/memory-log.ts`).

* **The Worker assigns the sequence.** A record is not part of the user's memory
  until the Worker has appended it and returned its authoritative `sequence`.
  Devices never choose ordering. This is the entire content of "the cloud is the
  authority" — everything else follows from it.
* **The device's zkr database is a capture engine and an offline mirror, not the
  record of truth.** It still produces records (that is where evidence and
  locators are minted) but a record that has not been acknowledged by the Worker
  is *pending*, not *remembered*.
* **The D1 read tables** (`memory_claims`, `memory_evidence`, …) remain a
  derived projection. They are rebuildable from `memory_log` and nothing else
  should be treated as a source.

### Why the device still mints records

`zkr` 0.3.1 exposes `remember`, `correct`, `delete_source`, `search` and
`export` — but **no import**. `remember` allocates its own row ids inside its own
transaction (`store/lifecycle.rs`); there is no API to apply a foreign replica's
records into a local `MemoryDb`. So the cloud cannot mint zkr-shaped records and
push them down, and the device cannot materialize another device's records into
zkr. This is a hard dependency limit, not a design choice — see §6.

## 3. Conflict resolution

Explicitly **not** last-writer-wins, and no wall-clock comparison anywhere.

1. **Append-only.** Nothing in `memory_log` is ever updated or deleted. Every
   mutation is a new entry with a strictly higher authoritative sequence.
2. **Record identity is `(uid, origin_replica, record_kind, record_id)`.** Two
   entries sharing an identity are successive revisions of one record. The entry
   with the highest authoritative sequence is current. Because the Worker assigns
   the sequence, "current" is decided by cloud arrival order, never by a device
   clock.
3. **Replays are idempotent and do not reorder.** An append whose identity and
   canonical payload both match the newest existing entry returns that entry's
   original sequence and writes nothing. A device that retries an upload after a
   flaky connection cannot move a record to the head of the log.
4. **Different replicas never merge.** `origin_replica` is part of identity, so
   two devices that capture the same meeting produce two independently cited
   records. Merging them would require asserting that one device's evidence
   supports the other device's claim, which is exactly the provenance lie the
   evidence model exists to prevent. Deduplication, if we ever want it, belongs
   in retrieval ranking, not in the log.
5. **Corrections and retractions are new records that reference the superseded
   one** (`correction`, `deletion` record kinds), which is already zkr's model.
   An evidence chain is never mutated in place, so a claim's citation is stable
   for the life of the claim.
6. **Conflicting replays are rejected, not merged.** If a device re-sends commit
   sequence *n* with a different `recorded_at` or `event_count` than the staged
   copy, `POST /v1/memory/zkr-sync` answers `409` and the device must resync from
   its cursor. Silent reconciliation of a divergent local log is forbidden.

## 4. Provenance is unchanged

The log stores the zkr export payloads byte-for-byte as canonical JSON. Every
claim still reaches a `TranscriptLocator` (device / provider / stream / segment
ids and time range) through `evidence -> source_revision -> source`, and the
projection still invalidates a claim when its source revision is tombstoned
(`memory-projection.ts`, `DELETE /v1/memory/sources/:id`). Nothing in this change
introduces a claim that cannot be cited, and the log makes provenance *stronger*:
the authoritative sequence is itself a citable fact about when the system came to
believe something.

## 5. Offline behaviour

**There is no on-device speech-to-text and this design does not pretend
otherwise.** `app/native/hub/src/local_ai.rs` wraps
`rs_ai_local::foundationmodels`, which is Apple Foundation Models — a text
generation model, macOS/aarch64 only, with no transcription entry point. The
local STT path in `stt.rs` is a deliberate fail-closed
`SttError::Unavailable` / `TranscriptionAuth::Local`. So:

| Capability | Offline behaviour |
| --- | --- |
| Audio capture | Works. Buffered by the write-ahead log (`app/lib/device/capture_wal.dart`), which already uploads idempotently on reconnect. |
| Transcription | Does **not** work offline. Audio waits in the WAL; segments are produced when the device reconnects. |
| Text capture (notes, corrections, scans) | Works. Written to local zkr, queued as pending log appends. |
| Recall | Works, from the local mirror of the authoritative log, at the last synced sequence. Stale, never wrong: the mirror only ever contains records the cloud already accepted. |
| Writes | Accepted locally as *pending*. Surfaces must distinguish pending from remembered; a pending record is not yet part of memory. |

On reconnect, in order: (1) flush pending zkr commits through `POST
/v1/memory/zkr-sync`, which is replay-safe; (2) pull `GET /v1/memory/log?after=`
from the persisted cursor to advance the mirror; (3) drain the capture WAL.
Step 2 must follow step 1 so a device immediately sees its own writes at their
authoritative sequence.

## 6. What remains, in order

1. **A durable mirror store.** `MemoryMirrorPump`
   (`app/lib/memory/memory_mirror.dart`) drains `GET /v1/memory/log` against a
   `MemoryMirrorStore`, but the only implementation shipped is in-memory, and
   nothing wires the pump into `AppServices` yet. A mirror that does not survive
   a restart is not an offline mirror. The store wants a file under
   `omiDataDirectory()` on desktop/mobile and IndexedDB on web; the cursor is
   already persisted separately and deliberately rewinds when it runs ahead of
   the store.
2. ~~**Route the direct cloud writes through the log.**~~ Done.
   `POST /v1/memories`, `POST /v1/memory/sources/:id/revisions` and
   `DELETE /v1/memory/sources/:id` now live in `worker/src/memory-write.ts`, mint
   zkr-shaped records under the `cloud` origin replica, append them to
   `memory_log` and let `projectMemory` do every read-table write. One residual
   direct writer remains and is listed at 6 below.
3. **A zkr import API.** The device mirror cannot become a real zkr database
   until `zkr` can apply externally-minted records with caller-supplied ids —
   roughly `MemoryDb::apply(records: &[ExportRecord])`, idempotent on
   `(record_kind, record_id)`, preserving `evidence_locators`. Without it the
   Dart mirror must be a separate read-only store and the hub's `search()` cannot
   see other replicas' memory. This is the gating upstream dependency.

   **Status: built upstream, not yet consumed here.** `zkr`'s working tree
   implements `MemoryDb::apply` (`src/store/apply.rs`) with the semantics this
   item asked for: caller-supplied ids; idempotence keyed on `(tenant_id,
   person_id, record_kind, record_id, payload_hash)` through a
   `memory_applied_records` ledger, so a re-applied record is counted skipped
   rather than duplicated; the whole apply running in one `Immediate`
   transaction; and a fixed nine-pass order (source, evidence, claim, origin,
   claim-evidence, profile, review, correction, deletion) that makes a commit
   order-independent — records may arrive in any order within a commit and still
   land with their references satisfied. Locators survive because the record is
   applied as exported and re-validated by `validate_transcript_locator` rather
   than rebuilt. `hub/Cargo.toml` pins `zkr = "0.3.1"`, and the 0.3.1 crate in
   the local registry has no `store/apply.rs`, so the hub cannot call it yet:
   until the dependency moves, the Dart mirror stays a read-only store.
4. ~~**Retire the per-replica projection namespace.**~~ Done, ahead of (3):
   `migrations/0030_memory_log_projection.sql` backfills `zkr_memory_records`
   into the log, deletes every `zkr:`-namespaced read-table row, and drops the
   staging tables. Records are now keyed by their bare zkr record id, so a
   reinstall rejoins the existing stream. Until (3) lands the device still
   cannot *apply* another replica's records locally; convergence is cloud-side
   only.
5. **`worker-rs` parity.** `worker-rs/**` was not touched. It needs the same
   `memory_log` append and read paths before it can serve any memory route, or it
   will silently diverge from the TypeScript Worker.
6. **The last direct read-table writer.** `worker/src/currents.ts` still inserts
   `memory_sources`, `memory_source_revisions` and `memory_evidence` directly
   when it materializes a Currents digest into a citable source, and
   `POST /v1/memory/daily-reviews` in `routes.ts` writes `memory_daily_reviews`
   and its citations directly. Both predate the log and neither has a
   `daily_review` projection statement to replace it, so they are the remaining
   drift; they are additive and never contradict the log, but they are not
   rebuildable from it.

## 7. Web target

Web becomes hub-independent for memory once step 1 above lands: reads come from
`GET /v1/memory/log` and `GET /v1/memory/retrieve`, writes from step 2's
log-backed endpoints, and no part of that path requires the Rust hub. As of this
change the Worker side of that contract exists and the Dart side does not, so
web is not yet hub-independent.

## 8. The read path: projections, not sources

`worker/src/memory-projection.ts` is the only writer of the D1 read tables, and
it derives all of them from one intermediate table. `materializeRecords` folds
new log entries into `memory_records` — the current revision of each record,
keyed `(uid, record_kind, record_id)` — under
`WHERE excluded.sequence >= memory_records.sequence`, so a later log sequence
always wins and following the log incrementally lands the same rows as replaying
it from zero. `projectMemory` then rewrites `memory_sources`,
`memory_source_revisions`, `memory_evidence`, `memory_claims`,
`memory_claims_fts`, `memory_claim_evidence` and `memory_profile_entries` from
`memory_records` in a single D1 batch, and records how far it got in
`memory_projection_state`. `ensureMemoryProjected` skips the whole batch when
the log head has not moved past that mark, and the `/v1/memory/*` and
`/v1/memories` middleware calls it before every read.

Two properties follow, and both are the reason for the shape:

* **A read table can be dropped and rebuilt.** Nothing in the projection reads
  its own output as an input, and nothing reaches for a wall clock while
  deriving a row: every timestamp falls back to the log entry's own
  `recorded_at` (`COALESCE(json_extract(...), s.recorded_at)`), so a rebuild
  from sequence zero produces the same rows rather than rows stamped with the
  rebuild's date. The one deliberate exception is the retraction sweep, which
  stamps `retracted_at` with the projection's `now` — a fact about when the
  system noticed the citation was gone, not about the record.
* **Rules that belong to the evidence model live in the projection, not in a
  route.** Deleting a source is an append of a `deletion` record; the projection
  propagates the tombstone to that source's evidence and then retracts every
  claim that is left with citations but no *live* citation. A claim's retraction
  is therefore the same whether the source was deleted from the web, from a
  device, or by replaying an old log — because it is computed, not performed.

Corrections work the same way: a claim is projected as `superseded` when a
`correction` record naming it as `superseded_claim_id` exists, so the correction
is a new record and the original row is never edited in place.

### 8.1 Cited retrieval

`retrieveCitedMemory` (`worker/src/memory-read.ts`) is the retrieval every
first-party and public surface answers from. It is a BM25 match over
`memory_claims_fts` — each whitespace-separated term of the query, first 16,
quoted and joined with `AND` — filtered to claims that are `accepted`, not
retracted, inside their valid and recorded time windows, not archived, and
processed. Then, for each candidate, it fetches the evidence supporting it,
joined `memory_claim_evidence -> memory_evidence -> memory_source_revisions ->
memory_sources` with `relation = 'supports'` and both tombstone columns null.

The last step is the one that matters: a candidate whose evidence list comes
back empty is dropped from the result rather than returned uncited. A claim the
system can no longer show you the source of is not an answer, so retrieval
returns fewer items instead of unsupported ones, and reports
`gaps: ["No cited memory matched the query."]` when that leaves nothing. Each
returned item carries `evidence_ids`, and each of those resolves through the
same chain to a source revision and its `locator` — for pendant and meeting
audio, a `TranscriptLocator` naming device, provider, stream, segment and time
range. A citation is traceable to the record that produced it because the record
is still in the log at a known sequence and the projection is a pure function of
it.

`listProfileMemories` applies the same discipline: it joins through evidence and
source with the identical liveness predicates, so an entry with no surviving
citation cannot appear in the profile view either.

## 9. The vector index

Semantic recall is a second index over the same claims, never a second source.
`worker/src/memory-vectors.ts` enqueues touched claim ids into
`pending_embeddings` after every log append — from the cloud write paths and
from `zkr-sync` alike — and `drainPendingEmbeddings` embeds them through Workers
AI and upserts into Vectorize, deleting the vector instead when the claim is no
longer eligible. Eligibility is the same predicate the read path uses, so a
retracted or archived claim is removed from the index rather than left to be
matched. `searchMemoryClaims` filters by `uid` at the index and then re-checks
every hit against `memory_claims` with the liveness and time-window conditions
before returning it, so a stale vector can cost a result but cannot produce one.
