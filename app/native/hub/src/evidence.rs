use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::scan::{ScanMemory, ScanState, SourceScan};

/// Bounds for every evidence collector. Each constant caps how much local
/// data is read so a scan stays fast and cannot balloon on large machines.
pub const MAX_APPS: usize = 120;
pub const MAX_BREW: usize = 80;
pub const MAX_PROJECTS: usize = 60;
pub const MAX_BROWSER_ROWS: usize = 80;
pub const BROWSER_WINDOW_DAYS: i64 = 14;
pub const SHELL_WINDOW_DAYS: i64 = 14;
pub const MAX_SHELL_COMMANDS: usize = 60;
pub const MAX_SSH_HOSTS: usize = 24;
pub const MAX_EDITOR_RECENTS: usize = 40;
/// Document skimming bounds: at most this many files are opened, preferring
/// the most recently modified, and at most this many bytes are read per file.
pub const MAX_DOC_READS: usize = 120;
pub const DOC_READ_BYTES: usize = 2048;
pub const MAX_XLSX_STRINGS: usize = 50;
pub const DOC_WALK_DEPTH: usize = 3;
/// Evidence lines are capped short so no single item dominates the prompt.
/// Document gists get a longer cap because they carry a title plus a one to
/// two line gist; everything else is a name-sized marker.
pub const EVIDENCE_LINE_CHARS: usize = 60;
pub const DOC_LINE_CHARS: usize = 200;
const ZIP_MAX_COMPRESSED: usize = 4 << 20;
const ZIP_MAX_UNCOMPRESSED: usize = 8 << 20;
const SECONDS_PER_DAY: i64 = 86_400;

const SENSITIVE_URL_MARKERS: &[&str] = &[
    "auth", "bank", "checkout", "login", "password", "signin", "sign-in", "token",
];
const SHELL_SECRET_MARKERS: &[&str] = &[
    "api_key",
    "apikey",
    "credential",
    "passwd",
    "password",
    "secret",
    "token",
    "key=",
];
const PROJECT_HOME_DIRS: &[&str] = &[
    "Documents",
    "Desktop",
    "Downloads",
    "projects",
    "Projects",
    "dev",
    "src",
    "work",
];

pub fn now_unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or(0)
}

fn mtime_unix(path: &Path) -> Option<i64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|value| value.as_secs() as i64)
}

fn age_days(now: i64, then: Option<i64>) -> Option<i64> {
    then.map(|then| ((now - then).max(0)) / SECONDS_PER_DAY)
}

pub fn normalize_line(value: &str) -> String {
    let mut words: Vec<&str> = Vec::new();
    for word in value.split_whitespace() {
        if words
            .last()
            .is_some_and(|last| last.eq_ignore_ascii_case(word))
        {
            continue;
        }
        words.push(word);
    }
    words.join(" ")
}

pub fn is_pure_numeric(value: &str) -> bool {
    let stripped: String = value
        .chars()
        .filter(|character| character.is_alphanumeric())
        .collect();
    !stripped.is_empty() && stripped.chars().all(|character| character.is_ascii_digit())
}

pub fn cap_chars(value: &str, limit: usize) -> String {
    if value.chars().count() <= limit {
        return value.to_owned();
    }
    let mut capped: String = value.chars().take(limit.saturating_sub(1)).collect();
    capped.push('…');
    capped
}

fn memory(stable_id: impl Into<String>, text: String, captured_at_ms: Option<i64>) -> ScanMemory {
    ScanMemory {
        stable_id: stable_id.into(),
        text,
        captured_at_ms,
    }
}

fn tagged(tag: &str, body: &str, limit: usize) -> Option<String> {
    let body = normalize_line(body);
    if body.is_empty() || is_pure_numeric(&body) {
        return None;
    }
    Some(format!("{tag}: {}", cap_chars(&body, limit)))
}

fn push_unique(memories: &mut Vec<ScanMemory>, seen: &mut BTreeSet<String>, item: ScanMemory) {
    let key = item.text.to_lowercase();
    if seen.insert(key) {
        memories.push(item);
    }
}

