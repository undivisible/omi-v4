use crate::capture_policy::{CapturePlan, SystemAudioCaptureMode, capture_plan};
use crate::signals::{
    CaptureSource, ClientCommand, Command, MeetingCompleted, MeetingInsight, NativeError,
    NativeEvent, TranscriptionAuth,
};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const INSIGHT_INTERVAL: Duration = Duration::from_secs(20);
pub const SUMMARY_TRANSCRIPT_CHARS: usize = 12_000;
pub const RAW_TRANSCRIPT_CHARS: usize = 48_000;
const INSIGHT_SOURCE_CHARS: usize = 500;
const ANSWER_CONTEXT_CHARS: usize = 1_200;
const ANSWER_CHARS: usize = 360;
pub const MAX_JOTS: usize = 200;
const JOT_CHARS: usize = 500;
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

#[derive(Clone, Debug, Default, Eq, PartialEq, serde::Deserialize, serde::Serialize)]
pub struct NoteSection {
    #[serde(default)]
    pub heading: String,
    #[serde(default)]
    pub points: Vec<String>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MeetingNote {
    pub title: Option<String>,
    pub summary: String,
    pub participants: Vec<String>,
    pub sections: Vec<NoteSection>,
    pub decisions: Vec<String>,
    pub actions: Vec<String>,
}

impl MeetingNote {
    pub fn key_points(&self) -> Vec<String> {
        self.sections
            .iter()
            .flat_map(|section| section.points.iter().cloned())
            .collect()
    }
}

pub fn note_prompt(transcript: &str, jots: &[String], title: &str) -> String {
    let bounded: String = transcript.chars().take(SUMMARY_TRANSCRIPT_CHARS).collect();
    let jot_block = if jots.is_empty() {
        String::new()
    } else {
        let mut block = String::from(
            "\n\nThe attendee jotted these rough notes during the meeting. Expand \
                          and polish them into the note, keeping their intent and ordering, and \
                          fill in surrounding details from the transcript:\n",
        );
        for jot in jots {
            block.push_str("- ");
            block.push_str(jot);
            block.push('\n');
        }
        block
    };
    format!(
        "You are a meeting note taker. Working title: {title}. From the transcript below, write \
         a polished structured meeting note. Return ONLY valid JSON in this exact format: \
         {{\"title\":\"short descriptive title\",\"summary\":\"2-3 sentence executive summary\",\
         \"participants\":[\"names actually mentioned, or empty\"],\
         \"sections\":[{{\"heading\":\"topic\",\"points\":[\"key point\"]}}],\
         \"decisions\":[\"decisions made\"],\"actions\":[\"action items\"]}}\
         {jot_block}\n\nTranscript:\n{bounded}"
    )
}

#[derive(serde::Deserialize)]
struct NotePayload {
    #[serde(default)]
    title: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    participants: Vec<String>,
    #[serde(default)]
    sections: Vec<NoteSection>,
    #[serde(default)]
    decisions: Vec<String>,
    #[serde(default)]
    actions: Vec<String>,
}

fn clean_list(values: Vec<String>) -> Vec<String> {
    values
        .into_iter()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .collect()
}

pub fn parse_note(output: &str) -> Option<MeetingNote> {
    let start = output.find('{')?;
    let end = output.rfind('}')?;
    let payload: NotePayload = serde_json::from_str(output.get(start..=end)?).ok()?;
    let summary = payload.summary.trim().to_owned();
    (!summary.is_empty()).then(|| MeetingNote {
        title: Some(payload.title.trim().to_owned()).filter(|value| !value.is_empty()),
        summary,
        participants: clean_list(payload.participants),
        sections: payload
            .sections
            .into_iter()
            .map(|section| NoteSection {
                heading: section.heading.trim().to_owned(),
                points: clean_list(section.points),
            })
            .filter(|section| !section.points.is_empty())
            .collect(),
        decisions: clean_list(payload.decisions),
        actions: clean_list(payload.actions),
    })
}

pub fn fallback_note(transcript: &str, jots: &[String]) -> MeetingNote {
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
    let jot_section = (!jots.is_empty()).then(|| NoteSection {
        heading: "Notes".to_owned(),
        points: jots.to_vec(),
    });
    MeetingNote {
        title: None,
        summary: summary.split_whitespace().collect::<Vec<_>>().join(" "),
        participants: Vec::new(),
        sections: jot_section.into_iter().collect(),
        decisions: Vec::new(),
        actions: Vec::new(),
    }
}

fn format_stamp(unix_ms: i64) -> String {
    chrono::DateTime::from_timestamp_millis(unix_ms)
        .map(|stamp| stamp.format("%Y-%m-%d %H:%M UTC").to_string())
        .unwrap_or_default()
}

pub fn note_markdown(
    note: &MeetingNote,
    title: &str,
    started_at_ms: i64,
    ended_at_ms: i64,
) -> String {
    let mut markdown = format!(
        "# {}\n\n{} — {}\n",
        note.title.as_deref().unwrap_or(title),
        format_stamp(started_at_ms),
        format_stamp(ended_at_ms),
    );
    if !note.participants.is_empty() {
        markdown.push_str("\nAttendees: ");
        markdown.push_str(&note.participants.join(", "));
        markdown.push('\n');
    }
    if !note.summary.is_empty() {
        markdown.push_str("\n## Summary\n\n");
        markdown.push_str(&note.summary);
        markdown.push('\n');
    }
    for section in &note.sections {
        markdown.push_str("\n## ");
        markdown.push_str(if section.heading.is_empty() {
            "Discussion"
        } else {
            &section.heading
        });
        markdown.push_str("\n\n");
        for point in &section.points {
            markdown.push_str("- ");
            markdown.push_str(point);
            markdown.push('\n');
        }
    }
    if !note.decisions.is_empty() {
        markdown.push_str("\n## Decisions\n\n");
        for decision in &note.decisions {
            markdown.push_str("- ");
            markdown.push_str(decision);
            markdown.push('\n');
        }
    }
    if !note.actions.is_empty() {
        markdown.push_str("\n## Action items\n\n");
        for action in &note.actions {
            markdown.push_str("- [ ] ");
            markdown.push_str(action);
            markdown.push('\n');
        }
    }
    markdown
}

pub fn metadata_json(
    note: &MeetingNote,
    title: &str,
    started_at_ms: i64,
    ended_at_ms: i64,
) -> String {
    serde_json::json!({
        "kind": "meeting",
        "title": note.title.as_deref().unwrap_or(title),
        "startedAtMs": started_at_ms,
        "endedAtMs": ended_at_ms,
        "participants": note.participants,
        "keyPoints": note.key_points(),
        "decisions": note.decisions,
        "actions": note.actions,
    })
    .to_string()
}

pub fn answer_prompt(question: &str, context: &str) -> String {
    let bounded: String = context.chars().take(ANSWER_CONTEXT_CHARS).collect();
    format!(
        "You are quietly assisting someone in a live meeting. A question just came up. Using the \
         recent transcript for context, suggest a concise, confident answer or talking point (1-2 \
         sentences, plain text, no preamble). Recent transcript:\n{bounded}\n\nQuestion: \
         {question}"
    )
}

pub fn clean_answer(output: &str) -> Option<String> {
    let answer: String = output
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(ANSWER_CHARS)
        .collect();
    (!answer.is_empty()).then_some(answer)
}

#[derive(Debug)]
pub struct MeetingSession {
    title: Option<String>,
    manual: bool,
    transcript: String,
    limiter: InsightLimiter,
    started_at_ms: i64,
    jots: Vec<String>,
}

impl MeetingSession {
    pub fn new(title: Option<String>, manual: bool) -> Self {
        Self::new_at(title, manual, chrono::Utc::now().timestamp_millis())
    }

