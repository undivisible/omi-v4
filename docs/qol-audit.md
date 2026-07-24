# QoL / codebase audit (2026-07-24)

Living list from the ongoing pass. P0s get fixed in this effort; the rest are tracked.

## P0 — fixing now

| Item | Status |
|---|---|
| Home marketing jargon (zkr / D1 / local mirror / Blooio) | In progress — consumer rewrite in `site/lib/pages/home.dart` |
| Blooio provider still live as Sendblue fallback | Done — wire id is `imessage`; Blooio transport removed |
| Overlay submit dismisses pill; reply only in hub | In progress — keep bubble on overlay |
| Gemini Live has no tools / no AX | In progress — tool bridge + screen context |
| Currents only generated on client `/generate` | Done — daily cron batch at local 07:00 (`generateDueCurrents`) |
| Mobile connected status tinted blue | Done — warm teal/ink accents instead |
| Mobile launch crash | Likely stale/unsigned install; fresh signed build stays running |

## P1 — next

- Menu bar Capture still calls `showApp()` (forces hub) — covered by overlay agent
- Settings “Allow screen understanding” vs Accessibility AX — clarify copy
- `channels.imessage` health key (clients briefly accept legacy `channels.blooio`)
- Digests + Currents both scan users with `LIMIT 200` unordered beyond `uid` — fairer cursor/pagination if user count grows
- FaceTime hub docs still say Blooio in a few Rust comments

## P2 — polish

- `record_macos` / SPM friction on Flutter 3.44 (macOS 13+ already bumped)
- Pill `NSApp.activate` fallback can steal focus when keying fails
- Public API / Open surface marketing still mentions MCP (fine for API section)
- Channel-only `chan_*` accounts soft-deprecated; sunset policy TBD (see `docs/auth-migration.md`)

## Verified working

- Mobile companion already hosts Currents (`_MobileTasksSection` in `mobile_companion_shell.dart`)
- Currents already persist in D1 via `/v1/currents*`
- Digests already cron-batched daily/nightly by local offset
