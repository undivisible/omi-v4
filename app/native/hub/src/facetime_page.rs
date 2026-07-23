//! Everything that touches Apple's FaceTime web client, in one file.
//!
//! The join flow is UI automation against a page we do not control and Apple
//! can change without notice. All of it — the URL shape, the selectors, and
//! the in-page bridge script — lives here so a break is a small edit in an
//! obvious place rather than a hunt through the bridge.
//!
//! # Why this works at all
//!
//! `facetime.apple.com/join#…` links open in any WebRTC browser with no Apple
//! account and no sign-in. Media is ordinary WebRTC; FaceTime's end-to-end
//! encryption is layered on with the Insertable Streams / encoded-transform
//! API. That placement is what makes an in-page bridge possible and honest: a
//! participant who legitimately joined the call receives media that the
//! receiver transform has already decrypted, so `RTCPeerConnection`'s `track`
//! event hands us plaintext audio; and anything we put on an outbound track
//! passes through the sender transform and is encrypted like any other
//! participant's. We are a participant, not an eavesdropper — no encryption is
//! circumvented.
//!
//! The usual gate is the host admitting you from the waiting room. Blooio
//! creates the link and auto-admits the first joiner, so for links minted
//! through `worker/src/facetime.ts` that gate is not in the way. For any other
//! link, admission can simply never arrive, and [`JoinFailure::NotAdmitted`]
//! is the expected outcome.
//!
//! # Honesty about the bot
//!
//! The display name is set explicitly and defaults to `Omi`. The bot announces
//! itself as software; it must never be given a person's name.

#![allow(dead_code)]

use std::time::Duration;

pub(crate) const DEFAULT_DISPLAY_NAME: &str = "Omi";

/// How long to wait for the page to report a joined call before giving up.
pub(crate) const JOIN_TIMEOUT: Duration = Duration::from_secs(90);
/// How often the Rust side pulls captured caller audio out of the page.
pub(crate) const DRAIN_INTERVAL: Duration = Duration::from_millis(60);

/// The caller-side PCM the page hands back: 16 kHz mono PCM16, matching
/// `live_voice`'s input contract exactly so no resampling happens in Rust.
pub(crate) const CAPTURE_SAMPLE_RATE_HZ: u32 = 16_000;

/// The one place selectors live.
///
/// Each step lists several candidates because Apple ships both a localized and
/// an A/B-tested variant of this page; the bridge takes the first that
/// matches. Text-based fallbacks are matched case-insensitively in the script
/// below rather than by CSS, because the labels are localized.
pub(crate) mod selectors {
    /// The "your name" field on the pre-join screen.
    pub(crate) const NAME_INPUT: &[&str] = &[
        "input#name-field",
        "input[name='name']",
        "input[type='text']",
        "input",
    ];
    /// The button that advances from the name screen to the join screen.
    pub(crate) const CONTINUE_BUTTON: &[&str] = &[
        "button#continue-button",
        "button[type='submit']",
        "button.continue",
    ];
    /// The button that actually joins the call.
    pub(crate) const JOIN_BUTTON: &[&str] = &["button#join-button", "button.join", "button"];
    /// Text labels used when no selector matches. Lowercase, substring match.
    pub(crate) const CONTINUE_LABELS: &[&str] = &["continue", "weiter", "continuar", "continuer"];
    pub(crate) const JOIN_LABELS: &[&str] = &["join", "beitreten", "unirse", "rejoindre"];
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum JoinFailure {
    /// The link is not a FaceTime join link.
    InvalidLink,
    /// No usable Chromium was found, or it would not start.
    BrowserUnavailable(String),
    /// The page loaded but the join controls never appeared or never worked.
    PageChanged(String),
    /// We joined the waiting room and were never let in.
    NotAdmitted,
    /// The call ended, from either side.
    Ended,
    /// The DevTools connection failed.
    Protocol(String),
}

impl std::fmt::Display for JoinFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidLink => formatter.write_str("that is not a FaceTime join link"),
            Self::BrowserUnavailable(detail) => {
                write!(formatter, "no usable browser to join the call: {detail}")
            }
            Self::PageChanged(detail) => write!(
                formatter,
                "the FaceTime web page did not behave as expected: {detail}"
            ),
            Self::NotAdmitted => formatter.write_str("the call did not admit us"),
            Self::Ended => formatter.write_str("the call ended"),
            Self::Protocol(detail) => write!(formatter, "browser control failed: {detail}"),
        }
    }
}