pub fn scan_apps(home: &Path, now: i64) -> SourceScan {
    let mut memories = Vec::new();
    let mut seen = BTreeSet::new();
    let mut installed: Vec<(i64, String)> = Vec::new();
    for root in [PathBuf::from("/Applications"), home.join("Applications")] {
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(stem) = name.strip_suffix(".app") else {
                continue;
            };
            let modified = mtime_unix(&entry.path()).unwrap_or(0);
            installed.push((modified, stem.to_owned()));
        }
    }
    installed.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (modified, name) in installed.into_iter().take(MAX_APPS) {
        let recent = age_days(now, Some(modified)).is_some_and(|days| days <= 30);
        let body = if recent {
            format!("{name} (updated recently)")
        } else {
            name.clone()
        };
        if let Some(text) = tagged("APP", &body, EVIDENCE_LINE_CHARS) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("app:{name}"), text, Some(modified * 1_000)),
            );
        }
    }
    for name in running_apps().into_iter().take(MAX_APPS) {
        if let Some(text) = tagged("APP", &format!("{name} (running now)"), EVIDENCE_LINE_CHARS) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("app-running:{name}"), text, Some(now * 1_000)),
            );
        }
    }
    for name in dock_apps().into_iter().take(MAX_APPS) {
        if let Some(text) = tagged(
            "APP",
            &format!("{name} (pinned in Dock)"),
            EVIDENCE_LINE_CHARS,
        ) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("app-dock:{name}"), text, None),
            );
        }
    }
    let mut brews = BTreeSet::new();
    for root in [
        "/opt/homebrew/Cellar",
        "/opt/homebrew/Caskroom",
        "/usr/local/Cellar",
    ] {
        let Ok(entries) = fs::read_dir(root) else {
            continue;
        };
        for entry in entries.flatten() {
            brews.insert(entry.file_name().to_string_lossy().into_owned());
        }
    }
    for name in brews.into_iter().take(MAX_BREW) {
        if let Some(text) = tagged("APP", &format!("{name} (Homebrew)"), EVIDENCE_LINE_CHARS) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("brew:{name}"), text, None),
            );
        }
    }
    finish("apps", memories)
}

#[cfg(target_os = "macos")]
fn running_apps() -> Vec<String> {
    let script = "tell application \"System Events\" to get name of every application process whose background only is false";
    let output = std::process::Command::new("/usr/bin/osascript")
        .arg("-e")
        .arg(script)
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&output.stdout)
        .split(", ")
        .map(|name| name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .collect()
}

#[cfg(not(target_os = "macos"))]
fn running_apps() -> Vec<String> {
    Vec::new()
}

#[cfg(target_os = "macos")]
fn dock_apps() -> Vec<String> {
    let output = std::process::Command::new("/usr/bin/defaults")
        .args(["read", "com.apple.dock", "persistent-apps"])
        .output();
    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    parse_dock_labels(&String::from_utf8_lossy(&output.stdout))
}

#[cfg(not(target_os = "macos"))]
fn dock_apps() -> Vec<String> {
    Vec::new()
}

#[cfg(any(target_os = "macos", test))]
pub fn parse_dock_labels(plist_text: &str) -> Vec<String> {
    plist_text
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            let value = line.strip_prefix("\"file-label\"")?;
            let value = value.trim_start().strip_prefix('=')?.trim();
            let value = value.trim_end_matches(';').trim().trim_matches('"');
            (!value.is_empty()).then(|| value.to_owned())
        })
        .collect()
}

pub fn scan_developer_activity(home: &Path, now: i64) -> SourceScan {
    let mut memories = Vec::new();
    let mut seen = BTreeSet::new();
    let mut projects: Vec<(i64, String)> = Vec::new();
    for dir in PROJECT_HOME_DIRS {
        let root = home.join(dir);
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') {
                continue;
            }
            let git = path.join(".git");
            if !git.exists() {
                continue;
            }
            let recency = mtime_unix(&git.join("FETCH_HEAD"))
                .or_else(|| mtime_unix(&git.join("HEAD")))
                .unwrap_or(0);
            projects.push((recency, name));
        }
    }
    projects.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (recency, name) in projects.into_iter().take(MAX_PROJECTS) {
        let days = age_days(now, Some(recency)).unwrap_or(i64::MAX);
        let body = if days <= 7 {
            format!("{name} (git repo, active this week)")
        } else if days <= 30 {
            format!("{name} (git repo, active this month)")
        } else {
            format!("{name} (git repo)")
        };
        if let Some(text) = tagged("PROJECT", &body, EVIDENCE_LINE_CHARS) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("project:{name}"), text, Some(recency * 1_000)),
            );
        }
    }
    for name in editor_recent_projects(home)
        .into_iter()
        .take(MAX_EDITOR_RECENTS)
    {
        if let Some(text) = tagged(
            "PROJECT",
            &format!("{name} (open in editor recently)"),
            EVIDENCE_LINE_CHARS,
        ) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("editor:{name}"), text, Some(now * 1_000)),
            );
        }
    }
    if let Ok(history) = fs::read_to_string(home.join(".zsh_history")) {
        for (command, count) in parse_zsh_history(&history, now)
            .into_iter()
            .take(MAX_SHELL_COMMANDS)
        {
            let body = if count > 1 {
                format!("{command} (x{count} in last two weeks)")
            } else {
                command.clone()
            };
            if let Some(text) = tagged("SHELL", &body, EVIDENCE_LINE_CHARS) {
                push_unique(
                    &mut memories,
                    &mut seen,
                    memory(format!("shell:{command}"), text, Some(now * 1_000)),
                );
            }
        }
    }
    if let Ok(config) = fs::read_to_string(home.join(".ssh/config")) {
        for host in parse_ssh_hosts(&config).into_iter().take(MAX_SSH_HOSTS) {
            if let Some(text) = tagged("SSH HOST", &host, EVIDENCE_LINE_CHARS) {
                push_unique(
                    &mut memories,
                    &mut seen,
                    memory(format!("ssh:{host}"), text, None),
                );
            }
        }
    }
    finish("developer", memories)
}

