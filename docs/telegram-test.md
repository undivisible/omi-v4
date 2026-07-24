# Telegram channel — test checklist

Production webhook base: `https://api.omi.tsc.hk/v1/webhooks/telegram` (see `worker/wrangler.jsonc` — API host is `api.omi.tsc.hk`).

## Prerequisites

| Secret / config | Where | Purpose |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | Worker secret + `worker/.dev.vars` | Outbound `sendMessage`, webhook registration |
| `TELEGRAM_WEBHOOK_SECRET` | Worker secret + `worker/.dev.vars` | Webhook auth header + link-code HMAC |
| `MIMO_API_KEY` + `MIMO_CHAT_COMPLETIONS_URL` | Worker secret | Server fallback replies (~2 min) |
| Active Pro entitlement | User account | Fallback assistant (non-Pro gets offline ack only) |

Copy `worker/.dev.vars.example` → `worker/.dev.vars` and fill placeholders. Never commit real values.

## 1. Register / verify webhook

One-time (or after secret rotation). Replace `<TOKEN>` and `<SECRET>` with values from `.dev.vars` / Cloudflare secrets:

```bash
curl -sS -X POST "https://api.telegram.org/bot<TOKEN>/setWebhook" \
  -H "Content-Type: application/json" \
  -d '{"url":"https://api.omi.tsc.hk/v1/webhooks/telegram","secret_token":"<SECRET>","allowed_updates":["message"]}'
```

Verify:

```bash
curl -sS "https://api.telegram.org/bot<TOKEN>/getWebhookInfo"
# expect url = https://api.omi.tsc.hk/v1/webhooks/telegram, last_error_message null
```

## 2. Smoke webhook auth (no real user impact)

Unauthorized (expect `401`):

```bash
curl -sS -w "\nHTTP %{http_code}\n" -X POST \
  "https://api.omi.tsc.hk/v1/webhooks/telegram" \
  -H "Content-Type: application/json" \
  -d '{"update_id":999999001,"message":{"message_id":1,"text":"/help","from":{"id":1},"chat":{"id":1}}}'
```

Authorized (expect `200`, `"replied":true` for `/help` on an unlinked sender):

```bash
curl -sS -w "\nHTTP %{http_code}\n" -X POST \
  "https://api.omi.tsc.hk/v1/webhooks/telegram" \
  -H "Content-Type: application/json" \
  -H "x-telegram-bot-api-secret-token: <SECRET>" \
  -d '{"update_id":999999002,"message":{"message_id":2,"text":"/help","from":{"id":999999002},"chat":{"id":999999002}}}'
```

Use high `update_id` values that will not collide with live Telegram traffic.

## 3. Happy path — link (reverse flow, recommended)

1. Open a **direct** chat with the bot (not a group; group chats are rejected).
2. Send `/start`.
3. Bot replies with a **7-character** link code (15-minute TTL, single use).
4. In Omi desktop or mobile: **Settings → Account → Link a chat**, paste the code  
   — or call `POST /v1/channels/link` with Firebase auth and body `{"code":"XXXXXXX"}`.
5. Bot sends confirmation: *"Linked — this chat now answers as …"*
6. Send `/status` — should show linked account and date.

**Alternative (app-initiated):** `POST /v1/channels/telegram/link` returns a 48-char token; send `/start <token>` in Telegram.

## 4. Happy path — assistant reply

After linking:

1. Send a normal message (not a command) in Telegram.
2. **Desktop online:** desktop polls `GET /v1/conversations/default/inbox`, claims the item, completes with assistant reply → outbound via `channel_deliveries` → Telegram `sendMessage`.
3. **Desktop offline ~2+ min:** cron runs `respondToStaleInboxItems` (`worker/src/inbox-fallback.ts`). Pro users get a managed completion; others get *"Got it — I'll answer when your desktop is back online."*

Immediate command replies (`/help`, link codes, unlink confirm) bypass the inbox queue via `sendChannelText`.

## 5. Unlink

- **From Telegram:** `/logout confirm` (or `/unlink confirm`).
- **From app:** `DELETE /v1/channels/telegram/link` (Firebase auth).

## 6. Group chat guard

Linking in Telegram groups/supergroups (negative `chat.id`) is rejected at `/start`, token bind, and app redemption. Expect: *"Group chats cannot be linked as your Omi channel…"*

## 7. Local tests

```bash
cd worker
bun test test/webhooks.test.ts test/channel-group.test.ts test/inbox-fallback.test.ts
bun test test/routes.test.ts test/channel-commands.test.ts
```

## Troubleshooting

| Symptom | Check |
|---|---|
| Webhook 401 | `TELEGRAM_WEBHOOK_SECRET` mismatch between Telegram `setWebhook` and Worker |
| No bot replies | `TELEGRAM_BOT_TOKEN` set in production Worker secrets |
| Link code never arrives | `TELEGRAM_WEBHOOK_SECRET` unset locally; rate limit (`channel-link-code:*`) |
| Message queued, no reply | Desktop must poll inbox, or wait ~2 min for fallback + Pro + MIMO keys |
| `getWebhookInfo` last_error | URL must be HTTPS; Worker must be deployed at `api.omi.tsc.hk` |
