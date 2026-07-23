//! Duplex bridge between a live call and a Gemini Live session.
//!
//! # Where the call's media comes from
//!
//! Blooio (`worker/src/facetime.ts`) places the call and mints the link, and
//! that is *all* it does: `POST /v2/api/facetime/calls` is its entire call
//! surface. Its v2 and v4 references expose no call, media, stream, track or
//! recording resource, and its webhook catalogue carries only message, group,
//! poll, reaction, typing and contact events — there is no `call.*` event and
//! no way to receive or inject call audio. That endpoint is also switched off
//! upstream today and answers 501.
//!
//! The media therefore comes from joining the link, not from Blooio. A
//! headless browser joins as an announced participant and *is* the media leg;
//! see [`crate::facetime_bridge`]. `CallTransport` is the seam between that
//! and everything here, so the bridge does not care which leg it is driving:
//! [`crate::facetime_bridge::FaceTimeTransport`] is the call, and
//! [`ChannelCallTransport`] is the app's own local audio/video path.
//!
//! Framing, sample rate, barge-in and cancellation all follow
//! [`crate::live_voice`]: 16 kHz mono PCM16 in, whatever rate the model
//! returns out, `Interrupted` clears in-flight output, `cancel` tears the
//! session down immediately. The session machinery is reused, not duplicated —
//! this drives a `RealtimeVoiceHandle`.
//!
//! Credentials never appear here. The bridge is handed an already-opened
//! handle, whose ephemeral token came from the environment or the Worker.

use crate::live_voice::{RealtimeVoiceEvent, RealtimeVoiceHandle};
use crate::mark_video::{MarkAnimator, VideoFrame};
use std::time::Duration;
use tokio::sync::mpsc;

/// Outbound video cadence. Twelve frames a second is plenty for a mark that
/// breathes rather than moves, and keeps the encoder's job small.
const FRAME_INTERVAL: Duration = Duration::from_millis(83);
const FRAME_SIZE_PX: u32 = 240;

/// Caller audio the bridge accepts: 16 kHz mono PCM16, as `live_voice` wants.
pub(crate) const CALLER_SAMPLE_RATE_HZ: u32 = 16_000;

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum CallMedia {
    /// Assistant speech for the caller, PCM16 at the model's output rate.
    Audio { sample_rate_hz: u32, bytes: Vec<u8> },
    /// One frame of the outbound Omi mark track.
    Video(VideoFrame),
    /// Barge-in: drop anything already queued for playout to the caller.
    FlushAudio,
}

/// The media leg to whoever is on the call.
pub(crate) trait CallTransport: Send {
    fn deliver(&mut self, media: CallMedia) -> Result<(), String>;
    /// Video is only rendered when the far end will show it, so an audio-only
    /// call costs nothing to draw.
    fn wants_video(&self) -> bool;
}

/// Bounds on a single call.
///
/// A realtime call is open-ended cost in a way a request/response turn is not,
/// so it is capped the same way `worker/src/stt-admission.ts` caps a
/// transcription: a wall-clock ceiling plus a metered budget, both refusing
/// rather than degrading when exhausted. Values come from the caller, which
/// reads them from configuration — nothing is hardcoded to a price.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) struct CallBudget {
    pub(crate) max_duration: Duration,
    /// Ceiling on caller audio forwarded upstream, in bytes of PCM16 at
    /// `CALLER_SAMPLE_RATE_HZ`. This is the billed input.
    pub(crate) max_caller_audio_bytes: u64,
    /// Ceiling on assistant audio returned. This is the billed output.
    pub(crate) max_assistant_audio_bytes: u64,
}

