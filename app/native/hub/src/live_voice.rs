#![cfg_attr(test, allow(dead_code))]

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message};
use url::Url;

const GEMINI_LIVE_HOST: &str = "generativelanguage.googleapis.com";
const GEMINI_LIVE_PATH: &str =
    "/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent";
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(8);
const FINAL_DRAIN_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);
const MAX_TOKEN_BYTES: usize = 16 * 1024;
const MAX_PENDING_AUDIO_BYTES: usize = 256 * 1024;
const EVENT_QUEUE_CAPACITY: usize = 64;
const INPUT_SAMPLE_RATE_HZ: u32 = 16_000;
const DEFAULT_OUTPUT_SAMPLE_RATE_HZ: u32 = 24_000;

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum RealtimeVoiceEvent {
    TranscriptDelta { text: String, final_segment: bool },
    AudioChunk { sample_rate_hz: u32, bytes: Vec<u8> },
    Interrupted,
    SessionEnded,
    Error(String),
}

#[derive(Clone, Eq, PartialEq)]
pub(crate) struct RealtimeVoiceSession {
    pub(crate) live_stream_id: String,
    pub(crate) ephemeral_token: String,
    pub(crate) model: String,
}

impl std::fmt::Debug for RealtimeVoiceSession {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RealtimeVoiceSession")
            .field("live_stream_id", &self.live_stream_id)
            .field("ephemeral_token", &"[redacted]")
            .field("model", &self.model)
            .finish()
    }
}

pub(crate) trait RealtimeVoiceProvider: Send + Sync {
    fn open(&self, session: RealtimeVoiceSession) -> Result<RealtimeVoiceHandle, String>;
}

enum LiveControl {
    Finish,
    Cancel,
}

pub(crate) struct RealtimeVoiceHandle {
    audio_sender: Option<mpsc::UnboundedSender<Vec<u8>>>,
    control_sender: Option<mpsc::UnboundedSender<LiveControl>>,
    pending_audio_bytes: Arc<AtomicUsize>,
    events: Option<mpsc::Receiver<RealtimeVoiceEvent>>,
}

