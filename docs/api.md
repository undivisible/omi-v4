# Omi Public API

Base URL: `https://omi.tsc.hk`

Two programmatic surfaces are served by the same Cloudflare Worker:

| Surface | Base path | Protocol |
| --- | --- | --- |
| Public REST API | `/api/v1` | JSON over HTTPS |
| MCP server | `/mcp` | MCP streamable HTTP (JSON-RPC 2.0) |

Both surfaces accept the same credentials, enforce the same scopes, resolve to
the same uid, and share one rate-limit budget per user. Everything they expose
is scoped to a single Omi account: there is no cross-account access and no
admin surface.

The first-party routes under `/v1/...` are **not** part of this contract. They
require a Firebase ID token, change with the apps, and are documented only by
the source. Build against `/api/v1` and `/mcp`.

---

## 1. Authentication

Every request to `/api/v1/*` and `/mcp` must carry a credential. Two are
accepted.

### 1.1 API keys (recommended for programmatic access)

An API key is a long-lived, per-account, revocable credential. Send it as a
bearer token:

```
Authorization: Bearer omi_sk_1f3c9ab2_9pQ7...43-chars
```

or, equivalently, in a dedicated header:

```
X-API-Key: omi_sk_1f3c9ab2_9pQ7...43-chars
```

`Authorization` wins when both are present.

Key format: `omi_sk_` + 8 lowercase hex characters (the public prefix) + `_` +
43 base64url characters (the secret). Total length is 59 characters. Match keys
with `^omi_sk_[0-9a-f]{8}_[A-Za-z0-9_-]{43}$`.

Storage: only the SHA-256 digest of the full key is persisted, in the D1 table
`api_keys`. Lookup is by public prefix and the digest comparison is
constant-time, so neither the database nor response timing reveals a usable
credential. The plaintext key is returned exactly once, at creation.

### 1.2 Firebase ID tokens

The apps' own credential also works on the public surface:

```
Authorization: Bearer <Firebase ID token>
```

A Firebase-authenticated caller is the account owner in person and therefore
carries **every** scope. Tokens expire in about an hour; do not use them for
unattended integrations.

### 1.3 Scopes

| Scope | Grants |
| --- | --- |
| `memory:read` | `GET /api/v1/memory/search`, `GET /api/v1/memories`; tools `search_memory`, `list_memories` |
| `currents:read` | `GET /api/v1/currents`; tool `list_currents` |
| `currents:write` | `POST /api/v1/currents`; tool `create_current` |
| `conversations:read` | `GET /api/v1/conversations/messages`, `GET /api/v1/notes`; tools `list_conversation_messages`, `list_meeting_notes` |
| `assistant:write` | `POST /api/v1/assistant/messages`; tool `ask_omi` |
| `facetime:write` | `POST /api/v1/facetime/calls`; tool `start_facetime_call` |
| `speech:write` | `POST /api/v1/speech/transcriptions`, `POST /api/v1/speech/synthesis`; tools `transcribe_audio`, `speak_text` |

`GET /api/v1/me` requires a valid credential but no scope.

A key missing the scope for a route gets `403` with
`{"error":"Missing scope","scope":"<scope>"}`. On MCP the same condition is a
JSON-RPC error with code `-32000`.

### 1.4 Managing keys

Key management is deliberately **not** available to API keys — a key cannot
mint or revoke keys. These three routes live on the first-party surface and
require a Firebase ID token.

#### `POST /v1/api-keys`

Create a key.

Request:

