//! Joins a FaceTime call with a headless browser and makes it a media leg.
//!
//! This is the meeting-bot pattern: a browser joins the call as an announced
//! participant, and the page itself is the bridge. Inbound, the caller's audio
//! is tapped off `RTCPeerConnection`'s track event, downsampled in-page to
//! 16 kHz PCM16 and drained into [`crate::live_voice`]. Outbound, the
//! assistant's speech and the animated Omi mark are presented to the page as
//! its own microphone and camera, synthesized entirely in JavaScript — a
//! canvas `captureStream` and a `MediaStreamAudioDestinationNode` — so no
//! virtual devices are installed and no system configuration is touched.
//!
//! Everything that knows what Apple's page looks like lives in
//! [`crate::facetime_page`]. This file only knows how to drive a browser.
//!
//! The browser is controlled over the Chrome DevTools Protocol directly, using
//! the WebSocket and HTTP clients the crate already carries. No automation
//! framework is added: CDP is a handful of JSON messages, and a dependency
//! that ships its own browser download and update pings is exactly what this
//! crate should not take on.
//!
//! Credentials are not involved here at all — a join link is a bearer of the
//! call, and the Gemini session it is bridged to was opened elsewhere with a
//! token from the environment.

#![allow(dead_code)]
// The call path is complete and tested end to end inside the hub, but nothing
// in this crate calls into it yet: the command that places a FaceTime call and
// hands back a join link lives in the Worker and the Dart UI, both outside this
// change's ownership. `facetime_bridge::live::join` and `call_bridge::run_call`
// are the two entry points that surface needs.

use crate::call_bridge::{CallMedia, CallTransport};
use crate::facetime_page::{self, JoinFailure, JoinStep, PageStatus};
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::{Value, json};
use std::time::Duration;
use tokio::sync::mpsc;

const CDP_DISCOVERY_TIMEOUT: Duration = Duration::from_secs(15);
const CDP_CALL_TIMEOUT: Duration = Duration::from_secs(20);
const JOIN_POLL_INTERVAL: Duration = Duration::from_millis(500);
/// Outbound media queued for the page. Video frames are droppable; audio is
/// not, so the queue is sized for roughly a second of both.
const OUTBOUND_QUEUE: usize = 64;

// ---------------------------------------------------------------------------
// Chrome DevTools Protocol
// ---------------------------------------------------------------------------

pub(crate) fn cdp_request(id: u64, method: &str, params: Value) -> String {
    json!({ "id": id, "method": method, "params": params }).to_string()
}

#[derive(Clone, Debug, PartialEq)]
pub(crate) enum CdpMessage {
    Result { id: u64, result: Value },
    Failure { id: u64, message: String },
    Event { method: String, params: Value },
}

pub(crate) fn parse_cdp_message(payload: &[u8]) -> Result<CdpMessage, String> {
    let value: Value =
        serde_json::from_slice(payload).map_err(|_| "browser sent an unreadable message")?;
    if let Some(id) = value.get("id").and_then(Value::as_u64) {
        if let Some(error) = value.get("error") {
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("browser rejected the command");
            return Ok(CdpMessage::Failure {
                id,
                message: message.to_owned(),
            });
        }
        return Ok(CdpMessage::Result {
            id,
            result: value.get("result").cloned().unwrap_or(Value::Null),
        });
    }
    let method = value
        .get("method")
        .and_then(Value::as_str)
        .ok_or("browser sent a message with no method")?;
    Ok(CdpMessage::Event {
        method: method.to_owned(),
        params: value.get("params").cloned().unwrap_or(Value::Null),
    })
}

pub(crate) fn evaluate_params(expression: &str) -> Value {
    json!({
        "expression": expression,
        "awaitPromise": true,
        "returnByValue": true,
        "userGesture": true,
    })
}

