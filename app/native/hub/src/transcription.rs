use crate::live_voice::{
    GeminiLiveProvider, LiveFunctionCall, RealtimeVoiceEvent, RealtimeVoiceHandle,
    RealtimeVoiceProvider, RealtimeVoiceSession, validate_session,
};
use crate::signals::{
    AudioChunk, AudioEncoding, AudioGateStats, LiveVoiceAudio, LiveVoicePhase, LiveVoiceState,
    LiveVoiceTranscript, NativeError, NativeEvent, ToolProgress, ToolStatus, TranscriptionAuth,
    TranscriptionRoute, TranscriptionState, TranscriptionStatus, TranscriptionStopAcknowledgement,
};
use crate::stt::{self, SttConfig, SttHandle};
use crate::vad::{GateDecision, SpeechGate};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const COMMAND_QUEUE_CAPACITY: usize = 32;
const AUDIO_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
const MAX_ACTIVE_LIVE_SESSIONS: usize = 2;
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
/// How often idle transcription sessions are swept. Per-chunk retain scanned
/// every active session on every audio frame; a periodic sweep is enough.
const SESSION_IDLE_SWEEP_INTERVAL: Duration = Duration::from_secs(5);
/// How often a streaming session reports what its gate has saved. Every chunk
/// would be one event per twenty milliseconds of audio for a number that only
/// moves slowly; a session that ends sooner than this still reports once, on
/// the way out.
const GATE_REPORT_INTERVAL: Duration = Duration::from_secs(15);

pub(crate) struct AudioSession {
    pub(crate) start_request_id: String,
    pub(crate) next_sequence: u64,
    pub(crate) accepted_bytes: u64,
    pub(crate) sample_rate_hz: u32,
    pub(crate) channels: u8,
    pub(crate) encoding: crate::signals::AudioEncoding,
    pub(crate) last_seen: Instant,
    pub(crate) device_id: String,
    pub(crate) route: TranscriptionRoute,
    pub(crate) language: String,
    pub(crate) epoch: u32,
    pub(crate) phase: TranscriptionPhase,
    pub(crate) provider: Option<SttHandle>,
    /// Decides which of this stream's audio is worth the metered socket. It
    /// lives on the session rather than on the provider because its pre-roll
    /// and hangover are per-stream state, and because a session that
    /// reconnects its provider must not forget what it was holding.
    pub(crate) gate: SpeechGate,
    pub(crate) last_gate_report: Instant,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TranscriptionPhase {
    Streaming,
    Draining,
}

pub(crate) struct StartTranscription {
    pub(crate) request_id: String,
    pub(crate) audio_stream_id: String,
    pub(crate) device_id: String,
    pub(crate) auth: TranscriptionAuth,
    pub(crate) trusted_worker_origin: Option<String>,
    pub(crate) language: String,
    pub(crate) sample_rate_hz: u32,
    pub(crate) channels: u8,
    pub(crate) encoding: AudioEncoding,
}

pub(crate) struct StartLiveVoice {
    pub(crate) request_id: String,
    pub(crate) live_stream_id: String,
    pub(crate) ephemeral_token: String,
    pub(crate) model: String,
    pub(crate) resumption_handle: Option<String>,
    pub(crate) session_context: Option<String>,
}

/// Computer-use tool calls from a Live session, forwarded to the command
/// runtime so they register as real ActionProposals.
pub(crate) struct LiveToolCalls {
    pub(crate) live_stream_id: String,
    pub(crate) calls: Vec<LiveFunctionCall>,
}

pub(crate) enum TranscriptionControl {
    Start(StartTranscription),
    Stop {
        request_id: String,
        stream_id: String,
    },
    StartLive(StartLiveVoice),
    StopLive {
        request_id: String,
        stream_id: String,
    },
    UpdateLiveContext {
        request_id: String,
        stream_id: String,
        session_context: String,
    },
    Fence,
}

pub(crate) struct AudioSessions {
    pub(crate) sessions: HashMap<String, AudioSession>,
    last_idle_sweep: Instant,
}

impl Default for AudioSessions {
    fn default() -> Self {
        Self {
            sessions: HashMap::new(),
            last_idle_sweep: Instant::now(),
        }
    }
}

impl AudioSessions {
    fn maybe_sweep_idle(&mut self, now: Instant) {
        if now.saturating_duration_since(self.last_idle_sweep) < SESSION_IDLE_SWEEP_INTERVAL {
            return;
        }
        self.last_idle_sweep = now;
        self.sessions.retain(|_, session| {
            now.saturating_duration_since(session.last_seen) < AUDIO_SESSION_IDLE_TIMEOUT
        });
    }
}

pub(crate) enum LiveAcceptOutcome {
    Accepted,
    NotLive(AudioChunk),
}

pub(crate) struct AudioProgress {
    pub(crate) request_id: String,
    pub(crate) status: ToolStatus,
    pub(crate) detail: String,
}

pub(crate) struct AudioAcceptError {
    pub(crate) request_id: String,
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

struct LiveSession {
    handle: RealtimeVoiceHandle,
    next_sequence: u64,
}

pub(crate) struct LiveSessions {
    sessions: Arc<Mutex<HashMap<String, LiveSession>>>,
    live_tools: Option<mpsc::Sender<LiveToolCalls>>,
}

impl Default for LiveSessions {
    fn default() -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            live_tools: None,
        }
    }
}