/// Accept only a genuine FaceTime join link, and strip nothing from it: the
/// fragment carries the call's key material, so it must survive intact.
pub(crate) fn join_url(link: &str) -> Result<String, JoinFailure> {
    let link = link.trim();
    if link.len() > 2_048 {
        return Err(JoinFailure::InvalidLink);
    }
    let parsed = url::Url::parse(link).map_err(|_| JoinFailure::InvalidLink)?;
    if parsed.scheme() != "https"
        || parsed.host_str() != Some("facetime.apple.com")
        || parsed.path() != "/join"
        || parsed.username() != ""
        || parsed.password().is_some()
        || parsed.fragment().is_none_or(str::is_empty)
    {
        return Err(JoinFailure::InvalidLink);
    }
    Ok(parsed.to_string())
}

/// A display name that cannot mislead a participant and cannot break out of
/// the script it is embedded in.
pub(crate) fn display_name(requested: Option<&str>) -> String {
    let cleaned: String = requested
        .unwrap_or(DEFAULT_DISPLAY_NAME)
        .chars()
        .filter(|character| !character.is_control())
        .take(32)
        .collect();
    let cleaned = cleaned.trim();
    if cleaned.is_empty() {
        DEFAULT_DISPLAY_NAME.to_owned()
    } else {
        cleaned.to_owned()
    }
}

/// Embed a value in a script as a JSON literal. `serde_json` escapes
/// everything that matters; the extra `<` guard keeps the result safe even if
/// it is ever placed inside an inline `<script>` element.
pub(crate) fn js_literal(value: &str) -> String {
    serde_json::Value::String(value.to_owned())
        .to_string()
        .replace('<', "\\u003c")
}

/// Chromium command line.
///
/// `--use-fake-ui-for-media-stream` auto-accepts the camera and microphone
/// prompt; the devices themselves are never touched, because the bootstrap
/// script replaces `getUserMedia` with an in-page canvas and Web Audio stream.
/// That is the whole reason to prefer the in-page approach: no OS-level
/// virtual device, no system configuration, nothing left behind.
pub(crate) fn chromium_arguments(debug_port: u16, profile_dir: &str) -> Vec<String> {
    vec![
        "--headless=new".to_owned(),
        format!("--remote-debugging-port={debug_port}"),
        format!("--user-data-dir={profile_dir}"),
        "--no-first-run".to_owned(),
        "--no-default-browser-check".to_owned(),
        "--disable-extensions".to_owned(),
        "--disable-sync".to_owned(),
        "--disable-background-networking".to_owned(),
        "--metrics-recording-only".to_owned(),
        "--no-pings".to_owned(),
        "--use-fake-ui-for-media-stream".to_owned(),
        "--autoplay-policy=no-user-gesture-required".to_owned(),
        "--window-size=640,640".to_owned(),
    ]
}

/// Where to find a Chromium. `OMI_CHROMIUM_PATH` wins, so an operator can
/// point at their own build without this list being edited.
pub(crate) fn chromium_candidates(env: impl Fn(&str) -> Option<String>) -> Vec<std::path::PathBuf> {
    let mut candidates = Vec::new();
    if let Some(explicit) = env("OMI_CHROMIUM_PATH").filter(|value| !value.trim().is_empty()) {
        candidates.push(std::path::PathBuf::from(explicit));
    }
    for path in [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "/usr/bin/google-chrome",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/usr/bin/microsoft-edge",
    ] {
        candidates.push(std::path::PathBuf::from(path));
    }
    candidates
}

