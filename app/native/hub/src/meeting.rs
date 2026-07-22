use crate::capture_policy::{SystemAudioCaptureMode, capture_plan};
use crate::signals::{
    CaptureSource, ClientCommand, Command, MeetingCompleted, MeetingInsight, NativeEvent,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const INSIGHT_INTERVAL: Duration = Duration::from_secs(20);
pub const SUMMARY_TRANSCRIPT_CHARS: usize = 12_000;
pub const RAW_TRANSCRIPT_CHARS: usize = 48_000;
const INSIGHT_SOURCE_CHARS: usize = 500;
const CONTROL_QUEUE_CAPACITY: usize = 64;
const DEFAULT_TITLE: &str = "Meeting";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InsightKind {
    Decision,
    Action,
    Response,
}

impl InsightKind {
    pub fn name(self) -> &'static str {
        match self {
            Self::Decision => "decision",
            Self::Action => "action",
            Self::Response => "response",
        }
    }

    pub fn text(self) -> &'static str {
        match self {
            Self::Decision => "Capture this decision",
            Self::Action => "Capture this commitment",
            Self::Response => "Offer a concise answer",
        }
    }
}

pub fn classification_prompt(utterance: &str) -> String {
    format!(
        "Classify this meeting utterance. Reply with exactly one word: decision for an agreed \
         choice, action for a concrete commitment, response for a question needing an answer, or \
         none. Utterance: {utterance}"
    )
}

pub fn parse_classification(output: &str) -> Option<Option<InsightKind>> {
    let word = output
        .split_whitespace()
        .next()?
        .trim_matches(|c: char| !c.is_ascii_alphabetic())
        .to_ascii_lowercase();
    match word.as_str() {
        "decision" => Some(Some(InsightKind::Decision)),
        "action" => Some(Some(InsightKind::Action)),
        "response" => Some(Some(InsightKind::Response)),
        "none" => Some(None),
        _ => None,
    }
}

fn contains_word(text: &str, word: &str) -> bool {
    text.split(|c: char| !(c.is_ascii_alphanumeric() || c == '\''))
        .any(|token| token == word)
}

fn is_decision(text: &str) -> bool {
    ["agree", "approved", "decided"]
        .iter()
        .any(|marker| text.contains(marker))
        || text.contains("let's ")
        || text.contains("we should ")
}

fn is_action(text: &str) -> bool {
    if text.contains("i'll ") || text.contains("let me ") {
        return true;
    }
    ["will", "shall", "gonna"]
        .iter()
        .any(|modal| contains_word(text, modal))
        && ["i", "we", "you"]
            .iter()
            .any(|subject| contains_word(text, subject))
}

fn is_question(text: &str) -> bool {
    text.ends_with('?')
        || ["who ", "what ", "when ", "where ", "why ", "how "]
            .iter()
            .any(|opener| text.starts_with(opener))
}

pub fn classify_heuristic(utterance: &str) -> Option<InsightKind> {
    let text = utterance.trim().to_lowercase();
    if text.is_empty() {
        return None;
    }
    if is_decision(&text) {
        return Some(InsightKind::Decision);
    }
    if is_action(&text) {
        return Some(InsightKind::Action);
    }
    is_question(&text).then_some(InsightKind::Response)
}

#[derive(Debug, Default)]
pub struct InsightLimiter {
    last: Option<Instant>,
}