pub fn parse_zsh_history(contents: &str, now: i64) -> Vec<(String, usize)> {
    let cutoff = now - SHELL_WINDOW_DAYS * SECONDS_PER_DAY;
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    for line in contents.lines() {
        let Some(rest) = line.strip_prefix(": ") else {
            continue;
        };
        let Some((stamp, command)) = rest.split_once(';') else {
            continue;
        };
        let Some(seconds) = stamp
            .split(':')
            .next()
            .and_then(|value| value.trim().parse::<i64>().ok())
        else {
            continue;
        };
        if seconds < cutoff {
            continue;
        }
        let lower = command.to_lowercase();
        if SHELL_SECRET_MARKERS
            .iter()
            .any(|marker| lower.contains(marker))
        {
            continue;
        }
        let Some(summary) = summarize_shell_command(command) else {
            continue;
        };
        let entry = counts.entry(summary.clone()).or_insert(0);
        if *entry == 0 {
            order.push(summary);
        }
        *entry += 1;
    }
    let mut ranked: Vec<(String, usize)> = order
        .into_iter()
        .map(|command| {
            let count = counts.get(&command).copied().unwrap_or(0);
            (command, count)
        })
        .collect();
    ranked.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    ranked
}

fn summarize_shell_command(command: &str) -> Option<String> {
    let mut tokens = command.split_whitespace().peekable();
    let mut binary = None;
    for token in tokens.by_ref() {
        if token.contains('=') && binary.is_none() {
            continue;
        }
        if token == "sudo" {
            continue;
        }
        binary = Some(token);
        break;
    }
    let binary = binary?;
    let binary = binary.rsplit('/').next().unwrap_or(binary);
    if binary.is_empty() {
        return None;
    }
    let mut parts = vec![binary.to_owned()];
    for token in tokens {
        if parts.len() >= 3 {
            break;
        }
        if let Some(rest) = token.strip_prefix("~/") {
            parts.push(format!("~/{rest}"));
        } else if !token.starts_with('-') && !token.starts_with('/') && !token.contains("://") {
            parts.push(token.to_owned());
        }
    }
    Some(parts.join(" "))
}

pub fn parse_ssh_hosts(config: &str) -> Vec<String> {
    let mut hosts = Vec::new();
    let mut seen = BTreeSet::new();
    for line in config.lines() {
        let line = line.trim();
        let Some(rest) = line
            .strip_prefix("Host ")
            .or_else(|| line.strip_prefix("host "))
        else {
            continue;
        };
        for alias in rest.split_whitespace() {
            if alias.contains('*') || alias.contains('?') {
                continue;
            }
            if seen.insert(alias.to_lowercase()) {
                hosts.push(alias.to_owned());
            }
        }
    }
    hosts
}

fn editor_recent_projects(home: &Path) -> Vec<String> {
    let mut names = Vec::new();
    let mut seen = BTreeSet::new();
    let mut push = |raw: &str, names: &mut Vec<String>| {
        let name = raw
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .unwrap_or(raw)
            .to_owned();
        if !name.is_empty() && seen.insert(name.to_lowercase()) {
            names.push(name);
        }
    };
    let vscode = home.join("Library/Application Support/Code/User/globalStorage");
    if let Ok(contents) = fs::read_to_string(vscode.join("storage.json")) {
        for path in parse_vscode_recents(&contents) {
            push(&path, &mut names);
        }
    }
    for path in vscode_state_recents(&vscode.join("state.vscdb")) {
        push(&path, &mut names);
    }
    let jetbrains = home.join("Library/Application Support/JetBrains");
    if let Ok(entries) = fs::read_dir(&jetbrains) {
        for entry in entries.flatten() {
            let file = entry.path().join("options/recentProjects.xml");
            if let Ok(contents) = fs::read_to_string(&file) {
                for path in parse_jetbrains_recents(&contents) {
                    push(&path, &mut names);
                }
            }
        }
    }
    for path in zed_recent_projects(&home.join("Library/Application Support/Zed/db")) {
        push(&path, &mut names);
    }
    names
}

pub fn parse_vscode_recents(json_text: &str) -> Vec<String> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(json_text) else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    collect_uris(&value, &mut paths);
    paths
}

fn collect_uris(value: &serde_json::Value, paths: &mut Vec<String>) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, inner) in map {
                if (key == "folderUri" || key == "fileUri" || key == "workspace")
                    && let Some(uri) = inner.as_str()
                    && let Some(path) = uri.strip_prefix("file://")
                {
                    paths.push(path.to_owned());
                } else {
                    collect_uris(inner, paths);
                }
            }
        }
        serde_json::Value::Array(items) => {
            for inner in items {
                collect_uris(inner, paths);
            }
        }
        _ => {}
    }
}

fn vscode_state_recents(path: &Path) -> Vec<String> {
    if !path.is_file() {
        return Vec::new();
    }
    let Ok(connection) = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    ) else {
        return Vec::new();
    };
    let value: Result<String, _> = connection.query_row(
        "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'",
        [],
        |row| row.get(0),
    );
    value
        .map(|json| parse_vscode_recents(&json))
        .unwrap_or_default()
}