impl RealtimeVoiceHandle {
    pub(crate) fn send_audio(&self, bytes: &[u8]) -> Result<(), String> {
        let Some(sender) = &self.audio_sender else {
            return Ok(());
        };
        let mut current = self.pending_audio_bytes.load(Ordering::Acquire);
        loop {
            let next = current
                .checked_add(bytes.len())
                .filter(|value| *value <= MAX_PENDING_AUDIO_BYTES)
                .ok_or_else(|| "live voice audio queue is full".to_owned())?;
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
            .map_err(|_| "live voice session is closed".to_owned());
        if result.is_err() {
            self.pending_audio_bytes
                .fetch_sub(bytes.len(), Ordering::AcqRel);
        }
        result
    }

    pub(crate) fn finish(&self) {
        if let Some(sender) = &self.control_sender {
            let _ = sender.send(LiveControl::Finish);
        }
    }

    pub(crate) fn cancel(&self) {
        if let Some(sender) = &self.control_sender {
            let _ = sender.send(LiveControl::Cancel);
        }
    }

    pub(crate) fn take_events(&mut self) -> Option<mpsc::Receiver<RealtimeVoiceEvent>> {
        self.events.take()
    }
}

pub(crate) struct GeminiLiveProvider;

pub(crate) fn validate_session(session: &RealtimeVoiceSession) -> Result<(), String> {
    if session.live_stream_id.trim().is_empty() {
        return Err("live voice stream id must not be empty".to_owned());
    }
    if session.model.trim().is_empty() || session.model.len() > 256 {
        return Err("live voice model is invalid".to_owned());
    }
    if session.ephemeral_token.is_empty()
        || session.ephemeral_token.len() > MAX_TOKEN_BYTES
        || session
            .ephemeral_token
            .bytes()
            .any(|byte| byte.is_ascii_control() || byte == b' ')
    {
        return Err("live voice token is invalid".to_owned());
    }
    Ok(())
}

pub(crate) fn live_endpoint(ephemeral_token: &str) -> Result<Url, String> {
    let mut endpoint = Url::parse(&format!("wss://{GEMINI_LIVE_HOST}{GEMINI_LIVE_PATH}"))
        .map_err(|_| "live voice endpoint is invalid".to_owned())?;
    endpoint
        .query_pairs_mut()
        .append_pair("access_token", ephemeral_token);
    if endpoint.scheme() != "wss"
        || endpoint.host_str() != Some(GEMINI_LIVE_HOST)
        || endpoint.port_or_known_default() != Some(443)
        || endpoint.path() != GEMINI_LIVE_PATH
        || endpoint.username() != ""
        || endpoint.password().is_some()
        || endpoint.fragment().is_some()
    {
        return Err("live voice endpoint is invalid".to_owned());
    }
    Ok(endpoint)
}

pub(crate) fn setup_message(model: &str) -> String {
    let model = if model.starts_with("models/") {
        model.to_owned()
    } else {
        format!("models/{model}")
    };
    serde_json::json!({
        "setup": {
            "model": model,
            "generationConfig": {
                "responseModalities": ["AUDIO"],
            },
            "realtimeInputConfig": {},
        }
    })
    .to_string()
}

pub(crate) fn realtime_input_message(bytes: &[u8]) -> String {
    serde_json::json!({
        "realtimeInput": {
            "audio": {
                "mimeType": format!("audio/pcm;rate={INPUT_SAMPLE_RATE_HZ}"),
                "data": BASE64.encode(bytes),
            }
        }
    })
    .to_string()
}

pub(crate) fn audio_stream_end_message() -> &'static str {
    r#"{"realtimeInput":{"audioStreamEnd":true}}"#
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerFrame {
    setup_complete: Option<serde_json::Value>,
    server_content: Option<ServerContent>,
    go_away: Option<serde_json::Value>,
    session_resumption_update: Option<SessionResumptionUpdate>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ServerContent {
    model_turn: Option<ModelTurn>,
    #[serde(default)]
    interrupted: bool,
    #[serde(default)]
    turn_complete: bool,
    output_transcription: Option<OutputTranscription>,
}

#[derive(Deserialize)]
struct ModelTurn {
    #[serde(default)]
    parts: Vec<ModelPart>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModelPart {
    inline_data: Option<InlineData>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InlineData {
    #[serde(default)]
    mime_type: String,
    #[serde(default)]
    data: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OutputTranscription {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SessionResumptionUpdate {
    #[serde(default)]
    new_handle: String,
    #[serde(default)]
    resumable: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub(crate) enum ServerMessage {
    SetupComplete,
    Content {
        audio: Vec<(u32, Vec<u8>)>,
        transcript: Option<String>,
        interrupted: bool,
        turn_complete: bool,
    },
    GoAway,
    SessionResumption {
        resumable: bool,
    },
    Unknown,
}

fn pcm_sample_rate(mime_type: &str) -> u32 {
    mime_type
        .split(';')
        .filter_map(|part| part.trim().strip_prefix("rate="))
        .find_map(|rate| rate.parse::<u32>().ok())
        .filter(|rate| (8_000..=96_000).contains(rate))
        .unwrap_or(DEFAULT_OUTPUT_SAMPLE_RATE_HZ)
}

pub(crate) fn parse_server_message(payload: &[u8]) -> Result<ServerMessage, String> {
    let frame: ServerFrame = serde_json::from_slice(payload)
        .map_err(|_| "live voice provider returned an invalid message".to_owned())?;
    if frame.setup_complete.is_some() {
        return Ok(ServerMessage::SetupComplete);
    }
    if frame.go_away.is_some() {
        return Ok(ServerMessage::GoAway);
    }
    if let Some(update) = frame.session_resumption_update {
        return Ok(ServerMessage::SessionResumption {
            resumable: update.resumable && !update.new_handle.is_empty(),
        });
    }
    let Some(content) = frame.server_content else {
        return Ok(ServerMessage::Unknown);
    };
    let mut audio = Vec::new();
    for part in content.model_turn.into_iter().flat_map(|turn| turn.parts) {
        let Some(inline) = part.inline_data else {
            continue;
        };
        if !inline.mime_type.starts_with("audio/pcm") {
            continue;
        }
        let bytes = BASE64
            .decode(inline.data.as_bytes())
            .map_err(|_| "live voice provider returned invalid audio".to_owned())?;
        if !bytes.is_empty() {
            audio.push((pcm_sample_rate(&inline.mime_type), bytes));
        }
    }
    let transcript = content
        .output_transcription
        .map(|value| value.text)
        .filter(|text| !text.trim().is_empty());
    Ok(ServerMessage::Content {
        audio,
        transcript,
        interrupted: content.interrupted,
        turn_complete: content.turn_complete,
    })
}

#[cfg(not(test))]
impl RealtimeVoiceProvider for GeminiLiveProvider {
    fn open(&self, session: RealtimeVoiceSession) -> Result<RealtimeVoiceHandle, String> {
        validate_session(&session)?;
        let endpoint = live_endpoint(&session.ephemeral_token)?;
        let (audio_sender, audio_receiver) = mpsc::unbounded_channel();
        let (control_sender, control_receiver) = mpsc::unbounded_channel();
        let (event_sender, event_receiver) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        let pending_audio_bytes = Arc::new(AtomicUsize::new(0));
        tokio::spawn(run(
            session,
            endpoint,
            audio_receiver,
            control_receiver,
            event_sender,
            Arc::clone(&pending_audio_bytes),
        ));
        Ok(RealtimeVoiceHandle {
            audio_sender: Some(audio_sender),
            control_sender: Some(control_sender),
            pending_audio_bytes,
            events: Some(event_receiver),
        })
    }
}

#[cfg(test)]
impl RealtimeVoiceProvider for GeminiLiveProvider {
    fn open(&self, session: RealtimeVoiceSession) -> Result<RealtimeVoiceHandle, String> {
        validate_session(&session)?;
        live_endpoint(&session.ephemeral_token)?;
        Ok(RealtimeVoiceHandle {
            audio_sender: None,
            control_sender: None,
            pending_audio_bytes: Arc::new(AtomicUsize::new(0)),
            events: None,
        })
    }
}

#[cfg_attr(test, allow(dead_code))]
async fn run(
    session: RealtimeVoiceSession,
    endpoint: Url,
    mut audio_receiver: mpsc::UnboundedReceiver<Vec<u8>>,
    mut control_receiver: mpsc::UnboundedReceiver<LiveControl>,
    events: mpsc::Sender<RealtimeVoiceEvent>,
    pending_audio_bytes: Arc<AtomicUsize>,
) {
    let model = session.model;
    let connection = async {
        let (socket, _) = tokio::time::timeout(CONNECT_TIMEOUT, connect_async(endpoint.as_str()))
            .await
            .map_err(|_| "live voice provider connection timed out".to_owned())?
            .map_err(|_| "live voice provider connection failed".to_owned())?;
        Ok::<_, String>(socket)
    };
    tokio::pin!(connection);
    let mut socket = tokio::select! {
        biased;
        control = control_receiver.recv() => {
            match control {
                Some(LiveControl::Finish) | Some(LiveControl::Cancel) | None => {
                    let _ = events.send(RealtimeVoiceEvent::SessionEnded).await;
                }
            }
            return;
        }
        result = &mut connection => match result {
            Ok(socket) => socket,
            Err(message) => {
                let _ = events.send(RealtimeVoiceEvent::Error(message)).await;
                return;
            }
        }
    };
    if socket
        .send(Message::Text(setup_message(&model).into()))
        .await
        .is_err()
    {
        let _ = events
            .send(RealtimeVoiceEvent::Error(
                "live voice provider rejected setup".to_owned(),
            ))
            .await;
        return;
    }
    let mut draining = false;
    loop {
        tokio::select! {
            biased;
            control = control_receiver.recv() => match control {
                Some(LiveControl::Finish) => {
                    while let Ok(bytes) = audio_receiver.try_recv() {
                        pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
                        if socket.send(Message::Text(realtime_input_message(&bytes).into())).await.is_err() {
                            let _ = events.send(RealtimeVoiceEvent::Error(
                                "live voice provider connection was lost".to_owned(),
                            )).await;
                            return;
                        }
                    }
                    if socket.send(Message::Text(audio_stream_end_message().into())).await.is_err() {
                        let _ = events.send(RealtimeVoiceEvent::Error(
                            "live voice provider connection was lost".to_owned(),
                        )).await;
                        return;
                    }
                    draining = true;
                }
                Some(LiveControl::Cancel) | None => {
                    let _ = socket.close(None).await;
                    let _ = events.send(RealtimeVoiceEvent::SessionEnded).await;
                    return;
                }
            },
            audio = audio_receiver.recv() => if let Some(bytes) = audio {
                pending_audio_bytes.fetch_sub(bytes.len(), Ordering::AcqRel);
                if !draining
                    && socket.send(Message::Text(realtime_input_message(&bytes).into())).await.is_err()
                {
                    let _ = events.send(RealtimeVoiceEvent::Error(
                        "live voice provider connection was lost".to_owned(),
                    )).await;
                    return;
                }
            },
            message = message_with_drain_timeout(&mut socket, draining) => match message {
                Some(Ok(payload)) => {
                    if !dispatch_server_payload(&payload, &events).await {
                        let _ = socket.close(None).await;
                        return;
                    }
                }
                Some(Err(())) => {}
                None => {
                    let _ = events.send(RealtimeVoiceEvent::SessionEnded).await;
                    return;
                }
            }
        }
    }
}

#[cfg_attr(test, allow(dead_code))]
async fn message_with_drain_timeout(
    socket: &mut (impl StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin),
    draining: bool,
) -> Option<Result<Vec<u8>, ()>> {
    let next = async {
        loop {
            return match socket.next().await {
                Some(Ok(Message::Text(text))) => Some(Ok(text.as_bytes().to_vec())),
                Some(Ok(Message::Binary(bytes))) => Some(Ok(bytes.to_vec())),
                Some(Ok(Message::Close(_))) | None => None,
                Some(Ok(_)) => continue,
                Some(Err(_)) => None,
            };
        }
    };
    if draining {
        tokio::time::timeout(FINAL_DRAIN_TIMEOUT, next)
            .await
            .unwrap_or(None)
    } else {
        next.await
    }
}

#[cfg_attr(test, allow(dead_code))]
async fn dispatch_server_payload(
    payload: &[u8],
    events: &mpsc::Sender<RealtimeVoiceEvent>,
) -> bool {
    let message = match parse_server_message(payload) {
        Ok(message) => message,
        Err(failure) => {
            let _ = events.send(RealtimeVoiceEvent::Error(failure)).await;
            return false;
        }
    };
    match message {
        ServerMessage::SetupComplete
        | ServerMessage::SessionResumption { .. }
        | ServerMessage::Unknown => true,
        ServerMessage::GoAway => {
            let _ = events.send(RealtimeVoiceEvent::SessionEnded).await;
            false
        }
        ServerMessage::Content {
            audio,
            transcript,
            interrupted,
            turn_complete,
        } => {
            if interrupted && events.send(RealtimeVoiceEvent::Interrupted).await.is_err() {
                return false;
            }
            for (sample_rate_hz, bytes) in audio {
                if events
                    .send(RealtimeVoiceEvent::AudioChunk {
                        sample_rate_hz,
                        bytes,
                    })
                    .await
                    .is_err()
                {
                    return false;
                }
            }
            if let Some(text) = transcript
                && events
                    .send(RealtimeVoiceEvent::TranscriptDelta {
                        text,
                        final_segment: turn_complete,
                    })
                    .await
                    .is_err()
            {
                return false;
            }
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session() -> RealtimeVoiceSession {
        RealtimeVoiceSession {
            live_stream_id: "live-1".to_owned(),
            ephemeral_token: "auth_tokens/abc123".to_owned(),
            model: "gemini-2.5-flash-native-audio-preview".to_owned(),
        }
    }

    #[test]
    fn endpoint_is_pinned_to_the_google_live_host() {
        let endpoint = live_endpoint("auth_tokens/abc123")
            .unwrap_or_else(|error| panic!("endpoint is valid: {error}"));
        assert_eq!(endpoint.host_str(), Some(GEMINI_LIVE_HOST));
        assert_eq!(endpoint.scheme(), "wss");
        assert_eq!(endpoint.path(), GEMINI_LIVE_PATH);
        assert_eq!(endpoint.query(), Some("access_token=auth_tokens%2Fabc123"));
    }

    #[test]
    fn session_validation_rejects_injectable_tokens() {
        assert_eq!(validate_session(&session()), Ok(()));
        let mut invalid = session();
        invalid.ephemeral_token = "token\r\nleak".to_owned();
        assert!(validate_session(&invalid).is_err());
        invalid.ephemeral_token = String::new();
        assert!(validate_session(&invalid).is_err());
        invalid = session();
        invalid.live_stream_id = "  ".to_owned();
        assert!(validate_session(&invalid).is_err());
        invalid = session();
        invalid.model = String::new();
        assert!(validate_session(&invalid).is_err());
    }

    #[test]
    fn session_debug_redacts_the_ephemeral_token() {
        let debug = format!("{:?}", session());
        assert!(!debug.contains("abc123"));
        assert!(debug.contains("[redacted]"));
    }

    #[test]
    fn setup_message_requests_audio_with_default_server_vad() {
        let value: serde_json::Value =
            serde_json::from_str(&setup_message("gemini-live")).unwrap_or_default();
        assert_eq!(
            value["setup"]["model"],
            serde_json::json!("models/gemini-live")
        );
        assert_eq!(
            value["setup"]["generationConfig"]["responseModalities"],
            serde_json::json!(["AUDIO"])
        );
        assert_eq!(value["setup"]["realtimeInputConfig"], serde_json::json!({}));
        let prefixed: serde_json::Value =
            serde_json::from_str(&setup_message("models/gemini-live")).unwrap_or_default();
        assert_eq!(
            prefixed["setup"]["model"],
            serde_json::json!("models/gemini-live")
        );
    }

    #[test]
    fn realtime_input_frames_carry_sixteen_kilohertz_pcm() {
        let value: serde_json::Value =
            serde_json::from_str(&realtime_input_message(&[1, 2, 3])).unwrap_or_default();
        assert_eq!(
            value["realtimeInput"]["audio"]["mimeType"],
            serde_json::json!("audio/pcm;rate=16000")
        );
        assert_eq!(
            value["realtimeInput"]["audio"]["data"],
            serde_json::json!(BASE64.encode([1, 2, 3]))
        );
        let end: serde_json::Value =
            serde_json::from_str(audio_stream_end_message()).unwrap_or_default();
        assert_eq!(
            end["realtimeInput"]["audioStreamEnd"],
            serde_json::json!(true)
        );
    }

    #[test]
    fn server_content_parses_audio_interruption_and_turns() {
        let payload = serde_json::json!({
            "serverContent": {
                "modelTurn": {
                    "parts": [
                        {"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": BASE64.encode([9, 8])}},
                        {"text": "ignored"},
                    ]
                },
                "interrupted": true,
                "turnComplete": true,
                "outputTranscription": {"text": "hello"},
            }
        })
        .to_string();
        assert_eq!(
            parse_server_message(payload.as_bytes()),
            Ok(ServerMessage::Content {
                audio: vec![(24_000, vec![9, 8])],
                transcript: Some("hello".to_owned()),
                interrupted: true,
                turn_complete: true,
            })
        );
    }

    #[test]
    fn lifecycle_messages_are_recognized() {
        assert_eq!(
            parse_server_message(br#"{"setupComplete":{}}"#),
            Ok(ServerMessage::SetupComplete)
        );
        assert_eq!(
            parse_server_message(br#"{"goAway":{"timeLeft":"10s"}}"#),
            Ok(ServerMessage::GoAway)
        );
        assert_eq!(
            parse_server_message(
                br#"{"sessionResumptionUpdate":{"newHandle":"h1","resumable":true}}"#
            ),
            Ok(ServerMessage::SessionResumption { resumable: true })
        );
        assert_eq!(
            parse_server_message(br#"{"usageMetadata":{"totalTokenCount":3}}"#),
            Ok(ServerMessage::Unknown)
        );
        assert!(parse_server_message(b"not-json").is_err());
        assert!(
            parse_server_message(
                br#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm","data":"%%%"}}]}}}"#
            )
            .is_err()
        );
    }

    #[test]
    fn unknown_pcm_rates_fall_back_to_the_output_default() {
        assert_eq!(pcm_sample_rate("audio/pcm;rate=24000"), 24_000);
        assert_eq!(pcm_sample_rate("audio/pcm;rate=16000"), 16_000);
        assert_eq!(pcm_sample_rate("audio/pcm"), 24_000);
        assert_eq!(pcm_sample_rate("audio/pcm;rate=999999"), 24_000);
    }

    #[test]
    fn audio_queue_is_bounded() {
        let (audio_sender, mut audio_receiver) = mpsc::unbounded_channel();
        let handle = RealtimeVoiceHandle {
            audio_sender: Some(audio_sender),
            control_sender: None,
            pending_audio_bytes: Arc::new(AtomicUsize::new(0)),
            events: None,
        };
        assert_eq!(handle.send_audio(&vec![0; MAX_PENDING_AUDIO_BYTES]), Ok(()));
        assert!(handle.send_audio(&[0]).is_err());
        assert_eq!(
            audio_receiver.try_recv().map(|bytes| bytes.len()),
            Ok(MAX_PENDING_AUDIO_BYTES)
        );
    }
}
