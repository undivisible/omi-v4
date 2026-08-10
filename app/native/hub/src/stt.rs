#![cfg_attr(test, allow(dead_code))]

use crate::signals::{AudioEncoding, TranscriptDelta, TranscriptGap, TranscriptionAuth};
use crate::signals::{NativeError, NativeEvent, TranscriptionState, TranscriptionStatus};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use std::collections::VecDeque;
use std::fmt;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::net::TcpStream;
use tokio::sync::mpsc;
use tokio_tungstenite::{
    MaybeTlsStream, WebSocketStream, connect_async,
    tungstenite::{
        client::IntoClientRequest,
        http::{HeaderValue, header::AUTHORIZATION},
        protocol::Message,
    },
};
use url::Url;

const XAI_HOST: &str = "api.x.ai";
const XAI_PATH: &str = "/v1/stt";
const MAX_CREDENTIAL_BYTES: usize = 16 * 1024;
const MAX_PENDING_AUDIO_BYTES: usize = 64 * 1024;
const AUDIO_CHANNEL_CAPACITY: usize = 64;
const MAX_RECONNECT_BUFFER_BYTES: usize = 64 * 1024;
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);
pub(crate) const FINAL_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum SttError {
    Unavailable,
    InvalidEndpoint,
    InvalidCredential,
    UnsupportedAudio,
    ConnectionFailed,
}

impl fmt::Display for SttError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unavailable => "local transcription is unavailable",
            Self::InvalidEndpoint => "transcription endpoint is invalid",
            Self::InvalidCredential => "transcription credential is invalid",
            Self::UnsupportedAudio => "transcription audio format is unsupported",
            Self::ConnectionFailed => "transcription provider connection failed",
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct SttConfig {
    pub request_id: String,
    pub audio_stream_id: String,
    pub device_id: String,
    pub language: String,
    pub sample_rate_hz: u32,
    pub channels: u8,
    pub encoding: AudioEncoding,
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct ConnectionPlan {
    endpoint: Url,
    authorization: String,
    provider: &'static str,
    reconnectable: bool,
}

impl ConnectionPlan {
    pub(crate) fn from_auth(
        auth: &TranscriptionAuth,
        config: &SttConfig,
        trusted_worker_origin: Option<&str>,
    ) -> Result<Self, SttError> {
        let encoding = xai_encoding(config)?;
        match auth {
            TranscriptionAuth::Managed {
                endpoint,
                firebase_token,
            } => {
                valid_credential(firebase_token)?;
                let endpoint = managed_endpoint(endpoint, trusted_worker_origin)?;
                Ok(Self {
                    endpoint,
                    authorization: format!("Bearer {firebase_token}"),
                    provider: "xai-managed",
                    reconnectable: false,
                })
            }
            TranscriptionAuth::Byok { endpoint, api_key } => {
                valid_credential(api_key)?;
                let mut endpoint = byok_endpoint(endpoint)?;
                for (key, value) in [
                    ("encoding", encoding.to_owned()),
                    ("sample_rate", config.sample_rate_hz.to_string()),
                    ("channels", config.channels.to_string()),
                    ("interim_results", "true".to_owned()),
                    ("diarize", "true".to_owned()),
                ] {
                    endpoint.query_pairs_mut().append_pair(key, &value);
                }
                if config.language != "multi" {
                    endpoint
                        .query_pairs_mut()
                        .append_pair("language", &config.language);
                }
                Ok(Self {
                    endpoint,
                    authorization: format!("Token {api_key}"),
                    provider: "xai-byok",
                    reconnectable: true,
                })
            }
            TranscriptionAuth::Local => Err(SttError::Unavailable),
        }
    }

    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn provider(&self) -> &'static str {
        self.provider
    }
}

fn xai_encoding(config: &SttConfig) -> Result<&'static str, SttError> {
    match config.encoding {
        AudioEncoding::PcmS16Le | AudioEncoding::PcmU8
            if matches!(config.sample_rate_hz, 8_000 | 16_000 | 48_000)
                && matches!(config.channels, 1 | 2) =>
        {
            Ok("pcm")
        }
        _ => Err(SttError::UnsupportedAudio),
    }
}

fn valid_credential(value: &str) -> Result<(), SttError> {
    if value.is_empty()
        || value.len() > MAX_CREDENTIAL_BYTES
        || value.bytes().any(|byte| byte.is_ascii_control())
    {
        return Err(SttError::InvalidCredential);
    }
    Ok(())
}

fn managed_endpoint(value: &str, trusted_origin: Option<&str>) -> Result<Url, SttError> {
    let endpoint = Url::parse(value).map_err(|_| SttError::InvalidEndpoint)?;
    let origin = Url::parse(trusted_origin.ok_or(SttError::InvalidEndpoint)?)
        .map_err(|_| SttError::InvalidEndpoint)?;
    let segments = endpoint
        .path_segments()
        .map(|items| items.collect::<Vec<_>>())
        .ok_or(SttError::InvalidEndpoint)?;
    let session_valid = segments.len() == 5
        && segments[0] == "v1"
        && segments[1] == "stt"
        && segments[2] == "sessions"
        && segments[3].len() == 64
        && segments[3].bytes().all(|byte| byte.is_ascii_hexdigit())
        && segments[4] == "stream";
    if endpoint.scheme() != "wss"
        || origin.scheme() != "https"
        || endpoint.host_str() != origin.host_str()
        || endpoint.port_or_known_default() != origin.port_or_known_default()
        || endpoint.username() != ""
        || endpoint.password().is_some()
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
        || !session_valid
    {
        return Err(SttError::InvalidEndpoint);
    }
    Ok(endpoint)
}

