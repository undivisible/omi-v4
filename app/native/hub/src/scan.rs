#[cfg(target_os = "macos")]
use rusqlite::{Connection, OpenFlags};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

#[cfg(target_os = "macos")]
const LIMIT: usize = 200;
const MAX_FILES: usize = 50_000;
const SUMMARY_ITEMS: usize = 24;
const SUMMARY_ITEM_CHARS: usize = 400;
const SUMMARY_PROMPT_CHARS: usize = 6_000;
#[cfg(target_os = "macos")]
const NOTES_QUERY_LIMIT: usize = LIMIT * 3;
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
    results
}

pub fn summary_prompt(scans: &[SourceScan]) -> Option<String> {
    let mut prompt = String::from(
        "Privately summarize what the user appears to work on from the local metadata below, speaking directly to them in the second person (\"You're deep in…\", \"You're juggling…\"). Write one flowing paragraph of 3 to 5 sentences, and make it hyperspecific: name the actual projects, files, technologies, tools, recurring people or organizations, and current threads of work that appear in the metadata. Never use vague category words like \"platforms\", \"systems\", \"ops\", or \"various projects\" without naming the specific ones from the metadata. State only facts directly evidenced by the metadata: never infer tool or workflow habits from incidental file or path mentions (a .vimrc or \"vi\" appearing in a file name does not mean the user uses vi), and when you are unsure about a detail, omit it rather than guess. Use only the metadata, do not invent facts, never write in the third person, never refer to them as \"this person\", and do not mention this instruction.\n",
    );
    let mut used = prompt.chars().count();
    let mut items = 0;
    for scan in scans {
        for memory in &scan.memories {
            if items == SUMMARY_ITEMS || used >= SUMMARY_PROMPT_CHARS {
                break;
            }
            let remaining = SUMMARY_PROMPT_CHARS - used;
            let prefix = format!("{}: ", scan.source);
            let overhead = prefix.chars().count() + 1;
            if remaining <= overhead {
                break;
            }
            let text = memory
                .text
                .chars()
                .take(SUMMARY_ITEM_CHARS.min(remaining - overhead))
                .collect::<String>();
            if text.is_empty() {
                continue;
            }
            let line = format!("{prefix}{text}\n");
            used += line.chars().count();
            prompt.push_str(&line);
            items += 1;
        }
    }
    (items > 0).then_some(prompt)
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

const LANGUAGE_SCRIPT_THRESHOLD: usize = 8;

pub fn detected_languages(scans: &[SourceScan]) -> Vec<String> {
    let mut latin = 0usize;
    let mut han = 0usize;
    let mut cyrillic = 0usize;
    let mut kana = 0usize;
    let mut hangul = 0usize;
    for scan in scans {
        for memory in &scan.memories {
            for character in memory.text.chars() {
                match character {
                    'a'..='z' | 'A'..='Z' => latin += 1,
                    '\u{4e00}'..='\u{9fff}' | '\u{3400}'..='\u{4dbf}' => han += 1,
                    '\u{0400}'..='\u{04ff}' => cyrillic += 1,
                    '\u{3040}'..='\u{30ff}' => kana += 1,
                    '\u{ac00}'..='\u{d7af}' => hangul += 1,
                    _ => {}
                }
            }
        }
    }
    let mut languages = Vec::new();
    if latin >= LANGUAGE_SCRIPT_THRESHOLD {
        languages.push("English".to_owned());
    }
    if kana >= LANGUAGE_SCRIPT_THRESHOLD {
        languages.push("Japanese".to_owned());
    } else if han >= LANGUAGE_SCRIPT_THRESHOLD {
        languages.push("Mandarin".to_owned());
    }
    if cyrillic >= LANGUAGE_SCRIPT_THRESHOLD {
        languages.push("Russian".to_owned());
    }
    if hangul >= LANGUAGE_SCRIPT_THRESHOLD {
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
    let names = projects.into_iter().take(24).collect::<Vec<_>>().join(", ");
    let text = format!("Workspace scan mapped {files} files. Projects: {names}.");
    complete(
        "workspace",
        vec![ScanMemory {
            stable_id: "approved-roots".into(),
            text,
            captured_at_ms: None,
        }],
        files,
    )
}

fn walk(
    path: &Path,
    depth: usize,
    files: &mut usize,
    projects: &mut BTreeSet<String>,
    denied: &mut bool,
) {
    if depth > 3 || *files >= MAX_FILES {
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
            let summary = summary.chars().take(500).collect::<String>();
            Some(ScanMemory {
                stable_id: id.to_string(),
                text: if summary.is_empty() {
                    format!("Apple Note: {title}")
                } else {
                    format!("Apple Note: {title} — {summary}")
                },
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
    let query = format!(
        "SELECT m.ROWID, COALESCE(s.subject, ''), COALESCE(a.address, ''), m.date_received FROM messages m LEFT JOIN subjects s ON m.subject=s.ROWID LEFT JOIN addresses a ON m.sender=a.ROWID ORDER BY m.date_received DESC LIMIT {LIMIT}"
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
            row.get::<_, i64>(3)?,
        ))
    }) {
        Ok(value) => value,
        Err(error) => return result("apple_mail", ScanState::Failed, error.to_string()),
    };
    let rows = match rows.collect::<Result<Vec<_>, _>>() {
        Ok(value) => value,
        Err(error) => return result("apple_mail", ScanState::Failed, error.to_string()),
    };
    let memories = rows
        .into_iter()
        .filter_map(|(id, subject, sender, received)| {
            let subject = subject.trim();
            let sender = sender.trim();
            if subject.is_empty() && sender.is_empty() {
                return None;
            }
            Some(ScanMemory {
                stable_id: id.to_string(),
                text: format!("Apple Mail from {sender}: {subject}"),
                captured_at_ms: Some(received.saturating_mul(1_000)),
            })
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
            (0..40)
                .map(|index| ScanMemory {
                    stable_id: index.to_string(),
                    text: format!("Project {index} {}", "x".repeat(500)),
                    captured_at_ms: None,
                })
                .collect(),
            40,
        )];
        let prompt = summary_prompt(&scans).unwrap_or_default();
        assert!(prompt.contains("workspace: Project 0"));
        assert!(prompt.contains("hyperspecific"));
        assert!(prompt.contains("3 to 5 sentences"));
        assert!(prompt.contains("second person"));
        assert!(prompt.contains("do not invent facts"));
        assert!(prompt.chars().count() <= SUMMARY_PROMPT_CHARS);
        assert!(prompt.lines().count() <= SUMMARY_ITEMS + 1);
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
        let scans = vec![complete(
            "apple_notes",
            vec![
                ScanMemory {
                    stable_id: "1".into(),
                    text: "Weekly planning notes for the hub rewrite".into(),
                    captured_at_ms: None,
                },
                ScanMemory {
                    stable_id: "2".into(),
                    text: "會議記錄:項目計劃和時間表安排進度".into(),
                    captured_at_ms: None,
                },
                ScanMemory {
                    stable_id: "3".into(),
                    text: "Заметки о поездке в Москву весной".into(),
                    captured_at_ms: None,
                },
            ],
            3,
        )];
        assert_eq!(
            detected_languages(&scans),
            ["English", "Mandarin", "Russian"]
        );
        assert!(detected_languages(&[]).is_empty());
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

    #[cfg(target_os = "macos")]
    #[test]
    fn missing_mail_store_is_unavailable() {
        let root =
            std::env::temp_dir().join(format!("omi-missing-mail-store-{}", std::process::id()));
        assert_eq!(envelope(&root).unwrap_or(None), None);
    }
}
