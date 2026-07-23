# Memory authority: cloud-first with a local mirror

Status: partially implemented. The authoritative cloud log, its read endpoint and
the device-side pull client have landed; the remaining work is listed in §6 in
the order it should be done. Read this before changing anything in
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
2. **Route the direct cloud writes through the log.** `POST /v1/memories`,
   `POST /v1/memory/sources/:id/revisions` and `DELETE /v1/memory/sources/:id`
   still write the read tables directly. They must append to `memory_log` and let
   the projection do the writing, or the second authority survives.
3. **A zkr import API.** The device mirror cannot become a real zkr database
   until `zkr` can apply externally-minted records with caller-supplied ids —
   roughly `MemoryDb::apply(records: &[ExportRecord])`, idempotent on
   `(record_kind, record_id)`, preserving `evidence_locators`. Without it the
   Dart mirror must be a separate read-only store and the hub's `search()` cannot
   see other replicas' memory. This is the gating upstream dependency.
4. **Retire the per-replica projection namespace** once (3) lands, so a reinstall
   rejoins the existing stream instead of forking one.
5. **`worker-rs` parity.** `worker-rs/**` was not touched. It needs the same
   `memory_log` append and read paths before it can serve any memory route, or it
   will silently diverge from the TypeScript Worker.

## 7. Web target

Web becomes hub-independent for memory once step 1 above lands: reads come from
`GET /v1/memory/log` and `GET /v1/memory/retrieve`, writes from step 2's
log-backed endpoints, and no part of that path requires the Rust hub. As of this
change the Worker side of that contract exists and the Dart side does not, so
web is not yet hub-independent.