```json
{
  "name": "my-integration",
  "scopes": ["memory:read", "currents:read", "currents:write"],
  "expiresAt": 1793664000000
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `name` | string | yes | 1–120 characters after trimming. Label only. |
| `scopes` | string[] | no | Defaults to all six scopes. Must be non-empty and contain only known scopes. Duplicates are collapsed. |
| `expiresAt` | integer \| null | no | Unix epoch **milliseconds**. Must be in the future. `null` or omitted means no expiry. |

`201` response:

```json
{
  "key": "omi_sk_1f3c9ab2_9pQ7...",
  "apiKey": {
    "id": "b3f1c0e2-...",
    "name": "my-integration",
    "prefix": "omi_sk_1f3c9ab2",
    "scopes": ["memory:read", "currents:read", "currents:write"],
    "createdAt": 1761177600000,
    "lastUsedAt": null,
    "expiresAt": 1793664000000,
    "revokedAt": null
  }
}
```

`key` is shown only here. Store it immediately.

Errors: `400 {"error":"Invalid API key request"}`,
`409 {"error":"API key limit reached"}` (25 live keys per account),
`429 {"error":"Too many requests"}` (10 creations per hour per account).

#### `GET /v1/api-keys`

`200` → `{"keys":[ <apiKey object>, ... ]}`, newest first, up to 100. Includes
revoked keys. Never includes the secret.

#### `DELETE /v1/api-keys/{id}`

`204` on success. `404 {"error":"API key not found"}` if the id is unknown,
belongs to another account, or is already revoked. Revocation is immediate: the
next request with that key gets `401`.

### 1.5 Authentication errors

| Status | Body | Cause |
| --- | --- | --- |
| `401` | `{"error":"Authentication required"}` | No credential presented. |
| `401` | `{"error":"Authentication failed"}` | Unknown, malformed, expired or revoked key; invalid Firebase token. |
| `503` | `{"error":"Authentication unavailable"}` | Credential store or Firebase key set unreachable. Retry. |

---

## 2. Rate limits

Limits are fixed windows counted per account (uid), shared between the REST API
and MCP. Firebase-authenticated calls count against the same budget.

| Bucket | Applies to | Limit |
| --- | --- | --- |
| `public-read` | `GET /memory/search`, `GET /memories`, `GET /currents`, `GET /conversations/messages`, `GET /notes`; and their tools | 120 requests / 60 s |
| `public-write` | `POST /currents`; tool `create_current` | 60 requests / 60 s |
| `public-assistant` | `POST /assistant/messages`; tool `ask_omi` | 20 requests / 60 s |
| `public-facetime` | `POST /facetime/calls`; tool `start_facetime_call` | 5 requests / 60 s |
| `public-transcribe` | `POST /speech/transcriptions`; tool `transcribe_audio` | 10 requests / 60 s |
| `public-speak` | `POST /speech/synthesis`; tool `speak_text` | 20 requests / 60 s |
| key creation | `POST /v1/api-keys` | 10 / 60 min |

Exceeding a limit returns `429` with `{"error":"Too many requests"}` and a
`Retry-After` header in whole seconds. On MCP the same condition arrives as a
tool result with `isError: true` and body `{"error":"Too many requests"}`.

`GET /api/v1/me` is not rate limited.

Managed-AI capacity control applies to `ask_omi` / `POST /assistant/messages`
independently of these buckets and can also produce `429`. The speech routes
sit behind the same managed-STT admission and cost reservation the live STT
sessions use, which can also produce `429` — see §4.10 and §4.11.

---

## 3. Conventions

- All request and response bodies are JSON; `Content-Type: application/json`.
- All timestamps in request and response bodies are Unix epoch **milliseconds**
  (integers), except inside a Current's `timing` block and `createdAt` /
  `updatedAt`, which are ISO-8601 strings — see §4.4.
- Errors are always `{"error": "<human-readable message>"}`, sometimes with
  extra fields (`scope` on a scope failure).
- Unknown query parameters and unknown body fields are ignored.
- Malformed JSON, a non-object body, or a body that fails validation is `400`.
- Unknown paths are `404 {"error":"Not found"}`.

---

## 4. REST endpoints

### 4.1 `GET /api/v1/me`

Identify the credential. No scope required.

`200`:

```json
{
  "uid": "firebase-uid",
  "email": "person@example.com",
  "auth": "api_key",
  "keyId": "b3f1c0e2-...",
  "scopes": ["memory:read", "currents:read"]
}
```

`auth` is `"api_key"` or `"firebase"`. For a Firebase caller, `keyId` and
`scopes` are `null` (meaning: all scopes).

### 4.2 `GET /api/v1/memory/search`

Scope: `memory:read`.

Search the account's memory. Every result cites the evidence it came from;
claims with no surviving citation are never returned.

| Query parameter | Type | Default | Range |
| --- | --- | --- | --- |
| `q` | string | — (required) | 1–500 characters |
| `limit` | integer | `12` | 1–50 (clamped to 20 in `semantic` mode) |
| `mode` | `keyword` \| `semantic` | `keyword` | — |

`keyword` is a BM25-ranked full-text match; every whitespace-separated term
(first 16) must be present. `semantic` is embedding similarity over the same
claims and is better for paraphrases.

`200`, `mode=keyword`:

```json
{
  "query": "release notes",
  "items": [
    {
      "memory": { "kind": "claim", "id": "claim-uuid" },
      "excerpt": "Ship the v4 release notes before Friday",
      "relevance_basis_points": 10000,
      "evidence_ids": ["evidence-uuid"]
    }
  ],
  "gaps": [],
  "mode": "keyword"
}
```

`relevance_basis_points` is a rank-derived score out of 10000, descending.
`gaps` contains `["No cited memory matched the query."]` when `items` is empty,
and is otherwise `[]`.

`200`, `mode=semantic`:

```json
{
  "query": "release notes",
  "mode": "semantic",
  "items": [
    { "id": "claim-uuid", "content": "Ship the v4 release notes before Friday", "score": 0.83 }
  ]
}
```

`score` is cosine similarity in `[0, 1]`. If the vector index is unavailable,
`items` is `[]` rather than an error.

Errors: `400 {"error":"Invalid memory search"}`, `403`, `429`.

### 4.3 `GET /api/v1/memories`

Scope: `memory:read`.

List the account's active profile memories — the durable view of who the user
is and what they are currently doing — newest updated first.

| Query parameter | Type | Default | Range |
| --- | --- | --- | --- |
| `limit` | integer | `100` | 1–100 |

`200`:

```json
{
  "memories": [
    {
      "id": "profile-entry-uuid",
      "content": "Prefers async written updates over meetings",
      "source": "conversation",
      "evidence": [
        {
          "id": "evidence-uuid",
          "sourceId": "source-uuid",
          "sourceRevisionId": "revision-uuid",
          "quote": "let's keep it in writing",
          "locator": null
        }
      ],
      "profileKind": "stable",
      "status": "active",
      "validFrom": 1761177600000,
      "validTo": null,
      "createdAt": 1761177600000,
      "updatedAt": 1761181200000
    }
  ]
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `source` | string | Originating source kind: `conversation`, `screen`, `audio`, `document`, `integration`, `user_correction`. |
| `evidence[].locator` | any \| null | Opaque source-specific position; may be `null`. |
| `profileKind` | `stable` \| `current` | Enduring trait vs present context. |
| `status` | `active` \| `pinned` | Archived entries are never returned. |
| `validFrom` / `validTo` | integer \| null | Validity window; `validTo: null` means open-ended. |

Errors: `400 {"error":"Invalid memory list"}`, `403`, `429`.

### 4.4 `GET /api/v1/currents`

Scope: `currents:read`.

List open Currents — proposed next actions derived from memory — ranked by
confidence adjusted by the user's past feedback. Only `surfaced` and `accepted`
Currents are returned; candidates not yet due, snoozed, dismissed and expired
ones are not. Up to 100 items. Reading this endpoint promotes due candidates and
expires overdue ones as a side effect, exactly as the app does.

`200`:

```json
{
  "currents": [
    {
      "id": "current-uuid",
      "status": "surfaced",
      "title": "Send the release notes",
      "summary": "The release shipped but nobody has been told.",
      "evidence": [{ "sourceId": "source-uuid", "reason": "Based on: let's ship Friday" }],
      "sourceKind": "conversation",
      "reason": "Based on: let's ship Friday",
      "confidence": 0.9,
      "proposedNextStep": "Draft a two-line note and send it.",
      "proposedAction": { "kind": "review", "instruction": "Draft a two-line note and send it." },
      "timing": {
        "surfaceAt": "2026-07-23T09:00:00.000Z",
        "expiresAt": null,
        "snoozedUntil": null
      },
      "feedbackReference": null,
      "executionReference": null,
      "createdAt": "2026-07-23T08:59:00.000Z",
      "updatedAt": "2026-07-23T09:00:00.000Z",
      "metadata": { "crepus": "<widget source>" }
    }
  ]
}
```

| Field | Type | Notes |
| --- | --- | --- |
| `status` | `surfaced` \| `accepted` | — |
| `confidence` | number | `0`–`1`. |
| `timing.*`, `createdAt`, `updatedAt` | ISO-8601 string \| null | Note: these are strings, not epoch milliseconds. |
| `sourceKind` | string \| null | Kind of the cited memory source. |
| `metadata.crepus` | string | Present only when the Current carries an AI-authored widget description. Treat as untrusted display data. |

Errors: `403`, `429`.

### 4.5 `POST /api/v1/currents`

Scope: `currents:write`.

Create a Current. It is created with status `candidate` and becomes visible to
the user at `surfaceAt`; it will therefore usually **not** appear in
`GET /api/v1/currents` until then.

Request:

```json
{
  "title": "Send the release notes",
  "summary": "The release shipped but nobody has been told.",
  "reason": "The user said the release was ready yesterday.",
  "proposedNextStep": "Draft a two-line note and send it.",
  "confidence": 0.8,
  "surfaceAt": 1761177600000,
  "expiresAt": 1761264000000
}
```

| Field | Type | Required | Default | Constraints |
| --- | --- | --- | --- | --- |
| `title` | string | yes | — | 1–120 characters. |
| `summary` | string | yes | — | 1–500 characters. |
| `reason` | string | yes | — | 1–500 characters. Recorded as the citation quote when `evidenceId` is omitted. |
| `proposedNextStep` | string | yes | — | 1–500 characters. |
| `confidence` | number | no | `0.7` | `0`–`1` inclusive. |
| `surfaceAt` | integer | no | now | Epoch ms, positive. |
| `expiresAt` | integer \| null | no | `null` | Epoch ms, strictly greater than `surfaceAt`. |
| `evidenceId` | string \| null | no | `null` | An existing Omi evidence id. Omit unless you hold one. |

Every Current must cite evidence. When `evidenceId` is omitted, a memory source
of kind `integration` is created for the account with `reason` as its quote, and
the new Current cites it. When `evidenceId` is supplied it must be a live,
non-tombstoned evidence id belonging to the caller's account.

`201` → `{"current": <Current object as in §4.4>}`.

Errors: `400 {"error":"Invalid Current"}`,
`404 {"error":"Cited evidence not found"}`, `403`, `429`.

### 4.6 `GET /api/v1/conversations/messages`

Scope: `conversations:read`.

Read the account's single assistant conversation in cursor order. `cursor` is a
monotonically increasing integer; page forward by passing the previous
`nextCursor` as `after`.

| Query parameter | Type | Default | Range |
| --- | --- | --- | --- |
| `after` | integer | `0` | ≥ 0 |
| `limit` | integer | `100` | 1–200 |

`200`:

```json
{
  "conversationId": "default",
  "messages": [
    {
      "cursor": 42,
      "id": "message-uuid",
      "clientMessageId": "api:9f0c...",
      "role": "user",
      "source": "web",
      "text": "what did I say about the release?",
      "channelMessageId": null,
      "deliveryId": null,
      "createdAt": 1761177600000
    }
  ],
  "nextCursor": 42
}
```

`role` is `user` or `assistant`. `source` is `app`, `web`, `desktop`,
`telegram` or `blooio`. `blooio` is the stored identifier for the **iMessage
channel**; the provider behind it is now Sendblue. The identifier is
deliberately unchanged — it appears in three D1 `CHECK` constraints and in
`worker-rs`, and rewriting it would rebuild those tables and require both
binaries to ship at once, for no functional gain. Existing bindings therefore
keep working untouched. See §4.9.2. `nextCursor` equals `after` when no messages were
returned, so polling is safe. `channelMessageId` and `deliveryId` are non-null
only for messages that travelled over a linked chat channel.

Errors: `400 {"error":"Invalid replay range"}`, `403`, `429`.

### 4.7 `GET /api/v1/notes`

Scope: `conversations:read`.

List generated notes — one per local day, written from that day's conversation
and meeting evidence — newest day first. This is the same corpus the MCP tool
`list_meeting_notes` reads.

| Query parameter | Type | Default | Range |
| --- | --- | --- | --- |
| `limit` | integer | `50` | 1–100 |

`200`:

```json
{
  "notes": [
    {
      "id": "review-uuid",
      "localDate": "2026-07-22",
      "inputRevision": "revision-fingerprint",
      "body": "Standup: the release is cut...",
      "citations": [
        {
          "id": "evidence-uuid",
          "sourceId": "source-uuid",
          "sourceRevisionId": "revision-uuid",
          "quote": "the release is cut",
          "locator": null
        }
      ],
      "createdAt": 1761177600000,
      "updatedAt": 1761181200000
    }
  ]
}
```

`localDate` is `YYYY-MM-DD` in the user's local timezone. `inputRevision`
identifies the input the note was generated from; a day can have more than one
note if its input changed. Retracted notes are never returned.

Errors: `400 {"error":"Invalid note list"}`, `403`, `429`.

### 4.8 `POST /api/v1/assistant/messages`

Scope: `assistant:write`. **Requires an active Omi Pro subscription on the
account.**

Send a message to the user's assistant and get the reply. The assistant answers
with the account's synced memory and the last 12 conversation messages in
context. Both the question and the reply are appended to the conversation read
by `GET /api/v1/conversations/messages`, recorded with source `web`.

Request:

```json
{
  "text": "summarise what I decided about the release",
  "clientMessageId": "my-app:2026-07-23:001"
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `text` | string | yes | 1–20000 characters after trimming. |
| `clientMessageId` | string | no | Idempotency key. 8–120 characters matching `[A-Za-z0-9._:-]`. Defaults to a generated `api:<uuid>`. The reply is stored under `<clientMessageId>:reply`. |

`200`:

```json
{
  "reply": "You decided to cut the release Friday and send notes after.",
  "message": {
    "cursor": 42,
    "id": "message-uuid",
    "clientMessageId": "my-app:2026-07-23:001",
    "role": "user",
    "source": "web",
    "text": "summarise what I decided about the release",
    "channelMessageId": null,
    "deliveryId": null,
    "createdAt": 1761177600000,
    "replayed": false
  },
  "answer": { "...": "same shape, role: assistant" }
}
```

`reply` is trimmed and truncated to 4096 characters. `message.replayed` is
`true` when the `clientMessageId` had already been stored with identical
content.

Reusing a `clientMessageId` with *different* text is a conflict, not a replay.

Errors:

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error":"Invalid assistant message"}` | Missing/oversized `text`, or malformed `clientMessageId`. |
| `403` | `{"error":"Managed Pro required"}` | Account has no active Pro entitlement. |
| `403` | `{"error":"Missing scope","scope":"assistant:write"}` | Key lacks the scope. |
| `409` | `{"error":"Client message ID conflict"}` | `clientMessageId` reused with different content. |
| `429` | `{"error":"Too many requests"}` | Rate limit or managed-AI capacity. |
| `502` | `{"error":"Managed AI unavailable"}` | Upstream model failed or is unconfigured. |

This endpoint is synchronous and can take tens of seconds. Allow at least a
60-second client timeout. It does not stream; for token streaming, use the
first-party `/v1/chat/completions` route with a Firebase token.

### 4.9 `POST /api/v1/facetime/calls`

Scope: `facetime:write`.

> **Status: live on accounts with a Sendblue FaceTime line.** The provider is
> Sendblue (`POST https://api.sendblue.com/facetime/start-call`), which requires
> a purchased FaceTime number. On an account without one the route keeps its
> graceful state and returns `503` with `code: "facetime_unavailable"`.

Place a FaceTime Audio call. The provider rings the handle on the recipient's
real device and returns Agora WebRTC credentials for the call's audio channel;
Omi joins that channel server-side and bridges the audio to Gemini Live, so the
recipient simply talks to Omi. There is no join link and no browser anywhere in
the path — see §4.9.1.

This is **side-effectful and not undoable**: it rings a real person's phone.
Confirm the handle with the user before calling it.

Request:

```json
{
  "handle": "+15551234567",
  "idempotencyKey": "my-app:call:001"
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `handle` | string | yes | Who to call. Must be an E.164 phone number — `+` then 7–15 digits, first digit non-zero. An email address parses but is refused with `400` before anything is sent upstream: Sendblue dials numbers, not FaceTime email identities. |
| `idempotencyKey` | string | no | 8–120 characters matching `[A-Za-z0-9._:-]`. Hashed with the uid to derive the session id, so a retry lands on the same admission reservation instead of placing a second call. Defaults to a fresh UUID, which makes each call distinct. |

A handle that is neither an E.164 number nor a plausible email address is
rejected locally with `400`; nothing is sent upstream.

`201`:

```json
{
  "call": {
    "handle": "+15551234567",
    "sessionId": "9f8e7d6c5b4a32100123456789abcdef",
    "link": "https://omi.tsc.hk/facetime/sessions/9f8e7d6c5b4a32100123456789abcdef"
  }
}
```

`link` is retained for compatibility with existing clients, which validate that
it is an `https` URL. It now addresses the bridge session rather than an Apple
join page; nothing joins the call by opening it.

Errors:

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error":"Invalid FaceTime handle"}` | Handle failed local validation, or `idempotencyKey` is malformed. No upstream call was made. |
| `400` | `{"error":"Handle rejected by provider"}` | Handle passed local validation but the provider refused it (upstream `400`/`422`) — for example a number with no FaceTime account. |
| `403` | `{"error":"Missing scope","scope":"facetime:write"}` | Key lacks the scope. |
| `429` | `{"error":"Too many requests"}` | Rate limit; see §2. |
| `502` | `{"error":"FaceTime calling unavailable"}` | Provider error, timeout, or an unusable response body. Safe to retry with the same `idempotencyKey`. |
| `429` | `{"error":"FaceTime capacity exceeded"}` | The realtime admission controller refused the session — the uid or the deployment is at its concurrent-session, seconds, or cost budget. `Retry-After` is set. |
| `503` | `{"error":"FaceTime calling is not provisioned on this account","code":"facetime_unavailable"}` | No FaceTime line on the Sendblue account (upstream `402`/`403`/`404`/`501`), or no `GEMINI_API_KEY` for the bridge. **Do not retry** — this is a product state, not a transient fault. Distinguish it by `code`, not by the status. When the bridge key is missing the phone is never rung. |
| `503` | `{"error":"FaceTime calling unavailable"}` | Credentials are unset or rejected (`SENDBLUE_*`, upstream `401`). |

#### 4.9.1 How the audio is bridged

`POST /facetime/start-call` returns `{appId, channelName, token, uid}` for an
Agora channel rather than a link. Joining that channel needs Agora's native
Server Gateway SDK (x86_64 Linux), which cannot run in the Workers runtime, so
the bridge is a **Cloudflare Container** (`worker/container/facetime-bridge`)
driven by the `FaceTimeBridge` Durable Object:

1. `startFaceTimeSession` takes an admission reservation from `STT_ADMISSION`
   (the same bounded seconds/cost controller the realtime STT path uses),
   records the session in `managed_ai_requests`, then places the call.
2. The Durable Object starts one container per call and passes the Agora
   credentials, the Gemini key and the session deadline as process environment.
   Nothing secret is baked into the image.
3. The container joins the channel, streams caller audio to Gemini Live at
   16 kHz mono, and pushes Gemini's 24 kHz audio back into the channel. Both
   directions use bounded queues that drop the oldest frames under
   backpressure, and every decoded chunk is size-capped.
4. The reservation is released on **every** exit path: the container's
   `monitor()` promise, an explicit stop, the Durable Object alarm, the
   container's own deadline, and the admission controller's claim alarm.

Audio only — no video track is published or subscribed.

Required environment (secrets via `wrangler secret put`, never committed):

| Variable | Purpose |
| --- | --- |
| `SENDBLUE_API_KEY_ID` / `SENDBLUE_API_KEY_SECRET` | Sendblue API credentials, sent as `sb-api-key-id` / `sb-api-secret-key`. |
| `SENDBLUE_FACETIME_NUMBER` | The FaceTime-enabled Sendblue number to call from. |
| `GEMINI_API_KEY` | Gemini Live. OpenRouter cannot carry realtime, so this is its own key. |
| `GEMINI_LIVE_MODEL` | Live model id (var, already set). |
| `FACETIME_MAX_SESSION_SECONDS` | Session cap, default 600, hard-capped at 3600. |
| `FACETIME_COST_MICROUSD_PER_MINUTE` | Reservation cost estimate, default 30000. |
| `FACETIME_SYSTEM_PROMPT` | Optional system instruction for the call. |
| `AGORA_CLOUD_PROXY` | `tcp` (default) pins media to TLS 443 via Agora Cloud Proxy; `udp` or anything else uses direct mode. |

#### 4.9.2 iMessage channel: Sendblue

The iMessage/SMS/RCS channel moved from Blooio to Sendblue. Exactly one
provider is live per deployment: `delivery.ts` uses Sendblue when the Sendblue
variables are set, and falls back to Blooio otherwise. Telegram is untouched.

**Outbound** — `POST https://api.sendblue.com/api/send-message` with
`{number, from_number, content}` and the `sb-api-key-id` / `sb-api-secret-key`
headers. Sendblue has **no idempotency key**, so the delivery queue's lease and
status machinery is the only duplicate-send guard; do not retry outside it.

**Inbound** — `POST /webhooks/sendblue/<SENDBLUE_WEBHOOK_PATH_TOKEN>`.

> **Security caveat, stated plainly.** Sendblue does not sign webhook bodies.
> It echoes the shared secret configured for the endpoint back in an
> `sb-signing-secret` header. There is no HMAC, no timestamp, and therefore no
> binding between the secret and the payload — anyone who observes that header
> once can forge inbound messages until it is rotated. This is materially
> weaker than the Blooio and Stripe paths, and cannot be fixed from our side.
>
> Compensating controls, all implemented in `worker/src/sendblue.ts`:
>
> 1. The header is compared in **constant time**, so it cannot be recovered by
>    timing the endpoint.
> 2. The route carries a **second high-entropy path segment**
>    (`SENDBLUE_WEBHOOK_PATH_TOKEN`), also compared in constant time. Both the
>    header and the path must leak together for a forgery to land.
> 3. Replay is bounded by `webhook_events`, keyed on `message_handle`, so a
>    captured request cannot be replayed into a second inbound message.
> 4. Rotate the secret through Sendblue's webhooks API on any suspicion of
>    exposure.

The `receive` payload is mapped as: `from_number` → channel user id,
`group_id` (when non-empty) → chat id so group threads stay one conversation,
`content` → text, `media_url` → carried through for voice-note transcription.
Outbound echoes (`is_outbound: true`) are dropped.

Sendblue also exposes a `call_log` webhook carrying `disposition`
(`connected` / `not_answered` / `voicemail`) and `transcript`. It fires only
for outbound calls placed from the Sendblue **dashboard** — not for API-placed
FaceTime calls — so it is not wired up.

Environment:

| Variable | Purpose |
| --- | --- |
| `SENDBLUE_NUMBER` | The line messages are sent from. |
| `SENDBLUE_WEBHOOK_SIGNING_SECRET` | Value expected in `sb-signing-secret`. |
| `SENDBLUE_WEBHOOK_PATH_TOKEN` | Secret path segment on the inbound route. |

Migrating the channel also gains SMS and RCS fallback, group messaging,
typing indicators, read receipts, expressive send styles and voice notes
(`.caf` media renders as a voice memo). It loses Blooio's body-signed webhook
and its idempotency key.

### 4.10 `POST /api/v1/speech/transcriptions`

Scope: `speech:write`. **Requires an active Omi Pro subscription on the
account.**

Transcribe a recording server-side. This is the path for callers that have no
in-process Omi hub — the FaceTime / Gemini Live bridge, a phone flushing a
write-ahead log of buffered audio after a dropout, and third-party
integrations. The live capture path in the desktop and mobile apps does not use
this route; it transcribes in the hub.

The call runs as an OpenRouter chat completion against the first tier whose
model declares audio input: balanced (`OMI_MODEL_BALANCED`, default
`xiaomi/mimo-v2.5`), then transcribe (`OMI_MODEL_TRANSCRIBE`), then multimodal
— through the Cloudflare AI Gateway when one is configured. When no configured
model can accept audio the request is refused with `503` rather than sent to a
text-only model.

Request:

```json
{
  "audio": "<base64>",
  "format": "mp3",
  "clientMessageId": "phone:wal:2026-07-23:0007",
  "language": "en",
  "durationSeconds": 42
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `audio` | string | yes | Base64 of the raw audio bytes; no `data:` prefix. Maximum 10 MiB decoded (about 14 MiB of base64). |
| `format` | string | yes | `wav` or `mp3`. |
| `clientMessageId` | string | yes | Idempotency key. 8–120 characters matching `[A-Za-z0-9._:-]`. Required, not defaulted: a retry that generated a fresh id would be charged twice. |
| `language` | string | no | `auto` (default) or a BCP-47 tag such as `en` or `en-US`. A hint only. |
| `durationSeconds` | integer | no | Known duration. When omitted it is estimated from the upload size, conservatively (`wav` at 32 kB/s, `mp3` at 4 kB/s), and the estimate is what gets reserved against the budget. |

The whole request body is capped at roughly 14 MiB; a larger body is rejected
before it is buffered. Audio longer than `SPEECH_MAX_AUDIO_SECONDS` (default
900 s) is rejected before any upstream call.

`200`:

```json
{
  "requestId": "sha256-of-uid-and-clientMessageId",
  "clientMessageId": "phone:wal:2026-07-23:0007",
  "model": "xiaomi/mimo-v2.5",
  "language": "en",
  "durationSeconds": 42,
  "text": "hello there second line",
  "segments": [
    { "index": 0, "start": 0, "end": 1.5, "text": "hello there" },
    { "index": 1, "start": 1.5, "end": 3, "text": "second line" }
  ]
}
```

`start` and `end` are seconds from the beginning of the audio, **as reported by
the model** — treat them as approximate, and expect `null` on both when the
model returns an untimed transcript. In that case the whole transcript is
returned as a single segment.

**Idempotency.** The `clientMessageId` decides identity. Retrying a completed
request with the same id and the same payload replays the stored transcript
verbatim with `"idempotentReplay": true` added — no second upstream call, no
second charge, no duplicated segments. Reusing the id with a *different*
payload is `409`. A retry that arrives while the first attempt is still running
is also `409`; retry once it settles.

Errors:

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error":"Invalid transcription request"}` | Missing or malformed `audio`, `format`, `clientMessageId`, `language`, or `durationSeconds`. |
| `403` | `{"error":"Managed Pro required"}` | Account has no active Pro entitlement. |
| `403` | `{"error":"Missing scope","scope":"speech:write"}` | Key lacks the scope. |
| `409` | `{"error":"Client message ID conflict"}` | `clientMessageId` reused with a different payload. |
| `409` | `{"error":"Speech request in progress"}` | An earlier attempt under this id is still running. |
| `413` | `{"error":"Audio too large"}` | Body or `audio` beyond the size ceiling. Nothing was buffered upstream. |
| `413` | `{"error":"Audio too long"}` | Audio beyond `SPEECH_MAX_AUDIO_SECONDS`. |
| `429` | `{"error":"Too many requests"}` | Rate limit; see §2. |
| `429` | `{"error":"Managed speech capacity exceeded"}` | Admission/cost budget exhausted. `Retry-After` in whole seconds. |
| `502` | `{"error":"Managed speech unavailable"}` | Provider error, timeout, or an unusable response body. The reservation is settled and released; safe to retry with the same `clientMessageId`. |
| `503` | `{"error":"Managed speech unavailable"}` | Speech is unconfigured on the deployment. |

Synchronous, and long audio takes a while: allow at least a 120-second client
timeout.

### 4.11 `POST /api/v1/speech/synthesis`

Scope: `speech:write`. **Requires an active Omi Pro subscription on the
account.**

Read text aloud and return the audio. Runs as an OpenRouter chat completion
with the audio output modality against the `speak` model tier
(`OMI_MODEL_SPEAK`, default `openai/gpt-audio-mini`), through the Cloudflare AI
Gateway when one is configured.

Request:

```json
{
  "text": "Your car is booked for Friday at nine.",
  "clientMessageId": "assistant:tts:0007",
  "voice": "alloy",
  "format": "mp3"
}
```

| Field | Type | Required | Notes |
| --- | --- | --- | --- |
| `text` | string | yes | 1–1000 characters, spoken verbatim. |
| `clientMessageId` | string | yes | Idempotency key. 8–120 characters matching `[A-Za-z0-9._:-]`. |
| `voice` | string | no | One of `alloy`, `ash`, `ballad`, `coral`, `echo`, `sage`, `shimmer`, `verse`. Defaults to `alloy`. |
| `format` | string | no | `mp3` (default) or `opus`. Uncompressed formats are not offered: the audio is retained for idempotent replay and has to fit in one row. |

`200`:

```json
{
  "requestId": "sha256-of-uid-and-clientMessageId",
  "clientMessageId": "assistant:tts:0007",
  "model": "openai/gpt-audio-mini",
  "voice": "alloy",
  "format": "mp3",
  "characters": 38,
  "estimatedSeconds": 3,
  "audio": "<base64>"
}
```

`estimatedSeconds` is the reservation estimate (about 14 characters per second
of speech), not a measurement of the returned audio.

**Idempotency.** Same rules as §4.10: a retry with the same id and same text,
voice and format replays the stored audio with `"idempotentReplay": true` and
is not charged again.

Errors:

| Status | Body | Cause |
| --- | --- | --- |
| `400` | `{"error":"Invalid speech request"}` | Missing or blank `text`, malformed `clientMessageId`, unknown `voice` or `format`. |
| `403` | `{"error":"Managed Pro required"}` | Account has no active Pro entitlement. |
| `403` | `{"error":"Missing scope","scope":"speech:write"}` | Key lacks the scope. |
| `409` | `{"error":"Client message ID conflict"}` | `clientMessageId` reused with different text, voice or format. |
| `409` | `{"error":"Speech request in progress"}` | An earlier attempt under this id is still running. |
| `413` | `{"error":"Text too long"}` | `text` beyond 1000 characters. Nothing was sent upstream. |
| `429` | `{"error":"Too many requests"}` | Rate limit; see §2. |
| `429` | `{"error":"Managed speech capacity exceeded"}` | Admission/cost budget exhausted. `Retry-After` in whole seconds. |
| `502` | `{"error":"Managed speech unavailable"}` | Provider error, timeout, or no audio in the response. |
| `502` | `{"error":"Synthesized audio too large"}` | The provider returned audio too large to retain for replay. Shorten the text. |
| `503` | `{"error":"Managed speech unavailable"}` | Speech is unconfigured on the deployment. |

---

## 5. MCP server

Endpoint: `POST https://omi.tsc.hk/mcp`

Transport: MCP **streamable HTTP**, protocol version `2025-06-18`. The
implementation is JSON-RPC 2.0 over a single POST endpoint and is stateless:
there are no session ids, no `Mcp-Session-Id` header, and no server-initiated
messages. Every request carries its own credential.

- `GET /mcp` → `405` (the optional SSE stream is not offered).
- `DELETE /mcp` → `405` (there is no session to terminate).
- Request bodies larger than 256 KiB → `413`.

Responses are `application/json`; the server never replies with
`text/event-stream`. Successful responses carry
`MCP-Protocol-Version: 2025-06-18`.

### 5.1 Authentication

Identical to §1: an `omi_sk_` API key or a Firebase ID token in
`Authorization: Bearer ...` (or the key in `X-API-Key`). A request with no valid
credential is rejected with HTTP `401` before any JSON-RPC parsing.

Client configuration example:

```json
{
  "mcpServers": {
    "omi": {
      "type": "http",
      "url": "https://omi.tsc.hk/mcp",
      "headers": { "Authorization": "Bearer omi_sk_..." }
    }
  }
}
```

### 5.2 Supported methods

| Method | Behaviour |
| --- | --- |
| `initialize` | Returns `protocolVersion`, `capabilities: {"tools":{"listChanged":false}}`, `serverInfo: {"name":"omi","version":"1.0.0"}`, and `instructions`. |
| `ping` | Returns `{}`. |
| `tools/list` | Returns `{"tools":[...]}`. No pagination; the full list is always returned and never changes at runtime. |
| `tools/call` | Runs a tool. See §5.3. |
| `notifications/*` | Accepted and ignored; the server replies HTTP `202` with an empty body. |

Any other method returns JSON-RPC error `-32601`.

A JSON array of messages (a batch) is answered with an array of the responses
that have ids, in request order. A batch containing only notifications returns
HTTP `202` with an empty body.

Error codes: `-32700` malformed JSON, `-32600` invalid JSON-RPC envelope,
`-32601` unknown method, `-32602` unknown tool or malformed `params`, `-32000`
missing scope or tool execution failure.

### 5.3 `tools/call` result shape

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "content": [{ "type": "text", "text": "{\"currents\":[]}" }],
    "structuredContent": { "currents": [] },
    "isError": false
  }
}
```

`structuredContent` is the exact JSON body the corresponding REST endpoint
returns; `content[0].text` is that same object serialized. Application-level
failures (validation, rate limits, missing Pro, not found) come back as a
**successful** JSON-RPC response with `isError: true` and
`structuredContent: {"error": "..."}` — matching the REST error bodies in §4.
Protocol-level failures (unknown tool, missing scope) come back as JSON-RPC
errors.

### 5.4 Tools

| Tool | Scope | REST equivalent |
| --- | --- | --- |
| `search_memory` | `memory:read` | `GET /api/v1/memory/search` |
| `list_memories` | `memory:read` | `GET /api/v1/memories` |
| `list_currents` | `currents:read` | `GET /api/v1/currents` |
| `create_current` | `currents:write` | `POST /api/v1/currents` |
| `list_meeting_notes` | `conversations:read` | `GET /api/v1/notes` |
| `list_conversation_messages` | `conversations:read` | `GET /api/v1/conversations/messages` |
| `ask_omi` | `assistant:write` | `POST /api/v1/assistant/messages` |
| `start_facetime_call` | `facetime:write` | `POST /api/v1/facetime/calls` |

Every input schema is a JSON Schema object with `additionalProperties: false`.

#### `search_memory`

```
query    string   required, 1–500
limit    integer  optional, 1–50, default 12
mode     enum     optional, "keyword" | "semantic", default "keyword"
```

#### `list_memories`

```
limit    integer  optional, 1–100, default 100
```

#### `list_currents`

No arguments.

#### `create_current`

```
title             string   required, 1–120
summary           string   required, 1–500
reason            string   required, 1–500
proposedNextStep  string   required, 1–500
confidence        number   optional, 0–1, default 0.7
surfaceAt         integer  optional, epoch ms, default now
expiresAt         integer  optional, epoch ms, > surfaceAt
evidenceId        string   optional, ≤ 200
```

#### `list_meeting_notes`

```
limit    integer  optional, 1–100, default 50
```

#### `list_conversation_messages`

```
after    integer  optional, ≥ 0, default 0
limit    integer  optional, 1–200, default 100
```

#### `ask_omi`

```
text     string   required, 1–20000
```

Requires an active Omi Pro subscription; without one the result is
`isError: true` with `{"error":"Managed Pro required"}`.

#### `start_facetime_call`

```
handle          string   required, 3-254, E.164 phone number
idempotencyKey  string   optional, 8-120 chars of [A-Za-z0-9._:-]
```

Side-effectful: it rings a real person's device, and Omi then joins the call's
audio. See §4.9 for the full semantics. On an account with no FaceTime line the
tool returns `isError: true` with
`{"error":"FaceTime calling is not provisioned on this account","code":"facetime_unavailable"}`.

#### `transcribe_audio`

```
audio            string   required, base64 audio bytes
format           string   required, 'wav' or 'mp3'
clientMessageId  string   required, 8-120 chars of [A-Za-z0-9._:-]
language         string   optional, BCP-47 hint, defaults to 'auto'
durationSeconds  integer  optional, 1-3600
```

Server-side transcription; see §4.10 for the full semantics. The audio travels
inline in the JSON-RPC request, so the **256 KiB body cap applies**: that is
roughly 180 KiB of audio, about 45 seconds of mp3. Anything longer must go to
`POST /api/v1/speech/transcriptions`.

#### `speak_text`

```
text             string   required, 1-1000
clientMessageId  string   required, 8-120 chars of [A-Za-z0-9._:-]
voice            string   optional, one of alloy|ash|ballad|coral|echo|sage|shimmer|verse
format           string   optional, 'mp3' (default) or 'opus'
```

Returns base64 audio; see §4.11. Both tools require an active Omi Pro
subscription and are idempotent on `clientMessageId`.

---

## 6. Data lifetime and deletion

Deleting an Omi account (`DELETE /v1/account`, first-party, Firebase-only)
removes every row this API can read, including all API keys for that account.
Revoking a key is immediate and irreversible; there is no un-revoke.
