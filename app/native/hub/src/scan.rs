#[cfg(target_os = "macos")]
use rusqlite::{Connection, OpenFlags};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Component, Path, PathBuf};

#[cfg(target_os = "macos")]
const LIMIT: usize = 500;
const MAX_FILES: usize = 200_000;
const MAX_WALK_DEPTH: usize = 5;
const MAX_PROJECT_NAMES: usize = 48;
const SUMMARY_ITEMS: usize = 96;
const SUMMARY_PROMPT_CHARS: usize = 12_000;
const CORROBORATION_BONUS: i32 = 25;
const ALL_CAPS_PENALTY: i32 = 15;
const RECENCY_WINDOW_DAYS: i64 = 30;
#[cfg(target_os = "macos")]
const NOTES_QUERY_LIMIT: usize = LIMIT * 3;
#[cfg(target_os = "macos")]
const MAIL_QUERY_LIMIT: usize = LIMIT * 4;
#[cfg(target_os = "macos")]
const NOTES_CLASSIFIER_NOISE: &[&str] = &[
    "Document Documents Papers Written Document Written Documents",
    "Chart Charts Graph Graphs",
    "Machine Apparatus Machines",
    "Consumer Electronics Electronic Device Electronic Devices Electronics",
    "Computer Computers Computing Device Computing Devices Computing Machine Computing Machines",
    "Electronic Computer Electronic Computers",
];
const MARKERS: &[&str] = &[
    "Cargo.toml",
    "Package.swift",
    "go.mod",
    "package.json",
    "pubspec.yaml",
    "pyproject.toml",
];
const SKIP: &[&str] = &[
    ".git",
    ".dart_tool",
    ".Trash",
    "build",
    "DerivedData",
    "dist",
    "Library",
    "node_modules",
    "target",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ScanState {
    Complete,
    Denied,
    Unavailable,
    Failed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ScanMemory {
    pub stable_id: String,
    pub text: String,
    pub captured_at_ms: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SourceScan {
    pub source: String,
    pub state: ScanState,
    pub items_found: u64,
    pub detail: String,
    pub memories: Vec<ScanMemory>,
}

pub fn scan_sources(roots: &[String], notes: bool, mail: bool) -> Vec<SourceScan> {
    let mut results = vec![scan_workspace(roots)];
    if notes {
        results.push(scan_notes());
    }
    if mail {
        results.push(scan_mail());
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let now = crate::evidence::now_unix_seconds();
        let root_paths = roots.iter().map(PathBuf::from).collect::<Vec<_>>();
        results.push(crate::evidence::scan_apps(&home, now));
        results.push(crate::evidence::scan_developer_activity(&home, now));
        results.push(crate::evidence::scan_browsing(&home, now));
        results.push(crate::evidence::scan_documents(&root_paths, &home, now));
    }
    results
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SummaryPrompts {
    /// Full prompt for the on-device model, including document gists.
    pub local: String,
    /// Prompt for the off-device managed/dev fallback. Document content
    /// gists (DOC lines) are excluded entirely so skimmed file contents
    /// never leave the machine; only the local Foundation-Models path sees
    /// them.
    pub fallback: String,
    /// Top-scored evidence names (original casing), used to add the
    /// **name** emphasis markers after the fact when the model ignores the
    /// marker instruction, so the rendered summary always pops.
    pub emphasis_candidates: Vec<String>,
}

/// Small models routinely drop the ** marker protocol, or only apply it to a
/// couple of names; wrap every remaining evidence name that actually appears
/// in the summary (longest first so substrings don't split larger names) up
/// to the cap, counting any markers the model already added toward that cap.
pub fn ensure_summary_emphasis(summary: &str, candidates: &[String]) -> String {
    const MAX_SPANS: usize = 8;
    let mut ordered: Vec<&String> = candidates.iter().collect();
    ordered.sort_by_key(|name| std::cmp::Reverse(name.chars().count()));
    let mut result = summary.to_owned();
    let mut wrapped = result.matches("**").count() / 2;
    for name in ordered {
        if wrapped >= MAX_SPANS {
            break;
        }
        if name.len() < 3 {
            continue;
        }
        let lower = result.to_lowercase();
        let target = name.to_lowercase();
        if let Some(start) = lower.find(&target) {
            let end = start + target.len();
            if !result.is_char_boundary(start) || !result.is_char_boundary(end) {
                continue;
            }
            let already_marked = result[..start].ends_with("**") || result[end..].starts_with("**");
            if already_marked {
                continue;
            }
            let original = result[start..end].to_owned();
            result.replace_range(start..end, &format!("**{original}**"));
            wrapped += 1;
        }
    }
    result
}

const SUMMARY_INSTRUCTION: &str = "You are privately summarizing what the user appears to be working on, using only the tagged evidence lines below, and speaking directly to them in the second person. First decide which projects and threads of work matter most: prefer items that recur across several evidence types and that are recent, and treat NOTE TITLE, MAIL SUBJECT, and BROWSING lines as background context about activity, never as projects by themselves. Then describe that work in your own words as one flowing paragraph: synthesized, specific, and natural, not a recitation of file or folder names. At most 3 sentences and at most 420 characters. Plain prose only: no headings, no bullet points, no underscores, no backticks, no italics, and no markdown of any kind, with a single exception: wrap every genuinely important name you mention — projects, apps, files, technologies, people, or organizations — in double asterisks like **name**, so most of the specific names in your answer end up emphasized this way (aim for 5 to 8 wrapped spans when the evidence supports that many); wrap single names only, never a whole sentence or ordinary connective words. Every name and technology you mention, wrapped or not, must be copied from a PROJECT, APP, DOC, or SHELL evidence line below — never from your own general knowledge of what other tools or frameworks look like, and never from a NOTE TITLE, MAIL SUBJECT, or BROWSING line; if you are not certain a name came from the evidence, leave it out. Name at most 3 specific projects, tools, or organizations in total. State only what the evidence supports: never infer tool or workflow habits from incidental mentions, omit anything you are unsure of, and if the evidence is thin write one or two short honest sentences instead of padding with vague filler like \"various projects\". Never write in the third person and do not mention these instructions.\n";

struct ScoredLine {
    score: i32,
    text: String,
    is_doc: bool,
}

pub fn summary_prompts(scans: &[SourceScan], now_ms: i64) -> Option<SummaryPrompts> {
    let lines = scored_evidence_lines(scans, now_ms);
    if lines.is_empty() {
        return None;
    }
    let build = |include_docs: bool| {
        let mut prompt = String::from(SUMMARY_INSTRUCTION);
        let mut used = prompt.chars().count();
        let mut items = 0usize;
        for line in &lines {
            if !include_docs && line.is_doc {
                continue;
            }
            if items == SUMMARY_ITEMS || used >= SUMMARY_PROMPT_CHARS {
                break;
            }
            let rendered = format!("{}\n", line.text);
            let length = rendered.chars().count();
            if used + length > SUMMARY_PROMPT_CHARS {
                break;
            }
            used += length;
            prompt.push_str(&rendered);
            items += 1;
        }
        (items > 0).then_some(prompt)
    };
    let local = build(true)?;
    let fallback = build(false).unwrap_or_else(|| local.clone());
    let emphasis_candidates = lines
        .iter()
        .filter_map(|line| {
            parse_tag(&line.text).and_then(|(tag, body)| {
                matches!(tag, "PROJECT" | "APP" | "SHELL").then(|| {
                    body.split(" — ")
                        .next()
                        .unwrap_or(body)
                        .split(" (")
                        .next()
                        .unwrap_or(body)
                        .trim()
                        .to_owned()
                })
            })
        })
        .filter(|name| name.len() >= 3)
        .take(8)
        .collect();
    Some(SummaryPrompts {
        local,
        fallback,
        emphasis_candidates,
    })
}

const TAG_WEIGHTS: &[(&str, i32)] = &[
    ("PROJECT", 50),
    ("SHELL", 40),
    ("APP", 25),
    ("DOC", 22),
    ("NOTE TITLE", 18),
    ("MAIL SUBJECT", 15),
    ("BROWSING", 12),
    ("SSH HOST", 12),
];

fn parse_tag(text: &str) -> Option<(&'static str, &str)> {
    TAG_WEIGHTS.iter().find_map(|(tag, _)| {
        text.strip_prefix(tag)
            .and_then(|rest| rest.strip_prefix(": "))
            .map(|rest| (*tag, rest))
    })
}

fn evidence_name(body: &str) -> String {
    let name = body
        .split(" — ")
        .next()
        .unwrap_or(body)
        .split(" (")
        .next()
        .unwrap_or(body);
    crate::evidence::normalize_line(name).to_lowercase()
}

fn is_all_caps_label(body: &str) -> bool {
    let letters: Vec<char> = body
        .chars()
        .filter(|character| character.is_alphabetic())
        .collect();
    letters.len() > 3 && letters.iter().all(|character| character.is_uppercase())
}

fn scored_evidence_lines(scans: &[SourceScan], now_ms: i64) -> Vec<ScoredLine> {
    let mut source_names: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for scan in scans {
        for memory in &scan.memories {
            if let Some((_, body)) = parse_tag(&memory.text) {
                let name = evidence_name(body);
                if name.len() >= 3 {
                    source_names
                        .entry(name)
                        .or_default()
                        .insert(scan.source.clone());
                }
            }
        }
    }
    let mut seen = BTreeSet::new();
    let mut lines = Vec::new();
    for scan in scans {
        for memory in &scan.memories {
            let text = crate::evidence::normalize_line(&memory.text);
            if text.is_empty() || !seen.insert(text.to_lowercase()) {
                continue;
            }
            let (tag, body) = parse_tag(&text).unwrap_or(("", text.as_str()));
            if crate::evidence::is_pure_numeric(body) {
                continue;
            }
            let base = TAG_WEIGHTS
                .iter()
                .find(|(candidate, _)| *candidate == tag)
                .map(|(_, weight)| *weight)
                .unwrap_or(10);
            let mut score = base;
            if let Some(captured) = memory.captured_at_ms {
                let days = ((now_ms - captured).max(0)) / 86_400_000;
                if days <= RECENCY_WINDOW_DAYS {
                    score += (RECENCY_WINDOW_DAYS - days) as i32;
                }
            }
            let name = evidence_name(body);
            if name.len() >= 3
                && let Some(sources) = source_names.get(&name)
                && sources.len() > 1
            {
                score += CORROBORATION_BONUS * (sources.len() as i32 - 1);
            }
            if is_all_caps_label(body) {
                score -= ALL_CAPS_PENALTY;
            }
            lines.push(ScoredLine {
                score,
                text,
                is_doc: tag == "DOC",
            });
        }
    }
    lines.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.text.cmp(&b.text)));
    lines
}

pub fn detected_name() -> Option<String> {
    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    let contents = fs::read_to_string(home.join(".gitconfig")).ok()?;
    parse_git_user_name(&contents)
}

fn parse_git_user_name(contents: &str) -> Option<String> {
    let mut in_user = false;
    for line in contents.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_user = line == "[user]";
            continue;
        }
        if !in_user {
            continue;
        }
        if let Some(value) = line.strip_prefix("name")
            && let Some(value) = value.trim_start().strip_prefix('=')
        {
            let value = value.trim().trim_matches('"').trim();
            if !value.is_empty() {
                return Some(value.to_owned());
            }
        }
    }
    None
}