impl LiveSessions {
    fn with_live_tools(live_tools: mpsc::Sender<LiveToolCalls>) -> Self {
        Self {
            sessions: Arc::new(Mutex::new(HashMap::new())),
            live_tools: Some(live_tools),
        }
    }

    pub(crate) fn start(
        &mut self,
        provider: &dyn RealtimeVoiceProvider,
        start: StartLiveVoice,
    ) -> Result<(), AudioAcceptError> {
        let session = RealtimeVoiceSession {
            live_stream_id: start.live_stream_id.clone(),
            ephemeral_token: start.ephemeral_token,
            model: start.model,
            resumption_handle: start.resumption_handle,
            session_context: start.session_context,
        };
        if let Err(message) = validate_session(&session) {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "live_voice_start_invalid",
                message,
            });
        }
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        if sessions.contains_key(&start.live_stream_id) {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "live_voice_start_conflict",
                message: "live voice stream was already started".to_owned(),
            });
        }
        if sessions.len() >= MAX_ACTIVE_LIVE_SESSIONS {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "live_voice_capacity_exceeded",
                message: "too many active live voice sessions".to_owned(),
            });
        }
        let mut handle = provider.open(session).map_err(|message| AudioAcceptError {
            request_id: start.request_id.clone(),
            code: "live_voice_provider_invalid",
            message,
        })?;
        if let Some(events) = handle.take_events() {
            tokio::spawn(forward_live_events(
                start.live_stream_id.clone(),
                events,
                Arc::clone(&self.sessions),
                self.live_tools.clone(),
            ));
        }
        sessions.insert(
            start.live_stream_id,
            LiveSession {
                handle,
                next_sequence: 0,
            },
        );
        Ok(())
    }

    pub(crate) fn stop(&mut self, stream_id: &str) -> bool {
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        match sessions.remove(stream_id) {
            Some(session) => {
                session.handle.cancel();
                true
            }
            None => false,
        }
    }

    pub(crate) fn update_context(&self, stream_id: &str, session_context: &str) -> bool {
        if session_context.trim().is_empty() {
            return false;
        }
        let sessions = self
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        match sessions.get(stream_id) {
            Some(session) => {
                session.handle.update_context(session_context);
                true
            }
            None => false,
        }
    }

    pub(crate) fn cancel_all(&mut self) {
        let drained: Vec<_> = self
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .drain()
            .collect();
        for (stream_id, session) in drained {
            session.handle.cancel();
            NativeEvent::LiveVoiceState(LiveVoiceState {
                live_stream_id: stream_id,
                state: LiveVoicePhase::Ended,
                detail: Some("live voice session was fenced".to_owned()),
                resumption_handle: None,
            })
            .send();
        }
    }

    pub(crate) fn try_accept(
        &self,
        chunk: AudioChunk,
    ) -> Result<LiveAcceptOutcome, AudioAcceptError> {
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner());
        let Some(session) = sessions.get_mut(&chunk.request_id) else {
            return Ok(LiveAcceptOutcome::NotLive(chunk));
        };
        if chunk.sequence != session.next_sequence {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "invalid_audio_sequence",
                message: format!(
                    "expected audio sequence {}, received {}",
                    session.next_sequence, chunk.sequence
                ),
            });
        }
        if chunk.sample_rate_hz != 16_000
            || chunk.channels != 1
            || chunk.encoding != AudioEncoding::PcmS16Le
        {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "live_voice_unsupported_audio",
                message: "live voice requires 16 kHz mono PCM16 audio".to_owned(),
            });
        }
        session.next_sequence =
            session
                .next_sequence
                .checked_add(1)
                .ok_or_else(|| AudioAcceptError {
                    request_id: chunk.request_id.clone(),
                    code: "audio_counter_overflow",
                    message: "audio sequence overflowed".to_owned(),
                })?;
        if chunk.end_of_stream {
            let stream_id = chunk.request_id;
            if let Some(session) = sessions.remove(&stream_id) {
                session.handle.finish();
            }
            return Ok(LiveAcceptOutcome::Accepted);
        }
        session
            .handle
            .send_audio(&chunk.bytes)
            .map_err(|message| AudioAcceptError {
                request_id: chunk.request_id,
                code: "live_voice_provider_unavailable",
                message,
            })?;
        Ok(LiveAcceptOutcome::Accepted)
    }
}