/// Unwrap a `Runtime.evaluate` reply. A thrown exception is a page change, not
/// a protocol fault: it means the script met a page it did not expect.
pub(crate) fn evaluate_value(result: &Value) -> Result<Value, JoinFailure> {
    if let Some(details) = result.get("exceptionDetails") {
        let text = details
            .get("exception")
            .and_then(|exception| exception.get("description"))
            .and_then(Value::as_str)
            .or_else(|| details.get("text").and_then(Value::as_str))
            .unwrap_or("the page script threw");
        return Err(JoinFailure::PageChanged(text.to_owned()));
    }
    Ok(result
        .get("result")
        .and_then(|inner| inner.get("value"))
        .cloned()
        .unwrap_or(Value::Null))
}

pub(crate) fn evaluate_string(result: &Value) -> Result<String, JoinFailure> {
    match evaluate_value(result)? {
        Value::String(text) => Ok(text),
        Value::Null => Ok(String::new()),
        other => Err(JoinFailure::PageChanged(format!(
            "expected text from the page, got {other}"
        ))),
    }
}

/// Pull the page's debugger socket out of `/json/version`.
pub(crate) fn debugger_url(body: &str) -> Result<String, JoinFailure> {
    let value: Value = serde_json::from_str(body)
        .map_err(|_| JoinFailure::Protocol("devtools returned unreadable JSON".to_owned()))?;
    value
        .get("webSocketDebuggerUrl")
        .and_then(Value::as_str)
        .filter(|url| url.starts_with("ws://127.0.0.1:") || url.starts_with("ws://localhost:"))
        .map(str::to_owned)
        .ok_or_else(|| JoinFailure::Protocol("devtools exposed no debugger socket".to_owned()))
}

/// Decode the base64 PCM16 the page hands back, rejecting a partial sample
/// rather than shifting the stream by a byte.
pub(crate) fn decode_capture(encoded: &str) -> Result<Vec<u8>, JoinFailure> {
    if encoded.is_empty() {
        return Ok(Vec::new());
    }
    let bytes = BASE64
        .decode(encoded.as_bytes())
        .map_err(|_| JoinFailure::PageChanged("captured audio was not base64".to_owned()))?;
    if bytes.len() % 2 != 0 {
        return Err(JoinFailure::PageChanged(
            "captured audio was not whole samples".to_owned(),
        ));
    }
    Ok(bytes)
}

/// The script that hands one piece of outbound media to the page.
pub(crate) fn deliver_script(media: &CallMedia) -> String {
    match media {
        CallMedia::Audio {
            sample_rate_hz,
            bytes,
        } => format!(
            "window.__omi.pushAudio({}, {sample_rate_hz})",
            facetime_page::js_literal(&BASE64.encode(bytes))
        ),
        CallMedia::Video(frame) => format!(
            "window.__omi.pushFrame({}, {}, {})",
            facetime_page::js_literal(&BASE64.encode(&frame.luma)),
            frame.width,
            frame.height
        ),
        CallMedia::FlushAudio => "window.__omi.flushAudio()".to_owned(),
    }
}

/// Decide what to do after one pass of the join script.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum JoinProgress {
    Continue,
    Joined,
    Failed,
}

pub(crate) fn join_progress(step: JoinStep, status: &PageStatus) -> JoinProgress {
    if status.ended {
        return JoinProgress::Failed;
    }
    if status.joined || step == JoinStep::Joined {
        return JoinProgress::Joined;
    }
    match step {
        JoinStep::Ended => JoinProgress::Failed,
        _ => JoinProgress::Continue,
    }
}

// ---------------------------------------------------------------------------
// The transport
// ---------------------------------------------------------------------------

/// The call leg, as [`crate::call_bridge`] sees it.
///
/// `deliver` is synchronous and the page is not, so media is queued here and
/// written by the pump task that owns the DevTools connection. A closed queue
/// means the browser is gone, which is the call ending.
pub(crate) struct FaceTimeTransport {
    outbound: mpsc::Sender<CallMedia>,
    video: bool,
}

impl FaceTimeTransport {
    pub(crate) fn new(outbound: mpsc::Sender<CallMedia>, video: bool) -> Self {
        Self { outbound, video }
    }
}

impl CallTransport for FaceTimeTransport {
    fn deliver(&mut self, media: CallMedia) -> Result<(), String> {
        match self.outbound.try_send(media) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(CallMedia::Video(_))) => Ok(()),
            Err(mpsc::error::TrySendError::Full(_)) => {
                Err("the call is not draining audio".to_owned())
            }
            Err(mpsc::error::TrySendError::Closed(_)) => Err("the call ended".to_owned()),
        }
    }

    fn wants_video(&self) -> bool {
        self.video
    }
}