    pub fn new_at(title: Option<String>, manual: bool, started_at_ms: i64) -> Self {
        Self {
            title: title.filter(|value| !value.trim().is_empty()),
            manual,
            transcript: String::new(),
            limiter: InsightLimiter::default(),
            started_at_ms,
            jots: Vec::new(),
        }
    }

    pub fn started_at_ms(&self) -> i64 {
        self.started_at_ms
    }

    pub fn push_jot(&mut self, text: &str) {
        let text: String = text.trim().chars().take(JOT_CHARS).collect();
        if text.is_empty() || self.jots.len() >= MAX_JOTS {
            return;
        }
        self.jots.push(text);
    }

    pub fn jots(&self) -> &[String] {
        &self.jots
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

    pub fn upgrade_to_manual(&mut self, title: Option<String>) {
        self.manual = true;
        if let Some(title) = title.filter(|value| !value.trim().is_empty()) {
            self.title = Some(title);
        }
    }
}

pub fn should_auto_start(mode: SystemAudioCaptureMode, meeting_active: bool) -> bool {
    meeting_active && capture_plan(mode, true, meeting_active).microphone
}

pub fn compose_completion(
    session: &MeetingSession,
    note: MeetingNote,
    now_ms: i64,
) -> (MeetingCompleted, ClientCommand) {
    let title = note
        .title
        .clone()
        .unwrap_or_else(|| session.title().to_owned());
    let started_at_ms = session.started_at_ms();
    let markdown = note_markdown(&note, session.title(), started_at_ms, now_ms);
    let metadata = metadata_json(&note, session.title(), started_at_ms, now_ms);
    let transcript: String = session
        .transcript()
        .chars()
        .take(SUMMARY_TRANSCRIPT_CHARS)
        .collect();
    let mut evidence = markdown.clone();
    evidence.push_str("\n## Transcript\n\n");
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
        summary: note.summary,
        actions: note.actions,
        started_at_ms,
        ended_at_ms: now_ms,
        participants: note.participants,
        key_points: note
            .sections
            .iter()
            .flat_map(|section| section.points.iter().cloned())
            .collect(),
        decisions: note.decisions,
        note_markdown: markdown,
        metadata_json: metadata,
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
    Jot {
        text: String,
    },
    ProvideAuth {
        auth: TranscriptionAuth,
        trusted_worker_origin: Option<String>,
    },
    SetMode {
        mode: SystemAudioCaptureMode,
    },
}

pub fn capture_allowed(mode: SystemAudioCaptureMode, session_active: bool) -> bool {
    capture_plan(mode, true, session_active).system_audio && session_active
}

#[derive(Default)]
pub struct CaptureSlot<H> {
    handle: Option<H>,
    pending: Option<(TranscriptionAuth, Option<String>)>,
}

impl<H> CaptureSlot<H> {
    pub fn new() -> Self {
        Self {
            handle: None,
            pending: None,
        }
    }