struct LiveEventTranslator {
    live_stream_id: String,
    sequence: u64,
}

impl LiveEventTranslator {
    fn new(live_stream_id: String) -> Self {
        Self {
            live_stream_id,
            sequence: 0,
        }
    }

    /// Maps a provider event to the signal sent to Dart. `Started` is only
    /// emitted once the provider acknowledged setup (setupComplete), so the
    /// UI never shows a live session that failed inside the connect window.
    /// The returned flag marks terminal events that end the forwarding loop.
    fn translate(&mut self, event: RealtimeVoiceEvent) -> (NativeEvent, bool) {
        match event {
            RealtimeVoiceEvent::Started => (
                NativeEvent::LiveVoiceState(LiveVoiceState {
                    live_stream_id: self.live_stream_id.clone(),
                    state: LiveVoicePhase::Started,
                    detail: None,
                    resumption_handle: None,
                }),
                false,
            ),
            RealtimeVoiceEvent::TranscriptDelta {
                text,
                final_segment,
                assistant,
            } => (
                NativeEvent::LiveVoiceTranscript(LiveVoiceTranscript {
                    live_stream_id: self.live_stream_id.clone(),
                    text,
                    final_segment,
                    assistant,
                }),
                false,
            ),
            RealtimeVoiceEvent::AudioChunk {
                sample_rate_hz,
                bytes,
            } => {
                let sequence = self.sequence;
                self.sequence = self.sequence.saturating_add(1);
                (
                    NativeEvent::LiveVoiceAudio(LiveVoiceAudio {
                        live_stream_id: self.live_stream_id.clone(),
                        sequence,
                        sample_rate_hz,
                        bytes,
                    }),
                    false,
                )
            }
            RealtimeVoiceEvent::Interrupted => (
                NativeEvent::LiveVoiceState(LiveVoiceState {
                    live_stream_id: self.live_stream_id.clone(),
                    state: LiveVoicePhase::Interrupted,
                    detail: None,
                    resumption_handle: None,
                }),
                false,
            ),
            // Tool calls register as ActionProposals via the live-tools
            // channel. A short transcript note keeps the listening UI aware
            // until the proposal event arrives.
            RealtimeVoiceEvent::ToolCall { calls } => {
                let detail = calls
                    .iter()
                    .map(|call| call.name.as_str())
                    .collect::<Vec<_>>()
                    .join(", ");
                (
                    NativeEvent::LiveVoiceTranscript(LiveVoiceTranscript {
                        live_stream_id: self.live_stream_id.clone(),
                        text: format!("Proposing: {detail}"),
                        final_segment: false,
                        assistant: true,
                    }),
                    false,
                )
            }
            RealtimeVoiceEvent::SessionEnded { resumption_handle } => (
                NativeEvent::LiveVoiceState(LiveVoiceState {
                    live_stream_id: self.live_stream_id.clone(),
                    state: LiveVoicePhase::Ended,
                    detail: None,
                    resumption_handle,
                }),
                true,
            ),
            RealtimeVoiceEvent::Error {
                message,
                resumption_handle,
            } => (
                NativeEvent::LiveVoiceState(LiveVoiceState {
                    live_stream_id: self.live_stream_id.clone(),
                    state: LiveVoicePhase::Failed,
                    detail: Some(message),
                    resumption_handle,
                }),
                true,
            ),
        }
    }

    fn closed(&self) -> NativeEvent {
        NativeEvent::LiveVoiceState(LiveVoiceState {
            live_stream_id: self.live_stream_id.clone(),
            state: LiveVoicePhase::Ended,
            detail: None,
            resumption_handle: None,
        })
    }
}