/// The bridge, injected before any page script runs.
///
/// It does four things and nothing else:
///   * replaces `getUserMedia` with a synthetic stream — a 240x240 canvas we
///     paint the Omi mark into, and a `MediaStreamAudioDestinationNode` we
///     feed the assistant's speech into,
///   * wraps `RTCPeerConnection` so every inbound audio track is tapped,
///     downsampled to 16 kHz mono PCM16 and queued,
///   * exposes `window.__omi` for the Rust side to drain and push through,
///   * tracks joined/ended state so the bridge can tell "waiting to be
///     admitted" from "in the call" from "call over".
pub(crate) const BRIDGE_SCRIPT: &str = r#"
(() => {
  if (window.__omi) return;
  const CAPTURE_RATE = 16000;
  const FRAME = 240;
  const MAX_QUEUED_INBOUND = 32000 * 8;
  const state = {
    inbound: [], inboundLength: 0,
    outbound: [], outboundOffset: 0,
    joined: false, ended: false, remoteTracks: 0, error: null,
  };

  const audioContext = () => {
    if (!state.ac) state.ac = new (window.AudioContext || window.webkitAudioContext)();
    return state.ac;
  };

  const synthetic = () => {
    if (state.stream) return state.stream;
    const ac = audioContext();
    state.dest = ac.createMediaStreamDestination();
    const speaker = ac.createScriptProcessor(2048, 1, 1);
    speaker.onaudioprocess = (event) => {
      const out = event.outputBuffer.getChannelData(0);
      for (let i = 0; i < out.length; i += 1) {
        let sample = 0;
        while (state.outbound.length > 0) {
          const head = state.outbound[0];
          if (state.outboundOffset < head.length) {
            sample = head[state.outboundOffset];
            state.outboundOffset += 1;
            break;
          }
          state.outbound.shift();
          state.outboundOffset = 0;
        }
        out[i] = sample;
      }
    };
    speaker.connect(state.dest);
    state.speaker = speaker;
    const canvas = document.createElement('canvas');
    canvas.width = FRAME; canvas.height = FRAME;
    state.canvas = canvas;
    state.paint = canvas.getContext('2d');
    state.paint.fillStyle = '#000';
    state.paint.fillRect(0, 0, FRAME, FRAME);
    const video = canvas.captureStream(12);
    state.stream = new MediaStream([
      ...video.getVideoTracks(),
      ...state.dest.stream.getAudioTracks(),
    ]);
    return state.stream;
  };

  const media = navigator.mediaDevices;
  if (media && media.getUserMedia) {
    media.getUserMedia = async (constraints) => {
      const stream = synthetic();
      const tracks = [];
      if (!constraints || constraints.audio) tracks.push(...stream.getAudioTracks());
      if (constraints && constraints.video) tracks.push(...stream.getVideoTracks());
      return new MediaStream(tracks.length > 0 ? tracks : stream.getTracks());
    };
  }

  const tap = (track) => {
    const ac = audioContext();
    const source = ac.createMediaStreamSource(new MediaStream([track]));
    const listener = ac.createScriptProcessor(4096, 1, 1);
    const ratio = ac.sampleRate / CAPTURE_RATE;
    listener.onaudioprocess = (event) => {
      const input = event.inputBuffer.getChannelData(0);
      const count = Math.floor(input.length / ratio);
      const pcm = new Int16Array(count);
      for (let i = 0; i < count; i += 1) {
        const value = input[Math.floor(i * ratio)] || 0;
        pcm[i] = Math.max(-1, Math.min(1, value)) * 32767;
      }
      state.inbound.push(pcm);
      state.inboundLength += pcm.length * 2;
      // Evict oldest-first until the queue is back inside the cap, decrementing
      // as we go: a counter that is only ever incremented freezes at the cap and
      // then bounds nothing. One chunk always survives so a single oversized
      // chunk cannot empty the queue.
      while (state.inboundLength > MAX_QUEUED_INBOUND && state.inbound.length > 1) {
        state.inboundLength -= state.inbound.shift().length * 2;
      }
    };
    source.connect(listener);
    const sink = ac.createGain();
    sink.gain.value = 0;
    listener.connect(sink);
    sink.connect(ac.destination);
    state.remoteTracks += 1;
    state.joined = true;
    track.addEventListener('ended', () => {
      state.remoteTracks -= 1;
      if (state.remoteTracks <= 0) state.ended = true;
    });
  };

  const Native = window.RTCPeerConnection;
  if (Native) {
    const Wrapped = function (...args) {
      const pc = new Native(...args);
      pc.addEventListener('track', (event) => {
        if (event.track && event.track.kind === 'audio') {
          try { tap(event.track); } catch (failure) { state.error = String(failure); }
        }
      });
      pc.addEventListener('connectionstatechange', () => {
        if (pc.connectionState === 'failed' || pc.connectionState === 'closed') state.ended = true;
      });
      return pc;
    };
    Wrapped.prototype = Native.prototype;
    Object.setPrototypeOf(Wrapped, Native);
    window.RTCPeerConnection = Wrapped;
    window.webkitRTCPeerConnection = Wrapped;
  }

  const toBase64 = (bytes) => {
    let binary = '';
    for (let i = 0; i < bytes.length; i += 1) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  };
  const fromBase64 = (text) => {
    const binary = atob(text);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes;
  };

  window.__omi = {
    status: () => JSON.stringify({
      joined: state.joined, ended: state.ended,
      tracks: state.remoteTracks, error: state.error,
    }),
    drainAudio: () => {
      if (state.inbound.length === 0) return '';
      let total = 0;
      for (const chunk of state.inbound) total += chunk.length;
      const merged = new Int16Array(total);
      let at = 0;
      for (const chunk of state.inbound) { merged.set(chunk, at); at += chunk.length; }
      state.inbound = []; state.inboundLength = 0;
      return toBase64(new Uint8Array(merged.buffer));
    },
    pushAudio: (encoded, rate) => {
      synthetic();
      const bytes = fromBase64(encoded);
      const pcm = new Int16Array(bytes.buffer, bytes.byteOffset, bytes.byteLength >> 1);
      const ac = audioContext();
      const ratio = rate / ac.sampleRate;
      const count = Math.floor(pcm.length / ratio);
      const samples = new Float32Array(count);
      for (let i = 0; i < count; i += 1) samples[i] = (pcm[Math.floor(i * ratio)] || 0) / 32768;
      state.outbound.push(samples);
      return true;
    },
    flushAudio: () => { state.outbound = []; state.outboundOffset = 0; return true; },
    pushFrame: (encoded, width, height) => {
      synthetic();
      const luma = fromBase64(encoded);
      const image = state.paint.createImageData(width, height);
      for (let i = 0; i < luma.length; i += 1) {
        const value = luma[i];
        image.data[i * 4] = value;
        image.data[i * 4 + 1] = value;
        image.data[i * 4 + 2] = value;
        image.data[i * 4 + 3] = 255;
      }
      state.paint.putImageData(image, 0, 0);
      return true;
    },
  };
})();
"#;