fn byok_endpoint(value: &str) -> Result<Url, SttError> {
    let endpoint = Url::parse(value).map_err(|_| SttError::InvalidEndpoint)?;
    if endpoint.scheme() != "wss"
        || endpoint.host_str() != Some(XAI_HOST)
        || endpoint.port_or_known_default() != Some(443)
        || endpoint.path() != XAI_PATH
        || endpoint.username() != ""
        || endpoint.password().is_some()
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
    {
        return Err(SttError::InvalidEndpoint);
    }
    Ok(endpoint)
}

#[cfg_attr(test, allow(dead_code))]
pub(crate) async fn connect(
    plan: &ConnectionPlan,
) -> Result<WebSocketStream<MaybeTlsStream<TcpStream>>, SttError> {
    let mut request = plan
        .endpoint
        .as_str()
        .into_client_request()
        .map_err(|_| SttError::InvalidEndpoint)?;
    let authorization =
        HeaderValue::from_str(&plan.authorization).map_err(|_| SttError::InvalidCredential)?;
    request.headers_mut().insert(AUTHORIZATION, authorization);
    let (socket, _) = tokio::time::timeout(CONNECT_TIMEOUT, connect_async(request))
        .await
        .map_err(|_| SttError::ConnectionFailed)?
        .map_err(|_| SttError::ConnectionFailed)?;
    Ok(socket)
}

pub(crate) struct SttHandle {
    audio_sender: Option<mpsc::Sender<Vec<u8>>>,
    control_sender: Option<mpsc::Sender<SttControl>>,
    pending_audio_bytes: Arc<AtomicUsize>,
}

#[cfg_attr(test, allow(dead_code))]
enum SttControl {
    Finish,
    Cancel,
}

impl SttHandle {
    pub(crate) fn send_audio(&self, bytes: &[u8]) -> Result<(), SttError> {
        self.send_audio_owned(bytes.to_vec())
    }

    pub(crate) fn send_audio_owned(&self, bytes: Vec<u8>) -> Result<(), SttError> {
        let Some(sender) = &self.audio_sender else {
            return Ok(());
        };
        let byte_len = bytes.len();
        let mut current = self.pending_audio_bytes.load(Ordering::Acquire);
        loop {
            let next = current
                .checked_add(byte_len)
                .filter(|value| *value <= MAX_PENDING_AUDIO_BYTES)
                .ok_or(SttError::ConnectionFailed)?;
            match self.pending_audio_bytes.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(observed) => current = observed,
            }
        }
        let result = sender.try_send(bytes).map_err(|_| SttError::ConnectionFailed);
        if result.is_err() {
            self.pending_audio_bytes
                .fetch_sub(byte_len, Ordering::AcqRel);
        }
        result
    }

    pub(crate) fn finish(&self) {
        if let Some(sender) = &self.control_sender {
            let _ = sender.try_send(SttControl::Finish);
        }
    }

    pub(crate) fn cancel(&self) {
        if let Some(sender) = &self.control_sender {
            let _ = sender.try_send(SttControl::Cancel);
        }
    }
}

#[cfg(not(test))]
pub(crate) fn spawn(
    config: SttConfig,
    auth: &TranscriptionAuth,
    trusted_worker_origin: Option<&str>,
) -> Result<SttHandle, SttError> {
    let plan = ConnectionPlan::from_auth(auth, &config, trusted_worker_origin)?;
    let (audio_sender, audio_receiver) = mpsc::channel(AUDIO_CHANNEL_CAPACITY);
    let (control_sender, control_receiver) = mpsc::channel(AUDIO_CHANNEL_CAPACITY);
    let pending_audio_bytes = Arc::new(AtomicUsize::new(0));
    tokio::spawn(run(
        config,
        plan,
        audio_receiver,
        control_receiver,
        Arc::clone(&pending_audio_bytes),
    ));
    Ok(SttHandle {
        audio_sender: Some(audio_sender),
        control_sender: Some(control_sender),
        pending_audio_bytes,
    })
}

#[cfg(test)]
pub(crate) fn spawn(
    _config: SttConfig,
    _auth: &TranscriptionAuth,
    _trusted_worker_origin: Option<&str>,
) -> Result<SttHandle, SttError> {
    Ok(SttHandle {
        audio_sender: None,
        control_sender: None,
        pending_audio_bytes: Arc::new(AtomicUsize::new(0)),
    })
}

#[derive(Default)]
struct ReconnectAudioBuffer {
    frames: VecDeque<Vec<u8>>,
    bytes: usize,
}