async fn forward_live_events(
    live_stream_id: String,
    mut events: mpsc::Receiver<RealtimeVoiceEvent>,
    sessions: Arc<Mutex<HashMap<String, LiveSession>>>,
    live_tools: Option<mpsc::Sender<LiveToolCalls>>,
) {
    let remove_session = |live_stream_id: &str| {
        sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .remove(live_stream_id);
    };
    let mut translator = LiveEventTranslator::new(live_stream_id.clone());
    while let Some(event) = events.recv().await {
        if let RealtimeVoiceEvent::ToolCall { calls } = &event
            && let Some(sender) = &live_tools
        {
            let _ = sender
                .send(LiveToolCalls {
                    live_stream_id: live_stream_id.clone(),
                    calls: calls.clone(),
                })
                .await;
        }
        let (signal, terminal) = translator.translate(event);
        if terminal {
            remove_session(&live_stream_id);
        }
        signal.send();
        if terminal {
            return;
        }
    }
    remove_session(&live_stream_id);
    translator.closed().send();
}

pub struct AudioDispatcher {
    receiver: mpsc::Receiver<AudioChunk>,
    controls: mpsc::Receiver<TranscriptionControl>,
    sessions: AudioSessions,
    live: LiveSessions,
    live_provider: Arc<dyn RealtimeVoiceProvider>,
}

impl AudioDispatcher {
    #[allow(dead_code)]
    pub fn channel() -> (
        mpsc::Sender<AudioChunk>,
        mpsc::Sender<TranscriptionControl>,
        Self,
    ) {
        let (sender, receiver) = mpsc::channel(AUDIO_QUEUE_CAPACITY);
        let (control_sender, controls) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        (
            sender,
            control_sender,
            Self {
                receiver,
                controls,
                sessions: AudioSessions::default(),
                live: LiveSessions::default(),
                live_provider: Arc::new(GeminiLiveProvider),
            },
        )
    }