impl InsightLimiter {
    pub fn allow(&mut self, now: Instant) -> bool {
        if self
            .last
            .is_some_and(|last| now.saturating_duration_since(last) < INSIGHT_INTERVAL)
        {
            return false;
        }
        self.last = Some(now);
        true
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MeetingSummary {
    pub summary: String,
    pub actions: Vec<String>,
}

pub fn summary_prompt(transcript: &str) -> String {
    let bounded: String = transcript.chars().take(SUMMARY_TRANSCRIPT_CHARS).collect();
    format!(
        "You are a meeting assistant. Given the transcript below, produce a concise summary and \
         a list of action items. Return ONLY valid JSON in this exact format: \
         {{\"summary\":\"2-3 sentence summary of the meeting\",\"actions\":[\"action item \
         1\",\"action item 2\"]}}\n\n{bounded}"
    )
}

#[derive(serde::Deserialize)]
struct SummaryPayload {
    #[serde(default)]
    summary: String,
    #[serde(default)]
    actions: Vec<String>,
}

pub fn parse_summary(output: &str) -> Option<MeetingSummary> {
    let start = output.find('{')?;
    let end = output.rfind('}')?;
    let payload: SummaryPayload = serde_json::from_str(output.get(start..=end)?).ok()?;
    let summary = payload.summary.trim().to_owned();
    (!summary.is_empty()).then(|| MeetingSummary {
        summary,
        actions: payload
            .actions
            .into_iter()
            .map(|action| action.trim().to_owned())
            .filter(|action| !action.is_empty())
            .collect(),
    })
}

pub fn fallback_summary(transcript: &str) -> MeetingSummary {
    let mut summary = String::new();
    let mut sentences = 0;
    for character in transcript.trim().chars().take(SUMMARY_TRANSCRIPT_CHARS) {
        summary.push(character);
        if matches!(character, '.' | '!' | '?') {
            sentences += 1;
            if sentences == 2 {
                break;
            }
        }
    }
    MeetingSummary {
        summary: summary.split_whitespace().collect::<Vec<_>>().join(" "),
        actions: Vec::new(),
    }
}

#[derive(Debug)]
pub struct MeetingSession {
    title: Option<String>,
    manual: bool,
    transcript: String,
    limiter: InsightLimiter,
}

impl MeetingSession {
    pub fn new(title: Option<String>, manual: bool) -> Self {
        Self {
            title: title.filter(|value| !value.trim().is_empty()),
            manual,
            transcript: String::new(),
            limiter: InsightLimiter::default(),
        }
    }

    pub fn push_final(&mut self, text: &str) {
        let text = text.trim();
        let accumulated = self.transcript.chars().count();
        if text.is_empty() || accumulated >= RAW_TRANSCRIPT_CHARS {
            return;
        }
        if !self.transcript.is_empty() {
            self.transcript.push('\n');
        }
        let remaining = RAW_TRANSCRIPT_CHARS.saturating_sub(accumulated + 1);
        self.transcript.extend(text.chars().take(remaining));
    }

    pub fn transcript(&self) -> &str {
        &self.transcript
    }

    pub fn is_manual(&self) -> bool {
        self.manual
    }

    pub fn title(&self) -> &str {
        self.title.as_deref().unwrap_or(DEFAULT_TITLE)
    }
}

pub fn should_auto_start(mode: SystemAudioCaptureMode, meeting_active: bool) -> bool {
    meeting_active && capture_plan(mode, true, meeting_active).microphone
}

pub fn compose_completion(
    session: &MeetingSession,
    summary: MeetingSummary,
    now_ms: i64,
) -> (MeetingCompleted, ClientCommand) {
    let title = session.title().to_owned();
    let transcript: String = session
        .transcript()
        .chars()
        .take(SUMMARY_TRANSCRIPT_CHARS)
        .collect();
    let mut evidence = format!("Meeting: {title}\nSummary: {}", summary.summary);
    for action in &summary.actions {
        evidence.push_str("\nAction: ");
        evidence.push_str(action);
    }
    evidence.push_str("\n\n");
    evidence.push_str(&transcript);
    let command = ClientCommand {
        request_id: format!("meeting-{now_ms}"),
        command: Command::CaptureEvent {
            ingestion_key: format!("meeting:{now_ms}"),
            source: CaptureSource::Chat,
            occurred_at_ms: now_ms,
            recorded_at_ms: now_ms,
            text: Some(evidence),
            application: None,
            window_title: None,
            transcript_locator: None,
        },
    };
    let completed = MeetingCompleted {
        title,
        summary: summary.summary,
        actions: summary.actions,
    };
    (completed, command)
}

pub enum MeetingControl {
    Start {
        title: Option<String>,
    },
    Stop,
    Gate {
        active: bool,
        suggested_title: Option<String>,
    },
    FinalSegment {
        text: String,
    },
}

static CONTROLS: OnceLock<mpsc::Sender<MeetingControl>> = OnceLock::new();

pub fn install(sender: mpsc::Sender<MeetingControl>) {
    let _ = CONTROLS.set(sender);
}

fn notify(control: MeetingControl) {
    if let Some(sender) = CONTROLS.get() {
        let _ = sender.try_send(control);
    }
}

pub fn request_start(title: Option<String>) {
    notify(MeetingControl::Start { title });
}

pub fn request_stop() {
    notify(MeetingControl::Stop);
}

pub fn observe_gate(active: bool, suggested_title: Option<String>) {
    notify(MeetingControl::Gate {
        active,
        suggested_title,
    });
}

pub fn observe_final_segment(text: &str) {
    if !text.trim().is_empty() {
        notify(MeetingControl::FinalSegment {
            text: text.to_owned(),
        });
    }
}

pub struct MeetingRuntime {
    receiver: mpsc::Receiver<MeetingControl>,
    captures: mpsc::Sender<ClientCommand>,
    mode: SystemAudioCaptureMode,
    cancellation: CancellationToken,
    classifying: Arc<AtomicBool>,
}

pub fn channel(
    captures: mpsc::Sender<ClientCommand>,
) -> (mpsc::Sender<MeetingControl>, MeetingRuntime) {
    let (sender, receiver) = mpsc::channel(CONTROL_QUEUE_CAPACITY);
    (
        sender,
        MeetingRuntime {
            receiver,
            captures,
            mode: SystemAudioCaptureMode::default(),
            cancellation: CancellationToken::new(),
            classifying: Arc::new(AtomicBool::new(false)),
        },
    )
}

impl MeetingRuntime {
    pub async fn run(mut self) {
        let mut session: Option<MeetingSession> = None;
        loop {
            let control = tokio::select! {
                () = self.cancellation.cancelled() => break,
                control = self.receiver.recv() => match control {
                    Some(control) => control,
                    None => break,
                },
            };
            match control {
                MeetingControl::Start { title } => {
                    if session.is_none() {
                        session = Some(MeetingSession::new(title, true));
                    }
                }
                MeetingControl::Stop => {
                    if let Some(finished) = session.take() {
                        self.finish(finished);
                    }
                }
                MeetingControl::Gate {
                    active: true,
                    suggested_title,
                } => {
                    if session.is_none() && should_auto_start(self.mode, true) {
                        session = Some(MeetingSession::new(suggested_title, false));
                    }
                }
                MeetingControl::Gate { active: false, .. } => {
                    if session.as_ref().is_some_and(|current| !current.is_manual())
                        && let Some(finished) = session.take()
                    {
                        self.finish(finished);
                    }
                }
                MeetingControl::FinalSegment { text } => {
                    if let Some(current) = &mut session {
                        current.push_final(&text);
                        self.maybe_classify(current, &text);
                    }
                }
            }
        }
        self.cancellation.cancel();
    }

    fn maybe_classify(&self, session: &mut MeetingSession, text: &str) {
        let source: String = text.trim().chars().take(INSIGHT_SOURCE_CHARS).collect();
        if source.is_empty()
            || self.classifying.load(Ordering::Acquire)
            || !session.limiter.allow(Instant::now())
        {
            return;
        }
        self.classifying.store(true, Ordering::Release);
        let classifying = Arc::clone(&self.classifying);
        let cancellation = self.cancellation.clone();
        tokio::spawn(async move {
            let kind = classify(&source, &cancellation).await;
            classifying.store(false, Ordering::Release);
            if let Some(kind) = kind {
                NativeEvent::MeetingInsight(MeetingInsight {
                    kind: kind.name().to_owned(),
                    text: kind.text().to_owned(),
                    source_text: source,
                })
                .send();
            }
        });
    }

    fn finish(&self, session: MeetingSession) {
        let captures = self.captures.clone();
        let cancellation = self.cancellation.clone();
        tokio::spawn(async move {
            if session.transcript().trim().is_empty() {
                return;
            }
            let prompt = summary_prompt(session.transcript());
            let output = tokio::select! {
                () = cancellation.cancelled() => return,
                output = crate::local_ai::respond(&prompt) => output,
            };
            let summary = output
                .as_deref()
                .and_then(parse_summary)
                .unwrap_or_else(|| fallback_summary(session.transcript()));
            let (completed, capture) =
                compose_completion(&session, summary, chrono::Utc::now().timestamp_millis());
            let _ = captures.send(capture).await;
            NativeEvent::MeetingCompleted(completed).send();
        });
    }
}

async fn classify(source: &str, cancellation: &CancellationToken) -> Option<InsightKind> {
    if crate::local_ai::is_available() {
        let prompt = classification_prompt(source);
        let output = tokio::select! {
            () = cancellation.cancelled() => return None,
            output = crate::local_ai::summarize(&prompt) => output,
        };
        if let Some(parsed) = output.as_deref().and_then(parse_classification) {
            return parsed;
        }
    }
    classify_heuristic(source)
}

#[cfg(test)]
mod tests {
    use super::*;
    use zkr::{MemoryDb, PersonId, RememberInput, SourceKind, TenantId};

    #[test]
    fn heuristic_classification_matches_the_reference_table() {
        let table: &[(&str, Option<InsightKind>)] = &[
            ("We agreed to ship on Friday", Some(InsightKind::Decision)),
            ("Let's go with option B", Some(InsightKind::Decision)),
            ("That plan is approved", Some(InsightKind::Decision)),
            ("We should revisit pricing", Some(InsightKind::Decision)),
            ("I'll send the notes", Some(InsightKind::Action)),
            ("Let me check with legal", Some(InsightKind::Action)),
            ("We will review tomorrow", Some(InsightKind::Action)),
            ("You gonna own the rollout", Some(InsightKind::Action)),
            ("what time works for everyone", Some(InsightKind::Response)),
            ("Is that okay?", Some(InsightKind::Response)),
            ("The weather is nice today", None),
            ("Willow trees line the road", None),
            ("", None),
            ("   ", None),
        ];
        for (utterance, expected) in table {
            assert_eq!(classify_heuristic(utterance), *expected, "{utterance}");
        }
    }

    #[test]
    fn model_classification_words_are_parsed_leniently() {
        assert_eq!(
            parse_classification("decision"),
            Some(Some(InsightKind::Decision))
        );
        assert_eq!(
            parse_classification("  Action."),
            Some(Some(InsightKind::Action))
        );
        assert_eq!(
            parse_classification("Response for that"),
            Some(Some(InsightKind::Response))
        );
        assert_eq!(parse_classification("none"), Some(None));
        assert_eq!(parse_classification("unsure"), None);
        assert_eq!(parse_classification(""), None);
    }

    #[test]
    fn insights_are_rate_limited_to_one_per_interval() {
        let mut limiter = InsightLimiter::default();
        let start = Instant::now();
        assert!(limiter.allow(start));
        assert!(!limiter.allow(start + Duration::from_secs(19)));
        assert!(limiter.allow(start + INSIGHT_INTERVAL));
        assert!(!limiter.allow(start + INSIGHT_INTERVAL));
    }

    #[test]
    fn summary_json_is_parsed_from_fenced_output() {
        let output = "Sure, here you go:\n```json\n{\"summary\":\"We aligned on launch. \
                      Follow-ups were assigned.\",\"actions\":[\"Ship beta\",\"  \",\"Email QA\"]}\n```";
        let summary = parse_summary(output).unwrap_or_else(|| panic!("summary parses"));
        assert_eq!(
            summary.summary,
            "We aligned on launch. Follow-ups were assigned."
        );
        assert_eq!(summary.actions, vec!["Ship beta", "Email QA"]);
    }

    #[test]
    fn unusable_summary_output_falls_back_to_leading_sentences() {
        assert!(parse_summary("no json here").is_none());
        assert!(parse_summary("{\"actions\":[\"x\"]}").is_none());
        assert!(parse_summary("{not valid}").is_none());
        let fallback =
            fallback_summary("First point. Second\npoint! Third point that must not appear.");
        assert_eq!(fallback.summary, "First point. Second point!");
        assert!(fallback.actions.is_empty());
    }

    #[test]
    fn sessions_accumulate_final_segments_within_the_raw_bound() {
        let mut session = MeetingSession::new(Some("  ".to_owned()), true);
        assert_eq!(session.title(), "Meeting");
        session.push_final("  hello team  ");
        session.push_final("");
        session.push_final(&"x".repeat(RAW_TRANSCRIPT_CHARS));
        session.push_final("overflow is dropped");
        assert!(session.transcript().starts_with("hello team\n"));
        assert!(session.transcript().chars().count() <= RAW_TRANSCRIPT_CHARS);
        assert!(!session.transcript().contains("overflow"));
    }

    #[test]
    fn auto_start_follows_the_capture_policy() {
        assert!(should_auto_start(
            SystemAudioCaptureMode::OnlyDuringMeetings,
            true
        ));
        assert!(!should_auto_start(
            SystemAudioCaptureMode::OnlyDuringMeetings,
            false
        ));
        assert!(should_auto_start(SystemAudioCaptureMode::Always, true));
    }

    #[test]
    fn completed_meetings_compose_a_capture_stored_as_a_conversation_source() {
        let mut session = MeetingSession::new(Some("Standup".to_owned()), false);
        session.push_final("We agreed to ship on Friday.");
        session.push_final("I'll email the release notes.");
        let (completed, capture) = compose_completion(
            &session,
            MeetingSummary {
                summary: "Team agreed to ship Friday.".to_owned(),
                actions: vec!["Email release notes".to_owned()],
            },
            10,
        );
        assert_eq!(completed.title, "Standup");
        assert_eq!(completed.summary, "Team agreed to ship Friday.");
        assert_eq!(completed.actions, vec!["Email release notes"]);
        let Command::CaptureEvent {
            ingestion_key,
            source,
            occurred_at_ms,
            recorded_at_ms,
            text: Some(evidence),
            ..
        } = capture.command
        else {
            panic!("capture command composes");
        };
        assert_eq!(source, CaptureSource::Chat);
        assert_eq!(ingestion_key, "meeting:10");
        assert!(evidence.contains("Meeting: Standup"));
        assert!(evidence.contains("Action: Email release notes"));
        assert!(evidence.contains("We agreed to ship on Friday."));

        let path = std::env::temp_dir().join(format!(
            "omi-v4-meeting-{}-{}.sqlite3",
            std::process::id(),
            chrono::Utc::now().timestamp_millis()
        ));
        let mut database = MemoryDb::open(&path)
            .unwrap_or_else(|error_value| panic!("memory opens: {error_value}"));
        let remembered = database
            .remember(RememberInput {
                tenant_id: TenantId::new("tenant-1")
                    .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
                person_id: PersonId::new("person-1")
                    .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
                ingestion_key: Some(ingestion_key),
                kind: SourceKind::Conversation,
                text: evidence,
                captured_at: occurred_at_ms,
                recorded_at: recorded_at_ms,
                claim: None,
            })
            .unwrap_or_else(|error_value| panic!("meeting stores: {error_value}"));
        assert!(!remembered.source_id.0.is_empty());
        drop(database);
        let _ = std::fs::remove_file(path);
    }
}