impl ReconnectAudioBuffer {
    fn stash(&mut self, frame: Vec<u8>, pending_audio_bytes: &AtomicUsize) {
        let len = frame.len();
        while self.bytes.saturating_add(len) > MAX_RECONNECT_BUFFER_BYTES && !self.frames.is_empty()
        {
            if let Some(old) = self.frames.front() {
                self.bytes -= old.len();
                self.frames.pop_front();
            }
        }
        if self.bytes.saturating_add(len) <= MAX_RECONNECT_BUFFER_BYTES {
            self.bytes += len;
            self.frames.push(frame);
        }
        pending_audio_bytes.fetch_sub(len, Ordering::AcqRel);
    }

    async fn flush(
        &mut self,
        socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
        config: &SttConfig,
        epoch: u32,
    ) -> bool {
        while let Some(bytes) = self.frames.pop_front() {
            self.bytes -= bytes.len();
            crate::speech_recognition::observe_stream_audio(config, epoch, &bytes);
            let encoded = encode_audio(bytes, config.encoding);
            if socket.send(Message::Binary(encoded.into())).await.is_err() {
                return false;
            }
        }
        true
    }
}

#[cfg_attr(test, allow(dead_code))]
async fn run(
    config: SttConfig,
    plan: ConnectionPlan,
    mut audio_receiver: mpsc::Receiver<Vec<u8>>,
    mut control_receiver: mpsc::Receiver<SttControl>,
    pending_audio_bytes: Arc<AtomicUsize>,
) {
    let connection = connect(&plan);
    tokio::pin!(connection);
    let mut socket = tokio::select! {
        biased;
        control = control_receiver.recv() => {
            match control {
                Some(SttControl::Finish) => {
                    terminal_status(&config, TranscriptionState::Finished, 0);
                }
                Some(SttControl::Cancel) | None => {
                    terminal_status(&config, TranscriptionState::Cancelled, 0);
                }
            }
            return;
        }
        result = &mut connection => match result {
            Ok(socket) => socket,
            Err(error) => {
                terminal_error(
                    &config,
                    "transcription_connect_failed",
                    &error.to_string(),
                    0,
                );
                return;
            }
        }
    };
    let mut state = TranscriptState::new(config.clone(), plan.provider());
    NativeEvent::TranscriptionStatus(TranscriptionStatus {
        request_id: config.request_id.clone(),
        audio_stream_id: config.audio_stream_id.clone(),
        state: TranscriptionState::Started,
        stt_epoch: 0,
    })
    .send();
    let mut reconnect_buffer = ReconnectAudioBuffer::default();
    loop {
        tokio::select! {
            biased;
            control = control_receiver.recv() => match control {
                Some(SttControl::Finish) => {
                    while let Ok(bytes) = audio_receiver.try_recv() {
                        pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
                        crate::speech_recognition::observe_stream_audio(&config, state.epoch, &bytes);
                        let encoded = encode_audio(bytes, config.encoding);
                        if socket.send(Message::Binary(encoded.into())).await.is_err() {
                            terminal_error(
                                &config,
                                "transcription_connection_lost",
                                "transcription provider connection was lost while draining audio",
                                state.epoch,
                            );
                            return;
                        }
                    }
                    if socket.send(Message::Text(r#"{"type":"audio.done"}"#.into())).await.is_err() {
                        let now = unix_time_ms();
                        NativeEvent::TranscriptGap(state.reconnect_gap(now, now)).send();
                        terminal_error(
                            &config,
                            "transcription_finalize_failed",
                            "transcription provider rejected finalization",
                            state.epoch,
                        );
                        return;
                    }
                    drain_final_results(&config, &mut socket, &mut state).await;
                    return;
                }
                Some(SttControl::Cancel) | None => {
                    let _ = socket.close(None).await;
                    terminal_status(&config, TranscriptionState::Cancelled, state.epoch);
                    return;
                }
            },
            command = audio_receiver.recv() => if let Some(bytes) = command {
                    pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
                    crate::speech_recognition::observe_stream_audio(&config, state.epoch, &bytes);
                    let encoded = encode_audio(bytes, config.encoding);
                    if socket.send(Message::Binary(encoded.into())).await.is_err() {
                        let now = unix_time_ms();
                        NativeEvent::TranscriptGap(state.reconnect_gap(now, now)).send();
                        terminal_error(
                            &config,
                            "transcription_connection_lost",
                            "transcription provider connection was lost",
                            state.epoch,
                        );
                        return;
                    }
            },
            message = socket.next() => match message {
                Some(Ok(Message::Text(text))) => {
                    if let Some(parsed) = state.parse_delta(text.as_ref(), unix_time_ms()) {
                        let delta = parsed.delta;
                        if delta.final_segment
                            && config.request_id == crate::meeting_capture::CAPTURE_STREAM_ID
                        {
                            crate::meeting::observe_final_segment(
                                &delta.text,
                                diarization_key(&delta),
                                segment_audio(&delta, parsed.word_derived),
                            );
                        }
                        NativeEvent::TranscriptDelta(delta).send();
                    }
                }
                Some(Ok(Message::Close(_))) | None => match recover(
                    &config,
                    &plan,
                    &mut state,
                    &mut audio_receiver,
                    &mut control_receiver,
                    &pending_audio_bytes,
                    &mut reconnect_buffer,
                ).await {
                    Some(reconnected) => {
                        socket = reconnected;
                        if !reconnect_buffer.flush(&mut socket, &config, state.epoch).await {
                            let now = unix_time_ms();
                            NativeEvent::TranscriptGap(state.reconnect_gap(now, now)).send();
                            terminal_error(
                                &config,
                                "transcription_connection_lost",
                                "transcription provider connection was lost while replaying buffered audio",
                                state.epoch,
                            );
                            return;
                        }
                    }
                    None => return,
                },
                Some(Err(_)) => match recover(
                    &config,
                    &plan,
                    &mut state,
                    &mut audio_receiver,
                    &mut control_receiver,
                    &pending_audio_bytes,
                    &mut reconnect_buffer,
                ).await {
                    Some(reconnected) => {
                        socket = reconnected;
                        if !reconnect_buffer.flush(&mut socket, &config, state.epoch).await {
                            let now = unix_time_ms();
                            NativeEvent::TranscriptGap(state.reconnect_gap(now, now)).send();
                            terminal_error(
                                &config,
                                "transcription_connection_lost",
                                "transcription provider connection was lost while replaying buffered audio",
                                state.epoch,
                            );
                            return;
                        }
                    }
                    None => return,
                },
                Some(Ok(_)) => {}
            }
        }
    }
}

async fn drain_final_results(
    config: &SttConfig,
    socket: &mut WebSocketStream<MaybeTlsStream<TcpStream>>,
    state: &mut TranscriptState,
) {
    let drain = async {
        while let Some(message) = socket.next().await {
            match message {
                Ok(Message::Text(text)) => {
                    if let Some(parsed) = state.parse_delta(text.as_ref(), unix_time_ms()) {
                        let delta = parsed.delta;
                        if delta.final_segment
                            && config.request_id == crate::meeting_capture::CAPTURE_STREAM_ID
                        {
                            crate::meeting::observe_final_segment(
                                &delta.text,
                                diarization_key(&delta),
                                segment_audio(&delta, parsed.word_derived),
                            );
                        }
                        NativeEvent::TranscriptDelta(delta).send();
                    }
                }
                Ok(Message::Close(_)) | Err(_) => break,
                _ => {}
            }
        }
    };
    let _ = tokio::time::timeout(FINAL_DRAIN_TIMEOUT, drain).await;
    let _ = socket.close(None).await;
    terminal_status(config, TranscriptionState::Finished, state.epoch);
}

async fn recover(
    config: &SttConfig,
    plan: &ConnectionPlan,
    state: &mut TranscriptState,
    audio_receiver: &mut mpsc::Receiver<Vec<u8>>,
    control_receiver: &mut mpsc::Receiver<SttControl>,
    pending_audio_bytes: &AtomicUsize,
    reconnect_buffer: &mut ReconnectAudioBuffer,
) -> Option<WebSocketStream<MaybeTlsStream<TcpStream>>> {
    let disconnected_at = unix_time_ms();
    if !plan.reconnectable {
        NativeEvent::TranscriptGap(state.reconnect_gap(disconnected_at, disconnected_at)).send();
        terminal_error(
            config,
            "transcription_managed_session_lost",
            "managed transcription session was lost and cannot be reused",
            state.epoch,
        );
        return None;
    }
    NativeEvent::TranscriptionStatus(TranscriptionStatus {
        request_id: config.request_id.clone(),
        audio_stream_id: config.audio_stream_id.clone(),
        state: TranscriptionState::Reconnecting,
        stt_epoch: state.epoch.saturating_add(1),
    })
    .send();
    for delay_ms in [250, 500, 1_000] {
        recovery_delay(
            config,
            state,
            audio_receiver,
            control_receiver,
            pending_audio_bytes,
            reconnect_buffer,
            delay_ms,
        )
        .await?;
        let connection = connect(plan);
        tokio::pin!(connection);
        let socket = loop {
            tokio::select! {
                biased;
                control = control_receiver.recv() => {
                    finish_during_recovery(config, state, control);
                    return None;
                }
                audio = audio_receiver.recv() => {
                    if let Some(bytes) = audio {
                        reconnect_buffer.stash(bytes, pending_audio_bytes);
                    }
                }
                result = &mut connection => break result.ok(),
            }
        };
        if let Some(socket) = socket {
            NativeEvent::TranscriptGap(state.reconnect_gap(disconnected_at, unix_time_ms())).send();
            NativeEvent::TranscriptionStatus(TranscriptionStatus {
                request_id: config.request_id.clone(),
                audio_stream_id: config.audio_stream_id.clone(),
                state: TranscriptionState::Started,
                stt_epoch: state.epoch,
            })
            .send();
            return Some(socket);
        }
    }
    NativeEvent::TranscriptGap(state.reconnect_gap(disconnected_at, unix_time_ms())).send();
    terminal_error(
        config,
        "transcription_connection_lost",
        "transcription provider connection was lost",
        state.epoch,
    );
    None
}

async fn recovery_delay(
    config: &SttConfig,
    state: &mut TranscriptState,
    audio_receiver: &mut mpsc::Receiver<Vec<u8>>,
    control_receiver: &mut mpsc::Receiver<SttControl>,
    pending_audio_bytes: &AtomicUsize,
    reconnect_buffer: &mut ReconnectAudioBuffer,
    delay_ms: u64,
) -> Option<()> {
    let delay = tokio::time::sleep(std::time::Duration::from_millis(delay_ms));
    tokio::pin!(delay);
    loop {
        tokio::select! {
            biased;
            control = control_receiver.recv() => {
                finish_during_recovery(config, state, control);
                return None;
            }
            audio = audio_receiver.recv() => {
                if let Some(bytes) = audio {
                    reconnect_buffer.stash(bytes, pending_audio_bytes);
                }
            }
            () = &mut delay => return Some(()),
        }
    }
}

fn finish_during_recovery(
    config: &SttConfig,
    state: &mut TranscriptState,
    control: Option<SttControl>,
) {
    match control {
        Some(SttControl::Cancel) | None => {
            terminal_status(config, TranscriptionState::Cancelled, state.epoch);
        }
        Some(SttControl::Finish) => {
            let now = unix_time_ms();
            NativeEvent::TranscriptGap(state.reconnect_gap(now, now)).send();
            terminal_error(
                config,
                "transcription_connection_lost",
                "transcription provider connection was lost before finalization",
                state.epoch,
            );
        }
    }
}

#[cfg_attr(test, allow(dead_code))]
fn terminal_status(config: &SttConfig, state: TranscriptionState, epoch: u32) {
    NativeEvent::TranscriptionStatus(TranscriptionStatus {
        request_id: config.request_id.clone(),
        audio_stream_id: config.audio_stream_id.clone(),
        state,
        stt_epoch: epoch,
    })
    .send();
}

#[cfg_attr(test, allow(dead_code))]
fn terminal_error(config: &SttConfig, code: &str, message: &str, epoch: u32) {
    NativeEvent::Error(NativeError {
        request_id: Some(config.request_id.clone()),
        code: code.to_owned(),
        message: message.to_owned(),
        retryable: true,
    })
    .send();
    terminal_status(config, TranscriptionState::Failed, epoch);
}

fn encode_audio(bytes: Vec<u8>, encoding: AudioEncoding) -> Vec<u8> {
    if encoding != AudioEncoding::PcmU8 {
        return bytes;
    }
    let mut output = Vec::with_capacity(bytes.len().saturating_mul(2));
    for sample in bytes {
        output.extend_from_slice(&((i16::from(*sample) - 128) << 8).to_le_bytes());
    }
    output
}

#[cfg_attr(test, allow(dead_code))]
fn unix_time_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |duration| {
            i64::try_from(duration.as_millis()).unwrap_or(i64::MAX)
        })
}

