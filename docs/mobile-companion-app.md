# Mobile Pendant Companion App

*Research pass and design proposal, 2026-07-22. Grounded in the upstream BasedHardware/omi open-source architecture (fetched as untrusted reference data on this date) and in the existing omi-v4 mobile code (`app/lib/device/`, `app/lib/features/device_screen.dart`, `worker/src/`). Nothing here is implemented beyond what is cited; this document defines the target: the mobile app becomes a pure pendant companion — pairing, relay, and light review — while every other surface (desktop app, web portal, Telegram, Blooio/linq) consumes the captured data through the shared Worker.*

## 1. Upstream vs. omi-v4 today

### 1.1 How upstream structures pendant ↔ phone ↔ backend

Upstream (BasedHardware/omi) is an nRF5340/Zephyr pendant plus a Flutter phone app plus a Python/FastAPI backend:

- **BLE protocol** — one Omi GATT service (`19b10000-…`) with an audio-stream characteristic (`19b10001`, notify) and an audio-codec characteristic (`19b10002`, read; firmware ids map to PCM8/PCM16/Opus), plus the standard Battery service (`180f`/`2a19`). Audio packets carry a 3-byte header (16-bit packet id + 8-bit fragment index) ahead of codec payload. High-throughput link: MTU ≈ 498, 7.5–15 ms connection interval.
- **Background audio relay** — `CaptureProvider` streams reassembled audio over a persistent WebSocket to the backend (Deepgram STT + VAD/diarization). iOS uses `bluetooth-central` + audio background modes with native Pigeon recorders; Android uses a foreground service (`NativeMicRecorderService`).
- **Offline buffering & sync** — three tiers: a phone-side WAL, on-device flash pages, and an SD-card ring buffer (LittleFS; `CMD_RING_INFO`/`CMD_RING_READ`/`CMD_RING_ADVANCE` commands over a storage service). `SyncProvider` reconciles offline recordings when connectivity returns, gated by an `autoSyncOfflineRecordings` preference.
- **Speech profile** — a short enrollment recording uploaded to the backend so diarization can label "you" vs. others.
- **Firmware updates (DFU)** — MCUboot secure bootloader on-device; the app drives OTA via the `nordic_dfu` package with a `FirmwareUpdateDialog` progress/disconnect flow.
- **Device UX** — dedicated pairing onboarding pages, persistent `btDevice` preference, automatic reconnection, live battery state in `DeviceProvider`.

### 1.2 What omi-v4 mobile already has

| Concern | omi-v4 state | Where |
|---|---|---|
| BLE scan/connect (Omi service filter, codec + battery read, notify subscribe) | Implemented, cross-platform via `universal_ble` | `app/lib/device/universal_ble_device_relay.dart` |
| 3-byte packet reassembly with discontinuity/too-large gap frames | Implemented | `app/lib/device/device_audio_frame.dart` |
| Codec model (PCM8 8 kHz, PCM16/Opus 16 kHz, firmware ids 1/20/21) | Implemented | `app/lib/device/device_models.dart` |
| Role gating (mobile owns the pendant; desktop/web are observers) | Implemented (`DeviceRelayRole`) | `app/lib/device/device_relay.dart` |
| Bounded forwarding into the Rust hub live-STT session (backpressure, gap fail-fast, reconnect grace, EOS drain, stop acks) | Implemented | `app/lib/device/device_audio_forwarder.dart` |
| Managed/BYOK Deepgram live route, `zkr` capture of final segments | Implemented in the hub (per PLAN.md "Mobile relay" slice) | `app/native/hub/` |
| Devices screen (scan/connect/battery/RSSI tiles) | Minimal | `app/lib/features/device_screen.dart` |

### 1.3 What upstream does that v4 lacks

