#[cfg(target_os = "macos")]
use rusqlite::{Connection, OpenFlags};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Component, Path, PathBuf};

#[cfg(target_os = "macos")]
const LIMIT: usize = 200;
const MAX_FILES: usize = 50_000;
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