    pub fn channel_with_live_tools() -> (
        mpsc::Sender<AudioChunk>,
        mpsc::Sender<TranscriptionControl>,
        mpsc::Receiver<LiveToolCalls>,
        Self,
    ) {
        let (sender, receiver) = mpsc::channel(AUDIO_QUEUE_CAPACITY);
        let (control_sender, controls) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        let (live_tools_sender, live_tools_receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        (
            sender,
            control_sender,
            live_tools_receiver,
            Self {
                receiver,
                controls,
                sessions: AudioSessions::default(),
                live: LiveSessions::with_live_tools(live_tools_sender),
                live_provider: Arc::new(GeminiLiveProvider),
            },
        )
    }

    pub async fn run(mut self) {
        loop {
            tokio::select! {
                biased;
                control = self.controls.recv() => match control {
                    Some(TranscriptionControl::Start(start)) => {
                        if let Err(failure) = self.sessions.start(start) {
                            NativeEvent::Error(NativeError {
                                request_id: Some(failure.request_id),
                                code: failure.code.to_owned(),
                                message: failure.message,
                                retryable: false,
                            })
                            .send();
                        }
                    }
                    Some(TranscriptionControl::Stop { request_id, stream_id }) => {
                        let (acknowledgement, status) = self.sessions.stop(&request_id, &stream_id);
                        NativeEvent::TranscriptionStopAcknowledged(acknowledgement).send();
                        if let Some(status) = status {
                            NativeEvent::TranscriptionStatus(status).send();
                        }
                    }
                    Some(TranscriptionControl::StartLive(start)) => {
                        if let Err(failure) = self.live.start(self.live_provider.as_ref(), start) {
                            NativeEvent::Error(NativeError {
                                request_id: Some(failure.request_id),
                                code: failure.code.to_owned(),
                                message: failure.message,
                                retryable: false,
                            })
                            .send();
                        }
                    }
                    Some(TranscriptionControl::StopLive { request_id, stream_id }) => {
                        if !self.live.stop(&stream_id) {
                            NativeEvent::Error(NativeError {
                                request_id: Some(request_id),
                                code: "live_voice_not_started".to_owned(),
                                message: "live voice stream is not active".to_owned(),
                                retryable: false,
                            })
                            .send();
                        }
                    }
                    Some(TranscriptionControl::UpdateLiveContext {
                        request_id,
                        stream_id,
                        session_context,
                    }) => {
                        if !self.live.update_context(&stream_id, &session_context) {
                            NativeEvent::Error(NativeError {
                                request_id: Some(request_id),
                                code: "live_voice_not_started".to_owned(),
                                message: "live voice stream is not active".to_owned(),
                                retryable: false,
                            })
                            .send();
                        }
                    }
                    Some(TranscriptionControl::Fence) => {
                        self.sessions.cancel_all();
                        self.live.cancel_all();
                    }
                    None if self.receiver.is_closed() => break,
                    None => {}
                },
                chunk = self.receiver.recv() => match chunk {
                    Some(chunk) => match self.live.try_accept(chunk) {
                        Ok(LiveAcceptOutcome::Accepted) => {}
                        Ok(LiveAcceptOutcome::NotLive(chunk)) => match self.sessions.accept(chunk) {
                            Ok(Some(next)) => {
                                NativeEvent::ToolProgress(ToolProgress {
                                    request_id: next.request_id,
                                    tool: "audio".to_owned(),
                                    status: next.status,
                                    detail: Some(next.detail),
                                })
                                .send();
                            }
                            Ok(None) => {}
                            Err(failure) => NativeEvent::Error(NativeError {
                                request_id: Some(failure.request_id),
                                code: failure.code.to_owned(),
                                message: failure.message,
                                retryable: false,
                            })
                            .send(),
                        },
                        Err(failure) => NativeEvent::Error(NativeError {
                            request_id: Some(failure.request_id),
                            code: failure.code.to_owned(),
                            message: failure.message,
                            retryable: false,
                        })
                        .send(),
                    },
                    None if self.controls.is_closed() => break,
                    None => {}
                }
            }
        }
    }
}

/// Packages a gate's running total for the client. The durations are derived
/// from the byte counts and the stream's own format, because a saving stated in
/// seconds of audio is the one that lines up with how a transcription session
/// is billed.
fn gate_stats(audio_stream_id: &str, gate: &SpeechGate) -> AudioGateStats {
    let stats = gate.stats();
    AudioGateStats {
        audio_stream_id: audio_stream_id.to_owned(),
        enabled: gate.enabled(),
        gateable: gate.gateable(),
        forwarded_bytes: stats.forwarded_bytes,
        suppressed_bytes: stats.suppressed_bytes,
        forwarded_ms: gate.bytes_to_ms(stats.forwarded_bytes),
        suppressed_ms: gate.bytes_to_ms(stats.suppressed_bytes),
    }
}

impl AudioSessions {
    pub(crate) fn start(&mut self, start: StartTranscription) -> Result<(), AudioAcceptError> {
        if matches!(&start.auth, TranscriptionAuth::Local) {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "transcription_local_unavailable",
                message: "local transcription is unavailable".to_owned(),
            });
        }
        if let Some(existing) = self.sessions.get(&start.audio_stream_id) {
            let exact = existing.device_id == start.device_id
                && existing.route == start.auth.route()
                && existing.language == start.language
                && existing.sample_rate_hz == start.sample_rate_hz
                && existing.channels == start.channels
                && existing.encoding == start.encoding;
            return if exact {
                Ok(())
            } else {
                Err(AudioAcceptError {
                    request_id: start.request_id,
                    code: "transcription_start_conflict",
                    message: "audio stream was already started with different metadata".to_owned(),
                })
            };
        }
        if self.sessions.len() >= MAX_ACTIVE_AUDIO_SESSIONS {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "audio_capacity_exceeded",
                message: "too many active audio sessions".to_owned(),
            });
        }
        let route = start.auth.route();
        let provider = Some(
            stt::spawn(
                SttConfig {
                    request_id: start.request_id.clone(),
                    audio_stream_id: start.audio_stream_id.clone(),
                    device_id: start.device_id.clone(),
                    language: start.language.clone(),
                    sample_rate_hz: start.sample_rate_hz,
                    channels: start.channels,
                    encoding: start.encoding,
                },
                &start.auth,
                start.trusted_worker_origin.as_deref(),
            )
            .map_err(|failure| AudioAcceptError {
                request_id: start.request_id.clone(),
                code: "transcription_provider_invalid",
                message: failure.to_string(),
            })?,
        );
        let stream_id = start.audio_stream_id.clone();
        self.sessions.insert(
            stream_id.clone(),
            AudioSession {
                start_request_id: start.request_id,
                next_sequence: 0,
                accepted_bytes: 0,
                sample_rate_hz: start.sample_rate_hz,
                channels: start.channels,
                encoding: start.encoding,
                last_seen: Instant::now(),
                device_id: start.device_id,
                route,
                language: start.language,
                epoch: 0,
                phase: TranscriptionPhase::Streaming,
                provider,
                gate: SpeechGate::new(
                    crate::vad::policy(),
                    start.encoding,
                    start.sample_rate_hz,
                    start.channels,
                ),
                last_gate_report: Instant::now(),
            },
        );
        Ok(())
    }

    pub(crate) fn stop(
        &mut self,
        request_id: &str,
        stream_id: &str,
    ) -> (
        TranscriptionStopAcknowledgement,
        Option<TranscriptionStatus>,
    ) {
        if let Some(mut session) = self.sessions.remove(stream_id) {
            session.phase = TranscriptionPhase::Draining;
            session.gate.finish();
            NativeEvent::AudioGateStats(gate_stats(stream_id, &session.gate)).send();
            let provider_reports_terminal = session.provider.is_some();
            if let Some(provider) = &session.provider {
                provider.cancel();
            }
            let status = (!provider_reports_terminal).then(|| TranscriptionStatus {
                request_id: session.start_request_id,
                audio_stream_id: stream_id.to_owned(),
                state: TranscriptionState::Cancelled,
                stt_epoch: session.epoch,
            });
            (
                TranscriptionStopAcknowledgement {
                    request_id: request_id.to_owned(),
                    audio_stream_id: stream_id.to_owned(),
                    accepted: true,
                },
                status,
            )
        } else {
            (
                TranscriptionStopAcknowledgement {
                    request_id: request_id.to_owned(),
                    audio_stream_id: stream_id.to_owned(),
                    accepted: false,
                },
                None,
            )
        }
    }

    pub(crate) fn cancel_all(&mut self) {
        for (stream_id, session) in self.sessions.drain() {
            if let Some(provider) = &session.provider {
                provider.cancel();
            } else {
                NativeEvent::TranscriptionStatus(TranscriptionStatus {
                    request_id: session.start_request_id,
                    audio_stream_id: stream_id,
                    state: TranscriptionState::Cancelled,
                    stt_epoch: session.epoch,
                })
                .send();
            }
        }
    }

    pub(crate) fn accept(
        &mut self,
        chunk: AudioChunk,
    ) -> Result<Option<AudioProgress>, AudioAcceptError> {
        self.accept_at(chunk, Instant::now())
    }

    pub(crate) fn accept_at(
        &mut self,
        chunk: AudioChunk,
        now: Instant,
    ) -> Result<Option<AudioProgress>, AudioAcceptError> {
        self.maybe_sweep_idle(now);
        if !self.sessions.contains_key(&chunk.request_id) {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "transcription_not_started",
                message: "audio stream must be started before sending audio".to_owned(),
            });
        }
        let session = self
            .sessions
            .get_mut(&chunk.request_id)
            .ok_or_else(|| AudioAcceptError {
                request_id: chunk.request_id.clone(),
                code: "transcription_not_started",
                message: "audio stream must be started before sending audio".to_owned(),
            })?;
        if chunk.sequence != session.next_sequence {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "invalid_audio_sequence",
                message: format!(
                    "expected audio sequence {}, received {}",
                    session.next_sequence, chunk.sequence
                ),
            });
        }
        if chunk.sample_rate_hz != session.sample_rate_hz
            || chunk.channels != session.channels
            || chunk.encoding != session.encoding
        {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "audio_format_changed",
                message: "audio format changed during an active session".to_owned(),
            });
        }
        // Voice-activity gating happens here, between accepting a chunk from
        // the client and paying to send it: the sequence and byte accounting
        // above describe what the device delivered, which must stay true
        // whether or not the audio was worth transmitting.
        if !chunk.end_of_stream {
            session.gate.set_policy(crate::vad::policy());
            let decision = session.gate.observe(&chunk.bytes);
            if let Some(provider) = &session.provider {
                let send = |bytes: &[u8]| {
                    provider
                        .send_audio(bytes)
                        .map_err(|failure| AudioAcceptError {
                            request_id: chunk.request_id.clone(),
                            code: "transcription_provider_unavailable",
                            message: failure.to_string(),
                        })
                };
                match &decision {
                    GateDecision::Pass => send(&chunk.bytes)?,
                    // The retained run-up goes first so the provider hears the
                    // start of the word, not its second half.
                    GateDecision::PassWithPreRoll(pre_roll) => {
                        send(pre_roll)?;
                        send(&chunk.bytes)?;
                    }
                    GateDecision::Suppress => {}
                }
            }
        }
        let first_chunk = session.next_sequence == 0;
        let next_sequence =
            session
                .next_sequence
                .checked_add(1)
                .ok_or_else(|| AudioAcceptError {
                    request_id: chunk.request_id.clone(),
                    code: "audio_counter_overflow",
                    message: "audio sequence overflowed".to_owned(),
                })?;
        let accepted_bytes = session
            .accepted_bytes
            .checked_add(chunk.bytes.len() as u64)
            .ok_or_else(|| AudioAcceptError {
                request_id: chunk.request_id.clone(),
                code: "audio_counter_overflow",
                message: "accepted audio byte count overflowed".to_owned(),
            })?;
        session.next_sequence = next_sequence;
        session.accepted_bytes = accepted_bytes;
        session.last_seen = now;
        // A saving nobody can see is one nobody will trust, so the gate's
        // running total is reported periodically and again when the stream
        // ends. It stays inside the process: this is a signal to the client,
        // not a measurement sent anywhere.
        if chunk.end_of_stream
            || now.saturating_duration_since(session.last_gate_report) >= GATE_REPORT_INTERVAL
        {
            session.last_gate_report = now;
            if chunk.end_of_stream {
                session.gate.finish();
            }
            NativeEvent::AudioGateStats(gate_stats(&chunk.request_id, &session.gate)).send();
        }
        let progress = if chunk.end_of_stream {
            let stream_id = chunk.request_id.clone();
            let epoch = session.epoch;
            session.phase = TranscriptionPhase::Draining;
            if let Some(provider) = &session.provider {
                provider.finish();
            }
            NativeEvent::TranscriptionStatus(TranscriptionStatus {
                request_id: stream_id.clone(),
                audio_stream_id: stream_id.clone(),
                state: TranscriptionState::Draining,
                stt_epoch: epoch,
            })
            .send();
            self.sessions.remove(&stream_id);
            Some((
                ToolStatus::Complete,
                format!("accepted {accepted_bytes} audio bytes"),
            ))
        } else if first_chunk {
            Some((ToolStatus::Running, "audio stream accepted".to_owned()))
        } else {
            None
        };
        Ok(progress.map(|(status, detail)| AudioProgress {
            request_id: chunk.request_id,
            status,
            detail,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct CapturingProvider(Mutex<Option<RealtimeVoiceSession>>);

    impl RealtimeVoiceProvider for CapturingProvider {
        fn open(&self, session: RealtimeVoiceSession) -> Result<RealtimeVoiceHandle, String> {
            *self.0.lock().unwrap_or_else(|poison| poison.into_inner()) = Some(session.clone());
            GeminiLiveProvider.open(session)
        }
    }

    fn start_request(resumption_handle: Option<String>) -> StartLiveVoice {
        StartLiveVoice {
            request_id: "request-1".to_owned(),
            live_stream_id: "live-1".to_owned(),
            ephemeral_token: "auth_tokens/abc123".to_owned(),
            model: "gemini-live".to_owned(),
            resumption_handle,
            session_context: None,
        }
    }

    fn started_stream(encoding: AudioEncoding) -> AudioSessions {
        let mut sessions = AudioSessions::default();
        let started = sessions.start(StartTranscription {
            request_id: "voice-1".to_owned(),
            audio_stream_id: "voice-1".to_owned(),
            device_id: "omi-1".to_owned(),
            auth: TranscriptionAuth::Byok {
                endpoint: "wss://api.deepgram.com/v1/listen".to_owned(),
                api_key: "key".to_owned(),
            },
            trusted_worker_origin: None,
            language: "en".to_owned(),
            sample_rate_hz: 16_000,
            channels: 1,
            encoding,
        });
        assert!(started.is_ok());
        sessions
    }

    /// 16 kHz mono 16-bit audio at `amplitude`, alternating sign so a loud
    /// window measures loud rather than averaging to a constant offset.
    fn pcm16(amplitude: i16, ms: u32) -> Vec<u8> {
        (0..(16 * ms as usize))
            .flat_map(|index| {
                let value = if index % 2 == 0 {
                    amplitude
                } else {
                    -amplitude
                };
                value.to_le_bytes()
            })
            .collect()
    }

    fn feed(
        sessions: &mut AudioSessions,
        encoding: AudioEncoding,
        chunks: impl IntoIterator<Item = Vec<u8>>,
    ) -> AudioGateStats {
        let mut sequence = 0;
        for bytes in chunks {
            let accepted = sessions.accept(AudioChunk {
                request_id: "voice-1".to_owned(),
                sequence,
                sample_rate_hz: 16_000,
                channels: 1,
                encoding,
                end_of_stream: false,
                bytes,
            });
            assert!(accepted.is_ok());
            sequence += 1;
        }
        let _ = crate::signals::test_events::take();
        let ended = sessions.accept(AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding,
            end_of_stream: true,
            bytes: Vec::new(),
        });
        assert!(ended.is_ok());
        crate::signals::test_events::take()
            .into_iter()
            .find_map(|event| match event {
                NativeEvent::AudioGateStats(stats) => Some(stats),
                _ => None,
            })
            .unwrap_or_else(|| panic!("a finished stream reports what its gate saved"))
    }

    #[test]
    fn silence_from_the_device_never_reaches_the_metered_session() {
        let mut sessions = started_stream(AudioEncoding::PcmS16Le);
        let stats = feed(
            &mut sessions,
            AudioEncoding::PcmS16Le,
            (0..50).map(|_| pcm16(0, 20)),
        );
        assert!(stats.enabled);
        assert!(stats.gateable);
        assert_eq!(stats.forwarded_bytes, 0);
        // A second of silence accepted from the device, and a second of
        // silence that was never paid to transmit.
        assert_eq!(stats.suppressed_ms, 1_000);
        assert_eq!(stats.suppressed_bytes, 50 * pcm16(0, 20).len() as u64);
    }

    #[test]
    fn speech_reaches_the_session_together_with_the_silence_before_it() {
        let mut sessions = started_stream(AudioEncoding::PcmS16Le);
        let stats = feed(
            &mut sessions,
            AudioEncoding::PcmS16Le,
            (0..50)
                .map(|_| pcm16(0, 20))
                .chain((0..10).map(|_| pcm16(6_000, 20))),
        );
        // Everything spoken, plus the retained run-up that keeps the first
        // word whole; the rest of the silence stayed on the device.
        assert_eq!(stats.forwarded_ms, 300 + 200);
        assert_eq!(stats.suppressed_ms, 1_000 - 300);
    }

    #[test]
    fn an_opus_stream_is_forwarded_whole_and_says_it_was_not_gated() {
        let mut sessions = started_stream(AudioEncoding::Opus);
        // Opus packets carry no loudness the hub can read without decoding
        // them, so the gate must not pretend to judge these bytes.
        let stats = feed(
            &mut sessions,
            AudioEncoding::Opus,
            (0..10).map(|_| vec![0xfc_u8; 80]),
        );
        assert!(!stats.gateable);
        assert_eq!(stats.forwarded_bytes, 800);
        assert_eq!(stats.suppressed_bytes, 0);
    }

    #[test]
    fn live_start_passes_the_resumption_handle_to_the_provider() {
        let provider = CapturingProvider(Mutex::new(None));
        let mut sessions = LiveSessions::default();
        assert!(
            sessions
                .start(&provider, start_request(Some("handle-1".to_owned())))
                .is_ok()
        );
        let session = provider
            .0
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .take()
            .unwrap_or_else(|| panic!("provider was opened"));
        assert_eq!(session.resumption_handle.as_deref(), Some("handle-1"));

        let provider = CapturingProvider(Mutex::new(None));
        let mut sessions = LiveSessions::default();
        assert!(sessions.start(&provider, start_request(None)).is_ok());
        let session = provider
            .0
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .take()
            .unwrap_or_else(|| panic!("provider was opened"));
        assert_eq!(session.resumption_handle, None);
    }

    #[test]
    fn started_is_emitted_only_after_the_provider_confirms_setup() {
        let mut translator = LiveEventTranslator::new("live-1".to_owned());
        // Events that arrive before setupComplete must never surface Started.
        let (signal, terminal) = translator.translate(RealtimeVoiceEvent::Error {
            message: "connect failed".to_owned(),
            resumption_handle: None,
        });
        assert!(terminal);
        assert!(matches!(
            signal,
            NativeEvent::LiveVoiceState(LiveVoiceState {
                state: LiveVoicePhase::Failed,
                ..
            })
        ));

        let mut translator = LiveEventTranslator::new("live-1".to_owned());
        let (signal, terminal) = translator.translate(RealtimeVoiceEvent::Started);
        assert!(!terminal);
        assert!(matches!(
            signal,
            NativeEvent::LiveVoiceState(LiveVoiceState {
                state: LiveVoicePhase::Started,
                ..
            })
        ));
    }

    #[test]
    fn transcripts_and_failures_carry_speaker_and_resumption_metadata() {
        let mut translator = LiveEventTranslator::new("live-1".to_owned());
        let (signal, _) = translator.translate(RealtimeVoiceEvent::TranscriptDelta {
            text: "assistant reply".to_owned(),
            final_segment: true,
            assistant: true,
        });
        assert!(matches!(
            signal,
            NativeEvent::LiveVoiceTranscript(LiveVoiceTranscript {
                assistant: true,
                final_segment: true,
                ..
            })
        ));
        let (signal, terminal) = translator.translate(RealtimeVoiceEvent::Error {
            message: "network".to_owned(),
            resumption_handle: Some("handle-2".to_owned()),
        });
        assert!(terminal);
        match signal {
            NativeEvent::LiveVoiceState(state) => {
                assert!(matches!(state.state, LiveVoicePhase::Failed));
                assert_eq!(state.resumption_handle.as_deref(), Some("handle-2"));
            }
            other => panic!("unexpected signal: {other:?}"),
        }
    }
}