/// Language detection thresholds. A language is claimed only when its
/// script both clears a minimum total character count and appears with at
/// least LANGUAGE_MIN_SOURCE_CHARS characters in two or more distinct scan
/// sources; a stray run of characters in a single note is no longer enough
/// (stray kana previously produced a false Japanese claim). Han characters
/// without a kana claim map to Mandarin only; Cantonese stays honestly
/// undetectable from script alone.
const LANGUAGE_MIN_TOTAL_CHARS: usize = 24;
const LANGUAGE_MIN_SOURCE_CHARS: usize = 4;
const LANGUAGE_MIN_SOURCES: usize = 2;

pub fn detected_languages(scans: &[SourceScan]) -> Vec<String> {
    const SCRIPTS: usize = 5;
    let mut totals = [0usize; SCRIPTS];
    let mut sources = [0usize; SCRIPTS];
    for scan in scans {
        let mut per_scan = [0usize; SCRIPTS];
        for memory in &scan.memories {
            for character in memory.text.chars() {
                let index = match character {
                    'a'..='z' | 'A'..='Z' => 0,
                    '\u{4e00}'..='\u{9fff}' | '\u{3400}'..='\u{4dbf}' => 1,
                    '\u{0400}'..='\u{04ff}' => 2,
                    '\u{3040}'..='\u{30ff}' => 3,
                    '\u{ac00}'..='\u{d7af}' => 4,
                    _ => continue,
                };
                per_scan[index] += 1;
            }
        }
        for index in 0..SCRIPTS {
            totals[index] += per_scan[index];
            if per_scan[index] >= LANGUAGE_MIN_SOURCE_CHARS {
                sources[index] += 1;
            }
        }
    }
    let strong = |index: usize| {
        totals[index] >= LANGUAGE_MIN_TOTAL_CHARS && sources[index] >= LANGUAGE_MIN_SOURCES
    };
    let mut languages = Vec::new();
    if strong(0) {
        languages.push("English".to_owned());
    }
    if strong(3) {
        languages.push("Japanese".to_owned());
    } else if strong(1) {
        languages.push("Mandarin".to_owned());
    }
    if strong(2) {
        languages.push("Russian".to_owned());
    }
    if strong(4) {
        languages.push("Korean".to_owned());
    }
    languages
}

