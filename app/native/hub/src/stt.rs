#![cfg_attr(test, allow(dead_code))]

use crate::signals::{AudioEncoding, TranscriptDelta, TranscriptGap, TranscriptionAuth};
use crate::signals::{NativeError, NativeEvent, TranscriptionState, TranscriptionStatus};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
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

const DEEPGRAM_HOST: &str = "api.deepgram.com";
const DEEPGRAM_PATH: &str = "/v1/listen";
const MAX_CREDENTIAL_BYTES: usize = 16 * 1024;
const MAX_PENDING_AUDIO_BYTES: usize = 64 * 1024;
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);
const FINAL_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);

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
        let encoding = deepgram_encoding(config)?;
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
                    provider: "deepgram-managed",
                    reconnectable: false,
                })
            }
            TranscriptionAuth::Byok { endpoint, api_key } => {
                valid_credential(api_key)?;
                let mut endpoint = byok_endpoint(endpoint)?;
                for (key, value) in [
                    ("model", "nova-3".to_owned()),
                    ("language", config.language.clone()),
                    ("encoding", encoding.to_owned()),
                    ("sample_rate", config.sample_rate_hz.to_string()),
                    ("channels", config.channels.to_string()),
                    ("interim_results", "true".to_owned()),
                    ("diarize", "true".to_owned()),
                ] {
                    endpoint.query_pairs_mut().append_pair(key, &value);
                }
                Ok(Self {
                    endpoint,
                    authorization: format!("Token {api_key}"),
                    provider: "deepgram-byok",
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

fn deepgram_encoding(config: &SttConfig) -> Result<&'static str, SttError> {
    match config.encoding {
        AudioEncoding::PcmS16Le | AudioEncoding::PcmU8
            if matches!(config.sample_rate_hz, 8_000 | 16_000 | 48_000)
                && matches!(config.channels, 1 | 2) =>
        {
            Ok("linear16")
        }
        AudioEncoding::Opus if config.sample_rate_hz == 16_000 && config.channels == 1 => {
            Ok("opus")
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
        || endpoint.host_str() != Some(DEEPGRAM_HOST)
        || endpoint.port_or_known_default() != Some(443)
        || endpoint.path() != DEEPGRAM_PATH
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
    audio_sender: Option<mpsc::UnboundedSender<Vec<u8>>>,
    control_sender: Option<mpsc::UnboundedSender<SttControl>>,
    pending_audio_bytes: Arc<AtomicUsize>,
}

#[cfg_attr(test, allow(dead_code))]
enum SttControl {
    Finish,
    Cancel,
}

impl SttHandle {
    pub(crate) fn send_audio(&self, bytes: &[u8]) -> Result<(), SttError> {
        let Some(sender) = &self.audio_sender else {
            return Ok(());
        };
        let mut current = self.pending_audio_bytes.load(Ordering::Acquire);
        loop {
            let next = current
                .checked_add(bytes.len())
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
        let result = sender
            .send(bytes.to_vec())
            .map_err(|_| SttError::ConnectionFailed);
        if result.is_err() {
            self.pending_audio_bytes
                .fetch_sub(bytes.len(), Ordering::AcqRel);
        }
        result
    }

    pub(crate) fn finish(&self) {
        if let Some(sender) = &self.control_sender {
            let _ = sender.send(SttControl::Finish);
        }
    }

    pub(crate) fn cancel(&self) {
        if let Some(sender) = &self.control_sender {
            let _ = sender.send(SttControl::Cancel);
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
    let (audio_sender, audio_receiver) = mpsc::unbounded_channel();
    let (control_sender, control_receiver) = mpsc::unbounded_channel();
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

#[cfg_attr(test, allow(dead_code))]
async fn run(
    config: SttConfig,
    plan: ConnectionPlan,
    mut audio_receiver: mpsc::UnboundedReceiver<Vec<u8>>,
    mut control_receiver: mpsc::UnboundedReceiver<SttControl>,
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
    loop {
        tokio::select! {
            biased;
            control = control_receiver.recv() => match control {
                Some(SttControl::Finish) => {
                    while let Ok(bytes) = audio_receiver.try_recv() {
                        pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
                        let encoded = encode_audio(&bytes, config.encoding);
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
                    if socket.send(Message::Text(r#"{"type":"Finalize"}"#.into())).await.is_err()
                        || socket.send(Message::Text(r#"{"type":"CloseStream"}"#.into())).await.is_err()
                    {
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
                    let encoded = encode_audio(&bytes, config.encoding);
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
                    if let Some(delta) = state.parse(text.as_ref(), unix_time_ms()) {
                        if delta.final_segment {
                            crate::meeting::observe_final_segment(&delta.text).await;
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
                ).await {
                    Some(reconnected) => socket = reconnected,
                    None => return,
                },
                Some(Err(_)) => match recover(
                    &config,
                    &plan,
                    &mut state,
                    &mut audio_receiver,
                    &mut control_receiver,
                    &pending_audio_bytes,
                ).await {
                    Some(reconnected) => socket = reconnected,
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
                    if let Some(delta) = state.parse(text.as_ref(), unix_time_ms()) {
                        if delta.final_segment {
                            crate::meeting::observe_final_segment(&delta.text).await;
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
    audio_receiver: &mut mpsc::UnboundedReceiver<Vec<u8>>,
    control_receiver: &mut mpsc::UnboundedReceiver<SttControl>,
    pending_audio_bytes: &AtomicUsize,
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
                        pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
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
    audio_receiver: &mut mpsc::UnboundedReceiver<Vec<u8>>,
    control_receiver: &mut mpsc::UnboundedReceiver<SttControl>,
    pending_audio_bytes: &AtomicUsize,
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
                    pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
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

fn encode_audio(bytes: &[u8], encoding: AudioEncoding) -> Vec<u8> {
    if encoding != AudioEncoding::PcmU8 {
        return bytes.to_vec();
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
struct DeepgramResponse {
    #[serde(default)]
    is_final: bool,
    #[serde(default)]
    speech_final: bool,
    channel: Option<DeepgramChannel>,
}

#[derive(Deserialize)]
struct DeepgramChannel {
    #[serde(default)]
    alternatives: Vec<DeepgramAlternative>,
}

#[derive(Deserialize)]
struct DeepgramAlternative {
    #[serde(default)]
    transcript: String,
    #[serde(default)]
    words: Vec<DeepgramWord>,
    #[serde(default)]
    languages: Vec<String>,
}

#[derive(Deserialize)]
struct DeepgramWord {
    start: f64,
    end: f64,
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

    pub(crate) fn parse(&mut self, json: &str, occurred_at_ms: i64) -> Option<TranscriptDelta> {
        let response: DeepgramResponse = serde_json::from_str(json).ok()?;
        let alternative = response.channel?.alternatives.into_iter().next()?;
        let text = alternative.transcript.trim();
        if text.is_empty() {
            return None;
        }
        let start_ms = alternative
            .words
            .first()
            .map_or(occurred_at_ms, |word| seconds_to_millis(word.start));
        let end_ms = alternative
            .words
            .last()
            .map_or(occurred_at_ms, |word| seconds_to_millis(word.end));
        let final_segment = response.is_final || response.speech_final;
        let sequence = self.sequence;
        if final_segment {
            self.sequence = self.sequence.saturating_add(1);
        }
        Some(TranscriptDelta {
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
            language: alternative.languages.into_iter().next().or_else(|| {
                (self.config.language != "multi").then(|| self.config.language.clone())
            }),
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
            Ok(("deepgram-managed", false))
        );
        assert!(matches!(
            ConnectionPlan::from_auth(&auth, &config(), Some("https://evil.example")),
            Err(SttError::InvalidEndpoint)
        ));
    }

    #[test]
    fn byok_endpoint_is_exact_and_credentials_reject_controls() {
        let auth = TranscriptionAuth::Byok {
            endpoint: "wss://api.deepgram.com/v1/listen".to_owned(),
            api_key: "dg-secret".to_owned(),
        };
        let plan = ConnectionPlan::from_auth(&auth, &config(), None);
        assert_eq!(
            plan.map(|value| (value.provider, value.reconnectable)),
            Ok(("deepgram-byok", true))
        );
        let injected = TranscriptionAuth::Byok {
            endpoint: "wss://api.deepgram.com/v1/listen".to_owned(),
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
        let mut state = TranscriptState::new(config(), "deepgram-managed");
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
    fn unsigned_pcm_is_converted_to_advertised_linear_sixteen() {
        let mut value = config();
        value.sample_rate_hz = 8_000;
        value.encoding = AudioEncoding::PcmU8;
        let auth = TranscriptionAuth::Byok {
            endpoint: "wss://api.deepgram.com/v1/listen".to_owned(),
            api_key: "dg-secret".to_owned(),
        };
        let plan = ConnectionPlan::from_auth(&auth, &value, None)
            .unwrap_or_else(|error| panic!("PCM8 plan is valid: {error}"));
        assert_eq!(
            plan.endpoint
                .query_pairs()
                .find(|(key, _)| key == "encoding")
                .map(|(_, value)| value.into_owned()),
            Some("linear16".to_owned())
        );
        assert_eq!(
            encode_audio(&[0, 128, 255], AudioEncoding::PcmU8),
            [0, 128, 0, 0, 0, 127]
        );
        assert_eq!(encode_audio(&[1, 2], AudioEncoding::PcmS16Le), [1, 2]);
    }

    #[test]
    fn deepgram_audio_contract_matches_physical_omi_codecs() {
        let mut value = config();
        value.sample_rate_hz = 8_000;
        assert_eq!(deepgram_encoding(&value), Ok("linear16"));

        value.sample_rate_hz = 16_000;
        value.encoding = AudioEncoding::Opus;
        assert_eq!(deepgram_encoding(&value), Ok("opus"));

        value.channels = 2;
        assert_eq!(deepgram_encoding(&value), Err(SttError::UnsupportedAudio));

        value.channels = 1;
        value.sample_rate_hz = 48_000;
        assert_eq!(deepgram_encoding(&value), Err(SttError::UnsupportedAudio));
    }

    #[test]
    fn terminal_control_is_independent_from_bounded_audio() {
        let (audio_sender, mut audio_receiver) = mpsc::unbounded_channel();
        let (control_sender, mut control_receiver) = mpsc::unbounded_channel();
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