// ---------------------------------------------------------------------------
// Driving a real browser
// ---------------------------------------------------------------------------

/// A joined call: the caller's audio, a transport to speak back through, and a
/// guard whose drop closes the browser.
#[cfg_attr(test, allow(dead_code))]
pub(crate) struct JoinedCall {
    pub(crate) caller_audio: mpsc::Receiver<Vec<u8>>,
    pub(crate) transport: FaceTimeTransport,
    pub(crate) browser: BrowserProcess,
}

/// Owns the spawned browser and its throwaway profile, and takes both down
/// when the call is over. A realtime session that leaks a headless Chromium is
/// unbounded cost of the most embarrassing kind.
#[cfg_attr(test, allow(dead_code))]
pub(crate) struct BrowserProcess {
    child: Option<std::process::Child>,
    profile: std::path::PathBuf,
}

impl Drop for BrowserProcess {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.profile);
    }
}

#[cfg_attr(test, allow(dead_code))]
pub(crate) fn locate_browser() -> Result<std::path::PathBuf, JoinFailure> {
    facetime_page::chromium_candidates(|name| std::env::var(name).ok())
        .into_iter()
        .find(|path| path.is_file())
        .ok_or_else(|| {
            JoinFailure::BrowserUnavailable(
                "install Chrome, Chromium or Edge, or set OMI_CHROMIUM_PATH".to_owned(),
            )
        })
}

#[cfg(not(test))]
pub(crate) mod live {
    use super::{
        BrowserProcess, CDP_CALL_TIMEOUT, CDP_DISCOVERY_TIMEOUT, CdpMessage, Duration,
        FaceTimeTransport, JOIN_POLL_INTERVAL, JoinFailure, JoinProgress, JoinStep, JoinedCall,
        OUTBOUND_QUEUE, PageStatus, Value, cdp_request, debugger_url, decode_capture,
        deliver_script, evaluate_params, evaluate_string, evaluate_value, facetime_page,
        join_progress, locate_browser, mpsc, parse_cdp_message,
    };
    use crate::call_bridge::CallMedia;
    use crate::facetime_page::{BRIDGE_SCRIPT, DRAIN_INTERVAL, JOIN_TIMEOUT};
    use futures::{SinkExt, StreamExt};
    use serde_json::json;
    use tokio_tungstenite::tungstenite::protocol::Message;

    struct Cdp {
        socket: tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        next_id: u64,
    }

    impl Cdp {
        async fn call(&mut self, method: &str, params: Value) -> Result<Value, JoinFailure> {
            self.next_id += 1;
            let id = self.next_id;
            self.socket
                .send(Message::Text(cdp_request(id, method, params).into()))
                .await
                .map_err(|_| JoinFailure::Protocol("lost the browser connection".to_owned()))?;
            let deadline = tokio::time::Instant::now() + CDP_CALL_TIMEOUT;
            loop {
                let next = tokio::time::timeout_at(deadline, self.socket.next())
                    .await
                    .map_err(|_| {
                        JoinFailure::Protocol("the browser stopped replying".to_owned())
                    })?;
                let payload = match next {
                    Some(Ok(Message::Text(text))) => text.as_bytes().to_vec(),
                    Some(Ok(Message::Binary(bytes))) => bytes.to_vec(),
                    Some(Ok(_)) => continue,
                    Some(Err(_)) | None => {
                        return Err(JoinFailure::Protocol("the browser went away".to_owned()));
                    }
                };
                match parse_cdp_message(&payload)
                    .map_err(|e| JoinFailure::Protocol(e.to_owned()))?
                {
                    CdpMessage::Result { id: got, result } if got == id => return Ok(result),
                    CdpMessage::Failure { id: got, message } if got == id => {
                        return Err(JoinFailure::Protocol(message));
                    }
                    _ => continue,
                }
            }
        }