fn scan_workspace(roots: &[String]) -> SourceScan {
    let paths = match roots
        .iter()
        .map(|root| {
            let path = PathBuf::from(root);
            if !path.is_absolute() || path.components().any(|part| part == Component::ParentDir) {
                Err("Approved workspace roots must be absolute and cannot contain '..'.".to_owned())
            } else {
                Ok(path)
            }
        })
        .collect::<Result<Vec<_>, _>>()
    {
        Ok(paths) => paths,
        Err(error) => return result("workspace", ScanState::Failed, error),
    };
    if paths.is_empty() {
        return result(
            "workspace",
            ScanState::Unavailable,
            "No approved workspace roots were supplied.",
        );
    }
    let mut files = 0usize;
    let mut projects = BTreeSet::new();
    let mut denied = false;
    for path in paths {
        walk(&path, 0, &mut files, &mut projects, &mut denied);
    }
    if files == 0 && denied {
        return result(
            "workspace",
            ScanState::Denied,
            "Access to the approved workspace roots was denied.",
        );
    }
    let memories = projects
        .into_iter()
        .take(MAX_PROJECT_NAMES)
        .filter(|name| !crate::evidence::is_pure_numeric(name))
        .map(|name| ScanMemory {
            stable_id: format!("approved-roots:{name}"),
            text: format!(
                "PROJECT: {} (approved workspace)",
                crate::evidence::cap_chars(&crate::evidence::normalize_line(&name), 48)
            ),
            captured_at_ms: None,
        })
        .collect::<Vec<_>>();
    complete("workspace", memories, files)
}