impl CallBudget {
    /// A budget expressed the way the admission paths express theirs: seconds
    /// of speech each way.
    pub(crate) fn from_seconds(
        max_duration_seconds: u64,
        caller_seconds: u64,
        assistant_seconds: u64,
    ) -> Self {
        let bytes_per_second = u64::from(CALLER_SAMPLE_RATE_HZ) * 2;
        Self {
            max_duration: Duration::from_secs(max_duration_seconds.clamp(1, 3_600)),
            max_caller_audio_bytes: caller_seconds.saturating_mul(bytes_per_second),
            // Output arrives at a higher rate than input; budget it against
            // the same nominal byte rate so the number the operator sets is
            // still "seconds of assistant speech" to within the rate ratio.
            max_assistant_audio_bytes: assistant_seconds.saturating_mul(bytes_per_second * 2),
        }
    }
}

impl Default for CallBudget {
    fn default() -> Self {
        Self::from_seconds(600, 600, 600)
    }
}

/// The default ceiling for every leg of a call, in seconds. Ten minutes of
/// wall clock and ten minutes of speech each way is a generous call and a
/// bounded bill; an operator raises or lowers it per deployment.
const DEFAULT_CALL_SECONDS: u64 = 600;

/// The environment variables the ceilings are read from, in the order
/// [`CallBudget::from_seconds`] takes them.
const CALL_BUDGET_VARS: [&str; 3] = [
    "OMI_CALL_MAX_SECONDS",
    "OMI_CALL_CALLER_SECONDS",
    "OMI_CALL_ASSISTANT_SECONDS",
];

/// Resolves the per-call ceilings from a value lookup, the same way
/// [`crate::model_tier::model_for_tier`] resolves a model id: configuration
/// first, a documented default second, nothing hardcoded at the call site. A
/// blank or unreadable value is configuration that says nothing, so it falls
/// back rather than refusing the call.
pub(crate) fn budget_from(value: impl Fn(&str) -> Option<String>) -> CallBudget {
    let seconds = |name: &str| {
        value(name)
            .and_then(|configured| configured.trim().parse::<u64>().ok())
            .filter(|configured| *configured > 0)
            .unwrap_or(DEFAULT_CALL_SECONDS)
    };
    CallBudget::from_seconds(
        seconds(CALL_BUDGET_VARS[0]),
        seconds(CALL_BUDGET_VARS[1]),
        seconds(CALL_BUDGET_VARS[2]),
    )
}