    pub fn provide(&mut self, auth: TranscriptionAuth, trusted_worker_origin: Option<String>) {
        self.handle = None;
        self.pending = Some((auth, trusted_worker_origin));
    }

    pub fn sync(
        &mut self,
        mode: SystemAudioCaptureMode,
        session_active: bool,
        start: impl FnOnce(CapturePlan, TranscriptionAuth, Option<String>) -> Option<H>,
    ) {
        if !capture_allowed(mode, session_active) {
            self.handle = None;
            return;
        }
        if self.handle.is_none()
            && let Some((auth, trusted_worker_origin)) = self.pending.take()
        {
            self.handle = start(
                capture_plan(mode, true, session_active),
                auth,
                trusted_worker_origin,
            );
        }
    }

    pub fn stop(&mut self) {
        self.handle = None;
        self.pending = None;
    }

    pub fn active(&self) -> bool {
        self.handle.is_some()
    }
}

static CONTROLS: RwLock<Option<mpsc::Sender<MeetingControl>>> = RwLock::new(None);

pub fn install(sender: mpsc::Sender<MeetingControl>) {
    *CONTROLS
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(sender);
}

fn control_sender() -> Option<mpsc::Sender<MeetingControl>> {
    CONTROLS
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

fn notify(control: MeetingControl) -> bool {
    let Some(sender) = control_sender() else {
        return false;
    };
    match sender.try_send(control) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) => {
            eprintln!(
                "omi meeting control queue is full ({CONTROL_QUEUE_CAPACITY} slots); dropping a non-critical event"
            );
            false
        }
        Err(mpsc::error::TrySendError::Closed(_)) => false,
    }
}

pub fn request_start(title: Option<String>) -> bool {
    notify(MeetingControl::Start { title })
}

pub fn request_stop() -> bool {
    notify(MeetingControl::Stop)
}

pub fn request_jot(text: String) -> bool {
    notify(MeetingControl::Jot { text })
}

pub fn observe_gate(active: bool, suggested_title: Option<String>) {
    notify(MeetingControl::Gate {
        active,
        suggested_title,
    });
}

pub fn provide_auth(auth: TranscriptionAuth, trusted_worker_origin: Option<String>) {
    notify(MeetingControl::ProvideAuth {
        auth,
        trusted_worker_origin,
    });
}

pub fn set_mode(mode: SystemAudioCaptureMode) {
    notify(MeetingControl::SetMode { mode });
}

/// Delivers a final transcript segment to the meeting runtime.
///
/// Unlike `notify`, this must not silently drop the segment when the control
/// queue is momentarily full: losing final transcript text is worse than a
/// bit of latency, so a full queue falls back to a blocking send.
pub async fn observe_final_segment(text: &str) {
    if text.trim().is_empty() {
        return;
    }
    let Some(sender) = control_sender() else {
        return;
    };
    let control = MeetingControl::FinalSegment {
        text: text.to_owned(),
    };
    match sender.try_send(control) {
        Ok(()) => {}
        Err(mpsc::error::TrySendError::Full(control)) => {
            eprintln!(
                "omi meeting control queue is full ({CONTROL_QUEUE_CAPACITY} slots); blocking to deliver a final transcript segment"
            );
            if sender.send(control).await.is_err() {
                eprintln!("omi meeting control queue closed; final transcript segment lost");
            }
        }
        Err(mpsc::error::TrySendError::Closed(_)) => {
            eprintln!("omi meeting control queue closed; final transcript segment lost");
        }
    }
}

pub struct MeetingRuntime {
    receiver: mpsc::Receiver<MeetingControl>,
    captures: mpsc::Sender<ClientCommand>,
    mode: SystemAudioCaptureMode,
    cancellation: CancellationToken,
    classifying: Arc<AtomicBool>,
    capture: CaptureSlot<crate::meeting_capture::MeetingCaptureHandle>,
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
            capture: CaptureSlot::new(),
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
                    match &mut session {
                        Some(current) => current.upgrade_to_manual(title),
                        None => session = Some(MeetingSession::new(title, true)),
                    }
                    self.sync_capture(session.is_some());
                }
                MeetingControl::Stop => {
                    self.capture.stop();
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
                    self.sync_capture(session.is_some());
                }
                MeetingControl::Gate { active: false, .. } => {
                    if session.as_ref().is_some_and(|current| !current.is_manual())
                        && let Some(finished) = session.take()
                    {
                        self.capture.stop();
                        self.finish(finished);
                    }
                }
                MeetingControl::FinalSegment { text } => {
                    if let Some(current) = &mut session {
                        current.push_final(&text);
                        self.maybe_classify(current, &text);
                    }
                }
                MeetingControl::Jot { text } => {
                    if let Some(current) = &mut session {
                        current.push_jot(&text);
                    }
                }
                MeetingControl::ProvideAuth {
                    auth,
                    trusted_worker_origin,
                } => {
                    self.capture.provide(auth, trusted_worker_origin);
                    self.sync_capture(session.is_some());
                }
                MeetingControl::SetMode { mode } => {
                    self.mode = mode;
                    self.sync_capture(session.is_some());
                }
            }
        }
        self.capture.stop();
        self.cancellation.cancel();
    }

    fn sync_capture(&mut self, session_active: bool) {
        self.capture
            .sync(self.mode, session_active, |plan, auth, origin| {
                match crate::meeting_capture::start(plan, auth, origin) {
                    Ok(handle) => Some(handle),
                    Err(message) => {
                        if plan.microphone {
                            NativeEvent::Error(NativeError {
                                request_id: Some(
                                    crate::meeting_capture::CAPTURE_STREAM_ID.to_owned(),
                                ),
                                code: "meeting_system_audio_unavailable".to_owned(),
                                message,
                                retryable: true,
                            })
                            .send();
                        }
                        None
                    }
                }
            });
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
        let context: String = {
            let transcript = session.transcript();
            let skip = transcript
                .chars()
                .count()
                .saturating_sub(ANSWER_CONTEXT_CHARS);
            transcript.chars().skip(skip).collect()
        };
        tokio::spawn(async move {
            let kind = classify(&source, &cancellation).await;
            let text = match kind {
                Some(InsightKind::Response) => suggest_answer(&source, &context, &cancellation)
                    .await
                    .unwrap_or_else(|| InsightKind::Response.text().to_owned()),
                Some(kind) => kind.text().to_owned(),
                None => String::new(),
            };
            classifying.store(false, Ordering::Release);
            if let Some(kind) = kind {
                NativeEvent::MeetingInsight(MeetingInsight {
                    kind: kind.name().to_owned(),
                    text,
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
            let now_ms = chrono::Utc::now().timestamp_millis();
            let prompt = note_prompt(session.transcript(), session.jots(), session.title());
            let output = tokio::select! {
                () = cancellation.cancelled() => return,
                output = generate_note_output(&prompt) => output,
            };
            let note = output
                .as_deref()
                .and_then(parse_note)
                .unwrap_or_else(|| fallback_note(session.transcript(), session.jots()));
            let (completed, capture) = compose_completion(&session, note, now_ms);
            let _ = captures.send(capture).await;
            NativeEvent::MeetingCompleted(completed).send();
        });
    }
}

async fn generate_note_output(prompt: &str) -> Option<String> {
    if let Some(output) = crate::local_ai::respond(prompt).await {
        return Some(output);
    }
    let key = crate::dev_gemini::api_key()?;
    crate::dev_gemini::generate(&key, prompt).await
}

async fn suggest_answer(
    question: &str,
    context: &str,
    cancellation: &CancellationToken,
) -> Option<String> {
    let prompt = answer_prompt(question, context);
    let output = tokio::select! {
        () = cancellation.cancelled() => return None,
        output = generate_note_output(&prompt) => output,
    };
    output.as_deref().and_then(clean_answer)
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
    fn note_json_is_parsed_from_fenced_output() {
        let output = "Sure, here you go:\n```json\n{\"title\":\" Launch Sync \",\"summary\":\"We \
                      aligned on launch. Follow-ups were assigned.\",\"participants\":[\"Ana\",\" \
                      \"],\"sections\":[{\"heading\":\"Launch\",\"points\":[\"Beta ships \
                      Friday\",\"  \"]},{\"heading\":\"Empty\",\"points\":[]}],\"decisions\":\
                      [\"Ship Friday\"],\"actions\":[\"Ship beta\",\"  \",\"Email QA\"]}\n```";
        let note = parse_note(output).unwrap_or_else(|| panic!("note parses"));
        assert_eq!(note.title.as_deref(), Some("Launch Sync"));
        assert_eq!(
            note.summary,
            "We aligned on launch. Follow-ups were assigned."
        );
        assert_eq!(note.participants, vec!["Ana"]);
        assert_eq!(note.sections.len(), 1);
        assert_eq!(note.sections[0].points, vec!["Beta ships Friday"]);
        assert_eq!(note.key_points(), vec!["Beta ships Friday"]);
        assert_eq!(note.decisions, vec!["Ship Friday"]);
        assert_eq!(note.actions, vec!["Ship beta", "Email QA"]);
    }

    #[test]
    fn unusable_note_output_falls_back_to_leading_sentences_and_jots() {
        assert!(parse_note("no json here").is_none());
        assert!(parse_note("{\"actions\":[\"x\"]}").is_none());
        assert!(parse_note("{not valid}").is_none());
        let jots = vec!["pricing follow-up".to_owned()];
        let fallback = fallback_note(
            "First point. Second\npoint! Third point that must not appear.",
            &jots,
        );
        assert_eq!(fallback.summary, "First point. Second point!");
        assert!(fallback.actions.is_empty());
        assert_eq!(fallback.sections.len(), 1);
        assert_eq!(fallback.sections[0].heading, "Notes");
        assert_eq!(fallback.sections[0].points, jots);
        assert!(fallback_note("x.", &[]).sections.is_empty());
    }

    #[test]
    fn note_markdown_renders_every_populated_section() {
        let note = MeetingNote {
            title: Some("Launch Sync".to_owned()),
            summary: "We aligned on launch.".to_owned(),
            participants: vec!["Ana".to_owned(), "Ben".to_owned()],
            sections: vec![NoteSection {
                heading: String::new(),
                points: vec!["Beta ships Friday".to_owned()],
            }],
            decisions: vec!["Ship Friday".to_owned()],
            actions: vec!["Email QA".to_owned()],
        };
        let markdown = note_markdown(&note, "Meeting", 0, 60_000);
        assert!(markdown.starts_with("# Launch Sync\n"));
        assert!(markdown.contains("1970-01-01 00:00 UTC — 1970-01-01 00:01 UTC"));
        assert!(markdown.contains("Attendees: Ana, Ben"));
        assert!(markdown.contains("## Summary\n\nWe aligned on launch."));
        assert!(markdown.contains("## Discussion\n\n- Beta ships Friday"));
        assert!(markdown.contains("## Decisions\n\n- Ship Friday"));
        assert!(markdown.contains("## Action items\n\n- [ ] Email QA"));
    }

    #[test]
    fn metadata_json_carries_structured_meeting_fields() {
        let note = MeetingNote {
            title: None,
            summary: "Short.".to_owned(),
            participants: vec!["Ana".to_owned()],
            sections: vec![NoteSection {
                heading: "Topic".to_owned(),
                points: vec!["A point".to_owned()],
            }],
            decisions: vec!["Decided".to_owned()],
            actions: vec!["Do it".to_owned()],
        };
        let metadata: serde_json::Value =
            serde_json::from_str(&metadata_json(&note, "Standup", 5, 9))
                .unwrap_or_else(|error_value| panic!("metadata parses: {error_value}"));
        assert_eq!(metadata["kind"], "meeting");
        assert_eq!(metadata["title"], "Standup");
        assert_eq!(metadata["startedAtMs"], 5);
        assert_eq!(metadata["endedAtMs"], 9);
        assert_eq!(metadata["participants"][0], "Ana");
        assert_eq!(metadata["keyPoints"][0], "A point");
        assert_eq!(metadata["decisions"][0], "Decided");
        assert_eq!(metadata["actions"][0], "Do it");
    }

    #[test]
    fn jots_are_trimmed_bounded_and_capped() {
        let mut session = MeetingSession::new_at(None, true, 0);
        session.push_jot("  pricing follow-up  ");
        session.push_jot("   ");
        session.push_jot(&"y".repeat(2 * JOT_CHARS));
        assert_eq!(session.jots()[0], "pricing follow-up");
        assert_eq!(session.jots()[1].chars().count(), JOT_CHARS);
        for index in 0..MAX_JOTS {
            session.push_jot(&format!("jot {index}"));
        }
        assert_eq!(session.jots().len(), MAX_JOTS);
    }

    #[test]
    fn note_prompt_embeds_jots_for_enhancement() {
        let with_jots = note_prompt("hello", &["pricing".to_owned()], "Sync");
        assert!(with_jots.contains("- pricing"));
        assert!(with_jots.contains("rough notes"));
        let without = note_prompt("hello", &[], "Sync");
        assert!(!without.contains("rough notes"));
    }

    #[test]
    fn suggested_answers_are_flattened_and_bounded() {
        assert_eq!(
            clean_answer("  The beta\nships Friday.  "),
            Some("The beta ships Friday.".to_owned())
        );
        assert!(clean_answer("   ").is_none());
        let long = clean_answer(&"word ".repeat(200)).unwrap_or_default();
        assert!(long.chars().count() <= ANSWER_CHARS);
        assert!(answer_prompt("When do we ship?", "context here").contains("When do we ship?"));
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
    fn manual_start_upgrades_an_auto_session_and_adopts_the_title() {
        let mut session = MeetingSession::new(Some("Zoom".to_owned()), false);
        session.push_final("early context");
        session.upgrade_to_manual(Some("Quarterly Review".to_owned()));
        assert!(session.is_manual());
        assert_eq!(session.title(), "Quarterly Review");
        assert!(session.transcript().contains("early context"));
        session.upgrade_to_manual(Some("  ".to_owned()));
        assert_eq!(session.title(), "Quarterly Review");
        session.upgrade_to_manual(None);
        assert_eq!(session.title(), "Quarterly Review");
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
    fn capture_slot_starts_only_with_auth_and_an_active_session() {
        struct FakeHandle(std::sync::Arc<AtomicBool>);
        impl Drop for FakeHandle {
            fn drop(&mut self) {
                self.0.store(true, Ordering::Release);
            }
        }
        let stopped = std::sync::Arc::new(AtomicBool::new(false));
        let mut slot: CaptureSlot<FakeHandle> = CaptureSlot::new();
        slot.sync(
            SystemAudioCaptureMode::OnlyDuringMeetings,
            true,
            |_, _, _| panic!("capture must not start without auth"),
        );
        slot.provide(TranscriptionAuth::Local, None);
        slot.sync(
            SystemAudioCaptureMode::OnlyDuringMeetings,
            false,
            |_, _, _| panic!("capture must not start without a session"),
        );
        slot.sync(SystemAudioCaptureMode::OnlyDuringMeetings, true, {
            let stopped = stopped.clone();
            move |plan, auth, origin| {
                assert!(plan.system_audio);
                assert!(matches!(auth, TranscriptionAuth::Local));
                assert_eq!(origin, None);
                Some(FakeHandle(stopped))
            }
        });
        assert!(slot.active());
        slot.sync(SystemAudioCaptureMode::Never, true, |_, _, _| {
            panic!("mode change must stop instead of starting")
        });
        assert!(!slot.active());
        assert!(stopped.load(Ordering::Acquire));
    }

    #[test]
    fn capture_slot_stops_when_the_session_ends() {
        let mut slot: CaptureSlot<()> = CaptureSlot::new();
        slot.provide(
            TranscriptionAuth::Local,
            Some("https://api.omi.example".to_owned()),
        );
        slot.sync(SystemAudioCaptureMode::Always, true, |_, _, origin| {
            assert_eq!(origin.as_deref(), Some("https://api.omi.example"));
            Some(())
        });
        assert!(slot.active());
        slot.sync(SystemAudioCaptureMode::Always, false, |_, _, _| {
            panic!("capture must not restart after the session ends")
        });
        assert!(!slot.active());
        assert!(!capture_allowed(SystemAudioCaptureMode::Always, false));
        assert!(!capture_allowed(SystemAudioCaptureMode::Never, true));
        assert!(capture_allowed(SystemAudioCaptureMode::Always, true));
    }

    #[test]
    fn completed_meetings_compose_a_capture_stored_as_a_conversation_source() {
        let mut session = MeetingSession::new_at(Some("Standup".to_owned()), false, 5);
        session.push_final("We agreed to ship on Friday.");
        session.push_final("I'll email the release notes.");
        let (completed, capture) = compose_completion(
            &session,
            MeetingNote {
                title: None,
                summary: "Team agreed to ship Friday.".to_owned(),
                participants: vec!["Ana".to_owned()],
                sections: vec![NoteSection {
                    heading: "Release".to_owned(),
                    points: vec!["Friday is the date".to_owned()],
                }],
                decisions: vec!["Ship Friday".to_owned()],
                actions: vec!["Email release notes".to_owned()],
            },
            10,
        );
        assert_eq!(completed.title, "Standup");
        assert_eq!(completed.summary, "Team agreed to ship Friday.");
        assert_eq!(completed.actions, vec!["Email release notes"]);
        assert_eq!(completed.started_at_ms, 5);
        assert_eq!(completed.ended_at_ms, 10);
        assert_eq!(completed.participants, vec!["Ana"]);
        assert_eq!(completed.key_points, vec!["Friday is the date"]);
        assert_eq!(completed.decisions, vec!["Ship Friday"]);
        assert!(completed.note_markdown.contains("# Standup"));
        assert!(
            completed
                .note_markdown
                .contains("- [ ] Email release notes")
        );
        assert!(completed.metadata_json.contains("\"kind\":\"meeting\""));
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
        assert!(evidence.contains("# Standup"));
        assert!(evidence.contains("- [ ] Email release notes"));
        assert!(evidence.contains("## Transcript"));
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