fn walk(
    path: &Path,
    depth: usize,
    files: &mut usize,
    projects: &mut BTreeSet<String>,
    denied: &mut bool,
) {
    if depth > MAX_WALK_DEPTH || *files >= MAX_FILES {
        return;
    }
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(error) => {
            *denied |= error.kind() == std::io::ErrorKind::PermissionDenied;
            return;
        }
    };
    for entry in entries.flatten() {
        if *files >= MAX_FILES {
            return;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || SKIP.contains(&name.as_str()) {
            continue;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_symlink() {
            continue;
        }
        if kind.is_dir() {
            walk(&entry.path(), depth + 1, files, projects, denied);
        } else if kind.is_file() {
            *files += 1;
            if MARKERS.contains(&name.as_str())
                && let Some(parent) = entry.path().parent().and_then(Path::file_name)
            {
                projects.insert(parent.to_string_lossy().into_owned());
            }
        }
    }
}

#[cfg(target_os = "macos")]
fn scan_notes() -> SourceScan {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return result(
            "apple_notes",
            ScanState::Unavailable,
            "Home directory unavailable.",
        );
    };
    let candidates = [
        home.join("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"),
        home.join(
            "Library/Group Containers/group.com.apple.notes/Accounts/LocalAccount/NoteStore.sqlite",
        ),
    ];
    let Some(path) = candidates.iter().find(|path| path.exists()) else {
        return result(
            "apple_notes",
            ScanState::Unavailable,
            "Apple Notes database was not found.",
        );
    };
    let connection = match open(path, "apple_notes") {
        Ok(value) => value,
        Err(value) => return value,
    };
    let columns = match columns(&connection, "ZICCLOUDSYNCINGOBJECT") {
        Ok(value) => value,
        Err(value) => return result("apple_notes", ScanState::Failed, value),
    };
    if !["Z_PK", "ZTITLE", "ZMODIFICATIONDATE", "ZNOTE"]
        .iter()
        .all(|name| columns.contains(*name))
    {
        return result(
            "apple_notes",
            ScanState::Failed,
            "Apple Notes schema is unsupported.",
        );
    }
    let summary = if columns.contains("ZSUMMARY") {
        "COALESCE(ZSUMMARY, '')"
    } else {
        "''"
    };
    let deleted = if columns.contains("ZMARKEDFORDELETION") {
        "AND COALESCE(ZMARKEDFORDELETION, 0) = 0"
    } else {
        ""
    };
    let query = format!(
        "SELECT Z_PK, ZTITLE, {summary}, ZMODIFICATIONDATE FROM ZICCLOUDSYNCINGOBJECT WHERE ZNOTE IS NOT NULL AND ZTITLE IS NOT NULL {deleted} ORDER BY ZMODIFICATIONDATE DESC LIMIT {NOTES_QUERY_LIMIT}"
    );
    let mut statement = match connection.prepare(&query) {
        Ok(value) => value,
        Err(error) => return result("apple_notes", ScanState::Failed, error.to_string()),
    };
    let rows = match statement.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, f64>(3)?,
        ))
    }) {
        Ok(value) => value,
        Err(error) => return result("apple_notes", ScanState::Failed, error.to_string()),
    };
    let rows = match rows.collect::<Result<Vec<_>, _>>() {
        Ok(value) => value,
        Err(error) => return result("apple_notes", ScanState::Failed, error.to_string()),
    };
    let memories = rows
        .into_iter()
        .filter_map(|(id, title, summary, modified)| {
            let title = normalize_note_field(&title);
            let summary = normalize_note_field(&summary);
            if title.is_empty() || is_likely_note_attachment(&title, &summary) {
                return None;
            }
            let summary = summary.chars().take(120).collect::<String>();
            Some(ScanMemory {
                stable_id: id.to_string(),
                text: crate::evidence::cap_chars(
                    &if summary.is_empty() {
                        format!("NOTE TITLE: {title}")
                    } else {
                        format!("NOTE TITLE: {title} — {summary}")
                    },
                    160,
                ),
                captured_at_ms: apple_time(modified),
            })
        })
        .take(LIMIT)
        .collect::<Vec<_>>();
    let count = memories.len();
    complete("apple_notes", memories, count)
}

#[cfg(not(target_os = "macos"))]
fn scan_notes() -> SourceScan {
    result(
        "apple_notes",
        ScanState::Unavailable,
        "Apple Notes is available only on macOS.",
    )
}

