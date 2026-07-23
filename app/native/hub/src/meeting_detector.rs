use std::time::{Duration, Instant};

pub const MEETING_POLL_INTERVAL: Duration = Duration::from_secs(4);
pub const MEETING_POLL_INTERVAL_IDLE: Duration = Duration::from_secs(15);
pub const BROWSER_GATE_IDLE_AFTER: Duration = Duration::from_secs(60);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MeetingApp {
    pub name: String,
    pub bundle_id: String,
}

#[derive(Debug, Default)]
pub struct MeetingGate {
    observed: bool,
    active: bool,
    inactive_for: Option<Duration>,
}

impl MeetingGate {
    pub fn apply(&mut self, detected: bool, elapsed: Duration) -> bool {
        self.observed = true;
        if detected {
            self.active = true;
            self.inactive_for = None;
        } else if self.active {
            let inactive_for = self.inactive_for.unwrap_or_default() + elapsed;
            if inactive_for >= Duration::from_secs(8) {
                self.active = false;
                self.inactive_for = None;
            } else {
                self.inactive_for = Some(inactive_for);
            }
        }
        self.active
    }

    pub fn has_observed_state(&self) -> bool {
        self.observed
    }
}

#[derive(Debug, Default)]
pub struct BrowserGate {
    inactive_since: Option<Instant>,
}

impl BrowserGate {
    pub fn observe(&mut self, active: bool, now: Instant) {
        if active {
            self.inactive_since = None;
        } else {
            self.inactive_since.get_or_insert(now);
        }
    }

    pub fn interval(&self, now: Instant) -> Duration {
        match self.inactive_since {
            Some(since) if now.saturating_duration_since(since) > BROWSER_GATE_IDLE_AFTER => {
                MEETING_POLL_INTERVAL_IDLE
            }
            _ => MEETING_POLL_INTERVAL,
        }
    }
}

#[cfg(any(target_os = "macos", test))]
const NATIVE_CALL_APP_NAMES: &[&str] = &[
    "microsoft teams",
    "zoom.us",
    "facetime",
    "webex",
    "cisco webex meetings",
    "goto meeting",
    "gotomeeting",
];

/// Applications whose ownership of the microphone means a call is under way.
///
/// Slack and Discord are here because huddles and voice channels are meetings
/// in every sense that matters here, and both hold the microphone only while
/// one is running — the same signal the reference assistants rely on.
#[cfg(any(target_os = "macos", test))]
const NATIVE_CALL_BUNDLE_IDS: &[&str] = &[
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.microsoft.teams2",
    "com.apple.facetime",
    "cisco-systems.spark",
    "com.cisco.webex",
    "com.cisco.webexmeetingsapp",
    "com.webex.meetingmanager",
    "com.logmein.gotomeeting",
    "com.logmein.goto",
    "com.tinyspeck.slackmacgap",
    "com.slack.slack",
    "com.hnc.discord",
    "com.discordapp.discord",
];

#[cfg(any(target_os = "macos", test))]
const BROWSER_APP_NAMES: &[&str] = &[
    "google chrome",
    "google chrome canary",
    "chromium",
    "arc",
    "dia",
    "safari",
    "safari technology preview",
    "firefox",
    "firefox developer edition",
    "microsoft edge",
    "brave browser",
    "opera",
    "opera gx",
    "vivaldi",
    "comet",
];

/// Window-title fragments that mean the front tab is a live call.
///
/// These stay narrow on purpose: a tab merely *about* a meeting product must
/// not arm capture, so each keyword is either a join URL shape or the title a
/// platform only uses once you are in the call.
#[cfg(any(target_os = "macos", test))]
const BROWSER_CALL_KEYWORDS: &[&str] = &[
    "google meet",
    "meet.google.com",
    "teams - microsoft",
    "microsoft teams",
    "zoom.us/j/",
    "zoom.us/wc/",
    "zoom meeting",
    "whereby.com",
    "app.gather.town",
    "meet.jit.si",
    "jitsi meet",
    "huddle",
    "app.around.co",
    "livestorm",
    "bluejeans",
];

#[cfg(any(target_os = "macos", test))]
fn is_native_call_app(app: &MeetingApp) -> bool {
    let name = app.name.to_ascii_lowercase();
    let bundle_id = app.bundle_id.to_ascii_lowercase();
    NATIVE_CALL_APP_NAMES.contains(&name.as_str())
        || NATIVE_CALL_BUNDLE_IDS.iter().any(|candidate| {
            bundle_id == *candidate || bundle_id.starts_with(&format!("{candidate}."))
        })
}

#[cfg(test)]
fn is_call_window(app: &MeetingApp, title: &str) -> bool {
    if is_native_call_app(app) {
        return true;
    }
    is_browser_call_window(app, title)
}

