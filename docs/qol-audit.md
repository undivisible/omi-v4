# QoL / codebase audit (2026-07-24)

Living list from the ongoing pass. P0s get fixed in this effort; the rest are tracked.

## P0 — done

| Item | Status |
|---|---|
| Home marketing jargon (zkr / D1 / local mirror / Blooio) | Done on home — consumer copy; Open surface API/MCP stays technical on purpose |
| Blooio provider still live as Sendblue fallback | Done — wire id is `imessage`; Blooio transport removed |
| Overlay submit dismisses pill; reply only in hub | Done — multi-turn session under pill, 45s reuse window, channel colors |
| Gemini Live has no tools / no AX | Done — tools + proposals + hub/overlay AX; mid-session AX refresh (~90s) |
| Currents only generated on client `/generate` | Done — daily cron batch at local 07:00 (`generateDueCurrents`) |
| Mobile connected status tinted blue | Done — warm teal/ink accents instead |
| Mobile launch crash | Likely stale/unsigned install; fresh signed build stays running |
| Mobile Currents-first swipe pages | Done — PageView Currents / Chat / Memory |
| Mobile Memory search-or-add | Done — bottom field + trailing add |

## P1 — done this pass

- Menu bar Capture overlay-first (`_summonOverlayCapture`; hub-active chord still focuses composer)
- Settings: “Allow screen understanding” → Accessibility; separate “Allow Screen Recording” tile
- Global double-Shift Input Monitoring tile in Permissions
- `channels.imessage` health preferred; legacy `channels.blooio` still accepted (test coverage)
- Digests + Currents cron keyset cursor (`cron_cursors` / `scanOnboardedUsers`) with wrap
- FaceTime docs describe Sendblue/Agora current path (no Blooio framing)

## P2 — polish

- `record_macos` / SPM friction on Flutter 3.44 (macOS 13+ already bumped)
- Pill `NSApp.activate` fallback can steal focus when keying fails
- Public API / Open surface marketing still mentions MCP (fine for API section)
- Channel-only `chan_*` accounts soft-deprecated; sunset policy TBD (see `docs/auth-migration.md`)

## Verified working

- Mobile companion already hosts Currents (`_MobileTasksSection` in `mobile_companion_shell.dart`)
- Currents already persist in D1 via `/v1/currents*`
- Digests already cron-batched daily/nightly by local offset