#[cfg(any(target_os = "macos", test))]
const MAIL_FLAG_ANSWERED: i64 = 0x4;
#[cfg(any(target_os = "macos", test))]
const MAIL_FLAG_FLAGGED: i64 = 0x10;
#[cfg(any(target_os = "macos", test))]
const MAIL_SCORE_FLOOR: i32 = -40;
#[cfg(any(target_os = "macos", test))]
const MAIL_PROMO_KEYWORDS: &[&str] = &[
    "% off",
    "black friday",
    "coupon",
    "deal of",
    "discount",
    "flash sale",
    "free shipping",
    "last chance",
    "limited time",
    "newsletter",
    "promo",
    "sale",
    "special offer",
    "unsubscribe",
    "your order has shipped",
];
#[cfg(any(target_os = "macos", test))]
const MAIL_BULK_SENDERS: &[&str] = &[
    "bounce",
    "campaign",
    "donotreply",
    "do-not-reply",
    "info@",
    "mailer",
    "marketing",
    "news@",
    "newsletter",
    "no-reply",
    "noreply",
    "notifications@",
    "offers@",
    "promo",
    "support@",
    "updates@",
];

#[cfg(any(target_os = "macos", test))]
pub struct MailEvidence<'a> {
    pub subject: &'a str,
    pub sender_address: &'a str,
    pub sender_name: &'a str,
    pub replied: bool,
    pub flagged: bool,
    pub age_days: i64,
}

#[cfg(any(target_os = "macos", test))]
pub fn score_mail(evidence: &MailEvidence<'_>) -> i32 {
    let subject = evidence.subject.to_lowercase();
    let address = evidence.sender_address.to_lowercase();
    let mut score = 0i32;
    for keyword in MAIL_PROMO_KEYWORDS {
        if subject.contains(keyword) {
            score -= 25;
        }
    }
    if MAIL_BULK_SENDERS
        .iter()
        .any(|marker| address.contains(marker))
    {
        score -= 40;
    }
    let name = evidence.sender_name.trim();
    let looks_human = name.split_whitespace().count() >= 2
        && name.chars().all(|character| {
            character.is_alphabetic()
                || character.is_whitespace()
                || character == '\''
                || character == '-'
                || character == '.'
        });
    if looks_human {
        score += 20;
    }
    if evidence.replied {
        score += 40;
    }
    if evidence.flagged {
        score += 35;
    }
    score += (30 - evidence.age_days).clamp(-30, 30) as i32 / 3;
    score
}

#[cfg(target_os = "macos")]
fn scan_mail() -> SourceScan {
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return result(
            "apple_mail",
            ScanState::Unavailable,
            "Home directory unavailable.",
        );
    };
    let envelope = match envelope(&home.join("Library/Mail")) {
        Ok(Some(path)) => path,
        Ok(None) => {
            return result(
                "apple_mail",
                ScanState::Unavailable,
                "Apple Mail Envelope Index was not found.",
            );
        }
        Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
            return result(
                "apple_mail",
                ScanState::Denied,
                "Full Disk Access is required to scan Apple Mail.",
            );
        }
        Err(error) => return result("apple_mail", ScanState::Failed, error.to_string()),
    };
    let connection = match open(&envelope, "apple_mail") {
        Ok(value) => value,
        Err(value) => return value,
    };
    let message_columns = match columns(&connection, "messages") {
        Ok(value) => value,
        Err(value) => return result("apple_mail", ScanState::Failed, value),
    };
    if !["subject", "sender", "date_received"]
        .iter()
        .all(|name| message_columns.contains(*name))
    {
        return result(
            "apple_mail",
            ScanState::Failed,
            "Apple Mail schema is unsupported.",
        );
    }
    let flags = if message_columns.contains("flags") {
        "COALESCE(m.flags, 0)"
    } else {
        "0"
    };
    let comment = if columns(&connection, "addresses")
        .map(|names| names.contains("comment"))
        .unwrap_or(false)
    {
        "COALESCE(a.comment, '')"
    } else {
        "''"
    };
    let query = format!(
        "SELECT m.ROWID, COALESCE(s.subject, ''), COALESCE(a.address, ''), {comment}, m.date_received, {flags} FROM messages m LEFT JOIN subjects s ON m.subject=s.ROWID LEFT JOIN addresses a ON m.sender=a.ROWID ORDER BY m.date_received DESC LIMIT {MAIL_QUERY_LIMIT}"
    );
    let mut statement = match connection.prepare(&query) {
        Ok(value) => value,
        Err(error) => return result("apple_mail", ScanState::Failed, error.to_string()),
    };
    let rows = match statement.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, i64>(5)?,
        ))
    }) {
        Ok(value) => value,
        Err(error) => return result("apple_mail", ScanState::Failed, error.to_string()),
    };
    let rows = match rows.collect::<Result<Vec<_>, _>>() {
        Ok(value) => value,
        Err(error) => return result("apple_mail", ScanState::Failed, error.to_string()),
    };
    let newest = rows.iter().map(|row| row.4).max().unwrap_or(0);
    let mut seen = BTreeSet::new();
    let mut candidates = rows
        .into_iter()
        .filter_map(|(id, subject, sender, sender_name, received, flags)| {
            let subject = subject.trim().to_owned();
            let sender = sender.trim().to_owned();
            let sender_name = sender_name.trim().to_owned();
            if subject.is_empty() && sender.is_empty() {
                return None;
            }
            if !seen.insert(format!("{}\u{1f}{}", sender.to_lowercase(), subject)) {
                return None;
            }
            let score = score_mail(&MailEvidence {
                subject: &subject,
                sender_address: &sender,
                sender_name: &sender_name,
                replied: flags & MAIL_FLAG_ANSWERED != 0,
                flagged: flags & MAIL_FLAG_FLAGGED != 0,
                age_days: (newest - received).max(0) / 86_400,
            });
            Some((score, id, subject, sender, sender_name, received))
        })
        .collect::<Vec<_>>();
    candidates.sort_by(|a, b| b.0.cmp(&a.0).then(b.5.cmp(&a.5)));
    let memories = candidates
        .into_iter()
        .filter(|(score, ..)| *score > MAIL_SCORE_FLOOR)
        .take(LIMIT)
        .map(|(_, id, subject, sender, sender_name, received)| {
            let from = if sender_name.is_empty() {
                sender
            } else {
                format!("{sender_name} <{sender}>")
            };
            ScanMemory {
                stable_id: id.to_string(),
                text: crate::evidence::cap_chars(
                    &format!("MAIL SUBJECT: {subject} (from {from})"),
                    160,
                ),
                captured_at_ms: Some(received.saturating_mul(1_000)),
            }
        })
        .collect::<Vec<_>>();
    let count = memories.len();
    complete("apple_mail", memories, count)
}