- **Pairing UX** — v4 has a utilitarian scan list; upstream has guided onboarding, a remembered device (`btDevice`-style persistence), and automatic reconnect-on-launch. v4's adapter reconnects while the process lives (`autoConnect: true`, notification restore with 3 retries) but forgets the device across restarts.
- **Offline buffering** — v4 deliberately fails fast on gaps (`DeviceAudioGap`) and keeps only an 8-frame in-memory queue; there is no phone WAL, no SD-card/flash sync protocol, no `SyncProvider` equivalent. PLAN.md names "a small mobile WAL" as intended reliability work, unbuilt.
- **Battery/firmware surfaces** — battery is read once at connect, never notified/refreshed; `RelayDevice.firmwareRevision`/`hardwareRevision`/etc. exist as fields but are never populated (Device Information service is not read). No DFU path at all.
- **Background execution** — nothing platform-specific exists: no iOS `bluetooth-central` background mode wiring, no CoreBluetooth state restoration, no Android foreground service. The relay only works while Flutter is foregrounded. (iOS constraint to plan around: background BLE keeps delivering notifications under the `bluetooth-central` mode, but the app can be jetsoned; state restoration + user-visible session indicators are the upstream-proven pattern. There is no "background audio" entitlement path for BLE data — that mode is for audible playback/recording via the mic, not required here.)
- **Speech profile** — absent in v4 (backend diarization is not in scope yet; note as deferred).
- **Storage-service commands, button characteristic, haptics** — absent; only audio + codec + battery characteristics are used.

## 2. Target architecture: companion only

Principle: the phone is the pendant's modem and status panel. All intelligence, memory, chat, and delivery live behind the Worker; desktop, web, Telegram, and Blooio read the same data via existing routes (`worker/src/conversations.ts` `/v1/conversations/default/*`, `worker/src/memory-sync.ts` `/v1/memory/zkr-sync`, `worker/src/routes.ts` `/v1/memories` + `/v1/memory/retrieve`, `worker/src/delivery.ts` for channel outbound). This matches PLAN.md's locked decision: "Mobile owns BLE, background hardware relay, firmware, pairing, and device management; desktop owns primary assistant interaction."

### 2.1 Mobile screen list (complete)

1. **Pair / scan** — first-run and empty-state flow: permission priming, scan (existing `DeviceRelayService.scan()`), one-tap connect, persist the chosen device id, auto-reconnect on launch.
2. **Device status (home)** — connection phase, battery (add periodic/notify refresh), signal, codec, firmware revision (read Device Information service `180a`), capture on/off toggle, last-gap/error surface (`DeviceAudioForwarder.lastError`).
3. **Capture status + recent transcripts** — is a live STT session running, minutes captured today, and a read-only list of recent final transcript segments / conversations fetched from `GET /v1/conversations/default/messages` and `GET /v1/memories`. Light review only: no chat composer.
4. **Settings** — account (Firebase sign-in state, sign-out), processing-consent receipt view/revoke, transcription route indicator (managed vs BYOK), offline-buffer usage, app version. Nothing else.

### 2.2 Kept, dropped, and hidden v4 code on mobile

| Disposition | Code | Note |
|---|---|---|
| Keep | `app/lib/device/*` (all five files) | The relay core is the product |
| Keep | `app/lib/auth/`, `app/lib/onboarding/` consent receipt, `app/lib/settings/` client | Account + consent are required for processing authority |
| Keep (trimmed) | `app/lib/features/device_screen.dart` | Becomes the home surface, expanded per 2.1 |
| Keep | `app/lib/api/`, `app/lib/memory/` read paths | For the recent-transcripts list |
| Drop/hide on mobile | `app/lib/features/chat_screen.dart` + `omi_shell.dart` desktop chrome (menu bar, both-Shift `app/lib/keyboard/`, window-chrome channel) | Chat hub is desktop/channel-owned; `omi_shell.dart` is already desktop-shaped (`DesktopMenuBarController`, `omi/window_chrome`) |
| Drop/hide on mobile | `app/lib/features/currents_screen.dart`, `app/lib/currents/` | Currents surface belongs to desktop chat rows and the web portal (PLAN.md Product surfaces) |
| Drop/hide on mobile | Computer use / `praefectus` paths, `app/lib/menu_bar/` | Already platform-gated to desktop; ensure mobile never links them |
| Drop/hide on mobile | `app/lib/features/memory_screen.dart` full management | Memory management is web-portal-owned; mobile keeps read-only recent capture |
| Drop/hide on mobile | `app/lib/features/desktop_auth_screen.dart` | Desktop browser-handoff auth surface; not a mobile concern beyond deep-link approval if ever needed |