#[cfg(any(target_os = "macos", test))]
fn is_browser_call_window(app: &MeetingApp, title: &str) -> bool {
    let name = app.name.to_ascii_lowercase();
    let title = title.to_ascii_lowercase();
    BROWSER_APP_NAMES.contains(&name.as_str())
        && BROWSER_CALL_KEYWORDS
            .iter()
            .any(|keyword| title.contains(keyword))
}

#[cfg(test)]
fn parse_running_apps(output: &str) -> impl Iterator<Item = MeetingApp> + '_ {
    output.lines().filter_map(|line| {
        let (name, bundle_id) = line.split_once('\t')?;
        (!name.is_empty() && !bundle_id.is_empty()).then(|| MeetingApp {
            name: name.to_string(),
            bundle_id: bundle_id.to_string(),
        })
    })
}

#[cfg(target_os = "macos")]
fn browser_process_running() -> bool {
    std::process::Command::new("/usr/bin/pgrep")
        .args([
            "-x",
            "Safari|Google Chrome|Chromium|Arc|Dia|firefox|Microsoft Edge|Brave Browser|Opera|Vivaldi|Comet",
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

#[cfg(target_os = "macos")]
fn detect_call_window() -> Option<MeetingApp> {
    if !browser_process_running() {
        return None;
    }
    let script = "tell application \"System Events\"\nset outputText to \"\"\nrepeat with processRef in (every application process whose background only is false)\nset windowTitle to \"\"\ntry\nset windowTitle to name of window 1 of processRef\nend try\nset bundleId to \"\"\ntry\nset bundleId to bundle identifier of processRef\nend try\nset outputText to outputText & (name of processRef) & tab & bundleId & tab & windowTitle & linefeed\nend repeat\nreturn outputText\nend tell";
    let output = std::process::Command::new("/usr/bin/osascript")
        .args(["-e", script])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let output = String::from_utf8(output.stdout).ok()?;
    output.lines().find_map(|line| {
        let mut fields = line.splitn(3, '\t');
        let app = MeetingApp {
            name: fields.next()?.to_string(),
            bundle_id: fields.next()?.to_string(),
        };
        fields
            .next()
            .filter(|title| is_browser_call_window(&app, title))
            .map(|_| app)
    })
}

#[cfg(target_os = "macos")]
fn detect_mic_owner() -> Option<MeetingApp> {
    let self_pid = i32::try_from(std::process::id()).ok()?;
    if !corti_coreaudio::other_app_holds_input(self_pid) {
        return None;
    }
    let owner = corti_coreaudio::mic_owner().app;
    let app = MeetingApp {
        name: owner.name,
        bundle_id: owner.bundle_id?,
    };
    is_native_call_app(&app).then_some(app)
}

#[cfg(target_os = "macos")]
pub fn detect() -> Option<MeetingApp> {
    detect_mic_owner().or_else(detect_call_window)
}

#[cfg(not(target_os = "macos"))]
pub fn detect() -> Option<MeetingApp> {
    None
}

pub fn suggested_title() -> Option<String> {
    detect().map(|app| app.name)
}

#[cfg(target_os = "macos")]
pub async fn run_meeting_poll() {
    let mut gate = MeetingGate::default();
    let mut browser_gate = BrowserGate::default();
    let mut last_active = false;
    let mut elapsed = Duration::ZERO;
    loop {
        let polled = tokio::task::spawn_blocking(|| (detect(), browser_process_running()))
            .await
            .ok();
        let (detected, browser_running) = polled.unwrap_or((None, false));
        browser_gate.observe(browser_running || detected.is_some(), Instant::now());
        let active = gate.apply(detected.is_some(), elapsed);
        if gate.has_observed_state() && active != last_active {
            last_active = active;
            crate::meeting::observe_gate(active, detected.map(|app| app.name));
        }
        let interval = browser_gate.interval(Instant::now());
        tokio::time::sleep(interval).await;
        elapsed = interval;
    }
}

#[cfg(test)]
mod tests {
    use super::{
        BROWSER_GATE_IDLE_AFTER, BrowserGate, MEETING_POLL_INTERVAL, MEETING_POLL_INTERVAL_IDLE,
        MeetingApp, MeetingGate, is_browser_call_window, is_call_window, is_native_call_app,
        parse_running_apps,
    };
    use std::time::{Duration, Instant};

    #[test]
    fn keeps_a_meeting_active_until_the_off_grace_period_elapses() {
        let mut gate = MeetingGate::default();
        assert!(gate.apply(true, Duration::ZERO));
        assert!(gate.apply(false, Duration::from_secs(4)));
        assert!(!gate.apply(false, Duration::from_secs(4)));
    }

    #[test]
    fn identifies_known_native_call_apps_by_bundle_id() {
        assert!(is_native_call_app(&MeetingApp {
            name: "Zoom Workplace".into(),
            bundle_id: "us.zoom.xos".into(),
        }));
    }

    #[test]
    fn accepts_only_native_call_apps_as_microphone_owners() {
        assert!(is_native_call_app(&MeetingApp {
            name: "Zoom".into(),
            bundle_id: "us.zoom.xos.helper".into(),
        }));
        assert!(!is_native_call_app(&MeetingApp {
            name: "Google Chrome".into(),
            bundle_id: "com.google.Chrome".into(),
        }));
    }

    #[test]
    fn poll_interval_relaxes_after_a_minute_without_browser_or_meeting_activity() {
        let start = Instant::now();
        let mut gate = BrowserGate::default();
        gate.observe(false, start);
        assert_eq!(gate.interval(start), MEETING_POLL_INTERVAL);
        assert_eq!(
            gate.interval(start + BROWSER_GATE_IDLE_AFTER),
            MEETING_POLL_INTERVAL
        );
        assert_eq!(
            gate.interval(start + BROWSER_GATE_IDLE_AFTER + Duration::from_secs(1)),
            MEETING_POLL_INTERVAL_IDLE
        );
        gate.observe(false, start + Duration::from_secs(90));
        assert_eq!(
            gate.interval(start + Duration::from_secs(90)),
            MEETING_POLL_INTERVAL_IDLE
        );
        gate.observe(true, start + Duration::from_secs(91));
        assert_eq!(
            gate.interval(start + Duration::from_secs(91)),
            MEETING_POLL_INTERVAL
        );
    }

    #[test]
    fn ignores_an_idle_browser() {
        assert!(!is_native_call_app(&MeetingApp {
            name: "Google Chrome".into(),
            bundle_id: "com.google.Chrome".into(),
        }));
    }

    #[test]
    fn identifies_browser_call_windows_without_treating_other_tabs_as_meetings() {
        let browser = MeetingApp {
            name: "Google Chrome".into(),
            bundle_id: "com.google.Chrome".into(),
        };
        assert!(is_call_window(&browser, "Google Meet — Standup"));
        assert!(is_browser_call_window(&browser, "Google Meet — Standup"));
        assert!(!is_call_window(&browser, "GitHub - omi"));
    }

    #[test]
    fn treats_slack_huddles_and_discord_calls_as_native_calls() {
        for (name, bundle_id) in [
            ("Slack", "com.tinyspeck.slackmacgap"),
            ("Discord", "com.hnc.Discord"),
            ("Webex", "com.cisco.webex"),
        ] {
            assert!(
                is_native_call_app(&MeetingApp {
                    name: name.into(),
                    bundle_id: bundle_id.into(),
                }),
                "{bundle_id}"
            );
        }
    }

    #[test]
    fn recognises_call_windows_across_the_wider_browser_and_platform_list() {
        for (browser, title) in [
            ("Vivaldi", "Zoom Meeting"),
            ("Dia", "https://meet.jit.si/omi-standup"),
            ("Chromium", "Slack | Huddle in #eng"),
            ("Comet", "zoom.us/j/12345678"),
            ("Opera GX", "whereby.com/omi"),
        ] {
            let app = MeetingApp {
                name: browser.into(),
                bundle_id: "com.example.browser".into(),
            };
            assert!(is_browser_call_window(&app, title), "{browser}: {title}");
        }
    }

    #[test]
    fn leaves_ordinary_browsing_and_unknown_apps_alone() {
        let browser = MeetingApp {
            name: "Vivaldi".into(),
            bundle_id: "com.vivaldi.Vivaldi".into(),
        };
        assert!(!is_browser_call_window(&browser, "Pricing — Zoom"));
        assert!(!is_browser_call_window(&browser, "Inbox (12)"));
        assert!(!is_native_call_app(&browser));
        assert!(!is_browser_call_window(
            &MeetingApp {
                name: "Notes".into(),
                bundle_id: "com.apple.Notes".into(),
            },
            "Google Meet",
        ));
    }

    #[test]
    fn parses_system_events_app_pairs() {
        let apps = parse_running_apps("Finder\tcom.apple.finder\nzoom.us\tus.zoom.xos\n")
            .collect::<Vec<_>>();
        assert_eq!(apps[1].bundle_id, "us.zoom.xos");
    }

    #[test]
    fn stays_inactive_until_a_meeting_is_detected() {
        let mut gate = MeetingGate::default();
        assert!(!gate.has_observed_state());
        assert!(!gate.apply(false, Duration::ZERO));
        assert!(gate.has_observed_state());
        assert!(!gate.apply(false, Duration::from_secs(4)));
    }

    #[test]
    fn resets_the_off_grace_period_when_a_meeting_reappears() {
        let mut gate = MeetingGate::default();
        assert!(gate.apply(true, Duration::ZERO));
        assert!(gate.apply(false, Duration::from_secs(4)));
        assert!(gate.apply(true, Duration::from_secs(4)));
        assert!(gate.apply(false, Duration::from_secs(4)));
        assert!(!gate.apply(false, Duration::from_secs(4)));
    }
}