#[cfg(not(target_os = "macos"))]
fn scan_mail() -> SourceScan {
    result(
        "apple_mail",
        ScanState::Unavailable,
        "Apple Mail is available only on macOS.",
    )
}

#[cfg(target_os = "macos")]
fn open(path: &Path, source: &str) -> Result<Connection, SourceScan> {
    Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY
            | OpenFlags::SQLITE_OPEN_URI
            | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| {
        if error.to_string().contains("unable to open")
            || error.to_string().contains("not authorized")
        {
            result(
                source,
                ScanState::Denied,
                "Full Disk Access is required for this source.",
            )
        } else {
            result(source, ScanState::Failed, error.to_string())
        }
    })
}

#[cfg(target_os = "macos")]
fn columns(connection: &Connection, table: &str) -> Result<BTreeSet<String>, String> {
    let mut statement = connection
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| error.to_string())?;
    let rows = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| error.to_string())?;
    Ok(rows.filter_map(Result::ok).collect())
}

#[cfg(target_os = "macos")]
fn envelope(root: &Path) -> std::io::Result<Option<PathBuf>> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let mut versions = entries
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            Some((
                name.strip_prefix('V')?.parse::<u32>().ok()?,
                entry.path().join("MailData/Envelope Index"),
            ))
        })
        .filter(|(_, path)| path.is_file())
        .collect::<Vec<_>>();
    versions.sort_by_key(|(version, _)| std::cmp::Reverse(*version));
    Ok(versions.into_iter().next().map(|(_, path)| path))
}

#[cfg(target_os = "macos")]
fn normalize_note_field(value: &str) -> String {
    NOTES_CLASSIFIER_NOISE
        .iter()
        .fold(value.to_owned(), |text, noise| text.replace(noise, ""))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(target_os = "macos")]
fn is_likely_note_attachment(title: &str, summary: &str) -> bool {
    let combined = format!("{title} {summary}");
    if combined.is_empty()
        || combined.contains("SOLITE")
        || combined.contains("kMDItem")
        || combined
            .split(|character: char| !character.is_alphanumeric())
            .any(|word| word.eq_ignore_ascii_case("exec"))
    {
        return true;
    }
    let title = title.to_ascii_lowercase();
    [".png", ".jpg", ".jpeg", ".heic", ".pdf", ".mov", ".mp4"]
        .iter()
        .any(|extension| title.ends_with(extension))
        || title.starts_with("cleanshot ")
        || title.starts_with("image ")
        || (title.contains("scan") && title.contains("document"))
        || (title.chars().count() < 3 && summary.chars().count() < 12)
}

#[cfg(target_os = "macos")]
fn apple_time(seconds: f64) -> Option<i64> {
    seconds
        .is_finite()
        .then_some(((seconds + 978_307_200.0) * 1_000.0) as i64)
}

fn complete(source: &str, memories: Vec<ScanMemory>, count: usize) -> SourceScan {
    SourceScan {
        source: source.into(),
        state: ScanState::Complete,
        items_found: count as u64,
        detail: format!(
            "Read {count} bounded records without copying private bodies or attachments."
        ),
        memories,
    }
}