pub fn parse_jetbrains_recents(xml_text: &str) -> Vec<String> {
    let mut paths = Vec::new();
    let mut rest = xml_text;
    while let Some(start) = rest.find("key=\"") {
        rest = &rest[start + 5..];
        let Some(end) = rest.find('"') else {
            break;
        };
        let value = &rest[..end];
        if value.starts_with("$USER_HOME$/") || value.starts_with('/') {
            paths.push(value.replace("$USER_HOME$", "~"));
        }
        rest = &rest[end..];
    }
    paths
}

fn zed_recent_projects(root: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(root) else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    for entry in entries.flatten() {
        let database = entry.path().join("db.sqlite");
        if !database.is_file() {
            continue;
        }
        let Ok(connection) = rusqlite::Connection::open_with_flags(
            &database,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        ) else {
            continue;
        };
        let Ok(mut statement) = connection
            .prepare("SELECT local_paths FROM workspaces ORDER BY timestamp DESC LIMIT 20")
        else {
            continue;
        };
        let Ok(rows) = statement.query_map([], |row| row.get::<_, Vec<u8>>(0)) else {
            continue;
        };
        for row in rows.flatten() {
            let text = String::from_utf8_lossy(&row);
            for part in text.split('\u{0}') {
                let part = part.trim_matches(|character: char| !character.is_ascii_graphic());
                if part.starts_with('/') && part.len() > 1 {
                    paths.push(part.to_owned());
                }
            }
        }
    }
    paths
}

pub fn scan_browsing(home: &Path, now: i64) -> SourceScan {
    let mut memories = Vec::new();
    let mut seen = BTreeSet::new();
    let mut rows: Vec<(i64, String, String)> = Vec::new();
    let safari = home.join("Library/Safari/History.db");
    let mut denied = false;
    if safari.is_file() {
        match browser_history_rows(&safari, BrowserKind::Safari, now) {
            Ok(mut safari_rows) => rows.append(&mut safari_rows),
            Err(BrowserError::Denied) => denied = true,
            Err(BrowserError::Other) => {}
        }
    }
    let chrome = home.join("Library/Application Support/Google/Chrome/Default/History");
    if chrome.is_file()
        && let Some(copy) = copy_to_private_temp(&chrome)
        && let Ok(mut chrome_rows) = browser_history_rows(&copy.path, BrowserKind::Chrome, now)
    {
        rows.append(&mut chrome_rows);
    }
    rows.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (visits, domain, title) in rows.into_iter().take(MAX_BROWSER_ROWS) {
        let body = if title.is_empty() {
            domain.clone()
        } else {
            format!("{domain} — {title}")
        };
        if let Some(text) = tagged("BROWSING", &body, EVIDENCE_LINE_CHARS) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(format!("browse:{domain}:{visits}"), text, Some(now * 1_000)),
            );
        }
    }
    if memories.is_empty() && denied {
        return SourceScan {
            source: "browsing".into(),
            state: ScanState::Denied,
            items_found: 0,
            detail: "Full Disk Access is required to read browser history.".into(),
            memories: Vec::new(),
        };
    }
    finish("browsing", memories)
}

enum BrowserKind {
    Safari,
    Chrome,
}

enum BrowserError {
    Denied,
    Other,
}

struct PrivateTempCopy {
    path: PathBuf,
    directory: PathBuf,
}

impl Drop for PrivateTempCopy {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
        let _ = fs::remove_dir(&self.directory);
    }
}

/// Chrome keeps its History database locked while running, so the file is
/// copied into a private per-run 0700/0600 temp directory (mirroring the
/// meeting_capture temp pattern) and deleted immediately after the query.
fn copy_to_private_temp(source: &Path) -> Option<PrivateTempCopy> {
    let directory = std::env::temp_dir().join(format!(
        "omi-scan-{}-{}",
        std::process::id(),
        now_unix_seconds()
    ));
    fs::create_dir_all(&directory).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&directory, fs::Permissions::from_mode(0o700));
    }
    let path = directory.join("history-copy.db");
    fs::copy(source, &path).ok()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
    Some(PrivateTempCopy { path, directory })
}

fn browser_history_rows(
    path: &Path,
    kind: BrowserKind,
    now: i64,
) -> Result<Vec<(i64, String, String)>, BrowserError> {
    let connection = rusqlite::Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|error| {
        let message = error.to_string();
        if message.contains("unable to open") || message.contains("not authorized") {
            BrowserError::Denied
        } else {
            BrowserError::Other
        }
    })?;
    let (query, cutoff) = match kind {
        BrowserKind::Safari => (
            "SELECT i.url, COALESCE(MAX(v.title), ''), i.visit_count \
             FROM history_items i JOIN history_visits v ON v.history_item = i.id \
             WHERE v.visit_time > ?1 GROUP BY i.id ORDER BY i.visit_count DESC LIMIT 400",
            (now - BROWSER_WINDOW_DAYS * SECONDS_PER_DAY - 978_307_200) as f64,
        ),
        BrowserKind::Chrome => (
            "SELECT url, COALESCE(title, ''), visit_count FROM urls \
             WHERE last_visit_time > ?1 ORDER BY visit_count DESC LIMIT 400",
            ((now - BROWSER_WINDOW_DAYS * SECONDS_PER_DAY + 11_644_473_600) as f64) * 1_000_000.0,
        ),
    };
    let mut statement = connection.prepare(query).map_err(|_| BrowserError::Other)?;
    let rows = statement
        .query_map([cutoff], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .map_err(|_| BrowserError::Other)?;
    let mut best: BTreeMap<String, (i64, String)> = BTreeMap::new();
    for row in rows.flatten() {
        let (url, title, visits) = row;
        let Some(domain) = safe_domain(&url) else {
            continue;
        };
        let entry = best.entry(domain).or_insert((0, String::new()));
        entry.0 += visits.max(1);
        if entry.1.is_empty() && !looks_sensitive(&title.to_lowercase()) {
            entry.1 = normalize_line(&title);
        }
    }
    Ok(best
        .into_iter()
        .map(|(domain, (visits, title))| (visits, domain, title))
        .collect())
}