Concretely: `main.dart` routes to a `MobileCompanionShell` (device status home) when `defaultTargetPlatform` is iOS/Android instead of `OmiShell`, mirroring how `_createDeviceRelay()` in `app/lib/app_services.dart` already branches on platform for `DeviceRelayRole.mobileOwner`.

## 3. Audio path decision

```
pendant (Opus/PCM8/PCM16, 3-byte header)
  → phone BLE (UniversalBleDeviceRelayAdapter → decodeDeviceAudioFrames)
  → DeviceAudioForwarder → Rinf hub (NativeHub.startTranscription / sendAudio)
  → live route: managed/BYOK Deepgram stream (Worker STT admission: POST /v1/stt/sessions, GET /v1/stt/sessions/:id/stream)
  → final segments → zkr capture → /v1/memory/zkr-sync → D1
  → consumed by desktop / web / Telegram / Blooio via /v1/conversations + /v1/memory routes
```

Decisions:

- **Live path stays Deepgram managed/BYOK through the hub.** This is the audited, implemented slice (PLAN.md "Complete the audited live-STT slice…"; `DeviceAudioForwarder` already maps codecs to `AudioEncoding.pcmU8/pcmS16Le/opus` and speaks the hub's start/stop/ack protocol). Nothing new to design.
- **Batch path for recovered/offline audio: `POST /v1/asr/transcribe` (mimo-v2.5-asr).** The Worker route exists (`worker/src/asr.ts`), takes base64-chunked long recordings, and PLAN.md pins MiMo ASR as batch-only. Offline-buffered audio (section 4) is uploaded here after reconnect rather than replayed through the live socket — replaying stale audio through a live session is explicitly forbidden by the plan ("Never replay already-sent unacknowledged audio").
- **Gemini Live is NOT the pendant path.** `worker/src/voice.ts` (`POST /v1/voice/gemini/token`) mints ephemeral tokens for the desktop interactive duplex assistant (see `docs/realtime-voice-abstraction.md`); pendant capture is one-way transcription, not conversation, and must not consume duplex session minutes.
- **Local STT** remains fail-closed until a real provider exists; the mobile UI shows only managed/BYOK routes.

## 4. Reliability plan ("rock solid")

- **Reconnect** — persist the paired device id; on launch and on BLE-adapter power-on, attempt connect with `autoConnect: true` (already used). Keep the adapter's 3-attempt notification-restore ladder but make retries unbounded with exponential backoff (1 s → 30 s cap) while the device is "remembered". `DeviceAudioForwarder.reconnectGrace` (20 s) stays the live-session bound: a longer outage ends the STT session cleanly (EOS/stop) and a new session starts on reconnect — sessions are cheap; corrupt streams are not.
- **Offline buffer bounds** — add the PLAN.md mobile WAL: when the hub/network is unreachable but BLE audio flows, append reassembled frames (with packet ids and wall-clock anchors) to an on-disk ring, bounded to a fixed budget (proposal: 256 MiB ≈ several hours of Opus; oldest-out). On recovery, upload as batch to `/v1/asr/transcribe` with a deterministic recording id for idempotency, then delete. Gaps stay explicit source gaps — never synthesize continuity. Pendant-side SD/flash sync (upstream `CMD_RING_*`) is a later phase; the storage characteristic protocol is documented and additive.
- **Background execution** — iOS: `bluetooth-central` background mode + CoreBluetooth state restoration (restore identifier through `universal_ble` or a thin native shim), accept that transcription streaming may be deferred while backgrounded and lean on the WAL. Android: a connected-device foreground service with a persistent notification showing capture state; request `BLUETOOTH_CONNECT`/`BLUETOOTH_SCAN` (API 31+) and battery-optimization exemption prompt. Desktop/web keep `DeviceRelayRole` observer roles unchanged.
- **Battery UX** — subscribe to Battery Level notifications (characteristic `2a19` supports notify on upstream firmware) instead of the current one-shot read; surface low-battery (<15%) and charging states on the home screen and as a local notification.
- **Firmware update** — explicitly deferred for v0. Read and display `firmwareRevision` from the Device Information service now; adopt an MCUboot/`nordic_dfu`-style OTA flow as a dedicated later phase (it requires careful disconnect/resume handling and a signed-image pipeline). The home screen may show "update managed by the official Omi app" until then.
- **Permission flows** — permission priming screen before the first scan (the adapter already maps denial to `DeviceCapabilityState.permissionRequired`); distinct recoverable states for Bluetooth-off (`adapterUnavailable`), permission-denied (deep-link to app settings), and consent-not-granted (processing consent receipt is required before any audio leaves the phone — reuse the onboarding consent flow).

## 5. Phased implementation checklist

Each phase is sized for one follow-up agent and independently shippable.

**Phase 1 — Companion shell**
- [ ] Add `MobileCompanionShell` routing in `app/lib/main.dart` for iOS/Android; desktop keeps `OmiShell`.
- [ ] Expand `device_screen.dart` into the status home (connection, battery, codec, capture toggle, last error).
- [ ] Hide chat/currents/memory-management/computer-use surfaces on mobile; verify no desktop-only code (menu bar, keyboard, praefectus) links into mobile builds.
- [ ] Mobile settings screen: account, consent receipt, route indicator, version.

**Phase 2 — Pairing polish**
- [ ] Persist paired device id; auto-reconnect on launch/adapter-on with backoff.
- [ ] Permission priming + recoverable error states (Bluetooth off, denied, consent missing).
- [ ] Read Device Information service (`180a`) into `RelayDevice.firmwareRevision`/`hardwareRevision`/`modelNumber`.
- [ ] Battery notifications + low-battery UX.

**Phase 3 — Background relay**
- [ ] iOS `bluetooth-central` background mode + state restoration.
- [ ] Android foreground service with capture notification; API-31+ permissions and battery-optimization prompt.
- [ ] Physical-device background lifecycle proof (matches PLAN.md "background recovery" gap).

**Phase 4 — Offline WAL + batch upload**
- [ ] Bounded on-disk ring for reassembled frames during outages.
- [ ] Idempotent recovery upload via `POST /v1/asr/transcribe`; delete on ack; explicit gap records.
- [ ] Buffer-usage surface in settings.

**Phase 5 — Review surface**
- [ ] Recent transcripts/conversations list from `GET /v1/conversations/default/messages` and `GET /v1/memories` (read-only).
- [ ] Capture stats (minutes today, session count).

**Phase 6 (deferred, separate specs)**
- [ ] Pendant SD/flash sync via storage-service `CMD_RING_*` commands.
- [ ] MCUboot OTA firmware updates.
- [ ] Speech profile enrollment (blocked on backend diarization).

## 6. Sources

- [BasedHardware/omi](https://github.com/BasedHardware/omi) — README and repo structure (firmware `omi/`, Flutter `app/`, FastAPI `backend/`).
- [DeepWiki: BasedHardware/omi — hardware and firmware architecture](https://deepwiki.com/BasedHardware/omi/2.4-hardware-and-firmware-architecture) — GATT layout, MTU/interval, LittleFS ring buffer and `CMD_RING_*`, MCUboot.
- [DeepWiki: BasedHardware/omi — mobile app architecture](https://deepwiki.com/BasedHardware/omi/2.2-mobile-app-architecture) — pairing/`DeviceProvider`, background capture, WAL/`SyncProvider`, `nordic_dfu`.
- Local ground truth: `app/lib/device/`, `app/lib/features/device_screen.dart`, `app/lib/app_services.dart`, `worker/src/{routes,asr,stt,voice,conversations,memory-sync,delivery}.ts`, `PLAN.md`, `docs/realtime-voice-abstraction.md`.