        async fn evaluate(&mut self, expression: &str) -> Result<Value, JoinFailure> {
            let result = self
                .call("Runtime.evaluate", evaluate_params(expression))
                .await?;
            evaluate_value(&result).map(|_| result)
        }
    }

    /// Start a browser, join `link` as `name`, and hand back the media leg.
    pub(crate) async fn join(
        link: &str,
        name: Option<&str>,
        video: bool,
    ) -> Result<JoinedCall, JoinFailure> {
        let url = facetime_page::join_url(link)?;
        let name = facetime_page::display_name(name);
        let executable = locate_browser()?;
        let profile = std::env::temp_dir().join(format!(
            "omi-facetime-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|since| since.as_nanos())
                .unwrap_or_default()
        ));
        std::fs::create_dir_all(&profile).map_err(|failure| {
            JoinFailure::BrowserUnavailable(format!("could not make a browser profile: {failure}"))
        })?;
        let port = free_port()?;
        let child = std::process::Command::new(&executable)
            .args(facetime_page::chromium_arguments(
                port,
                &profile.to_string_lossy(),
            ))
            .arg("about:blank")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|failure| {
                JoinFailure::BrowserUnavailable(format!("the browser would not start: {failure}"))
            })?;
        let browser = BrowserProcess {
            child: Some(child),
            profile,
        };

        let mut cdp = connect(port).await?;
        cdp.call("Page.enable", json!({})).await?;
        cdp.call("Runtime.enable", json!({})).await?;
        cdp.call(
            "Page.addScriptToEvaluateOnNewDocument",
            json!({ "source": BRIDGE_SCRIPT }),
        )
        .await?;
        cdp.call("Page.navigate", json!({ "url": url })).await?;

        let step_script = facetime_page::join_step_script(&name);
        let deadline = tokio::time::Instant::now() + JOIN_TIMEOUT;
        let mut last = JoinStep::Unknown;
        loop {
            if tokio::time::Instant::now() >= deadline {
                return Err(facetime_page::timeout_failure(last));
            }
            tokio::time::sleep(JOIN_POLL_INTERVAL).await;
            let stepped = match cdp.evaluate(&step_script).await {
                Ok(value) => facetime_page::parse_join_step(&evaluate_string(&value)?),
                // Navigation tears down the execution context; try again.
                Err(JoinFailure::Protocol(_)) => continue,
                Err(other) => return Err(other),
            };
            last = stepped;
            let status = match cdp
                .evaluate("window.__omi ? window.__omi.status() : ''")
                .await
            {
                Ok(value) => {
                    let text = evaluate_string(&value)?;
                    if text.is_empty() {
                        PageStatus::default()
                    } else {
                        facetime_page::parse_status(&text)?
                    }
                }
                Err(_) => PageStatus::default(),
            };
            match join_progress(stepped, &status) {
                JoinProgress::Joined => break,
                JoinProgress::Failed => return Err(JoinFailure::Ended),
                JoinProgress::Continue => {}
            }
        }