/// The join click-through, as one idempotent step the bridge can retry.
///
/// It reports what it did so the Rust side can distinguish "still on the name
/// screen" from "waiting to be admitted" from "the page is not what we think
/// it is". Every selector it uses comes from [`selectors`] above.
pub(crate) fn join_step_script(name: &str) -> String {
    let name = js_literal(name);
    let name_inputs = js_literal(&selectors::NAME_INPUT.join(","));
    let continue_buttons = js_literal(&selectors::CONTINUE_BUTTON.join(","));
    let join_buttons = js_literal(&selectors::JOIN_BUTTON.join(","));
    let continue_labels = js_literal(&selectors::CONTINUE_LABELS.join("|"));
    let join_labels = js_literal(&selectors::JOIN_LABELS.join("|"));
    format!(
        r#"
(() => {{
  const status = window.__omi ? JSON.parse(window.__omi.status()) : {{ joined: false, ended: false }};
  if (status.ended) return 'ended';
  if (status.joined) return 'joined';
  const pick = (list) => {{
    for (const selector of list.split(',')) {{
      const found = document.querySelector(selector);
      if (found && found.offsetParent !== null && !found.disabled) return found;
    }}
    return null;
  }};
  const byLabel = (labels) => {{
    const wanted = labels.split('|');
    for (const button of document.querySelectorAll('button,[role=button]')) {{
      const text = (button.textContent || '').trim().toLowerCase();
      if (button.offsetParent === null || button.disabled) continue;
      if (wanted.some((label) => text.includes(label))) return button;
    }}
    return null;
  }};
  const field = pick({name_inputs});
  if (field && field.value !== {name}) {{
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
    setter.call(field, {name});
    field.dispatchEvent(new Event('input', {{ bubbles: true }}));
    field.dispatchEvent(new Event('change', {{ bubbles: true }}));
    return 'named';
  }}
  const join = pick({join_buttons}) || byLabel({join_labels});
  if (join) {{ join.click(); return 'joining'; }}
  const proceed = pick({continue_buttons}) || byLabel({continue_labels});
  if (proceed) {{ proceed.click(); return 'continued'; }}
  return field ? 'waiting' : 'unknown';
}})()
"#
    )
}

/// What one pass of [`join_step_script`] reported.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum JoinStep {
    /// The display name was filled in.
    Named,
    /// The name screen was dismissed.
    Continued,
    /// Join was clicked; from here we are in the waiting room.
    Joining,
    /// In the call, remote audio is flowing.
    Joined,
    /// Sitting on a screen we recognise, with nothing to click yet.
    Waiting,
    /// The call is over.
    Ended,
    /// Nothing on the page matched anything we know about.
    Unknown,
}