#[derive(Deserialize)]
struct SttResponse {
    #[serde(rename = "type")]
    event_type: Option<String>,
    #[serde(default)]
    is_final: bool,
    #[serde(default)]
    speech_final: bool,
    channel: Option<ProviderChannel>,
    #[serde(default)]
    text: String,
    #[serde(default)]
    words: Vec<ProviderWord>,
    /// `[channel, channel_count]` on a streaming result. Only the first entry
    /// identifies the channel these words came from.
    #[serde(default)]
    channel_index: Vec<u32>,
}

#[derive(Deserialize)]
struct ProviderChannel {
    #[serde(default)]
    alternatives: Vec<ProviderAlternative>,
}

#[derive(Deserialize)]
struct ProviderAlternative {
    #[serde(default)]
    transcript: String,
    #[serde(default)]
    words: Vec<ProviderWord>,
    #[serde(default)]
    languages: Vec<String>,
}

#[derive(Deserialize)]
struct ProviderWord {
    start: f64,
    end: f64,
    /// The diarization index Deepgram assigns when `diarize=true` was
    /// requested. Absent on every response from a session that did not ask
    /// for diarization.
    #[serde(default)]
    speaker: Option<u32>,
}

/// The diarization index that spoke most of the words in a result.
///
/// Deepgram labels each word individually, so a segment that straddles a
/// speaker change carries two indices; the majority one describes the segment
/// as a whole, and ties keep the earliest speaker so the label stays stable
/// as an interim result grows.
fn dominant_speaker(words: &[ProviderWord]) -> Option<u32> {
    let mut tally: Vec<(u32, usize)> = Vec::new();
    for speaker in words.iter().filter_map(|word| word.speaker) {
        match tally.iter_mut().find(|(value, _)| *value == speaker) {
            Some((_, count)) => *count += 1,
            None => tally.push((speaker, 1)),
        }
    }
    tally
        .into_iter()
        .rev()
        .max_by_key(|(_, count)| *count)
        .map(|(speaker, _)| speaker)
}