fn looks_sensitive(lower: &str) -> bool {
    SENSITIVE_URL_MARKERS
        .iter()
        .any(|marker| lower.contains(marker))
}

pub fn safe_domain(url: &str) -> Option<String> {
    let lower = url.to_lowercase();
    if looks_sensitive(&lower) {
        return None;
    }
    let rest = lower
        .split_once("://")
        .map_or(lower.as_str(), |(_, rest)| rest);
    let host = rest.split(['/', '?', '#']).next()?;
    let host = host.split('@').next_back()?;
    let host = host.split(':').next()?;
    let host = host.strip_prefix("www.").unwrap_or(host);
    (host.contains('.')
        && !host
            .chars()
            .all(|character| character.is_ascii_digit() || character == '.'))
    .then(|| host.to_owned())
}

/// Document skimming reads actual file contents to understand the work, not
/// just names. Content never leaves this process except inside the local
/// Foundation-Models prompt; the managed fallback prompt excludes it (see
/// scan::summary_prompts).
pub fn scan_documents(roots: &[PathBuf], home: &Path, now: i64) -> SourceScan {
    let mut candidates: Vec<(i64, PathBuf)> = Vec::new();
    let mut probe = |root: &Path| {
        collect_documents(root, 0, &mut candidates);
    };
    for root in roots {
        probe(root);
    }
    for dir in PROJECT_HOME_DIRS {
        probe(&home.join(dir));
    }
    candidates.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    candidates.dedup_by(|a, b| a.1 == b.1);
    let mut memories = Vec::new();
    let mut seen = BTreeSet::new();
    for (modified, path) in candidates.into_iter().take(MAX_DOC_READS) {
        let Some(gist) = document_gist(&path) else {
            continue;
        };
        let title = path
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_default();
        let body = if gist.is_empty() {
            title.clone()
        } else {
            format!("{title} — {gist}")
        };
        if let Some(text) = tagged("DOC", &body, DOC_LINE_CHARS) {
            push_unique(
                &mut memories,
                &mut seen,
                memory(
                    format!("doc:{}", path.to_string_lossy()),
                    text,
                    Some(modified * 1_000),
                ),
            );
        }
    }
    let _ = now;
    finish("documents", memories)
}

fn collect_documents(root: &Path, depth: usize, candidates: &mut Vec<(i64, PathBuf)>) {
    if depth > DOC_WALK_DEPTH || candidates.len() >= MAX_DOC_READS * 8 {
        return;
    }
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let Ok(kind) = entry.file_type() else {
            continue;
        };
        if kind.is_symlink() {
            continue;
        }
        if kind.is_dir() {
            if !matches!(
                name.as_str(),
                "node_modules" | "target" | "build" | "dist" | "Library" | "DerivedData"
            ) {
                collect_documents(&entry.path(), depth + 1, candidates);
            }
            continue;
        }
        let lower = name.to_lowercase();
        if lower.ends_with(".md")
            || lower.ends_with(".txt")
            || lower.ends_with(".docx")
            || lower.ends_with(".xlsx")
        {
            let modified = mtime_unix(&entry.path()).unwrap_or(0);
            candidates.push((modified, entry.path()));
        }
    }
}

fn document_gist(path: &Path) -> Option<String> {
    let lower = path.to_string_lossy().to_lowercase();
    let text = if lower.ends_with(".md") || lower.ends_with(".txt") {
        read_prefix(path, DOC_READ_BYTES)?
    } else if lower.ends_with(".docx") {
        let bytes = bounded_read(path)?;
        docx_text(&bytes)?
    } else if lower.ends_with(".xlsx") {
        let bytes = bounded_read(path)?;
        xlsx_strings(&bytes).join(" ")
    } else {
        return None;
    };
    let mut lines = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with("---"));
    let first = lines.next().unwrap_or("").trim_start_matches('#').trim();
    let second = lines.next().unwrap_or("").trim_start_matches('#').trim();
    let gist = normalize_line(&format!("{first} {second}"));
    Some(cap_chars(&gist, 160))
}

fn read_prefix(path: &Path, limit: usize) -> Option<String> {
    use std::io::Read;
    let mut file = fs::File::open(path).ok()?;
    let mut buffer = vec![0u8; limit];
    let read = file.read(&mut buffer).ok()?;
    buffer.truncate(read);
    Some(String::from_utf8_lossy(&buffer).into_owned())
}