pub(crate) fn parse_join_step(value: &str) -> JoinStep {
    match value {
        "named" => JoinStep::Named,
        "continued" => JoinStep::Continued,
        "joining" => JoinStep::Joining,
        "joined" => JoinStep::Joined,
        "waiting" => JoinStep::Waiting,
        "ended" => JoinStep::Ended,
        _ => JoinStep::Unknown,
    }
}

/// Live call state, as reported by `window.__omi.status()`.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct PageStatus {
    pub(crate) joined: bool,
    pub(crate) ended: bool,
    pub(crate) tracks: u32,
    pub(crate) error: Option<String>,
}

pub(crate) fn parse_status(value: &str) -> Result<PageStatus, JoinFailure> {
    #[derive(serde::Deserialize)]
    struct Raw {
        #[serde(default)]
        joined: bool,
        #[serde(default)]
        ended: bool,
        #[serde(default)]
        tracks: u32,
        #[serde(default)]
        error: Option<String>,
    }
    let raw: Raw = serde_json::from_str(value)
        .map_err(|_| JoinFailure::PageChanged("status was unreadable".to_owned()))?;
    Ok(PageStatus {
        joined: raw.joined,
        ended: raw.ended,
        tracks: raw.tracks,
        error: raw.error.filter(|text| !text.is_empty()),
    })
}

