use crate::capture_policy::{CapturePlan, SystemAudioCaptureMode, capture_plan};
use crate::meeting_capture::MeetingSpeaker;
use crate::signals::{
    CaptureSource, ClientCommand, Command, MeetingCompleted, MeetingInsight, MeetingStateChanged,
    MeetingTranscriptTurn, NativeError, NativeEvent, TranscriptionAuth,
};
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, RwLock};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

/// One-shot note generator injected by the runtime: given a prompt it produces
/// meeting-note text (or `None` on failure). This lets the configured assistant
/// provider (BALANCED tier) reach meeting-note generation without the meeting
/// module depending on the runtime's streaming provider types.
pub type NoteGenerator = Arc<
    dyn Fn(String, CancellationToken) -> Pin<Box<dyn Future<Output = Option<String>> + Send>>
        + Send
        + Sync,
>;

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

/// How long the detector gate must stay off before a manual session ends by
/// itself.
///
/// A manual session outlives the gate on purpose — the user asked for it, so a
/// momentary detection blind spot must not cut the recording. It must not
/// outlive the *call*, though, or a session started by hand records until the
/// app quits. The detector already debounces eight seconds of absence before
/// it reports the gate off, so this grace only has to cover the longer blind
/// spots (a browser tab renamed mid-call, a screen share taking over the
/// window title) rather than a flap.
pub const MANUAL_GATE_OFF_GRACE: Duration = Duration::from_secs(180);

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

/// An action item, with the owner the model could attribute it to.
///
/// Both reference assistants surface an owner next to every task — Meetily's
/// bundled `standard_meeting.json` template even asks for an owner column —
/// and an unowned action item is the single most common thing a reader has to
/// go back to the transcript for.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ActionItem {
    pub text: String,
    pub owner: Option<String>,
}