/// Environment-backed variant of [`budget_from`].
pub(crate) fn budget_from_env() -> CallBudget {
    budget_from(|name| std::env::var(name).ok())
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum CallOutcome {
    /// The upstream session ended cleanly, or the caller hung up.
    Completed,
    /// A budget ceiling was reached; the session was cancelled.
    BudgetExhausted(&'static str),
    /// Upstream failed. The message is `live_voice`'s, unmodified.
    Upstream(String),
    /// The far end went away and could not be written to.
    TransportLost(String),
}

/// Run a call to completion.
///
/// `caller_audio` yields the caller's microphone as 16 kHz mono PCM16 and is
/// closed when they hang up. `handle` is an already-open Gemini Live session.
pub(crate) async fn run_call(
    mut handle: RealtimeVoiceHandle,
    mut caller_audio: mpsc::Receiver<Vec<u8>>,
    mut transport: impl CallTransport,
    budget: CallBudget,
) -> CallOutcome {
    let Some(mut events) = handle.take_events() else {
        handle.cancel();
        return CallOutcome::Upstream("live voice session produced no events".to_owned());
    };
    let mut animator = MarkAnimator::new();
    let mut caller_bytes = 0u64;
    let mut assistant_bytes = 0u64;
    let mut caller_open = true;
    let deadline = tokio::time::sleep(budget.max_duration);
    tokio::pin!(deadline);
    let mut frames = tokio::time::interval(FRAME_INTERVAL);
    frames.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut last_frame = tokio::time::Instant::now();

    let outcome = loop {
        tokio::select! {
            biased;
            () = &mut deadline => {
                break CallOutcome::BudgetExhausted("call reached its maximum duration");
            }
            chunk = caller_audio.recv(), if caller_open => match chunk {
                Some(bytes) => {
                    caller_bytes = caller_bytes.saturating_add(bytes.len() as u64);
                    if caller_bytes > budget.max_caller_audio_bytes {
                        break CallOutcome::BudgetExhausted("call reached its inbound audio budget");
                    }
                    // A full queue is back-pressure, not a fault: the caller
                    // keeps talking and the oldest audio is the least useful.
                    let _ = handle.send_audio(&bytes);
                }
                None => {
                    // Caller hung up. Let the model finish its sentence rather
                    // than cutting it; `finish` drains and then ends.
                    caller_open = false;
                    handle.finish();
                }
            },
            event = events.recv() => match event {
                Some(RealtimeVoiceEvent::AudioChunk { sample_rate_hz, bytes }) => {
                    assistant_bytes = assistant_bytes.saturating_add(bytes.len() as u64);
                    if assistant_bytes > budget.max_assistant_audio_bytes {
                        break CallOutcome::BudgetExhausted("call reached its outbound audio budget");
                    }
                    animator.observe_output(&bytes);
                    if let Err(failure) = transport.deliver(CallMedia::Audio { sample_rate_hz, bytes }) {
                        break CallOutcome::TransportLost(failure);
                    }
                }
                Some(RealtimeVoiceEvent::Interrupted) => {
                    // Barge-in. `live_voice` has already dropped the model's
                    // discarded audio; the caller's playout buffer still holds
                    // what we handed it, so that is flushed too, and the mark
                    // settles instead of dancing to speech nobody hears.
                    animator.silence();
                    if let Err(failure) = transport.deliver(CallMedia::FlushAudio) {
                        break CallOutcome::TransportLost(failure);
                    }
                }
                Some(RealtimeVoiceEvent::Error { message, .. }) => {
                    break CallOutcome::Upstream(message);
                }
                Some(RealtimeVoiceEvent::SessionEnded { .. }) | None => {
                    break CallOutcome::Completed;
                }
                Some(RealtimeVoiceEvent::Started | RealtimeVoiceEvent::TranscriptDelta { .. }) => {}
            },
            now = frames.tick(), if transport.wants_video() => {
                let dt = now.saturating_duration_since(last_frame).as_secs_f32();
                last_frame = now;
                animator.advance(dt);
                if let Err(failure) = transport.deliver(CallMedia::Video(animator.render(FRAME_SIZE_PX))) {
                    break CallOutcome::TransportLost(failure);
                }
            }
        }
    };
    handle.cancel();
    outcome
}

/// The shipped transport: the app's own media path.
///
/// This is the honest local equivalent of a FaceTime leg. Media is handed to
/// the host over a channel exactly as it would be handed to a call encoder;
/// the Dart side plays the audio and shows the mark frames. It is a real
/// duplex path, not a stub, and it is what the FaceTime transport would be
/// swapped in for.
///
/// Nothing constructs it outside the tests yet: the shipped call command joins
/// a link, so it is [`crate::facetime_bridge::FaceTimeTransport`] that runs.
/// This is the second transport the seam exists for, kept ready rather than
/// deleted and re-derived when the app's own call surface lands.
#[allow(dead_code)]
pub(crate) struct ChannelCallTransport {
    sink: mpsc::Sender<CallMedia>,
    video: bool,
}

impl ChannelCallTransport {
    #[allow(dead_code)]
    pub(crate) fn new(sink: mpsc::Sender<CallMedia>, video: bool) -> Self {
        Self { sink, video }
    }
}

impl CallTransport for ChannelCallTransport {
    fn deliver(&mut self, media: CallMedia) -> Result<(), String> {
        match self.sink.try_send(media) {
            Ok(()) => Ok(()),
            // A full playout queue means the host is behind, not gone. Video
            // frames are droppable; audio is not, and neither is a flush.
            Err(mpsc::error::TrySendError::Full(CallMedia::Video(_))) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => Err("call playout queue is full".to_owned()),
            Err(mpsc::error::TrySendError::Closed(_)) => Err("call media leg closed".to_owned()),
        }
    }

    fn wants_video(&self) -> bool {
        self.video
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::live_voice::LiveControl;
    use std::sync::{Arc, Mutex};

    struct Rig {
        handle: Option<RealtimeVoiceHandle>,
        upstream_audio: mpsc::UnboundedReceiver<Vec<u8>>,
        control: mpsc::UnboundedReceiver<LiveControl>,
        events: mpsc::Sender<RealtimeVoiceEvent>,
        caller: mpsc::Sender<Vec<u8>>,
        caller_rx: Option<mpsc::Receiver<Vec<u8>>>,
    }

    fn rig() -> Rig {
        let (audio_tx, upstream_audio) = mpsc::unbounded_channel();
        let (control_tx, control) = mpsc::unbounded_channel();
        let (events, events_rx) = mpsc::channel(64);
        let (caller, caller_rx) = mpsc::channel(64);
        Rig {
            handle: Some(RealtimeVoiceHandle::from_parts(
                audio_tx, control_tx, events_rx,
            )),
            upstream_audio,
            control,
            events,
            caller,
            caller_rx: Some(caller_rx),
        }
    }

    #[derive(Default)]
    struct Recorder {
        media: Arc<Mutex<Vec<CallMedia>>>,
        video: bool,
        fail_after: Option<usize>,
    }

    impl CallTransport for Recorder {
        fn deliver(&mut self, media: CallMedia) -> Result<(), String> {
            let mut recorded = self.media.lock().map_err(|_| "poisoned".to_owned())?;
            if self.fail_after.is_some_and(|limit| recorded.len() >= limit) {
                return Err("far end gone".to_owned());
            }
            recorded.push(media);
            Ok(())
        }

        fn wants_video(&self) -> bool {
            self.video
        }
    }

    fn speech(bytes: usize) -> Vec<u8> {
        (0..bytes).map(|index| (index % 251) as u8).collect()
    }

    #[tokio::test]
    async fn caller_audio_reaches_the_model_and_replies_reach_the_caller() {
        let mut rig = rig();
        let media = Arc::new(Mutex::new(Vec::new()));
        let transport = Recorder {
            media: Arc::clone(&media),
            video: false,
            fail_after: None,
        };
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            transport,
            CallBudget::default(),
        ));
        rig.caller.send(speech(640)).await.ok();
        rig.events
            .send(RealtimeVoiceEvent::AudioChunk {
                sample_rate_hz: 24_000,
                bytes: speech(480),
            })
            .await
            .ok();
        rig.events
            .send(RealtimeVoiceEvent::SessionEnded {
                resumption_handle: None,
            })
            .await
            .ok();
        assert_eq!(task.await.ok(), Some(CallOutcome::Completed));
        assert_eq!(rig.upstream_audio.recv().await, Some(speech(640)));
        let recorded = media.lock().unwrap_or_else(|failure| failure.into_inner());
        assert_eq!(
            recorded.as_slice(),
            [CallMedia::Audio {
                sample_rate_hz: 24_000,
                bytes: speech(480)
            }]
        );
    }

    #[tokio::test]
    async fn hangup_drains_the_turn_then_ends() {
        let mut rig = rig();
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            Recorder::default(),
            CallBudget::default(),
        ));
        drop(rig.caller);
        assert_eq!(rig.control.recv().await, Some(LiveControl::Finish));
        rig.events
            .send(RealtimeVoiceEvent::SessionEnded {
                resumption_handle: None,
            })
            .await
            .ok();
        assert_eq!(task.await.ok(), Some(CallOutcome::Completed));
        assert_eq!(rig.control.recv().await, Some(LiveControl::Cancel));
    }

    #[tokio::test]
    async fn barge_in_flushes_the_caller_playout_and_settles_the_mark() {
        let mut rig = rig();
        let media = Arc::new(Mutex::new(Vec::new()));
        let transport = Recorder {
            media: Arc::clone(&media),
            video: false,
            fail_after: None,
        };
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            transport,
            CallBudget::default(),
        ));
        rig.events
            .send(RealtimeVoiceEvent::AudioChunk {
                sample_rate_hz: 24_000,
                bytes: speech(480),
            })
            .await
            .ok();
        rig.events.send(RealtimeVoiceEvent::Interrupted).await.ok();
        rig.events
            .send(RealtimeVoiceEvent::SessionEnded {
                resumption_handle: None,
            })
            .await
            .ok();
        assert_eq!(task.await.ok(), Some(CallOutcome::Completed));
        let recorded = media.lock().unwrap_or_else(|failure| failure.into_inner());
        assert!(recorded.contains(&CallMedia::FlushAudio));
    }

    #[tokio::test]
    async fn upstream_failure_ends_the_call_with_the_upstream_message() {
        let mut rig = rig();
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            Recorder::default(),
            CallBudget::default(),
        ));
        rig.events
            .send(RealtimeVoiceEvent::Error {
                message: "live voice provider connection was lost".to_owned(),
                resumption_handle: None,
            })
            .await
            .ok();
        assert_eq!(
            task.await.ok(),
            Some(CallOutcome::Upstream(
                "live voice provider connection was lost".to_owned()
            ))
        );
        assert_eq!(rig.control.recv().await, Some(LiveControl::Cancel));
    }

    #[tokio::test]
    async fn a_dead_far_end_ends_the_call() {
        let mut rig = rig();
        let transport = Recorder {
            media: Arc::new(Mutex::new(Vec::new())),
            video: false,
            fail_after: Some(0),
        };
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            transport,
            CallBudget::default(),
        ));
        rig.events
            .send(RealtimeVoiceEvent::AudioChunk {
                sample_rate_hz: 24_000,
                bytes: speech(64),
            })
            .await
            .ok();
        assert_eq!(
            task.await.ok(),
            Some(CallOutcome::TransportLost("far end gone".to_owned()))
        );
    }

    #[tokio::test]
    async fn inbound_audio_budget_stops_the_call() {
        let mut rig = rig();
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let budget = CallBudget {
            max_caller_audio_bytes: 100,
            ..CallBudget::default()
        };
        let task = tokio::spawn(run_call(handle, caller_rx, Recorder::default(), budget));
        rig.caller.send(speech(256)).await.ok();
        assert_eq!(
            task.await.ok(),
            Some(CallOutcome::BudgetExhausted(
                "call reached its inbound audio budget"
            ))
        );
        assert_eq!(rig.control.recv().await, Some(LiveControl::Cancel));
    }

    #[tokio::test]
    async fn outbound_audio_budget_stops_the_call() {
        let mut rig = rig();
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let budget = CallBudget {
            max_assistant_audio_bytes: 100,
            ..CallBudget::default()
        };
        let task = tokio::spawn(run_call(handle, caller_rx, Recorder::default(), budget));
        rig.events
            .send(RealtimeVoiceEvent::AudioChunk {
                sample_rate_hz: 24_000,
                bytes: speech(256),
            })
            .await
            .ok();
        assert_eq!(
            task.await.ok(),
            Some(CallOutcome::BudgetExhausted(
                "call reached its outbound audio budget"
            ))
        );
    }

    #[tokio::test(start_paused = true)]
    async fn the_duration_ceiling_ends_an_idle_call() {
        let mut rig = rig();
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let budget = CallBudget {
            max_duration: Duration::from_secs(5),
            ..CallBudget::default()
        };
        let task = tokio::spawn(run_call(handle, caller_rx, Recorder::default(), budget));
        tokio::time::advance(Duration::from_secs(6)).await;
        assert_eq!(
            task.await.ok(),
            Some(CallOutcome::BudgetExhausted(
                "call reached its maximum duration"
            ))
        );
        assert_eq!(rig.control.recv().await, Some(LiveControl::Cancel));
    }

    #[tokio::test(start_paused = true)]
    async fn a_video_call_emits_mark_frames() {
        let mut rig = rig();
        let media = Arc::new(Mutex::new(Vec::new()));
        let transport = Recorder {
            media: Arc::clone(&media),
            video: true,
            fail_after: None,
        };
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            transport,
            CallBudget::default(),
        ));
        for _ in 0..12 {
            tokio::task::yield_now().await;
            tokio::time::advance(Duration::from_millis(90)).await;
        }
        rig.events
            .send(RealtimeVoiceEvent::SessionEnded {
                resumption_handle: None,
            })
            .await
            .ok();
        assert_eq!(task.await.ok(), Some(CallOutcome::Completed));
        let recorded = media.lock().unwrap_or_else(|failure| failure.into_inner());
        let frames = recorded
            .iter()
            .filter(|item| matches!(item, CallMedia::Video(_)))
            .count();
        assert!(frames >= 3, "expected mark frames, got {frames}");
    }

    #[tokio::test]
    async fn an_audio_only_call_draws_nothing() {
        let mut rig = rig();
        let media = Arc::new(Mutex::new(Vec::new()));
        let transport = Recorder {
            media: Arc::clone(&media),
            video: false,
            fail_after: None,
        };
        let handle = rig.handle.take().unwrap_or_else(|| unreachable!());
        let caller_rx = rig.caller_rx.take().unwrap_or_else(|| unreachable!());
        let task = tokio::spawn(run_call(
            handle,
            caller_rx,
            transport,
            CallBudget::default(),
        ));
        rig.events
            .send(RealtimeVoiceEvent::SessionEnded {
                resumption_handle: None,
            })
            .await
            .ok();
        task.await.ok();
        let recorded = media.lock().unwrap_or_else(|failure| failure.into_inner());
        assert!(
            !recorded
                .iter()
                .any(|item| matches!(item, CallMedia::Video(_)))
        );
    }

    #[test]
    fn the_channel_transport_drops_late_video_but_not_late_audio() {
        let (sink, _receiver) = mpsc::channel(1);
        let mut transport = ChannelCallTransport::new(sink, true);
        assert!(transport.wants_video());
        assert!(
            transport
                .deliver(CallMedia::Video(MarkAnimator::new().render(32)))
                .is_ok()
        );
        assert!(
            transport
                .deliver(CallMedia::Video(MarkAnimator::new().render(32)))
                .is_ok()
        );
        assert!(
            transport
                .deliver(CallMedia::Audio {
                    sample_rate_hz: 24_000,
                    bytes: speech(16),
                })
                .is_err()
        );
    }

    #[test]
    fn the_channel_transport_reports_a_closed_leg() {
        let (sink, receiver) = mpsc::channel(4);
        drop(receiver);
        let mut transport = ChannelCallTransport::new(sink, false);
        assert!(!transport.wants_video());
        assert_eq!(
            transport.deliver(CallMedia::FlushAudio),
            Err("call media leg closed".to_owned())
        );
    }

    #[test]
    fn budgets_from_seconds_are_bounded() {
        let budget = CallBudget::from_seconds(10_000, 60, 60);
        assert_eq!(budget.max_duration, Duration::from_secs(3_600));
        assert_eq!(budget.max_caller_audio_bytes, 60 * 32_000);
        assert_eq!(CallBudget::from_seconds(0, 1, 1).max_duration.as_secs(), 1);
    }

    #[test]
    fn configured_ceilings_reach_the_budget() {
        let configured = |name: &str| match name {
            "OMI_CALL_MAX_SECONDS" => Some("120".to_owned()),
            "OMI_CALL_CALLER_SECONDS" => Some("90".to_owned()),
            "OMI_CALL_ASSISTANT_SECONDS" => Some("30".to_owned()),
            _ => None,
        };
        let budget = budget_from(configured);
        assert_eq!(budget.max_duration, Duration::from_secs(120));
        assert_eq!(budget.max_caller_audio_bytes, 90 * 32_000);
        assert_eq!(budget.max_assistant_audio_bytes, 30 * 64_000);
    }

    #[test]
    fn unset_blank_and_nonsense_ceilings_fall_back_to_the_default() {
        for lookup in [
            (|_: &str| None) as fn(&str) -> Option<String>,
            |_: &str| Some("   ".to_owned()),
            |_: &str| Some("later".to_owned()),
            |_: &str| Some("0".to_owned()),
        ] {
            assert_eq!(budget_from(lookup), CallBudget::default());
        }
    }
}