/// Turn the outcome of a join attempt that ran out of time into the specific
/// failure. Sitting in the waiting room having clicked Join is not a broken
/// page — it is an admission that never came.
pub(crate) fn timeout_failure(last: JoinStep) -> JoinFailure {
    match last {
        JoinStep::Joining | JoinStep::Waiting => JoinFailure::NotAdmitted,
        JoinStep::Ended => JoinFailure::Ended,
        JoinStep::Joined => JoinFailure::Ended,
        JoinStep::Named | JoinStep::Continued => {
            JoinFailure::PageChanged("the join button never became usable".to_owned())
        }
        JoinStep::Unknown => {
            JoinFailure::PageChanged("no join controls were found on the page".to_owned())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_real_facetime_join_links_are_accepted() {
        assert!(join_url("https://facetime.apple.com/join#v=1&p=abc").is_ok());
        for bad in [
            "http://facetime.apple.com/join#v=1",
            "https://facetime.apple.com/join",
            "https://facetime.apple.com/other#v=1",
            "https://evil.example/join#v=1",
            "https://user:pass@facetime.apple.com/join#v=1",
            "not a url",
            "",
        ] {
            assert_eq!(join_url(bad), Err(JoinFailure::InvalidLink), "{bad}");
        }
    }

    #[test]
    fn the_fragment_survives_normalisation() {
        let link = "https://facetime.apple.com/join#v=1&p=Zm9vYmFy&k=QUJD";
        assert_eq!(join_url(link).ok().as_deref(), Some(link));
    }

    #[test]
    fn the_bot_always_has_a_name_and_it_is_omi_by_default() {
        assert_eq!(display_name(None), "Omi");
        assert_eq!(display_name(Some("   ")), "Omi");
        assert_eq!(display_name(Some("Omi Assistant")), "Omi Assistant");
        assert_eq!(display_name(Some("a\u{0}b\nc")), "abc");
        assert_eq!(display_name(Some(&"x".repeat(100))).len(), 32);
    }

    #[test]
    fn names_cannot_escape_the_script() {
        let script = join_step_script(&display_name(Some("\"); alert(1); (\"")));
        // The payload survives as text, but every quote that would have ended
        // the string literal is escaped, so it can never become a statement.
        assert!(!script.contains("\"); alert(1); (\""));
        assert!(script.contains(r#""\"); alert(1); (\"""#));
    }

    #[test]
    fn js_literals_are_safe_in_an_inline_script() {
        assert_eq!(js_literal("</script>"), r#""\u003c/script>""#);
        assert_eq!(js_literal("a\"b"), r#""a\"b""#);
    }

    #[test]
    fn chromium_arguments_are_headless_isolated_and_prompt_free() {
        let arguments = chromium_arguments(9333, "/tmp/omi-profile");
        assert!(arguments.contains(&"--headless=new".to_owned()));
        assert!(arguments.contains(&"--remote-debugging-port=9333".to_owned()));
        assert!(arguments.contains(&"--user-data-dir=/tmp/omi-profile".to_owned()));
        assert!(arguments.contains(&"--use-fake-ui-for-media-stream".to_owned()));
        assert!(arguments.contains(&"--disable-background-networking".to_owned()));
        // The fake *device* flags are deliberately absent: media is synthesized
        // in the page, so no OS device plumbing is involved.
        assert!(
            !arguments
                .iter()
                .any(|argument| argument.contains("use-fake-device-for-media-stream"))
        );
    }

    #[test]
    fn an_explicit_browser_path_wins() {
        let candidates = chromium_candidates(|name| {
            (name == "OMI_CHROMIUM_PATH").then(|| "/opt/my-chromium".to_owned())
        });
        assert_eq!(
            candidates
                .first()
                .map(|path| path.to_string_lossy())
                .as_deref(),
            Some("/opt/my-chromium")
        );
        assert!(candidates.len() > 1);
        assert!(chromium_candidates(|_| Some(String::new())).len() > 1);
    }

    #[test]
    fn the_bridge_script_installs_every_hook_it_promises() {
        for hook in [
            "getUserMedia",
            "RTCPeerConnection",
            "captureStream",
            "createMediaStreamDestination",
            "window.__omi",
            "drainAudio",
            "pushAudio",
            "pushFrame",
            "flushAudio",
            "status",
        ] {
            assert!(BRIDGE_SCRIPT.contains(hook), "missing {hook}");
        }
    }

    #[test]
    fn the_bridge_script_is_idempotent_and_bounded() {
        assert!(BRIDGE_SCRIPT.contains("if (window.__omi) return;"));
        assert!(BRIDGE_SCRIPT.contains("MAX_QUEUED_INBOUND"));
        // The inbound cap only bounds anything if eviction decrements the
        // counter it is measured against. A `shift()` that leaves the counter
        // alone freezes it at the cap and the queue stops being bounded by
        // bytes at all, so the decrement is asserted here rather than trusted.
        assert!(BRIDGE_SCRIPT.contains("state.inboundLength -= state.inbound.shift().length * 2;"));
        assert!(BRIDGE_SCRIPT.contains(
            "while (state.inboundLength > MAX_QUEUED_INBOUND && state.inbound.length > 1)"
        ));
    }

    #[test]
    fn the_join_script_uses_only_the_declared_selectors() {
        let script = join_step_script("Omi");
        for selector in selectors::NAME_INPUT {
            assert!(script.contains(selector), "missing {selector}");
        }
        for selector in selectors::JOIN_BUTTON {
            assert!(script.contains(selector), "missing {selector}");
        }
        for label in selectors::JOIN_LABELS {
            assert!(script.contains(label), "missing {label}");
        }
    }

    #[test]
    fn join_steps_round_trip() {
        assert_eq!(parse_join_step("named"), JoinStep::Named);
        assert_eq!(parse_join_step("continued"), JoinStep::Continued);
        assert_eq!(parse_join_step("joining"), JoinStep::Joining);
        assert_eq!(parse_join_step("joined"), JoinStep::Joined);
        assert_eq!(parse_join_step("waiting"), JoinStep::Waiting);
        assert_eq!(parse_join_step("ended"), JoinStep::Ended);
        assert_eq!(parse_join_step("something else"), JoinStep::Unknown);
    }

    #[test]
    fn status_is_parsed_and_bad_status_is_a_page_change() {
        let status = parse_status(r#"{"joined":true,"ended":false,"tracks":1,"error":null}"#);
        assert_eq!(
            status,
            Ok(PageStatus {
                joined: true,
                ended: false,
                tracks: 1,
                error: None
            })
        );
        assert_eq!(parse_status("{}"), Ok(PageStatus::default()));
        assert!(matches!(
            parse_status("nonsense"),
            Err(JoinFailure::PageChanged(_))
        ));
    }

    #[test]
    fn a_timeout_in_the_waiting_room_is_a_denied_admission_not_a_broken_page() {
        assert_eq!(timeout_failure(JoinStep::Joining), JoinFailure::NotAdmitted);
        assert_eq!(timeout_failure(JoinStep::Waiting), JoinFailure::NotAdmitted);
        assert_eq!(timeout_failure(JoinStep::Ended), JoinFailure::Ended);
        assert!(matches!(
            timeout_failure(JoinStep::Unknown),
            JoinFailure::PageChanged(_)
        ));
        assert!(matches!(
            timeout_failure(JoinStep::Named),
            JoinFailure::PageChanged(_)
        ));
    }

    #[test]
    fn failures_read_as_sentences() {
        assert_eq!(
            JoinFailure::NotAdmitted.to_string(),
            "the call did not admit us"
        );
        assert!(
            JoinFailure::BrowserUnavailable("none found".to_owned())
                .to_string()
                .contains("none found")
        );
    }
}