/// The identity of the voice behind a segment, as the provider reports it.
///
/// Diarization indices are only unique within a channel, so the channel is
/// folded into the key. Everything the hub sends today is mono, which makes
/// the channel `0` and the key the bare speaker index.
pub(crate) fn diarization_key(delta: &TranscriptDelta) -> Option<u64> {
    let speaker = delta.speaker?;
    let channel = delta.channel_index.unwrap_or(0);
    Some(u64::from(channel) << 32 | u64::from(speaker))
}

/// One parsed provider response, with the fact the delta itself cannot carry.
///
/// `word_derived` is false when the response had no word list, in which case
/// `start_ms` / `end_ms` fall back to a wall-clock `occurred_at_ms` — a value
/// on a different clock entirely from the audio buffer's, which is why it
/// travels separately rather than being inferred downstream.
/// The span of buffered capture audio a finalized segment was spoken in.
///
/// `None` whenever the span cannot be trusted to be on the stream clock, which
/// is the answer for every segment whose response carried no word list.
pub(crate) fn segment_audio(
    delta: &TranscriptDelta,
    word_derived: bool,
) -> Option<crate::speech_recognition::SegmentAudio> {
    let window = crate::speech_segments::stream_window(
        delta.stt_epoch,
        delta.start_ms,
        delta.end_ms,
        word_derived,
    )?;
    Some(crate::speech_recognition::SegmentAudio {
        window,
        segment_id: delta.segment_id.clone(),
    })
}