fn bounded_read(path: &Path) -> Option<Vec<u8>> {
    let size = fs::metadata(path).ok()?.len() as usize;
    if size > ZIP_MAX_COMPRESSED {
        return None;
    }
    fs::read(path).ok()
}

pub fn docx_text(bytes: &[u8]) -> Option<String> {
    let xml = zip_extract(bytes, "word/document.xml")?;
    let xml = String::from_utf8_lossy(&xml);
    let mut text = String::new();
    let mut in_tag = false;
    for character in xml.chars() {
        match character {
            '<' => {
                in_tag = true;
                if !text.ends_with(' ') {
                    text.push(' ');
                }
            }
            '>' => in_tag = false,
            _ if !in_tag => text.push(character),
            _ => {}
        }
        if text.chars().count() >= DOC_READ_BYTES {
            break;
        }
    }
    let text = normalize_line(&text);
    (!text.is_empty()).then_some(text)
}

pub fn xlsx_strings(bytes: &[u8]) -> Vec<String> {
    let Some(xml) = zip_extract(bytes, "xl/sharedStrings.xml") else {
        return Vec::new();
    };
    let xml = String::from_utf8_lossy(&xml);
    let mut strings = Vec::new();
    let mut rest = xml.as_ref();
    while strings.len() < MAX_XLSX_STRINGS {
        let Some(start) = rest.find("<t") else {
            break;
        };
        rest = &rest[start + 2..];
        let Some(close) = rest.find('>') else {
            break;
        };
        if rest[..close].ends_with('/') {
            rest = &rest[close + 1..];
            continue;
        }
        rest = &rest[close + 1..];
        let Some(end) = rest.find("</t>") else {
            break;
        };
        let value = normalize_line(&rest[..end]);
        if !value.is_empty() {
            strings.push(value);
        }
        rest = &rest[end + 4..];
    }
    strings
}

/// Minimal read-only ZIP extraction for OOXML documents: finds the end of
/// central directory, walks central-directory entries, and inflates a single
/// named member. Bounded by ZIP_MAX_COMPRESSED / ZIP_MAX_UNCOMPRESSED.
pub fn zip_extract(bytes: &[u8], member: &str) -> Option<Vec<u8>> {
    let eocd = find_eocd(bytes)?;
    let entries = u16::from_le_bytes([bytes[eocd + 10], bytes[eocd + 11]]) as usize;
    let mut offset = u32::from_le_bytes([
        bytes[eocd + 16],
        bytes[eocd + 17],
        bytes[eocd + 18],
        bytes[eocd + 19],
    ]) as usize;
    for _ in 0..entries.min(4096) {
        if offset + 46 > bytes.len() || &bytes[offset..offset + 4] != b"PK\x01\x02" {
            return None;
        }
        let method = u16::from_le_bytes([bytes[offset + 10], bytes[offset + 11]]);
        let compressed = u32::from_le_bytes([
            bytes[offset + 20],
            bytes[offset + 21],
            bytes[offset + 22],
            bytes[offset + 23],
        ]) as usize;
        let uncompressed = u32::from_le_bytes([
            bytes[offset + 24],
            bytes[offset + 25],
            bytes[offset + 26],
            bytes[offset + 27],
        ]) as usize;
        let name_len = u16::from_le_bytes([bytes[offset + 28], bytes[offset + 29]]) as usize;
        let extra_len = u16::from_le_bytes([bytes[offset + 30], bytes[offset + 31]]) as usize;
        let comment_len = u16::from_le_bytes([bytes[offset + 32], bytes[offset + 33]]) as usize;
        let local_offset = u32::from_le_bytes([
            bytes[offset + 42],
            bytes[offset + 43],
            bytes[offset + 44],
            bytes[offset + 45],
        ]) as usize;
        let name_end = offset + 46 + name_len;
        if name_end > bytes.len() {
            return None;
        }
        let name = &bytes[offset + 46..name_end];
        if name == member.as_bytes() {
            if compressed > ZIP_MAX_COMPRESSED || uncompressed > ZIP_MAX_UNCOMPRESSED {
                return None;
            }
            return extract_local(bytes, local_offset, method, compressed);
        }
        offset = name_end + extra_len + comment_len;
    }
    None
}

fn find_eocd(bytes: &[u8]) -> Option<usize> {
    let window = bytes.len().min(66_000);
    let start = bytes.len() - window;
    (start..bytes.len().checked_sub(22)? + 1)
        .rev()
        .find(|&index| &bytes[index..index + 4] == b"PK\x05\x06")
}

fn extract_local(bytes: &[u8], offset: usize, method: u16, compressed: usize) -> Option<Vec<u8>> {
    if offset + 30 > bytes.len() || &bytes[offset..offset + 4] != b"PK\x03\x04" {
        return None;
    }
    let name_len = u16::from_le_bytes([bytes[offset + 26], bytes[offset + 27]]) as usize;
    let extra_len = u16::from_le_bytes([bytes[offset + 28], bytes[offset + 29]]) as usize;
    let data_start = offset + 30 + name_len + extra_len;
    let data_end = data_start.checked_add(compressed)?;
    if data_end > bytes.len() {
        return None;
    }
    let data = &bytes[data_start..data_end];
    match method {
        0 => Some(data.to_vec()),
        8 => miniz_oxide::inflate::decompress_to_vec_with_limit(data, ZIP_MAX_UNCOMPRESSED).ok(),
        _ => None,
    }
}

