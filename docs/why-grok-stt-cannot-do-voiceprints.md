# Why grok-stt cannot supply voiceprints

**Date:** 2026-07-31

Short version: `x-ai/grok-stt-1.0` returns a transcript. That is the entire
output. It is not a partial speaker-identity source that needs more prompting
or a different parameter — there is nothing in the response to build an
identity from, and there never will be from this endpoint.

## The endpoint

`worker-rs/src/asr_logic.rs` posts audio to
`https://openrouter.ai/api/v1/audio/transcriptions` with
`model = "x-ai/grok-stt-1.0"`. That is OpenAI's `/audio/transcriptions` shape:
audio in, text out. It has no diarization parameter, no speaker field, no
embedding field, and no per-segment speaker index. Even the vendors that *do*
diarize on this route (Whisper-family services with `speaker_labels`) return
labels scoped to the one request, which is a different thing from an identity.

## What the other routes give us, and why none of them is enough

| Route | Speaker output | Usable as a voiceprint? |
|---|---|---|
| `x-ai/grok-stt-1.0` (batch, OpenRouter) | none | no — text only |
| Deepgram `diarize=true` (meeting path, `app/native/hub/src/stt.rs`) | integer index per segment, valid only inside that stream | no — index 2 in today's meeting has no relationship to index 2 in tomorrow's |
| Gemini Live | built-in transcription | no — no speaker vectors exposed |

A meeting-local index is exactly what `SpeakerRoster` in
`app/native/hub/src/meeting.rs` already consumes to produce `You` / `Them` /
`Speaker N`. It cannot be persisted into a person, because the number carries
no information about the voice — only about the order voices were first heard
in one recording.

## Why this is a design fact, not a limitation to route around

A voiceprint is a fixed-length vector in a space where distance means "same
person". Producing one requires running a speaker-embedding model over the
audio. A transcription API that returns text has, by construction, discarded
everything that model would read. No prompt, parameter, or provider swap
inside the current set changes that: the identity has to be computed where the
audio is, which for omi-v4 is the Rust hub.

## What follows

`app/native/hub/src/speech_profiles.rs` defines the seam
(`EmbeddingSource::embed`) and ships `NullEmbeddingSource`, which answers
`EmbeddingError::Unavailable` on every call — the same fail-closed posture
`SttError::Unavailable` takes for the local STT route. Everything downstream of
that seam (matching, storage, merge, eviction, quarantine, the roster bridge)
is implemented and unit-tested without a model. What is missing is a local
model to put behind it, and a re-measurement of `MATCH_THRESHOLD` and
`MATCH_MARGIN` against whatever that model's distance scale turns out to be.

Do not claim speech profiles in product copy until that lands. See
`docs/speech-profiles-and-displays.md` §6.