#[derive(Debug)]
pub(crate) struct ParsedDelta {
    pub(crate) delta: TranscriptDelta,
    pub(crate) word_derived: bool,
}

#[derive(Debug)]
pub(crate) struct TranscriptState {
    config: SttConfig,
    provider: String,
    epoch: u32,
    sequence: u64,
}

impl TranscriptState {
    pub(crate) fn new(config: SttConfig, provider: &str) -> Self {
        Self {
            config,
            provider: provider.to_owned(),
            epoch: 0,
            sequence: 0,
        }
    }

    #[cfg(test)]
    pub(crate) fn parse(&mut self, json: &str, occurred_at_ms: i64) -> Option<TranscriptDelta> {
        self.parse_delta(json, occurred_at_ms)
            .map(|parsed| parsed.delta)
    }

    /// The parse the live loop uses, which also reports whether the segment's
    /// offsets are on the provider's stream clock.
    pub(crate) fn parse_delta(&mut self, json: &str, occurred_at_ms: i64) -> Option<ParsedDelta> {
        let response: SttResponse = serde_json::from_str(json).ok()?;
        if response
            .event_type
            .as_deref()
            .is_some_and(|kind| kind != "transcript.partial")
        {
            return None;
        }
        let channel_index = response.channel_index.first().copied();
        let alternative = response
            .channel
            .and_then(|channel| channel.alternatives.into_iter().next())
            .unwrap_or(ProviderAlternative {
                transcript: response.text,
                words: response.words,
                languages: Vec::new(),
            });
        let text = alternative.transcript.trim();
        if text.is_empty() {
            return None;
        }
        let word_derived = !alternative.words.is_empty();
        let start_ms = alternative
            .words
            .first()
            .map_or(occurred_at_ms, |word| seconds_to_millis(word.start));
        let end_ms = alternative
            .words
            .last()
            .map_or(occurred_at_ms, |word| seconds_to_millis(word.end));
        let speaker = dominant_speaker(&alternative.words);
        let final_segment = response.is_final || response.speech_final;
        let sequence = self.sequence;
        if final_segment {
            self.sequence = self.sequence.saturating_add(1);
        }
        Some(ParsedDelta {
            word_derived,
            delta: TranscriptDelta {
                request_id: self.config.request_id.clone(),
                audio_stream_id: self.config.audio_stream_id.clone(),
                segment_id: format!(
                    "{}:epoch:{}:segment:{}",
                    self.config.audio_stream_id, self.epoch, sequence
                ),
                segment_sequence: sequence,
                stt_epoch: self.epoch,
                device_id: self.config.device_id.clone(),
                provider: self.provider.clone(),
                start_ms,
                end_ms,
                occurred_at_ms,
                text: text.to_owned(),
                final_segment,
                speaker,
                channel_index,
                language: alternative.languages.into_iter().next().or_else(|| {
                    (self.config.language != "multi").then(|| self.config.language.clone())
                }),
            },
        })
    }

    pub(crate) fn reconnect_gap(&mut self, start_ms: i64, end_ms: i64) -> TranscriptGap {
        let previous_epoch = self.epoch;
        self.epoch = self.epoch.saturating_add(1);
        TranscriptGap {
            request_id: self.config.request_id.clone(),
            audio_stream_id: self.config.audio_stream_id.clone(),
            stt_epoch: previous_epoch,
            start_ms,
            end_ms: end_ms.max(start_ms),
            reason: "provider connection lost; sent audio was not replayed".to_owned(),
        }
    }
}

