# Omi v4 roadmap

Status: code-authoritative snapshot at `449f08510829184473d4b54e485811a5b2930102` (2026-07-26).

Omi v4 is a proactive, evidence-backed second brain across the pendant, mobile, desktop, web, and messaging channels. This document separates implemented code from the remaining integration and release proof.

## Shipping baseline

- Flutter client targets iOS, Android, macOS, Windows, and web.
- The in-process Rust hub provides typed Rinf signals, assistant routing, evidence-backed memory, Currents, transcription, and macOS computer use.
- The Rust Worker contains authenticated API, D1, memory/vector, billing, channel, and scheduled-work paths.
- macOS has the continuous-chat hub, a menu-bar companion, Settings window, both-Shift gesture, voice overlay, and native permission bridges.
- Firmware builds for `omi-cv1` and `evt-test`; the three DevKit targets remain non-gating until their nRF 3.x port is complete.

## Milestone 1 — release candidate proof

Goal: prove the exact release commit on every supported client surface.

- Run the repository CI gates for Flutter, hub, Worker, and firmware.
- Build and install Android, iOS, macOS, Windows, and web artifacts from the same commit.
- Exercise onboarding, consent revocation, memory create/search/delete, chat, Currents, voice capture, and approved-action rejection on each applicable platform.
- Confirm macOS accessibility, microphone, screen-capture, and workspace permission states on a real machine.

Exit: all CI jobs pass and each platform has a recorded smoke result tied to the release commit.

## Milestone 2 — live integrations

Goal: replace configuration-only paths with bounded production evidence.

- Configure and verify Firebase Auth, model routes, Stripe, Telegram, Blooio, and the Worker secrets/bindings.
- Prove a Firebase-UID-scoped conversation round trip through the app, Telegram, and Blooio, including replay, idempotency, and an outbound reply.
- Verify managed and BYOK transcription with real audio, a reconnect gap, cancellation, and final transcript persistence.
- Confirm live Worker health, D1 migrations, Vectorize search, scheduled Currents/digests, and billing entitlement transitions.

Exit: each integration has a real credential/device test and a failure-path result; no unset secret silently appears as a working feature.

## Milestone 3 — desktop capability completion

Goal: turn desktop-specific code into cross-platform product proof.

- Validate the both-Shift and menu-bar flows on real macOS hardware.
- Validate Windows WASAPI meeting capture on physical hardware.
- Validate AX context reading against Mail, Chromium, and Electron, then add the bundle-ID privacy denylist before broad desktop rollout.
- Keep computer use macOS-only until `praefectus` supports the current Windows and Linux dependency graph; do not market those targets as computer-use capable before then.

Exit: supported desktop capabilities have permission, privacy, and live-app evidence; unsupported ones remain explicitly unavailable.

## Milestone 4 — pendant readiness

Goal: prove the production pendant path rather than only its build.

- Flash `omi-cv1` onto a real nRF5340 pendant and test BLE capture, reconnect, OTA, and app relay.
- Test OTA upgrade from a v2.9.0 device and verify that the moved NVS settings storage preserves or safely migrates device state.
- Port the DevKit targets through the nRF 3.x PDM API break, or keep them documented as non-shipping targets.

Exit: a real pendant completes capture and OTA recovery; firmware release artifacts come from the release workflow.

## Milestone 5 — post-v0 product work

These are product candidates, not release blockers.

- Close the meeting-to-Current-to-channel loop so accepted action items reach the linked owner channel.
- Evaluate the planned speech profiles and multi-display Rewind work only after the core release is stable.
- Consolidate provider plumbing behind `rs_ai` only if it removes existing code without weakening the live-voice path.
- Evaluate alternative STT and model tiers with measured quality, latency, and cost before replacing the current routes.

## Release sequence

1. Freeze a commit after Milestones 1–4 exit criteria are met.
2. Run the desktop, mobile, and firmware release workflows from a version tag.
3. Sign and notarize where release credentials are available; label unsigned artifacts as non-production.
4. Publish checksums and release notes only after artifact installation and live-service smoke tests pass.

## Current external dependencies

- Release signing identities and store/distribution credentials.
- Firebase, model-provider, Stripe, Telegram, Blooio, and observability credentials.
- Physical macOS, Windows, mobile, and nRF5340 pendant test hardware.
- A release Worker environment with the required Cloudflare bindings and migrations.