        let (caller_sender, caller_audio) = mpsc::channel(64);
        let (outbound, outbound_receiver) = mpsc::channel(OUTBOUND_QUEUE);
        tokio::spawn(pump(cdp, caller_sender, outbound_receiver));
        Ok(JoinedCall {
            caller_audio,
            transport: FaceTimeTransport::new(outbound, video),
            browser,
        })
    }

    /// The single owner of the DevTools connection once the call is up: it
    /// drains captured caller audio on a timer and writes outbound media as it
    /// arrives. Either side going quiet ends the call.
    async fn pump(
        mut cdp: Cdp,
        caller: mpsc::Sender<Vec<u8>>,
        mut outbound: mpsc::Receiver<CallMedia>,
    ) {
        let mut ticks = tokio::time::interval(DRAIN_INTERVAL);
        ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                media = outbound.recv() => {
                    let Some(media) = media else { return };
                    if cdp.evaluate(&deliver_script(&media)).await.is_err() {
                        return;
                    }
                }
                _ = ticks.tick() => {
                    let Ok(value) = cdp.evaluate("window.__omi.drainAudio()").await else {
                        return;
                    };
                    let Ok(encoded) = evaluate_string(&value) else { return };
                    let Ok(bytes) = decode_capture(&encoded) else { return };
                    if !bytes.is_empty() && caller.send(bytes).await.is_err() {
                        return;
                    }
                    let Ok(status) = cdp.evaluate("window.__omi.status()").await else {
                        return;
                    };
                    if evaluate_string(&status)
                        .ok()
                        .and_then(|text| facetime_page::parse_status(&text).ok())
                        .is_none_or(|status| status.ended)
                    {
                        return;
                    }
                }
            }
        }
    }

    fn free_port() -> Result<u16, JoinFailure> {
        std::net::TcpListener::bind("127.0.0.1:0")
            .and_then(|listener| listener.local_addr())
            .map(|address| address.port())
            .map_err(|failure| {
                JoinFailure::BrowserUnavailable(format!("no port for the browser: {failure}"))
            })
    }

    async fn connect(port: u16) -> Result<Cdp, JoinFailure> {
        let client = reqwest::Client::builder()
            .no_proxy()
            .build()
            .map_err(|failure| JoinFailure::Protocol(failure.to_string()))?;
        let deadline = tokio::time::Instant::now() + CDP_DISCOVERY_TIMEOUT;
        let endpoint = format!("http://127.0.0.1:{port}/json/version");
        let socket_url = loop {
            if tokio::time::Instant::now() >= deadline {
                return Err(JoinFailure::BrowserUnavailable(
                    "the browser never opened its devtools port".to_owned(),
                ));
            }
            if let Ok(response) = client.get(&endpoint).send().await
                && let Ok(body) = response.text().await
                && let Ok(url) = debugger_url(&body)
            {
                break url;
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        };
        let (socket, _) = tokio_tungstenite::connect_async(socket_url.as_str())
            .await
            .map_err(|_| JoinFailure::Protocol("could not attach to the browser".to_owned()))?;
        Ok(Cdp { socket, next_id: 0 })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::mark_video::VideoFrame;

    #[test]
    fn commands_are_framed_as_cdp_expects() {
        let request = cdp_request(7, "Page.navigate", json!({ "url": "about:blank" }));
        let value: Value = serde_json::from_str(&request).unwrap_or(Value::Null);
        assert_eq!(value["id"], 7);
        assert_eq!(value["method"], "Page.navigate");
        assert_eq!(value["params"]["url"], "about:blank");
    }

    #[test]
    fn replies_events_and_errors_are_told_apart() {
        assert_eq!(
            parse_cdp_message(br#"{"id":3,"result":{"ok":true}}"#),
            Ok(CdpMessage::Result {
                id: 3,
                result: json!({ "ok": true })
            })
        );
        assert_eq!(
            parse_cdp_message(br#"{"id":3,"error":{"message":"no such frame"}}"#),
            Ok(CdpMessage::Failure {
                id: 3,
                message: "no such frame".to_owned()
            })
        );
        assert_eq!(
            parse_cdp_message(br#"{"method":"Page.loadEventFired","params":{}}"#),
            Ok(CdpMessage::Event {
                method: "Page.loadEventFired".to_owned(),
                params: json!({})
            })
        );
        assert!(parse_cdp_message(b"{").is_err());
        assert!(parse_cdp_message(br#"{"params":{}}"#).is_err());
    }

    #[test]
    fn evaluate_asks_for_a_value_and_awaits_promises() {
        let params = evaluate_params("1 + 1");
        assert_eq!(params["awaitPromise"], true);
        assert_eq!(params["returnByValue"], true);
        assert_eq!(params["expression"], "1 + 1");
    }

    #[test]
    fn a_thrown_page_script_reads_as_a_page_change() {
        let thrown = json!({
            "exceptionDetails": {
                "exception": { "description": "TypeError: field is null" }
            }
        });
        assert_eq!(
            evaluate_value(&thrown),
            Err(JoinFailure::PageChanged(
                "TypeError: field is null".to_owned()
            ))
        );
        assert!(matches!(
            evaluate_value(&json!({ "exceptionDetails": {} })),
            Err(JoinFailure::PageChanged(_))
        ));
    }

    #[test]
    fn evaluate_unwraps_values() {
        let reply = json!({ "result": { "type": "string", "value": "joined" } });
        assert_eq!(evaluate_string(&reply).ok().as_deref(), Some("joined"));
        assert_eq!(evaluate_string(&json!({})).ok().as_deref(), Some(""));
        assert!(evaluate_string(&json!({ "result": { "value": 12 } })).is_err());
    }

    #[test]
    fn only_a_loopback_debugger_socket_is_accepted() {
        assert_eq!(
            debugger_url(r#"{"webSocketDebuggerUrl":"ws://127.0.0.1:9333/devtools/browser/x"}"#)
                .ok()
                .as_deref(),
            Some("ws://127.0.0.1:9333/devtools/browser/x")
        );
        for bad in [
            r#"{"webSocketDebuggerUrl":"ws://evil.example/devtools"}"#,
            r#"{}"#,
            "not json",
        ] {
            assert!(debugger_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn captured_audio_is_decoded_and_partial_samples_are_refused() {
        assert_eq!(decode_capture(""), Ok(Vec::new()));
        assert_eq!(decode_capture("AAEAAg=="), Ok(vec![0, 1, 0, 2]));
        assert!(matches!(
            decode_capture("AAEC"),
            Err(JoinFailure::PageChanged(_))
        ));
        assert!(matches!(
            decode_capture("not base64!!"),
            Err(JoinFailure::PageChanged(_))
        ));
    }

    #[test]
    fn outbound_media_becomes_the_right_page_call() {
        let audio = deliver_script(&CallMedia::Audio {
            sample_rate_hz: 24_000,
            bytes: vec![0, 1, 0, 2],
        });
        assert!(audio.starts_with("window.__omi.pushAudio(\"AAEAAg==\", 24000)"));
        let video = deliver_script(&CallMedia::Video(VideoFrame {
            width: 2,
            height: 2,
            luma: vec![255, 0, 0, 255],
        }));
        assert!(video.starts_with("window.__omi.pushFrame(\"/wAA/w==\", 2, 2)"));
        assert_eq!(
            deliver_script(&CallMedia::FlushAudio),
            "window.__omi.flushAudio()"
        );
    }

    #[test]
    fn join_progress_follows_the_page() {
        let waiting = PageStatus::default();
        assert_eq!(
            join_progress(JoinStep::Joining, &waiting),
            JoinProgress::Continue
        );
        assert_eq!(
            join_progress(JoinStep::Named, &waiting),
            JoinProgress::Continue
        );
        let live = PageStatus {
            joined: true,
            ..PageStatus::default()
        };
        assert_eq!(
            join_progress(JoinStep::Waiting, &live),
            JoinProgress::Joined
        );
        assert_eq!(
            join_progress(JoinStep::Joined, &waiting),
            JoinProgress::Joined
        );
        let over = PageStatus {
            joined: true,
            ended: true,
            ..PageStatus::default()
        };
        assert_eq!(join_progress(JoinStep::Joined, &over), JoinProgress::Failed);
        assert_eq!(
            join_progress(JoinStep::Ended, &waiting),
            JoinProgress::Failed
        );
    }

    #[test]
    fn a_missing_browser_says_how_to_fix_it() {
        let failure = JoinFailure::BrowserUnavailable(
            "install Chrome, Chromium or Edge, or set OMI_CHROMIUM_PATH".to_owned(),
        );
        assert!(failure.to_string().contains("OMI_CHROMIUM_PATH"));
    }

    #[test]
    fn the_transport_drops_late_frames_and_reports_a_dead_call() {
        let (sender, receiver) = mpsc::channel(1);
        let mut transport = FaceTimeTransport::new(sender, true);
        assert!(transport.wants_video());
        let frame = CallMedia::Video(VideoFrame {
            width: 1,
            height: 1,
            luma: vec![0],
        });
        assert_eq!(transport.deliver(frame.clone()), Ok(()));
        assert_eq!(transport.deliver(frame), Ok(()));
        assert!(transport.deliver(CallMedia::FlushAudio).is_err());
        drop(receiver);
        assert_eq!(
            transport.deliver(CallMedia::FlushAudio),
            Err("the call ended".to_owned())
        );
    }
}