fn seconds_to_millis(value: f64) -> i64 {
    if !value.is_finite() || value <= 0.0 {
        0
    } else if value >= i64::MAX as f64 / 1000.0 {
        i64::MAX
    } else {
        (value * 1000.0).round() as i64
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stashed_audio_is_replayed_oldest_first() {
        let pending = AtomicUsize::new(0);
        let mut buffer = ReconnectAudioBuffer::default();
        for value in 1_u8..=4 {
            pending.fetch_add(2, Ordering::AcqRel);
            buffer.stash(vec![value, value], &pending);
        }

        let replayed: Vec<Vec<u8>> =
            std::iter::from_fn(|| buffer.frames.pop_front()).collect();

        assert_eq!(
            replayed,
            vec![vec![1, 1], vec![2, 2], vec![3, 3], vec![4, 4]],
            "audio replayed after a reconnect must reach the provider in the \
             order it was spoken"
        );
    }

    fn config() -> SttConfig {
        SttConfig {
            request_id: "request-1".to_owned(),
            audio_stream_id: "stream-1".to_owned(),
            device_id: "omi-1".to_owned(),
            language: "multi".to_owned(),
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::PcmS16Le,
        }
    }

    #[test]
    fn managed_endpoint_is_pinned_to_the_trusted_worker() {
        let auth = TranscriptionAuth::Managed {
            endpoint: format!(
                "wss://api.omi.example/v1/stt/sessions/{}/stream",
                "a".repeat(64)
            ),
            firebase_token: "firebase-token".to_owned(),
        };
        let plan = ConnectionPlan::from_auth(&auth, &config(), Some("https://api.omi.example"));
        assert_eq!(
            plan.map(|value| (value.provider, value.reconnectable)),
            Ok(("xai-managed", false))
        );
        assert!(matches!(
            ConnectionPlan::from_auth(&auth, &config(), Some("https://evil.example")),
            Err(SttError::InvalidEndpoint)
        ));
    }

    #[test]
    fn byok_endpoint_is_exact_and_credentials_reject_controls() {
        let auth = TranscriptionAuth::Byok {
            endpoint: "wss://api.x.ai/v1/stt".to_owned(),
            api_key: "xai-secret".to_owned(),
        };
        let plan = ConnectionPlan::from_auth(&auth, &config(), None);
        assert_eq!(
            plan.as_ref()
                .map(|value| (value.provider, value.reconnectable)),
            Ok(("xai-byok", true))
        );
        assert_eq!(
            plan.map(|value| value
                .endpoint
                .query_pairs()
                .any(|(key, value)| key == "diarize" && value == "true")),
            Ok(true)
        );
        let injected = TranscriptionAuth::Byok {
            endpoint: "wss://api.x.ai/v1/stt".to_owned(),
            api_key: "secret\r\nleak".to_owned(),
        };
        assert!(matches!(
            ConnectionPlan::from_auth(&injected, &config(), None),
            Err(SttError::InvalidCredential)
        ));
    }

    #[test]
    fn local_route_is_typed_unavailable() {
        assert!(matches!(
            ConnectionPlan::from_auth(&TranscriptionAuth::Local, &config(), None),
            Err(SttError::Unavailable)
        ));
    }

    #[test]
    fn parser_generates_stable_segments_and_epochs() {
        let mut state = TranscriptState::new(config(), "xai-managed");
        let interim = state
            .parse(
                r#"{"is_final":false,"channel":{"alternatives":[{"transcript":" hello ","words":[{"start":1.25,"end":1.75}],"languages":["en"]}]}}"#,
                2_000,
            )
            .ok_or("missing interim");
        assert!(interim.is_ok());
        let interim = interim.unwrap_or_else(|_| unreachable!());
        assert_eq!(interim.segment_id, "stream-1:epoch:0:segment:0");
        assert_eq!(interim.start_ms, 1_250);
        assert!(!interim.final_segment);
        let final_delta = state
            .parse(
                r#"{"is_final":true,"channel":{"alternatives":[{"transcript":"hello","words":[{"start":1.25,"end":2.0}]}]}}"#,
                2_100,
            )
            .ok_or("missing final");
        assert!(final_delta.is_ok());
        let final_delta = final_delta.unwrap_or_else(|_| unreachable!());
        assert_eq!(final_delta.segment_sequence, 0);
        assert!(final_delta.final_segment);
        let gap = state.reconnect_gap(2_000, 2_400);
        assert_eq!(gap.stt_epoch, 0);
        let next = state
            .parse(
                r#"{"speech_final":true,"channel":{"alternatives":[{"transcript":"again","words":[]}]}}"#,
                3_000,
            )
            .ok_or("missing reconnect delta");
        assert!(next.is_ok());
        let next = next.unwrap_or_else(|_| unreachable!());
        assert_eq!(next.segment_id, "stream-1:epoch:1:segment:1");
    }

    #[test]
    fn parser_accepts_xai_streaming_events() {
        let mut state = TranscriptState::new(config(), "xai-byok");
        let delta = state
            .parse(
                r#"{"type":"transcript.partial","text":"hello","words":[{"text":"hello","start":0.25,"end":0.75,"speaker":2}],"is_final":true,"speech_final":true}"#,
                1_000,
            )
            .ok_or("missing xAI delta");
        assert!(delta.is_ok());
        let delta = delta.unwrap_or_else(|_| unreachable!());
        assert_eq!(delta.text, "hello");
        assert_eq!((delta.start_ms, delta.end_ms), (250, 750));
        assert_eq!(delta.speaker, Some(2));
        assert!(delta.final_segment);
        assert!(
            state
                .parse(
                    r#"{"type":"transcript.done","text":"hello","duration":0.75}"#,
                    1_100,
                )
                .is_none()
        );
    }

    #[test]
    fn diarization_speaker_and_channel_survive_the_parser() {
        let mut state = TranscriptState::new(config(), "xai-byok");
        let delta = state
            .parse(
                r#"{"is_final":true,"channel_index":[0,1],"channel":{"alternatives":[{"transcript":"we ship on friday","confidence":0.98,"words":[{"word":"we","start":1.0,"end":1.2,"confidence":0.99,"speaker":0,"speaker_confidence":0.71,"punctuated_word":"We"},{"word":"ship","start":1.2,"end":1.5,"confidence":0.98,"speaker":1,"speaker_confidence":0.68,"punctuated_word":"ship"},{"word":"on","start":1.5,"end":1.6,"confidence":0.97,"speaker":1,"speaker_confidence":0.68,"punctuated_word":"on"},{"word":"friday","start":1.6,"end":2.0,"confidence":0.96,"speaker":1,"speaker_confidence":0.68,"punctuated_word":"Friday."}],"languages":["en"]}]}}"#,
                2_000,
            )
            .ok_or("missing diarized delta");
        assert!(delta.is_ok());
        let delta = delta.unwrap_or_else(|_| unreachable!());
        assert_eq!(delta.speaker, Some(1));
        assert_eq!(delta.channel_index, Some(0));
        assert_eq!(diarization_key(&delta), Some(1));
    }

    #[test]
    fn undiarized_words_leave_the_segment_unattributed() {
        let mut state = TranscriptState::new(config(), "xai-managed");
        let delta = state
            .parse(
                r#"{"is_final":true,"channel":{"alternatives":[{"transcript":"hello","words":[{"start":1.0,"end":1.2}]}]}}"#,
                2_000,
            )
            .ok_or("missing delta");
        assert!(delta.is_ok());
        let delta = delta.unwrap_or_else(|_| unreachable!());
        assert_eq!(delta.speaker, None);
        assert_eq!(delta.channel_index, None);
        assert_eq!(diarization_key(&delta), None);
    }

    #[test]
    fn a_second_channel_never_collides_with_the_first_channels_speakers() {
        let mut state = TranscriptState::new(config(), "xai-byok");
        let delta = state
            .parse(
                r#"{"is_final":true,"channel_index":[1,2],"channel":{"alternatives":[{"transcript":"over here","words":[{"start":1.0,"end":1.2,"speaker":0}]}]}}"#,
                2_000,
            )
            .ok_or("missing delta");
        assert!(delta.is_ok());
        let delta = delta.unwrap_or_else(|_| unreachable!());
        assert_eq!((delta.speaker, delta.channel_index), (Some(0), Some(1)));
        assert_eq!(diarization_key(&delta), Some(1 << 32));
    }

    #[test]
    fn unsigned_pcm_is_converted_to_advertised_linear_sixteen() {
        let mut value = config();
        value.sample_rate_hz = 8_000;
        value.encoding = AudioEncoding::PcmU8;
        let auth = TranscriptionAuth::Byok {
            endpoint: "wss://api.x.ai/v1/stt".to_owned(),
            api_key: "xai-secret".to_owned(),
        };
        let plan = ConnectionPlan::from_auth(&auth, &value, None)
            .unwrap_or_else(|error| panic!("PCM8 plan is valid: {error}"));
        assert_eq!(
            plan.endpoint
                .query_pairs()
                .find(|(key, _)| key == "encoding")
                .map(|(_, value)| value.into_owned()),
            Some("pcm".to_owned())
        );
        assert_eq!(
            encode_audio(vec![0, 128, 255], AudioEncoding::PcmU8),
            [0, 128, 0, 0, 0, 127]
        );
        assert_eq!(encode_audio(vec![1, 2], AudioEncoding::PcmS16Le), [1, 2]);
    }

    #[test]
    fn encode_audio_pcm_s16le_returns_same_length_without_conversion() {
        let bytes = vec![1, 2, 3, 4];
        let len = bytes.len();
        let out = encode_audio(bytes, AudioEncoding::PcmS16Le);
        assert_eq!(out.len(), len);
        assert_eq!(out, [1, 2, 3, 4]);
    }

    #[test]
    fn xai_audio_contract_accepts_only_raw_pcm() {
        let mut value = config();
        value.sample_rate_hz = 8_000;
        assert_eq!(xai_encoding(&value), Ok("pcm"));

        value.sample_rate_hz = 16_000;
        value.encoding = AudioEncoding::Opus;
        assert_eq!(xai_encoding(&value), Err(SttError::UnsupportedAudio));

        value.channels = 2;
        assert_eq!(xai_encoding(&value), Err(SttError::UnsupportedAudio));

        value.channels = 1;
        value.sample_rate_hz = 48_000;
        assert_eq!(xai_encoding(&value), Err(SttError::UnsupportedAudio));
    }

    #[test]
    fn terminal_control_is_independent_from_bounded_audio() {
        let (audio_sender, mut audio_receiver) = mpsc::channel(AUDIO_CHANNEL_CAPACITY);
        let (control_sender, mut control_receiver) = mpsc::channel(AUDIO_CHANNEL_CAPACITY);
        let handle = SttHandle {
            audio_sender: Some(audio_sender),
            control_sender: Some(control_sender),
            pending_audio_bytes: Arc::new(AtomicUsize::new(0)),
        };
        assert_eq!(handle.send_audio(&vec![0; MAX_PENDING_AUDIO_BYTES]), Ok(()));
        assert_eq!(handle.send_audio(&[0]), Err(SttError::ConnectionFailed));
        handle.finish();
        assert!(matches!(
            control_receiver.try_recv(),
            Ok(SttControl::Finish)
        ));
        assert_eq!(
            audio_receiver.try_recv().map(|bytes| bytes.len()),
            Ok(MAX_PENDING_AUDIO_BYTES)
        );
    }
}