fn result(source: &str, state: ScanState, detail: impl Into<String>) -> SourceScan {
    SourceScan {
        source: source.into(),
        state,
        items_found: 0,
        detail: detail.into(),
        memories: Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_keeps_metadata_not_contents() {
        let root = std::env::temp_dir().join(format!("omi-scan-{}", std::process::id()));
        fs::create_dir_all(root.join("project")).unwrap_or_else(|error| panic!("fixture: {error}"));
        fs::write(root.join("project/Cargo.toml"), "secret")
            .unwrap_or_else(|error| panic!("fixture: {error}"));
        let scan = scan_workspace(&[root.to_string_lossy().into_owned()]);
        assert_eq!(scan.state, ScanState::Complete);
        assert!(scan.memories[0].text.contains("project"));
        assert!(!scan.memories[0].text.contains("secret"));
        fs::remove_dir_all(root).unwrap_or_else(|error| panic!("fixture cleanup: {error}"));
    }

    #[test]
    fn workspace_rejects_relative_and_parent_roots() {
        assert_eq!(
            scan_workspace(&["Documents".into()]).state,
            ScanState::Failed
        );
        assert_eq!(
            scan_workspace(&["/tmp/../etc".into()]).state,
            ScanState::Failed
        );
    }

    #[test]
    fn summary_prompt_is_bounded_and_uses_only_scan_metadata() {
        let scans = vec![complete(
            "workspace",
            (0..120)
                .map(|index| ScanMemory {
                    stable_id: index.to_string(),
                    text: format!("PROJECT: alpha{index} (git repo)"),
                    captured_at_ms: None,
                })
                .collect(),
            120,
        )];
        let prompts = summary_prompts(&scans, 0).unwrap_or_else(|| SummaryPrompts {
            local: String::new(),
            fallback: String::new(),
            emphasis_candidates: Vec::new(),
        });
        assert!(prompts.local.contains("PROJECT: alpha0"));
        assert!(prompts.local.contains("At most 3 sentences"));
        assert!(prompts.local.contains("second person"));
        assert!(prompts.local.contains("in your own words"));
        assert!(prompts.local.contains("**name**"));
        assert!(prompts.local.contains("5 to 8 wrapped spans"));
        assert!(!prompts.local.contains("verbatim"));
        assert!(prompts.local.chars().count() <= SUMMARY_PROMPT_CHARS);
        assert!(prompts.local.lines().count() <= SUMMARY_ITEMS + 20);
    }

    #[test]
    fn corroborated_recent_projects_outrank_stale_and_bulk_evidence() {
        let now_ms = 1_800_000_000_000i64;
        let scans = vec![
            complete(
                "workspace",
                vec![
                    ScanMemory {
                        stable_id: "1".into(),
                        text: "PROJECT: omi-v4 (git repo, active this week)".into(),
                        captured_at_ms: Some(now_ms - 86_400_000),
                    },
                    ScanMemory {
                        stable_id: "2".into(),
                        text: "PROJECT: old-blog (git repo)".into(),
                        captured_at_ms: Some(now_ms - 400 * 86_400_000),
                    },
                ],
                2,
            ),
            complete(
                "developer",
                vec![ScanMemory {
                    stable_id: "3".into(),
                    text: "PROJECT: omi-v4 (open in editor recently)".into(),
                    captured_at_ms: Some(now_ms),
                }],
                1,
            ),
            complete(
                "apple_notes",
                vec![
                    ScanMemory {
                        stable_id: "4".into(),
                        text: "NOTE TITLE: MEETING TEMPLATES".into(),
                        captured_at_ms: Some(now_ms),
                    },
                    ScanMemory {
                        stable_id: "5".into(),
                        text: "NOTE TITLE: 20260101".into(),
                        captured_at_ms: Some(now_ms),
                    },
                ],
                2,
            ),
        ];
        let lines = scored_evidence_lines(&scans, now_ms);
        assert!(lines[0].text.contains("omi-v4"));
        let position = |needle: &str| {
            lines
                .iter()
                .position(|line| line.text.contains(needle))
                .unwrap_or(usize::MAX)
        };
        assert!(position("omi-v4") < position("old-blog"));
        assert!(position("old-blog") < position("MEETING TEMPLATES"));
        assert!(!lines.iter().any(|line| line.text.contains("20260101")));
    }

    #[test]
    fn fallback_prompt_excludes_document_gists() {
        let scans = vec![
            complete(
                "documents",
                vec![ScanMemory {
                    stable_id: "1".into(),
                    text: "DOC: roadmap — ship the onboarding rewrite".into(),
                    captured_at_ms: None,
                }],
                1,
            ),
            complete(
                "workspace",
                vec![ScanMemory {
                    stable_id: "2".into(),
                    text: "PROJECT: omi-v4 (approved workspace)".into(),
                    captured_at_ms: None,
                }],
                1,
            ),
        ];
        let prompts = summary_prompts(&scans, 0).unwrap_or_else(|| SummaryPrompts {
            local: String::new(),
            fallback: String::new(),
            emphasis_candidates: Vec::new(),
        });
        assert!(prompts.local.contains("DOC: roadmap"));
        assert!(!prompts.fallback.contains("DOC: roadmap"));
        assert!(prompts.fallback.contains("PROJECT: omi-v4"));
    }

    #[test]
    fn git_user_name_is_parsed_from_the_user_section_only() {
        assert_eq!(
            parse_git_user_name("[user]\n\tname = Max Carter\n\temail = max@example.com\n"),
            Some("Max Carter".to_owned())
        );
        assert_eq!(
            parse_git_user_name("[user]\nname = \"Max Carter 祁明思\"\n"),
            Some("Max Carter 祁明思".to_owned())
        );
        assert_eq!(
            parse_git_user_name("[alias]\nname = status\n[user]\nemail = max@example.com\n"),
            None
        );
        assert_eq!(parse_git_user_name(""), None);
    }

    #[test]
    fn languages_are_detected_from_scanned_scripts() {
        let memory = |id: &str, text: &str| ScanMemory {
            stable_id: id.into(),
            text: text.into(),
            captured_at_ms: None,
        };
        let scans = vec![
            complete(
                "apple_notes",
                vec![
                    memory("1", "Weekly planning notes for the hub rewrite"),
                    memory("2", "會議記錄:項目計劃和時間表安排進度規劃"),
                    memory("3", "Заметки о поездке в Москву весной"),
                ],
                3,
            ),
            complete(
                "apple_mail",
                vec![
                    memory("4", "Follow up on the roadmap review"),
                    memory("5", "項目進度更新和季度計劃討論安排"),
                    memory("6", "Планы на квартал и заметки"),
                ],
                3,
            ),
        ];
        assert_eq!(
            detected_languages(&scans),
            ["English", "Mandarin", "Russian"]
        );
        assert!(detected_languages(&[]).is_empty());
    }

    #[test]
    fn stray_single_source_scripts_are_not_claimed_as_languages() {
        let scans = vec![
            complete(
                "apple_notes",
                vec![ScanMemory {
                    stable_id: "1".into(),
                    text: "Trip ideas こんにちはこんにちはこんにちはこんにちは".into(),
                    captured_at_ms: None,
                }],
                1,
            ),
            complete(
                "apple_mail",
                vec![ScanMemory {
                    stable_id: "2".into(),
                    text: "Quarterly report and planning follow ups".into(),
                    captured_at_ms: None,
                }],
                1,
            ),
        ];
        assert_eq!(detected_languages(&scans), ["English"]);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn note_metadata_matches_upstream_filtering() {
        assert_eq!(
            normalize_note_field("  Launch\n  checklist  "),
            "Launch checklist"
        );
        assert!(!is_likely_note_attachment(
            "Executive planning",
            "Q3 execution details"
        ));
        assert!(is_likely_note_attachment("exec", ""));
        assert!(is_likely_note_attachment("Scan of document", ""));
        assert!(is_likely_note_attachment("receipt.pdf", ""));
    }

    #[test]
    fn promotional_mail_scores_below_personal_threads() {
        let promotional = score_mail(&MailEvidence {
            subject: "Last chance: 40% off everything — flash sale ends tonight",
            sender_address: "no-reply@marketing.example.com",
            sender_name: "Example Deals",
            replied: false,
            flagged: false,
            age_days: 1,
        });
        let newsletter = score_mail(&MailEvidence {
            subject: "Your weekly newsletter — unsubscribe anytime",
            sender_address: "news@updates.example.com",
            sender_name: "",
            replied: false,
            flagged: false,
            age_days: 0,
        });
        let personal = score_mail(&MailEvidence {
            subject: "Re: dinner on Friday?",
            sender_address: "ana.silva@example.com",
            sender_name: "Ana Silva",
            replied: true,
            flagged: false,
            age_days: 2,
        });
        let flagged = score_mail(&MailEvidence {
            subject: "Contract draft for review",
            sender_address: "james.lee@example.com",
            sender_name: "James Lee",
            replied: false,
            flagged: true,
            age_days: 5,
        });
        assert!(promotional < personal);
        assert!(promotional < flagged);
        assert!(newsletter < personal);
        assert!(promotional <= MAIL_SCORE_FLOOR);
        assert!(newsletter <= MAIL_SCORE_FLOOR);
        assert!(personal > MAIL_SCORE_FLOOR);
        assert!(flagged > MAIL_SCORE_FLOOR);
    }

    #[test]
    fn summary_prompt_forbids_markdown_and_dedupes_lines() {
        let scans = vec![complete(
            "workspace",
            vec![
                ScanMemory {
                    stable_id: "1".into(),
                    text: "PROJECT: omi (approved workspace)".into(),
                    captured_at_ms: None,
                },
                ScanMemory {
                    stable_id: "2".into(),
                    text: "PROJECT:  omi  (approved workspace)".into(),
                    captured_at_ms: None,
                },
            ],
            2,
        )];
        let prompts = summary_prompts(&scans, 0).unwrap_or_else(|| SummaryPrompts {
            local: String::new(),
            fallback: String::new(),
            emphasis_candidates: Vec::new(),
        });
        assert!(prompts.local.contains("no markdown of any kind"));
        assert!(prompts.local.contains("420 characters"));
        assert!(prompts.local.contains("At most 3 sentences"));
        assert!(prompts.local.contains("double asterisks"));
        assert_eq!(prompts.local.matches("PROJECT: omi").count(), 1);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn missing_mail_store_is_unavailable() {
        let root =
            std::env::temp_dir().join(format!("omi-missing-mail-store-{}", std::process::id()));
        assert_eq!(envelope(&root).unwrap_or(None), None);
    }
}