fn finish(source: &str, memories: Vec<ScanMemory>) -> SourceScan {
    let count = memories.len();
    SourceScan {
        source: source.into(),
        state: ScanState::Complete,
        items_found: count as u64,
        detail: format!("Collected {count} bounded local activity markers on-device."),
        memories,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn deflate(data: &[u8]) -> Vec<u8> {
        miniz_oxide::deflate::compress_to_vec(data, 6)
    }

    fn tiny_zip(member: &str, data: &[u8], stored: bool) -> Vec<u8> {
        let (method, payload): (u16, Vec<u8>) = if stored {
            (0, data.to_vec())
        } else {
            (8, deflate(data))
        };
        let mut zip = Vec::new();
        let name = member.as_bytes();
        zip.extend_from_slice(b"PK\x03\x04");
        zip.extend_from_slice(&[20, 0, 0, 0]);
        zip.extend_from_slice(&method.to_le_bytes());
        zip.extend_from_slice(&[0; 8]);
        zip.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(data.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(name.len() as u16).to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        zip.extend_from_slice(name);
        zip.extend_from_slice(&payload);
        let central = zip.len();
        zip.extend_from_slice(b"PK\x01\x02");
        zip.extend_from_slice(&[20, 0, 20, 0, 0, 0]);
        zip.extend_from_slice(&method.to_le_bytes());
        zip.extend_from_slice(&[0; 8]);
        zip.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(data.len() as u32).to_le_bytes());
        zip.extend_from_slice(&(name.len() as u16).to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        zip.extend_from_slice(&[0; 8]);
        zip.extend_from_slice(&0u32.to_le_bytes());
        zip.extend_from_slice(name);
        let central_size = zip.len() - central;
        zip.extend_from_slice(b"PK\x05\x06");
        zip.extend_from_slice(&[0; 4]);
        zip.extend_from_slice(&1u16.to_le_bytes());
        zip.extend_from_slice(&1u16.to_le_bytes());
        zip.extend_from_slice(&(central_size as u32).to_le_bytes());
        zip.extend_from_slice(&(central as u32).to_le_bytes());
        zip.extend_from_slice(&0u16.to_le_bytes());
        zip
    }

    #[test]
    fn docx_extraction_strips_tags_from_tiny_zip() {
        let xml = b"<w:document><w:p><w:t>Quarterly roadmap</w:t><w:t>for the hub</w:t></w:p></w:document>";
        let zip = tiny_zip("word/document.xml", xml, false);
        let text = docx_text(&zip).unwrap_or_default();
        assert!(text.contains("Quarterly roadmap"));
        assert!(text.contains("for the hub"));
        assert!(!text.contains('<'));
        let stored = tiny_zip("word/document.xml", xml, true);
        assert!(
            docx_text(&stored)
                .unwrap_or_default()
                .contains("Quarterly roadmap")
        );
    }

    #[test]
    fn xlsx_extraction_reads_shared_strings() {
        let xml = b"<sst><si><t>Budget 2026</t></si><si><t xml:space=\"preserve\">Vendor list</t></si><si><t/></si></sst>";
        let zip = tiny_zip("xl/sharedStrings.xml", xml, false);
        assert_eq!(xlsx_strings(&zip), vec!["Budget 2026", "Vendor list"]);
        assert!(zip_extract(&zip, "word/document.xml").is_none());
        assert!(docx_text(b"not a zip").is_none());
    }

    #[test]
    fn zsh_history_keeps_recent_commands_and_drops_secrets() {
        let now = 1_800_000_000i64;
        let recent = now - 3_600;
        let stale = now - 40 * SECONDS_PER_DAY;
        let history = format!(
            ": {recent}:0;cargo test\n: {recent}:0;cargo test\n: {stale}:0;vim old.txt\n: {recent}:0;export API_KEY=abc\n: {recent}:0;git push ~/projects/omi-v4\nplain line without stamp\n"
        );
        let ranked = parse_zsh_history(&history, now);
        assert_eq!(ranked[0], ("cargo test".to_owned(), 2));
        assert!(
            ranked
                .iter()
                .any(|(command, _)| command == "git push ~/projects/omi-v4")
        );
        assert!(
            !ranked
                .iter()
                .any(|(command, _)| command.contains("API_KEY"))
        );
        assert!(!ranked.iter().any(|(command, _)| command.contains("vim")));
    }

    #[test]
    fn ssh_hosts_keep_aliases_only() {
        let config = "Host ultramarine chimera\n  HostName 192.168.4.134\nHost *\n  User root\nHost deploy?\n";
        assert_eq!(parse_ssh_hosts(config), vec!["ultramarine", "chimera"]);
    }

    #[test]
    fn editor_recents_are_parsed_from_fixtures() {
        let json = r#"{"lastKnownMenubarData":{},"windowsState":{"lastActiveWindow":{"folder":"x"}},"profileAssociations":{"workspaces":{}},"history":{"entries":[{"folderUri":"file:///Users/max/projects/omi-v4"},{"fileUri":"file:///Users/max/notes.md"}]}}"#;
        let paths = parse_vscode_recents(json);
        assert!(paths.contains(&"/Users/max/projects/omi-v4".to_owned()));
        assert!(paths.contains(&"/Users/max/notes.md".to_owned()));
        let xml = r#"<application><component name="RecentProjectsManager"><option name="additionalInfo"><map><entry key="$USER_HOME$/projects/alpenglow"><value/></entry><entry key="other"/></map></option></component></application>"#;
        assert_eq!(parse_jetbrains_recents(xml), vec!["~/projects/alpenglow"]);
    }

    #[test]
    fn dock_labels_are_parsed_from_defaults_output() {
        let plist = "(\n{\n\"tile-data\" = {\n\"file-label\" = Safari;\n};\n},\n{\n\"tile-data\" = {\n\"file-label\" = \"Visual Studio Code\";\n};\n}\n)";
        assert_eq!(
            parse_dock_labels(plist),
            vec!["Safari", "Visual Studio Code"]
        );
    }

    #[test]
    fn browser_domains_hide_sensitive_urls() {
        assert_eq!(
            safe_domain("https://www.github.com/omi/pull/1"),
            Some("github.com".to_owned())
        );
        assert_eq!(
            safe_domain("https://docs.rs:443/rusqlite"),
            Some("docs.rs".to_owned())
        );
        assert_eq!(safe_domain("https://bank.example.com/"), None);
        assert_eq!(safe_domain("https://example.com/login?next=/"), None);
        assert_eq!(safe_domain("https://accounts.example.com/signin"), None);
        assert_eq!(safe_domain("http://127.0.0.1/dashboard"), None);
        assert_eq!(safe_domain("localhost"), None);
    }

    #[test]
    fn browser_history_fixture_rows_are_grouped_by_domain() {
        let directory =
            std::env::temp_dir().join(format!("omi-history-fixture-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap_or_else(|error| panic!("fixture: {error}"));
        let path = directory.join("chrome-history.db");
        let connection =
            rusqlite::Connection::open(&path).unwrap_or_else(|error| panic!("fixture: {error}"));
        connection
            .execute_batch(
                "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);",
            )
            .unwrap_or_else(|error| panic!("fixture: {error}"));
        let now = 1_800_000_000i64;
        let chrome_now = (now as f64 + 11_644_473_600.0) * 1_000_000.0;
        for (url, title, visits) in [
            ("https://github.com/omi/omi-v4", "omi-v4 repository", 40),
            ("https://github.com/omi/omi-v4/issues", "issues", 10),
            ("https://mybank.example/login", "Bank Login", 99),
        ] {
            connection
                .execute(
                    "INSERT INTO urls (url, title, visit_count, last_visit_time) VALUES (?1, ?2, ?3, ?4)",
                    rusqlite::params![url, title, visits, chrome_now as i64],
                )
                .unwrap_or_else(|error| panic!("fixture: {error}"));
        }
        drop(connection);
        let rows = match browser_history_rows(&path, BrowserKind::Chrome, now) {
            Ok(rows) => rows,
            Err(_) => panic!("fixture query failed"),
        };
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].1, "github.com");
        assert_eq!(rows[0].0, 50);
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn evidence_hygiene_normalizes_and_filters() {
        assert_eq!(normalize_line("  omi   omi hub  "), "omi hub");
        assert!(is_pure_numeric("123 456"));
        assert!(!is_pure_numeric("omi4"));
        assert!(tagged("PROJECT", "20260101", EVIDENCE_LINE_CHARS).is_none());
        let capped =
            tagged("PROJECT", &"name ".repeat(40), EVIDENCE_LINE_CHARS).unwrap_or_default();
        assert!(capped.chars().count() <= EVIDENCE_LINE_CHARS + "PROJECT: ".len());
        assert_eq!(capped, "PROJECT: name");
    }

    #[test]
    fn documents_scan_reads_markdown_gists() {
        let root = std::env::temp_dir().join(format!("omi-doc-fixture-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap_or_else(|error| panic!("fixture: {error}"));
        let mut file = fs::File::create(root.join("roadmap.md"))
            .unwrap_or_else(|error| panic!("fixture: {error}"));
        writeln!(
            file,
            "# Voice memory roadmap\n\nShip the onboarding scan rewrite next."
        )
        .unwrap_or_else(|error| panic!("fixture: {error}"));
        drop(file);
        let scan = scan_documents(
            std::slice::from_ref(&root),
            &root.join("nonexistent-home"),
            now_unix_seconds(),
        );
        assert_eq!(scan.state, ScanState::Complete);
        assert!(scan.memories.iter().any(|memory| {
            memory.text.starts_with("DOC: roadmap") && memory.text.contains("Voice memory roadmap")
        }));
        let _ = fs::remove_dir_all(&root);
    }
}
