use crate::signals::{
    AudioChunk, AudioEncoding, NativeError, NativeEvent, ToolProgress, ToolStatus, TranscriptDelta,
    TranscriptGap, TranscriptionAuth, TranscriptionRoute, TranscriptionState, TranscriptionStatus,
    TranscriptionStopAcknowledgement,
};
use crate::stt::{self, SttConfig, SttHandle};
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const COMMAND_QUEUE_CAPACITY: usize = 32;
const AUDIO_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_RECONNECT_BUFFER_BYTES: usize = 64 * 1024;

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
    pub(crate) logical_sequence: u64,
    pub(crate) phase: TranscriptionPhase,
    pub(crate) reconnect_buffer: VecDeque<Vec<u8>>,
    pub(crate) reconnect_buffer_bytes: usize,
    pub(crate) provider: Option<SttHandle>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum TranscriptionPhase {
    Streaming,
    Reconnecting,
    Draining,
}

#[allow(dead_code)]
pub(crate) trait LiveSttProvider: Send {
    fn start(&mut self, stream_id: &str) -> Result<(), String>;
    fn send_audio(&mut self, bytes: &[u8]) -> Result<(), String>;
    fn finish(&mut self) -> Result<(), String>;
    fn cancel(&mut self);
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

pub(crate) struct ProviderTranscript {
    pub(crate) provider: String,
    pub(crate) start_ms: i64,
    pub(crate) end_ms: i64,
    pub(crate) text: String,
    pub(crate) final_segment: bool,
}

pub(crate) enum TranscriptionControl {
    Start(StartTranscription),
    Stop {
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

pub struct AudioDispatcher {
    receiver: mpsc::Receiver<AudioChunk>,
    controls: mpsc::Receiver<TranscriptionControl>,
    sessions: AudioSessions,
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
                    Some(TranscriptionControl::Fence) => self.sessions.cancel_all(),
                    None if self.receiver.is_closed() => break,
                    None => {}
                },
                chunk = self.receiver.recv() => match chunk {
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
    #[allow(dead_code)]
    pub(crate) fn provider_disconnected(
        &mut self,
        request_id: &str,
        stream_id: &str,
        gap_start_ms: i64,
        gap_end_ms: i64,
    ) -> Result<TranscriptGap, AudioAcceptError> {
        let session = self.0.get_mut(stream_id).ok_or_else(|| AudioAcceptError {
            request_id: request_id.to_owned(),
            code: "transcription_not_started",
            message: "audio stream was not started".to_owned(),
        })?;
        let previous_epoch = session.epoch;
        session.epoch = session
            .epoch
            .checked_add(1)
            .ok_or_else(|| AudioAcceptError {
                request_id: request_id.to_owned(),
                code: "audio_counter_overflow",
                message: "transcription epoch overflowed".to_owned(),
            })?;
        session.phase = TranscriptionPhase::Reconnecting;
        session.reconnect_buffer.clear();
        session.reconnect_buffer_bytes = 0;
        let gap = TranscriptGap {
            request_id: request_id.to_owned(),
            audio_stream_id: stream_id.to_owned(),
            stt_epoch: previous_epoch,
            start_ms: gap_start_ms,
            end_ms: gap_end_ms,
            reason: "provider connection lost; sent audio was not replayed".to_owned(),
        };
        NativeEvent::TranscriptGap(TranscriptGap {
            request_id: gap.request_id.clone(),
            audio_stream_id: gap.audio_stream_id.clone(),
            stt_epoch: gap.stt_epoch,
            start_ms: gap.start_ms,
            end_ms: gap.end_ms,
            reason: gap.reason.clone(),
        })
        .send();
        NativeEvent::TranscriptionStatus(TranscriptionStatus {
            request_id: request_id.to_owned(),
            audio_stream_id: stream_id.to_owned(),
            state: TranscriptionState::Reconnecting,
            stt_epoch: session.epoch,
        })
        .send();
        Ok(gap)
    }

    #[allow(dead_code)]
    pub(crate) fn provider_reconnected(
        &mut self,
        request_id: &str,
        stream_id: &str,
    ) -> Result<Vec<Vec<u8>>, AudioAcceptError> {
        let session = self.0.get_mut(stream_id).ok_or_else(|| AudioAcceptError {
            request_id: request_id.to_owned(),
            code: "transcription_not_started",
            message: "audio stream was not started".to_owned(),
        })?;
        if session.phase != TranscriptionPhase::Reconnecting {
            return Err(AudioAcceptError {
                request_id: request_id.to_owned(),
                code: "transcription_not_reconnecting",
                message: "audio stream is not reconnecting".to_owned(),
            });
        }
        session.phase = TranscriptionPhase::Streaming;
        session.reconnect_buffer_bytes = 0;
        Ok(session.reconnect_buffer.drain(..).collect())
    }

    #[allow(dead_code)]
    pub(crate) fn transcript(
        &mut self,
        request_id: &str,
        stream_id: &str,
        event: ProviderTranscript,
    ) -> Result<TranscriptDelta, AudioAcceptError> {
        let session = self.0.get_mut(stream_id).ok_or_else(|| AudioAcceptError {
            request_id: request_id.to_owned(),
            code: "transcription_not_started",
            message: "audio stream was not started".to_owned(),
        })?;
        let sequence = session.logical_sequence;
        let delta = TranscriptDelta {
            request_id: request_id.to_owned(),
            audio_stream_id: stream_id.to_owned(),
            segment_id: format!("{stream_id}:segment:{sequence}"),
            segment_sequence: sequence,
            stt_epoch: session.epoch,
            device_id: session.device_id.clone(),
            provider: event.provider,
            start_ms: event.start_ms,
            end_ms: event.end_ms,
            occurred_at_ms: event.end_ms,
            text: event.text,
            final_segment: event.final_segment,
            language: Some(session.language.clone()),
        };
        if event.final_segment {
            session.logical_sequence = session.logical_sequence.saturating_add(1);
        }
        Ok(delta)
    }

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
                logical_sequence: 0,
                phase: TranscriptionPhase::Streaming,
                reconnect_buffer: VecDeque::new(),
                reconnect_buffer_bytes: 0,
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
        let reconnect_buffer_bytes =
            if session.phase == TranscriptionPhase::Reconnecting && !chunk.end_of_stream {
                let buffered = session
                    .reconnect_buffer_bytes
                    .checked_add(chunk.bytes.len())
                    .ok_or_else(|| AudioAcceptError {
                        request_id: chunk.request_id.clone(),
                        code: "audio_counter_overflow",
                        message: "reconnect buffer size overflowed".to_owned(),
                    })?;
                if buffered > MAX_RECONNECT_BUFFER_BYTES {
                    return Err(AudioAcceptError {
                        request_id: chunk.request_id,
                        code: "transcription_reconnect_buffer_full",
                        message: "transcription reconnect buffer is full".to_owned(),
                    });
                }
                Some(buffered)
            } else {
                None
            };
        session.next_sequence = next_sequence;
        session.accepted_bytes = accepted_bytes;
        session.last_seen = now;
        if let Some(buffered) = reconnect_buffer_bytes {
            session.reconnect_buffer.push_back(chunk.bytes.clone());
            session.reconnect_buffer_bytes = buffered;
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
