use crate::live_voice::{
    GeminiLiveProvider, RealtimeVoiceEvent, RealtimeVoiceHandle, RealtimeVoiceProvider,
    RealtimeVoiceSession, validate_session,
};
use crate::signals::{
    AudioChunk, AudioEncoding, LiveVoiceAudio, LiveVoicePhase, LiveVoiceState, LiveVoiceTranscript,
    NativeError, NativeEvent, ToolProgress, ToolStatus, TranscriptionAuth, TranscriptionRoute,
    TranscriptionState, TranscriptionStatus, TranscriptionStopAcknowledgement,
};
use crate::stt::{self, SttConfig, SttHandle};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const COMMAND_QUEUE_CAPACITY: usize = 32;
const AUDIO_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
const MAX_ACTIVE_LIVE_SESSIONS: usize = 2;
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

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
    Fence,
}

#[derive(Default)]
pub(crate) struct AudioSessions(pub(crate) HashMap<String, AudioSession>);

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

#[derive(Default)]
pub(crate) struct LiveSessions(Arc<Mutex<HashMap<String, LiveSession>>>);

impl LiveSessions {
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
        };
        if let Err(message) = validate_session(&session) {
            return Err(AudioAcceptError {
                request_id: start.request_id,
                code: "live_voice_start_invalid",
                message,
            });
        }
        let mut sessions = self.0.lock().unwrap_or_else(|poison| poison.into_inner());
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
                Arc::clone(&self.0),
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
        let mut sessions = self.0.lock().unwrap_or_else(|poison| poison.into_inner());
        match sessions.remove(stream_id) {
            Some(session) => {
                session.handle.cancel();
                true
            }
            None => false,
        }
    }

    pub(crate) fn cancel_all(&mut self) {
        let drained: Vec<_> = self
            .0
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

    pub(crate) fn contains(&self, stream_id: &str) -> bool {
        self.0
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .contains_key(stream_id)
    }

    pub(crate) fn accept(&mut self, chunk: AudioChunk) -> Result<(), AudioAcceptError> {
        let mut sessions = self.0.lock().unwrap_or_else(|poison| poison.into_inner());
        let session = sessions
            .get_mut(&chunk.request_id)
            .ok_or_else(|| AudioAcceptError {
                request_id: chunk.request_id.clone(),
                code: "live_voice_not_started",
                message: "live voice stream must be started before sending audio".to_owned(),
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
            return Ok(());
        }
        session
            .handle
            .send_audio(&chunk.bytes)
            .map_err(|message| AudioAcceptError {
                request_id: chunk.request_id,
                code: "live_voice_provider_unavailable",
                message,
            })
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
) {
    let remove_session = |live_stream_id: &str| {
        sessions
            .lock()
            .unwrap_or_else(|poison| poison.into_inner())
            .remove(live_stream_id);
    };
    let mut translator = LiveEventTranslator::new(live_stream_id.clone());
    while let Some(event) = events.recv().await {
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
                    Some(TranscriptionControl::Fence) => {
                        self.sessions.cancel_all();
                        self.live.cancel_all();
                    }
                    None if self.receiver.is_closed() => break,
                    None => {}
                },
                chunk = self.receiver.recv() => match chunk {
                    Some(chunk) if self.live.contains(&chunk.request_id) => {
                        if let Err(failure) = self.live.accept(chunk) {
                            NativeEvent::Error(NativeError {
                                request_id: Some(failure.request_id),
                                code: failure.code.to_owned(),
                                message: failure.message,
                                retryable: false,
                            })
                            .send();
                        }
                    }
                    Some(chunk) => match self.sessions.accept(chunk) {
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
                    None if self.controls.is_closed() => break,
                    None => {}
                }
            }
        }
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
        if let Some(existing) = self.0.get(&start.audio_stream_id) {
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
        if self.0.len() >= MAX_ACTIVE_AUDIO_SESSIONS {
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
        self.0.insert(
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
        if let Some(mut session) = self.0.remove(stream_id) {
            session.phase = TranscriptionPhase::Draining;
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
        for (stream_id, session) in self.0.drain() {
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
        self.0.retain(|_, session| {
            now.saturating_duration_since(session.last_seen) < AUDIO_SESSION_IDLE_TIMEOUT
        });
        if !self.0.contains_key(&chunk.request_id) {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "transcription_not_started",
                message: "audio stream must be started before sending audio".to_owned(),
            });
        }
        let session = self
            .0
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
        if !chunk.end_of_stream
            && let Some(provider) = &session.provider
        {
            provider
                .send_audio(&chunk.bytes)
                .map_err(|failure| AudioAcceptError {
                    request_id: chunk.request_id.clone(),
                    code: "transcription_provider_unavailable",
                    message: failure.to_string(),
                })?;
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
            self.0.remove(&stream_id);
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
        }
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