impl ActionItem {
    /// The one-line rendering used wherever an action is a plain string: the
    /// exported markdown checklist, the completion signal, and the evidence
    /// text the task extractor reads.
    pub fn line(&self) -> String {
        match self.owner.as_deref() {
            Some(owner) => format!("{} — {owner}", self.text),
            None => self.text.clone(),
        }
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct MeetingNote {
    pub title: Option<String>,
    pub summary: String,
    pub participants: Vec<String>,
    pub sections: Vec<NoteSection>,
    pub decisions: Vec<String>,
    pub actions: Vec<ActionItem>,
    pub open_questions: Vec<String>,
}

impl MeetingNote {
    pub fn key_points(&self) -> Vec<String> {
        self.sections
            .iter()
            .flat_map(|section| section.points.iter().cloned())
            .collect()
    }

    pub fn action_lines(&self) -> Vec<String> {
        self.actions.iter().map(ActionItem::line).collect()
    }
}

pub fn note_prompt(transcript: &str, jots: &[String], title: &str) -> String {
    build_note_prompt("transcript", "Transcript", transcript, jots, title)
}

/// The reduce half of the map-reduce summary: the same note prompt, told that
/// its source is the ordered condensed notes of a transcript too long to send
/// in one request rather than the transcript itself.
pub fn digest_note_prompt(digest: &str, jots: &[String], title: &str) -> String {
    build_note_prompt(
        "condensed transcript notes",
        "Condensed notes covering the whole meeting in order, one part per section of the \
         transcript",
        digest,
        jots,
        title,
    )
}

fn build_note_prompt(
    source_noun: &str,
    source_label: &str,
    source: &str,
    jots: &[String],
    title: &str,
) -> String {
    let bounded: String = source.chars().take(SUMMARY_TRANSCRIPT_CHARS).collect();
    let jot_block = if jots.is_empty() {
        String::new()
    } else {
        let mut block = String::from(
            "\n\nThe attendee jotted these rough notes during the meeting, in the order they \
             typed them. Expand and polish them into the note, keeping their intent and \
             ordering, and fill in surrounding details from the transcript. Weave each jot into \
             whichever section it belongs to instead of turning it into its own heading.\n",
        );
        for jot in jots {
            block.push_str("- ");
            block.push_str(jot);
            block.push('\n');
        }
        block
    };
    format!(
        "You are a meeting note taker. Working title: {title}. From the {source_noun} below, \
         write a polished structured meeting note. Return ONLY valid JSON in this exact format: \
         {{\"title\":\"short descriptive title\",\"summary\":\"2-3 sentence executive summary\",\
         \"participants\":[\"names actually mentioned, or empty\"],\
         \"sections\":[{{\"heading\":\"topic\",\"points\":[\"key point\"]}}],\
         \"decisions\":[\"decisions made\"],\
         \"actions\":[{{\"text\":\"what will be done\",\"owner\":\"who owns it, or omit\"}}],\
         \"openQuestions\":[\"questions raised but left unanswered\"]}}\n\n\
         Rules:\n\
         - Use only what the transcript and notes actually say. Never infer, never invent a \
         name, a date, or a number. If you are unsure about something, leave it out.\n\
         - The transcript is speech-to-text and the jotted notes are typed in a hurry, so both \
         contain errors. Read through them for the intended meaning.\n\
         - Transcript lines prefixed \"You:\" are the attendee running this app; lines prefixed \
         \"Them:\" or \"Speaker 1:\", \"Speaker 2:\" and so on are other people on the call, one \
         number per voice. Unprefixed lines could be anyone. Use those prefixes to attribute \
         decisions and to fill in action owners, and set an owner only when the transcript makes \
         it clear. A \"Speaker N\" label is not a name, so never present it as one.\n\
         - Give every section a concrete topic heading and at least two specific points. Do not \
         create generic \"Overview\", \"Introduction\", \"Summary\", or \"Participants\" \
         sections; the summary and participants have their own fields.\n\
         - Keep points specific and concrete. Prefer the actual numbers, names, and commitments \
         over abstractions.\n\
         - Leave any array empty rather than padding it.\
         {jot_block}\n\n{source_label}:\n{bounded}"
    )
}

/// How much of the end of a chunk is repeated at the start of the next one, so
/// an exchange split across a boundary is still summarized in context.
const CHUNK_OVERLAP_CHARS: usize = 600;
/// The shortest a part of the combined digest may be, whatever the part count.
const MIN_DIGEST_PART_CHARS: usize = 400;

/// Splits a transcript into overlapping chunks that each fit one summarization
/// request.
///
/// A transcript within the budget comes back as a single chunk, which is the
/// path every ordinary meeting takes. Longer ones are cut at the last line,
/// sentence, or word boundary in the final quarter of each window, so a chunk
/// never starts mid-utterance, and every chunk after the first repeats the tail
/// of its predecessor.
pub fn transcript_chunks(transcript: &str) -> Vec<String> {
    let chars: Vec<char> = transcript.trim().chars().collect();
    if chars.is_empty() {
        return Vec::new();
    }
    if chars.len() <= SUMMARY_TRANSCRIPT_CHARS {
        return vec![chars.into_iter().collect()];
    }
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < chars.len() {
        let limit = start
            .saturating_add(SUMMARY_TRANSCRIPT_CHARS)
            .min(chars.len());
        let end = if limit == chars.len() {
            limit
        } else {
            split_point(&chars, start, limit)
        };
        let chunk: String = chars[start..end].iter().collect();
        let chunk = chunk.trim();
        if !chunk.is_empty() {
            chunks.push(chunk.to_owned());
        }
        if end >= chars.len() {
            break;
        }
        start = overlap_start(&chars, start, end);
    }
    chunks
}

/// The end of a chunk: the latest line break, sentence end, or word break in
/// the last quarter of the window, and the hard limit when the window holds
/// none of them.
fn split_point(chars: &[char], start: usize, limit: usize) -> usize {
    let earliest = start + (limit - start) * 3 / 4;
    let mut sentence = None;
    let mut word = None;
    for index in (earliest..limit).rev() {
        match chars[index] {
            '\n' => return index + 1,
            '.' | '!' | '?' => sentence = sentence.or(Some(index + 1)),
            character if character.is_whitespace() => word = word.or(Some(index + 1)),
            _ => {}
        }
    }
    sentence.or(word).unwrap_or(limit)
}

/// Where the next chunk begins: one overlap back from the end of this one,
/// advanced to the next line or sentence so the repeated text starts cleanly.
fn overlap_start(chars: &[char], start: usize, end: usize) -> usize {
    let raw = end.saturating_sub(CHUNK_OVERLAP_CHARS).max(start + 1);
    chars[raw..end]
        .iter()
        .position(|character| matches!(character, '\n' | '.' | '!' | '?'))
        .map_or(raw, |offset| raw + offset + 1)
}

/// The map half of the map-reduce summary: condense one chunk into plain text
/// that the reduce step can read, under the same grounding rules as the note
/// itself.
pub fn chunk_summary_prompt(chunk: &str, part: usize, total: usize, title: &str) -> String {
    format!(
        "You are condensing part {part} of {total} of a long meeting transcript. Working title: \
         {title}. Write plain text notes covering everything this part contains: what was \
         discussed, every decision, every commitment and who made it, every question left open, \
         and the numbers, names, and dates that were said.\n\n\
         Rules:\n\
         - Use only what this part of the transcript actually says. Never infer, never invent a \
         name, a date, or a number. If you are unsure about something, leave it out.\n\
         - The transcript is speech-to-text, so it contains errors. Read through them for the \
         intended meaning.\n\
         - Keep the speaker prefixes (\"You:\", \"Them:\", \"Speaker 1:\") when you attribute \
         something, so the final note can tell who said it.\n\
         - This is one part of a longer meeting. Do not write an overall conclusion, an \
         introduction, or a summary of the meeting as a whole, and do not guess at what the other \
         parts contain.\n\
         - Write short lines, one point each. No JSON, no headings, no preamble.\n\n\
         Transcript part {part} of {total}:\n{chunk}"
    )
}

/// Joins the per-chunk digests into the single body the reduce step reads.
///
/// Every part gets the same share of the budget, so the end of a long meeting
/// reaches the final note instead of being cut off by whatever came before it.
pub fn combine_chunk_digests(digests: &[String]) -> String {
    let total = digests.len().max(1);
    let budget = (SUMMARY_TRANSCRIPT_CHARS / total)
        .saturating_sub(48)
        .max(MIN_DIGEST_PART_CHARS);
    let mut combined = String::new();
    for (index, digest) in digests.iter().enumerate() {
        let bounded: String = digest.trim().chars().take(budget).collect();
        if bounded.is_empty() {
            continue;
        }
        if !combined.is_empty() {
            combined.push_str("\n\n");
        }
        combined.push_str(&format!("Part {} of {total}:\n", index + 1));
        combined.push_str(&bounded);
    }
    combined
}

#[derive(serde::Deserialize)]
struct ActionPayload {
    #[serde(default)]
    text: String,
    #[serde(default)]
    owner: String,
}

/// Accepts an action either as the structured object the prompt asks for or as
/// a bare string, which smaller models still fall back to.
#[derive(serde::Deserialize)]
#[serde(untagged)]
enum ActionEntry {
    Structured(ActionPayload),
    Line(String),
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
    actions: Vec<ActionEntry>,
    #[serde(default, rename = "openQuestions")]
    open_questions: Vec<String>,
}

fn clean_list(values: Vec<String>) -> Vec<String> {
    values
        .into_iter()
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
        .collect()
}

fn clean_actions(values: Vec<ActionEntry>) -> Vec<ActionItem> {
    values
        .into_iter()
        .map(|entry| match entry {
            ActionEntry::Structured(payload) => ActionItem {
                text: payload.text.trim().to_owned(),
                owner: Some(payload.owner.trim().to_owned()).filter(|value| !value.is_empty()),
            },
            ActionEntry::Line(text) => ActionItem {
                text: text.trim().to_owned(),
                owner: None,
            },
        })
        .filter(|action| !action.text.is_empty())
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
        actions: clean_actions(payload.actions),
        open_questions: clean_list(payload.open_questions),
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
        open_questions: Vec::new(),
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
            markdown.push_str(&action.text);
            if let Some(owner) = &action.owner {
                markdown.push_str(" — **");
                markdown.push_str(owner);
                markdown.push_str("**");
            }
            markdown.push('\n');
        }
    }
    if !note.open_questions.is_empty() {
        markdown.push_str("\n## Open questions\n\n");
        for question in &note.open_questions {
            markdown.push_str("- ");
            markdown.push_str(question);
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
        "actions": note.action_lines(),
        "openQuestions": note.open_questions,
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

/// How many diarized voices one meeting keeps numbers for. Beyond this the
/// roster stops growing and the segment falls back to the energy heuristic,
/// which is the behaviour a provider that never diarizes already gets.
const MAX_DIARIZED_SPEAKERS: usize = 16;

#[derive(Debug)]
struct RosterEntry {
    key: u64,
    local: u32,
    remote: u32,
    number: Option<u32>,
}

/// Resolves the transcription provider's diarization indices into the speaker
/// labels the transcript uses.
///
/// The provider numbers voices arbitrarily and has no idea which of them is
/// the person running the app; the two capture tracks do. So each diarized
/// index accumulates which side of the call the energy heuristic saw while it
/// was speaking, and the index that keeps coming back on the microphone track
/// is reported as `You`. Every other diarized voice gets a stable number, so
/// three people on the far end stop collapsing into one "Them".
#[derive(Debug, Default)]
pub struct SpeakerRoster {
    entries: Vec<RosterEntry>,
    assigned: u32,
}

impl SpeakerRoster {
    /// Real diarization takes precedence over the energy heuristic whenever
    /// the provider supplied an index; without one the heuristic's answer is
    /// passed through untouched.
    pub fn resolve(&mut self, diarized: Option<u64>, tracked: MeetingSpeaker) -> MeetingSpeaker {
        let Some(key) = diarized else {
            return tracked;
        };
        let position = match self.entries.iter().position(|entry| entry.key == key) {
            Some(position) => position,
            None if self.entries.len() < MAX_DIARIZED_SPEAKERS => {
                self.entries.push(RosterEntry {
                    key,
                    local: 0,
                    remote: 0,
                    number: None,
                });
                self.entries.len() - 1
            }
            None => return tracked,
        };
        let local = {
            let entry = &mut self.entries[position];
            match tracked {
                MeetingSpeaker::You => entry.local = entry.local.saturating_add(1),
                MeetingSpeaker::Them => entry.remote = entry.remote.saturating_add(1),
                MeetingSpeaker::Unknown | MeetingSpeaker::Diarized(_) => {}
            }
            entry.local > entry.remote
        };
        if local {
            return MeetingSpeaker::You;
        }
        let number = match self.entries[position].number {
            Some(number) => number,
            None => {
                self.assigned = self.assigned.saturating_add(1);
                self.entries[position].number = Some(self.assigned);
                self.assigned
            }
        };
        MeetingSpeaker::Diarized(number)
    }
}

#[derive(Debug)]
pub struct MeetingSession {
    title: Option<String>,
    manual: bool,
    transcript: String,
    last_speaker: Option<MeetingSpeaker>,
    roster: SpeakerRoster,
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
            last_speaker: None,
            roster: SpeakerRoster::default(),
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

    /// Appends a finalized segment, opening a new speaker turn whenever the
    /// side of the call changes and continuing the current turn otherwise.
    ///
    /// An unknown speaker never starts a labelled turn, so capture paths with
    /// no far end (the microphone-only fallback) read exactly as they did
    /// before speaker attribution existed.
    pub fn push_final(&mut self, speaker: MeetingSpeaker, text: &str) {
        let text = text.trim();
        let accumulated = self.transcript.chars().count();
        if text.is_empty() || accumulated >= RAW_TRANSCRIPT_CHARS {
            return;
        }
        let label = speaker.label();
        let continues =
            label.is_some() && self.last_speaker == Some(speaker) && !self.transcript.is_empty();
        let mut prefix = String::new();
        if continues {
            prefix.push(' ');
        } else {
            if !self.transcript.is_empty() {
                prefix.push('\n');
            }
            if let Some(label) = label {
                prefix.push_str(&label);
                prefix.push_str(": ");
            }
        }
        let remaining = RAW_TRANSCRIPT_CHARS.saturating_sub(accumulated);
        if prefix.chars().count() >= remaining {
            return;
        }
        self.transcript.push_str(&prefix);
        self.transcript
            .extend(text.chars().take(remaining - prefix.chars().count()));
        self.last_speaker = Some(speaker);
    }

    /// Combines the provider's diarization index, when there is one, with the
    /// side of the call the capture tracks heard.
    pub fn resolve_speaker(
        &mut self,
        diarized: Option<u64>,
        tracked: MeetingSpeaker,
    ) -> MeetingSpeaker {
        self.roster.resolve(diarized, tracked)
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
    let actions = note.action_lines();
    let key_points = note.key_points();
    let completed = MeetingCompleted {
        title,
        summary: note.summary,
        actions,
        started_at_ms,
        ended_at_ms: now_ms,
        participants: note.participants,
        key_points,
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
        speaker: MeetingSpeaker,
        diarized: Option<u64>,
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
    ConfigureNoteProvider(NoteGenerator),
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

/// Installs the note generator (the configured BALANCED-tier provider) so
/// meeting notes are produced by the user's provider rather than falling back
/// to sentence-clipping. Delivered the same way transcription auth is.
pub fn configure_note_provider(generator: NoteGenerator) {
    notify(MeetingControl::ConfigureNoteProvider(generator));
}

/// Delivers a final transcript segment to the meeting runtime.
///
/// Unlike `notify`, this must not silently drop the segment when the control
/// queue is momentarily full: losing final transcript text is worse than a
/// bit of latency, so a full queue falls back to a blocking send.
///
/// The speaker is sampled here rather than inside the runtime because the two
/// capture tracks only describe the moment the segment was spoken.
///
/// `diarized` is the transcription provider's own speaker index for the
/// segment, when the provider returned one; it takes precedence over the
/// capture-track heuristic inside the session's roster.
pub async fn observe_final_segment(text: &str, diarized: Option<u64>) {
    if text.trim().is_empty() {
        return;
    }
    let Some(sender) = control_sender() else {
        return;
    };
    let control = MeetingControl::FinalSegment {
        speaker: crate::meeting_capture::dominant_speaker(),
        diarized,
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
    note_generator: Option<NoteGenerator>,
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
            note_generator: None,
        },
    )
}

/// Publishes the session's existence whenever it changes, so the runtime — not
/// the platform detector — is the single source of truth for whether a meeting
/// is under way.
fn announce(session: Option<&MeetingSession>, announced: &mut bool) {
    let active = session.is_some();
    if active == *announced {
        return;
    }
    *announced = active;
    NativeEvent::MeetingStateChanged(MeetingStateChanged {
        active,
        suggested_title: session.map(|current| current.title().to_owned()),
    })
    .send();
}

async fn reached(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(at) => tokio::time::sleep_until(at).await,
        None => std::future::pending().await,
    }
}

impl MeetingRuntime {
    pub async fn run(mut self) {
        let mut session: Option<MeetingSession> = None;
        let mut announced = false;
        let mut gate_active = false;
        let mut auto_start_suppressed = false;
        let mut manual_end: Option<tokio::time::Instant> = None;
        loop {
            let control = tokio::select! {
                () = self.cancellation.cancelled() => break,
                () = reached(manual_end) => {
                    manual_end = None;
                    if let Some(finished) = session.take() {
                        self.capture.stop();
                        self.finish(finished);
                    }
                    announce(session.as_ref(), &mut announced);
                    continue;
                }
                control = self.receiver.recv() => match control {
                    Some(control) => control,
                    None => break,
                },
            };
            match control {
                MeetingControl::Start { title } => {
                    auto_start_suppressed = false;
                    manual_end = None;
                    match &mut session {
                        Some(current) => current.upgrade_to_manual(title),
                        None => session = Some(MeetingSession::new(title, true)),
                    }
                    self.sync_capture(session.is_some());
                }
                MeetingControl::Stop => {
                    self.capture.stop();
                    manual_end = None;
                    // Stopping by hand mid-call must not be undone a poll later
                    // by a detector that is still holding the gate open, so
                    // auto-start stays suppressed until the call itself ends.
                    // Starting again remains available throughout, because a
                    // manual Start ignores the gate entirely.
                    auto_start_suppressed = gate_active;
                    if let Some(finished) = session.take() {
                        self.finish(finished);
                    }
                }
                MeetingControl::Gate {
                    active: true,
                    suggested_title,
                } => {
                    gate_active = true;
                    manual_end = None;
                    if session.is_none()
                        && !auto_start_suppressed
                        && should_auto_start(self.mode, true)
                    {
                        session = Some(MeetingSession::new(suggested_title, false));
                    }
                    self.sync_capture(session.is_some());
                }
                MeetingControl::Gate { active: false, .. } => {
                    gate_active = false;
                    auto_start_suppressed = false;
                    match session.as_ref().map(MeetingSession::is_manual) {
                        Some(false) => {
                            if let Some(finished) = session.take() {
                                self.capture.stop();
                                self.finish(finished);
                            }
                        }
                        Some(true) => {
                            manual_end = Some(tokio::time::Instant::now() + MANUAL_GATE_OFF_GRACE);
                        }
                        None => {}
                    }
                }
                MeetingControl::FinalSegment {
                    speaker,
                    diarized,
                    text,
                } => {
                    if let Some(current) = &mut session {
                        let speaker = current.resolve_speaker(diarized, speaker);
                        current.push_final(speaker, &text);
                        NativeEvent::MeetingTranscriptTurn(MeetingTranscriptTurn {
                            speaker: speaker.name(),
                            text: text.trim().to_owned(),
                            occurred_at_ms: chrono::Utc::now().timestamp_millis(),
                        })
                        .send();
                        self.maybe_classify(current, speaker, &text);
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
                MeetingControl::ConfigureNoteProvider(generator) => {
                    self.note_generator = Some(generator);
                }
            }
            announce(session.as_ref(), &mut announced);
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

    fn maybe_classify(&self, session: &mut MeetingSession, speaker: MeetingSpeaker, text: &str) {
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
                    speaker: speaker.name(),
                })
                .send();
            }
        });
    }

    fn finish(&self, session: MeetingSession) {
        let captures = self.captures.clone();
        let cancellation = self.cancellation.clone();
        let generator = self.note_generator.clone();
        tokio::spawn(async move {
            if session.transcript().trim().is_empty() {
                return;
            }
            let now_ms = chrono::Utc::now().timestamp_millis();
            let chunks = transcript_chunks(session.transcript());
            let prompt = match chunks.as_slice() {
                [] => return,
                [single] => note_prompt(single, session.jots(), session.title()),
                chunks => {
                    let mut digests = Vec::with_capacity(chunks.len());
                    for (index, chunk) in chunks.iter().enumerate() {
                        let prompt =
                            chunk_summary_prompt(chunk, index + 1, chunks.len(), session.title());
                        let digest = tokio::select! {
                            () = cancellation.cancelled() => return,
                            output = generate_note_output(&prompt, generator.as_ref(), &cancellation) => output,
                        };
                        digests.push(digest.unwrap_or_else(|| chunk.clone()));
                    }
                    digest_note_prompt(
                        &combine_chunk_digests(&digests),
                        session.jots(),
                        session.title(),
                    )
                }
            };
            let output = tokio::select! {
                () = cancellation.cancelled() => return,
                output = generate_note_output(&prompt, generator.as_ref(), &cancellation) => output,
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

/// Meeting-note generation (BALANCED tier). On-device generation first, then
/// the configured provider (MiMo balanced), and only then the dev-only Gemini
/// fallback. Notes are one-shot: the provider stream is collected in full by
/// the generator before it returns.
async fn generate_note_output(
    prompt: &str,
    generator: Option<&NoteGenerator>,
    cancellation: &CancellationToken,
) -> Option<String> {
    if let Some(output) = crate::local_ai::respond(prompt).await {
        return Some(output);
    }
    note_output_without_local(prompt, generator, cancellation).await
}

/// The remote fallback order once on-device generation has been ruled out: the
/// configured provider (BALANCED tier) must be tried before the dev-only Gemini
/// path. Split out so the ordering is unit-testable without depending on
/// whether on-device generation happens to be available.
async fn note_output_without_local(
    prompt: &str,
    generator: Option<&NoteGenerator>,
    cancellation: &CancellationToken,
) -> Option<String> {
    if let Some(generator) = generator
        && let Some(output) = generator(prompt.to_owned(), cancellation.clone()).await
    {
        return Some(output);
    }
    let key = crate::dev_gemini::api_key()?;
    crate::dev_gemini::generate(&key, prompt).await
}

/// Latency-sensitive live output (SPEED tier): on-device generation, then the
/// dev-only Gemini fallback (`gemini-3.1-flash-lite`). Live insights and answer
/// suggestions must not wait on the heavier balanced provider.
async fn generate_speed_output(prompt: &str) -> Option<String> {
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
        output = generate_speed_output(&prompt) => output,
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

    #[tokio::test]
    async fn meeting_notes_use_the_configured_provider_before_the_dev_fallback() {
        // With on-device generation ruled out, a configured provider that yields
        // a note must be returned without the dev-only Gemini path being reached.
        let generator: NoteGenerator =
            Arc::new(|_prompt, _cancel| Box::pin(async { Some("PROVIDER_NOTE".to_owned()) }));
        let output = note_output_without_local(
            "summarize the meeting",
            Some(&generator),
            &CancellationToken::new(),
        )
        .await;
        assert_eq!(output.as_deref(), Some("PROVIDER_NOTE"));
    }

    #[tokio::test]
    async fn meeting_notes_pass_the_note_prompt_to_the_configured_provider() {
        let seen = Arc::new(std::sync::Mutex::new(None));
        let sink = Arc::clone(&seen);
        let generator: NoteGenerator = Arc::new(move |prompt, _cancel| {
            let sink = Arc::clone(&sink);
            Box::pin(async move {
                *sink.lock().unwrap_or_else(|failure| failure.into_inner()) = Some(prompt);
                Some("ok".to_owned())
            })
        });
        let _ =
            note_output_without_local("PROMPT_TEXT", Some(&generator), &CancellationToken::new())
                .await;
        assert_eq!(
            seen.lock()
                .unwrap_or_else(|failure| failure.into_inner())
                .as_deref(),
            Some("PROMPT_TEXT")
        );
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
                      [\"Ship Friday\"],\"actions\":[\"Ship beta\",\"  \",\"Email QA\"],\
                      \"openQuestions\":[\"Who signs off pricing?\",\" \"]}\n```";
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
        assert_eq!(note.action_lines(), vec!["Ship beta", "Email QA"]);
        assert_eq!(note.open_questions, vec!["Who signs off pricing?"]);
    }

    #[test]
    fn actions_carry_owners_and_still_accept_bare_strings() {
        let output = "{\"summary\":\"Aligned.\",\"actions\":[{\"text\":\" Email QA \",\
                      \"owner\":\" Ana \"},{\"text\":\"Book the room\",\"owner\":\"  \"},\
                      \"Draft the plan\",{\"text\":\"  \",\"owner\":\"Ben\"}]}";
        let note = parse_note(output).unwrap_or_else(|| panic!("note parses"));
        assert_eq!(
            note.actions,
            vec![
                ActionItem {
                    text: "Email QA".to_owned(),
                    owner: Some("Ana".to_owned()),
                },
                ActionItem {
                    text: "Book the room".to_owned(),
                    owner: None,
                },
                ActionItem {
                    text: "Draft the plan".to_owned(),
                    owner: None,
                },
            ]
        );
        assert_eq!(
            note.action_lines(),
            vec!["Email QA — Ana", "Book the room", "Draft the plan"]
        );
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
            actions: vec![
                ActionItem {
                    text: "Email QA".to_owned(),
                    owner: Some("Ana".to_owned()),
                },
                ActionItem {
                    text: "Book the room".to_owned(),
                    owner: None,
                },
            ],
            open_questions: vec!["Who signs off pricing?".to_owned()],
        };
        let markdown = note_markdown(&note, "Meeting", 0, 60_000);
        assert!(markdown.starts_with("# Launch Sync\n"));
        assert!(markdown.contains("1970-01-01 00:00 UTC — 1970-01-01 00:01 UTC"));
        assert!(markdown.contains("Attendees: Ana, Ben"));
        assert!(markdown.contains("## Summary\n\nWe aligned on launch."));
        assert!(markdown.contains("## Discussion\n\n- Beta ships Friday"));
        assert!(markdown.contains("## Decisions\n\n- Ship Friday"));
        assert!(markdown.contains("## Action items\n\n- [ ] Email QA — **Ana**"));
        assert!(markdown.contains("- [ ] Book the room\n"));
        assert!(markdown.contains("## Open questions\n\n- Who signs off pricing?"));
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
            actions: vec![ActionItem {
                text: "Do it".to_owned(),
                owner: Some("Ben".to_owned()),
            }],
            open_questions: vec!["Still open?".to_owned()],
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
        assert_eq!(metadata["actions"][0], "Do it — Ben");
        assert_eq!(metadata["openQuestions"][0], "Still open?");
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
    fn note_prompt_states_the_grounding_speaker_and_structure_rules() {
        let prompt = note_prompt("You: hello\nThem: hi", &[], "Sync");
        assert!(prompt.contains("Never infer"));
        assert!(prompt.contains("leave it out"));
        assert!(prompt.contains("\"You:\""));
        assert!(prompt.contains("\"Them:\""));
        assert!(prompt.contains("at least two specific points"));
        assert!(prompt.contains("\"Overview\""));
        assert!(prompt.contains("openQuestions"));
        assert!(prompt.contains("\"owner\""));
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
        session.push_final(MeetingSpeaker::Unknown, "  hello team  ");
        session.push_final(MeetingSpeaker::Unknown, "");
        session.push_final(MeetingSpeaker::Unknown, &"x".repeat(RAW_TRANSCRIPT_CHARS));
        session.push_final(MeetingSpeaker::Unknown, "overflow is dropped");
        assert!(session.transcript().starts_with("hello team\n"));
        assert!(session.transcript().chars().count() <= RAW_TRANSCRIPT_CHARS);
        assert!(!session.transcript().contains("overflow"));
    }

    #[test]
    fn transcripts_label_speaker_turns_and_merge_consecutive_ones() {
        let mut session = MeetingSession::new_at(None, true, 0);
        session.push_final(MeetingSpeaker::You, "Where are we on the beta?");
        session.push_final(MeetingSpeaker::Them, "QA finishes Thursday.");
        session.push_final(MeetingSpeaker::Them, "We ship Friday.");
        session.push_final(MeetingSpeaker::You, "Great.");
        assert_eq!(
            session.transcript(),
            "You: Where are we on the beta?\nThem: QA finishes Thursday. We ship \
             Friday.\nYou: Great."
        );
    }

    #[test]
    fn unattributed_segments_stay_unlabelled_so_mic_only_capture_reads_as_before() {
        let mut session = MeetingSession::new_at(None, true, 0);
        session.push_final(MeetingSpeaker::Unknown, "first line");
        session.push_final(MeetingSpeaker::Unknown, "second line");
        session.push_final(MeetingSpeaker::You, "mine");
        assert_eq!(session.transcript(), "first line\nsecond line\nYou: mine");
    }

    #[test]
    fn a_speaker_prefix_never_pushes_a_transcript_past_its_bound() {
        let mut session = MeetingSession::new_at(None, true, 0);
        session.push_final(MeetingSpeaker::You, &"x".repeat(RAW_TRANSCRIPT_CHARS - 10));
        session.push_final(MeetingSpeaker::Them, "dropped entirely");
        assert!(session.transcript().chars().count() <= RAW_TRANSCRIPT_CHARS);
        assert!(!session.transcript().contains("Them"));
    }

    #[test]
    fn provider_diarization_outranks_the_energy_heuristic_and_numbers_the_far_end() {
        let mut session = MeetingSession::new_at(None, true, 0);
        // The heuristic hears the far end; diarization separates two voices in it.
        let first = session.resolve_speaker(Some(1), MeetingSpeaker::Them);
        let second = session.resolve_speaker(Some(2), MeetingSpeaker::Them);
        assert_eq!(first, MeetingSpeaker::Diarized(1));
        assert_eq!(second, MeetingSpeaker::Diarized(2));
        assert_eq!(
            session.resolve_speaker(Some(1), MeetingSpeaker::Unknown),
            MeetingSpeaker::Diarized(1)
        );
        // The voice the microphone track keeps carrying is the attendee.
        assert_eq!(
            session.resolve_speaker(Some(0), MeetingSpeaker::You),
            MeetingSpeaker::You
        );
        assert_eq!(
            session.resolve_speaker(Some(0), MeetingSpeaker::Unknown),
            MeetingSpeaker::You
        );
        session.push_final(first, "QA finishes Thursday.");
        session.push_final(second, "Pricing is unresolved.");
        session.push_final(MeetingSpeaker::You, "Then we ship Friday.");
        assert_eq!(
            session.transcript(),
            "Speaker 1: QA finishes Thursday.\nSpeaker 2: Pricing is unresolved.\nYou: Then we \
             ship Friday."
        );
    }

    #[test]
    fn without_provider_diarization_the_energy_heuristic_still_decides() {
        let mut session = MeetingSession::new_at(None, true, 0);
        assert_eq!(
            session.resolve_speaker(None, MeetingSpeaker::You),
            MeetingSpeaker::You
        );
        assert_eq!(
            session.resolve_speaker(None, MeetingSpeaker::Them),
            MeetingSpeaker::Them
        );
        assert_eq!(
            session.resolve_speaker(None, MeetingSpeaker::Unknown),
            MeetingSpeaker::Unknown
        );
    }

    #[test]
    fn the_roster_stops_growing_and_falls_back_once_it_is_full() {
        let mut roster = SpeakerRoster::default();
        for index in 0..MAX_DIARIZED_SPEAKERS as u64 {
            assert!(matches!(
                roster.resolve(Some(index), MeetingSpeaker::Them),
                MeetingSpeaker::Diarized(_)
            ));
        }
        assert_eq!(
            roster.resolve(Some(999), MeetingSpeaker::Them),
            MeetingSpeaker::Them
        );
    }

    #[test]
    fn a_transcript_within_the_budget_is_summarized_in_one_request() {
        assert!(transcript_chunks("   ").is_empty());
        assert_eq!(
            transcript_chunks("  You: hello team  "),
            vec!["You: hello team".to_owned()]
        );
        let exact = "x".repeat(SUMMARY_TRANSCRIPT_CHARS);
        assert_eq!(transcript_chunks(&exact).len(), 1);
    }

    #[test]
    fn long_transcripts_split_on_line_boundaries_with_overlap_and_lose_nothing() {
        let mut transcript = String::new();
        let mut line = 0;
        while transcript.chars().count() < SUMMARY_TRANSCRIPT_CHARS * 3 {
            line += 1;
            transcript.push_str(&format!("Them: line {line} of the meeting goes here.\n"));
        }
        let chunks = transcript_chunks(&transcript);
        assert!(chunks.len() >= 3);
        for chunk in &chunks {
            assert!(chunk.chars().count() <= SUMMARY_TRANSCRIPT_CHARS);
            assert!(chunk.starts_with("Them: line "));
            assert!(chunk.ends_with('.'));
        }
        // Every line of the transcript survives in some chunk, and consecutive
        // chunks overlap rather than butting up against each other.
        for number in 1..=line {
            let needle = format!("line {number} of the meeting");
            assert!(
                chunks.iter().any(|chunk| chunk.contains(&needle)),
                "line {number} is missing from every chunk"
            );
        }
        for pair in chunks.windows(2) {
            let tail: String = pair[0].chars().rev().take(80).collect();
            let tail: String = tail.chars().rev().collect();
            assert!(pair[1].contains(&tail), "chunks do not overlap");
        }
    }

    #[test]
    fn the_tail_of_a_long_meeting_reaches_the_final_summary_prompt() {
        let mut transcript = String::new();
        while transcript.chars().count() < SUMMARY_TRANSCRIPT_CHARS * 2 {
            transcript.push_str("Them: routine status chatter that fills the meeting.\n");
        }
        transcript.push_str("You: the very last decision is to ship on the ninth.\n");
        let chunks = transcript_chunks(&transcript);
        assert!(chunks.len() > 1);
        assert!(
            chunks
                .last()
                .is_some_and(|chunk| chunk.contains("ship on the ninth"))
        );
        // With no model available every chunk digest falls back to the chunk
        // itself, and the tail still has to survive the reduce step.
        let digest = combine_chunk_digests(&chunks);
        assert!(digest.contains("ship on the ninth"));
        assert!(digest.contains(&format!("Part {} of {}", chunks.len(), chunks.len())));
        let prompt = digest_note_prompt(&digest, &[], "Meeting");
        assert!(prompt.contains("ship on the ninth"));
        assert!(prompt.contains("\"openQuestions\":"));
        assert!(prompt.contains("Never infer, never invent a name, a date, or a number."));
        assert!(prompt.chars().count() <= SUMMARY_TRANSCRIPT_CHARS * 2);
    }

    #[test]
    fn chunk_prompts_state_their_place_and_keep_the_grounding_rules() {
        let prompt = chunk_summary_prompt("Them: hello.", 2, 3, "Launch Sync");
        assert!(prompt.contains("part 2 of 3"));
        assert!(prompt.contains("Launch Sync"));
        assert!(prompt.contains("Never infer, never invent a name, a date, or a number."));
        assert!(prompt.contains("Do not write an overall conclusion"));
        assert!(prompt.ends_with("Them: hello."));
    }

    #[test]
    fn manual_start_upgrades_an_auto_session_and_adopts_the_title() {
        let mut session = MeetingSession::new(Some("Zoom".to_owned()), false);
        session.push_final(MeetingSpeaker::Unknown, "early context");
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
        session.push_final(MeetingSpeaker::Them, "We agreed to ship on Friday.");
        session.push_final(MeetingSpeaker::You, "I'll email the release notes.");
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
                actions: vec![ActionItem {
                    text: "Email release notes".to_owned(),
                    owner: Some("Ana".to_owned()),
                }],
                open_questions: Vec::new(),
            },
            10,
        );
        assert_eq!(completed.title, "Standup");
        assert_eq!(completed.summary, "Team agreed to ship Friday.");
        assert_eq!(completed.actions, vec!["Email release notes — Ana"]);
        assert_eq!(completed.started_at_ms, 5);
        assert_eq!(completed.ended_at_ms, 10);
        assert_eq!(completed.participants, vec!["Ana"]);
        assert_eq!(completed.key_points, vec!["Friday is the date"]);
        assert_eq!(completed.decisions, vec!["Ship Friday"]);
        assert!(completed.note_markdown.contains("# Standup"));
        assert!(
            completed
                .note_markdown
                .contains("- [ ] Email release notes — **Ana**")
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
        assert!(evidence.contains("Them: We agreed to ship on Friday."));
        assert!(evidence.contains("You: I'll email the release notes."));

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
                feature_flag: None,
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

    fn meeting_states() -> Vec<(bool, Option<String>)> {
        crate::signals::test_events::take()
            .into_iter()
            .filter_map(|event| match event {
                NativeEvent::MeetingStateChanged(state) => {
                    Some((state.active, state.suggested_title))
                }
                _ => None,
            })
            .collect()
    }

    fn runtime() -> (
        mpsc::Sender<MeetingControl>,
        MeetingRuntime,
        mpsc::Receiver<ClientCommand>,
    ) {
        let (captures, capture_receiver) = mpsc::channel(8);
        let (controls, runtime) = channel(captures);
        (controls, runtime, capture_receiver)
    }

    async fn send(controls: &mpsc::Sender<MeetingControl>, control: MeetingControl) {
        assert!(controls.send(control).await.is_ok());
    }

    #[tokio::test]
    async fn a_manual_start_and_stop_each_announce_the_meeting_state() {
        let (controls, runtime, _captures) = runtime();
        let driven = tokio::spawn(runtime.run());
        send(
            &controls,
            MeetingControl::Start {
                title: Some("Quarterly Review".to_owned()),
            },
        )
        .await;
        send(&controls, MeetingControl::Stop).await;
        drop(controls);
        let _ = driven.await;
        assert_eq!(
            meeting_states(),
            vec![(true, Some("Quarterly Review".to_owned())), (false, None)]
        );
    }

    #[tokio::test]
    async fn the_detector_gate_announces_through_the_runtime_exactly_once_per_change() {
        let (controls, runtime, _captures) = runtime();
        let driven = tokio::spawn(runtime.run());
        send(
            &controls,
            MeetingControl::Gate {
                active: true,
                suggested_title: Some("zoom.us".to_owned()),
            },
        )
        .await;
        send(
            &controls,
            MeetingControl::Gate {
                active: true,
                suggested_title: Some("zoom.us".to_owned()),
            },
        )
        .await;
        send(
            &controls,
            MeetingControl::Gate {
                active: false,
                suggested_title: None,
            },
        )
        .await;
        drop(controls);
        let _ = driven.await;
        assert_eq!(
            meeting_states(),
            vec![(true, Some("zoom.us".to_owned())), (false, None)]
        );
    }

    #[tokio::test]
    async fn a_manual_stop_survives_the_still_open_gate_and_still_allows_a_restart() {
        let (controls, runtime, _captures) = runtime();
        let driven = tokio::spawn(runtime.run());
        send(
            &controls,
            MeetingControl::Gate {
                active: true,
                suggested_title: Some("zoom.us".to_owned()),
            },
        )
        .await;
        send(&controls, MeetingControl::Stop).await;
        send(
            &controls,
            MeetingControl::Gate {
                active: true,
                suggested_title: Some("zoom.us".to_owned()),
            },
        )
        .await;
        send(&controls, MeetingControl::Start { title: None }).await;
        drop(controls);
        let _ = driven.await;
        assert_eq!(
            meeting_states(),
            vec![
                (true, Some("zoom.us".to_owned())),
                (false, None),
                (true, Some(DEFAULT_TITLE.to_owned())),
            ]
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_manual_session_ends_once_the_gate_has_stayed_off_through_the_grace() {
        let (controls, runtime, _captures) = runtime();
        let driven = tokio::spawn(runtime.run());
        send(&controls, MeetingControl::Start { title: None }).await;
        send(
            &controls,
            MeetingControl::Gate {
                active: false,
                suggested_title: None,
            },
        )
        .await;
        tokio::time::sleep(MANUAL_GATE_OFF_GRACE - Duration::from_secs(1)).await;
        assert_eq!(
            meeting_states(),
            vec![(true, Some(DEFAULT_TITLE.to_owned()))]
        );
        tokio::time::sleep(Duration::from_secs(2)).await;
        assert_eq!(meeting_states(), vec![(false, None)]);
        drop(controls);
        let _ = driven.await;
    }

    #[tokio::test(start_paused = true)]
    async fn a_detector_flap_does_not_end_a_manual_session() {
        let (controls, runtime, _captures) = runtime();
        let driven = tokio::spawn(runtime.run());
        send(&controls, MeetingControl::Start { title: None }).await;
        send(
            &controls,
            MeetingControl::Gate {
                active: false,
                suggested_title: None,
            },
        )
        .await;
        tokio::time::sleep(Duration::from_secs(10)).await;
        send(
            &controls,
            MeetingControl::Gate {
                active: true,
                suggested_title: Some("zoom.us".to_owned()),
            },
        )
        .await;
        tokio::time::sleep(MANUAL_GATE_OFF_GRACE * 2).await;
        assert_eq!(
            meeting_states(),
            vec![(true, Some(DEFAULT_TITLE.to_owned()))]
        );
        drop(controls);
        let _ = driven.await;
    }
}
