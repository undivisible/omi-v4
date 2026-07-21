use crate::signals::{
    AudioChunk, CaptureSource, ClientCommand, Command, MemoryCaptured, MemorySearchItem,
    MemorySearchResults, NativeError, NativeEvent, RuntimePhase, RuntimeStatus, ToolProgress,
    ToolStatus,
};
use std::collections::{HashMap, hash_map::Entry};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex, mpsc};
use tokio::task::{JoinError, JoinHandle, JoinSet, spawn_blocking};
use tokio_util::sync::CancellationToken;
use zkr::{MemoryDb, MemoryRef, PersonId, RememberInput, SearchInput, SourceKind, TenantId};

const COMMAND_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_COMMANDS: usize = 32;
const AUDIO_QUEUE_CAPACITY: usize = 32;
const MAX_ACTIVE_AUDIO_SESSIONS: usize = 8;
const AUDIO_SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(30);

struct MemoryContext {
    database: MemoryDb,
    tenant_id: TenantId,
    person_id: PersonId,
}

#[derive(Default)]
struct RuntimeState {
    memory: Option<Arc<StdMutex<MemoryContext>>>,
    configuration_generation: u64,
}

struct AudioSession {
    next_sequence: u64,
    accepted_bytes: u64,
    sample_rate_hz: u32,
    channels: u8,
    encoding: crate::signals::AudioEncoding,
    last_seen: Instant,
}

#[derive(Default)]
struct AudioSessions(HashMap<String, AudioSession>);

struct AudioProgress {
    request_id: String,
    status: ToolStatus,
    detail: String,
}

struct AudioAcceptError {
    request_id: String,
    code: &'static str,
    message: String,
}

#[derive(Debug, Eq, PartialEq)]
enum ActivationError {
    Capacity,
    Duplicate,
}

pub struct AudioDispatcher {
    receiver: mpsc::Receiver<AudioChunk>,
    sessions: AudioSessions,
}

impl AudioDispatcher {
    pub fn channel() -> (mpsc::Sender<AudioChunk>, Self) {
        let (sender, receiver) = mpsc::channel(AUDIO_QUEUE_CAPACITY);
        (
            sender,
            Self {
                receiver,
                sessions: AudioSessions::default(),
            },
        )
    }

    pub async fn run(mut self) {
        while let Some(chunk) = self.receiver.recv().await {
            match self.sessions.accept(chunk) {
                Ok(Some(next)) => {
                    progress(&next.request_id, "audio", next.status, Some(&next.detail));
                }
                Ok(None) => {}
                Err(failure) => error(
                    Some(failure.request_id),
                    failure.code,
                    &failure.message,
                    false,
                ),
            }
        }
    }
}

impl AudioSessions {
    fn accept(&mut self, chunk: AudioChunk) -> Result<Option<AudioProgress>, AudioAcceptError> {
        self.accept_at(chunk, Instant::now())
    }

    fn accept_at(
        &mut self,
        chunk: AudioChunk,
        now: Instant,
    ) -> Result<Option<AudioProgress>, AudioAcceptError> {
        self.0.retain(|_, session| {
            now.saturating_duration_since(session.last_seen) < AUDIO_SESSION_IDLE_TIMEOUT
        });
        if !self.0.contains_key(&chunk.request_id) && self.0.len() >= MAX_ACTIVE_AUDIO_SESSIONS {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "audio_capacity_exceeded",
                message: "too many active audio sessions".to_owned(),
            });
        }
        let session = self
            .0
            .entry(chunk.request_id.clone())
            .or_insert_with(|| AudioSession {
                next_sequence: 0,
                accepted_bytes: 0,
                sample_rate_hz: chunk.sample_rate_hz,
                channels: chunk.channels,
                encoding: chunk.encoding,
                last_seen: now,
            });
        if chunk.sequence != session.next_sequence {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "invalid_audio_sequence",
                message: format!(
                    "expected audio sequence {}, received {}",
                    session.next_sequence, chunk.sequence
                ),
            });
        }
        if chunk.sample_rate_hz != session.sample_rate_hz
            || chunk.channels != session.channels
            || chunk.encoding != session.encoding
        {
            return Err(AudioAcceptError {
                request_id: chunk.request_id,
                code: "audio_format_changed",
                message: "audio format changed during an active session".to_owned(),
            });
        }
        let first_chunk = session.next_sequence == 0;
        let next_sequence =
            session
                .next_sequence
                .checked_add(1)
                .ok_or_else(|| AudioAcceptError {
                    request_id: chunk.request_id.clone(),
                    code: "audio_counter_overflow",
                    message: "audio sequence overflowed".to_owned(),
                })?;
        let accepted_bytes = session
            .accepted_bytes
            .checked_add(chunk.bytes.len() as u64)
            .ok_or_else(|| AudioAcceptError {
                request_id: chunk.request_id.clone(),
                code: "audio_counter_overflow",
                message: "accepted audio byte count overflowed".to_owned(),
            })?;
        session.next_sequence = next_sequence;
        session.accepted_bytes = accepted_bytes;
        session.last_seen = now;
        let progress = if chunk.end_of_stream {
            self.0.remove(&chunk.request_id);
            Some((
                ToolStatus::Complete,
                format!("accepted {accepted_bytes} audio bytes"),
            ))
        } else if first_chunk {
            Some((ToolStatus::Running, "audio stream accepted".to_owned()))
        } else {
            None
        };
        Ok(progress.map(|(status, detail)| AudioProgress {
            request_id: chunk.request_id,
            status,
            detail,
        }))
    }
}

pub struct CommandDispatcher {
    receiver: mpsc::Receiver<ClientCommand>,
    state: Arc<Mutex<RuntimeState>>,
    active: Arc<Mutex<HashMap<String, CancellationToken>>>,
}

impl CommandDispatcher {
    pub fn channel() -> (mpsc::Sender<ClientCommand>, Self) {
        let (sender, receiver) = mpsc::channel(COMMAND_QUEUE_CAPACITY);
        (
            sender,
            Self {
                receiver,
                state: Arc::new(Mutex::new(RuntimeState::default())),
                active: Arc::new(Mutex::new(HashMap::new())),
            },
        )
    }

    pub async fn run(mut self) {
        let mut tasks = JoinSet::new();
        loop {
            reap_ready(&mut tasks, &self.active).await;
            let command = tokio::select! {
                biased;
                joined = tasks.join_next(), if !tasks.is_empty() => {
                    reap_joined(joined, &self.active).await;
                    continue;
                }
                command = self.receiver.recv() => match command {
                    Some(command) => command,
                    None => break,
                },
            };
            let request_id = command.request_id.clone();
            if matches!(command.command, Command::Cancel) {
                cancel(&self.active, &request_id).await;
                continue;
            }

            let cancellation = CancellationToken::new();
            {
                let mut active = self.active.lock().await;
                match activate(&mut active, request_id.clone(), cancellation.clone()) {
                    Ok(()) => {}
                    Err(ActivationError::Capacity) => {
                        error(
                            Some(request_id),
                            "command_capacity_exceeded",
                            "too many active commands",
                            true,
                        );
                        continue;
                    }
                    Err(ActivationError::Duplicate) => {
                        error(
                            Some(request_id),
                            "duplicate_request",
                            "request_id is already active",
                            false,
                        );
                        continue;
                    }
                }
            }

            let configuration_generation =
                if matches!(command.command, Command::ConfigureMemory { .. }) {
                    let mut state = self.state.lock().await;
                    state.configuration_generation =
                        state.configuration_generation.saturating_add(1);
                    Some(state.configuration_generation)
                } else {
                    None
                };
            let state = Arc::clone(&self.state);
            tasks.spawn(async move {
                let outcome = tokio::spawn(execute(
                    command,
                    state,
                    cancellation,
                    configuration_generation,
                ))
                .await;
                (request_id, outcome)
            });
        }
        cancel_all(&self.active).await;
        while let Some(joined) = tasks.join_next().await {
            reap_joined(Some(joined), &self.active).await;
        }
    }
}

fn activate(
    active: &mut HashMap<String, CancellationToken>,
    request_id: String,
    cancellation: CancellationToken,
) -> Result<(), ActivationError> {
    let at_capacity = active.len() >= MAX_ACTIVE_COMMANDS;
    match active.entry(request_id) {
        Entry::Occupied(_) => Err(ActivationError::Duplicate),
        Entry::Vacant(_) if at_capacity => Err(ActivationError::Capacity),
        Entry::Vacant(entry) => {
            entry.insert(cancellation);
            Ok(())
        }
    }
}

type TrackedTaskResult = Result<(String, Result<(), JoinError>), JoinError>;

async fn reap_ready(
    tasks: &mut JoinSet<(String, Result<(), JoinError>)>,
    active: &Mutex<HashMap<String, CancellationToken>>,
) {
    while let Some(joined) = tasks.try_join_next() {
        reap_joined(Some(joined), active).await;
    }
}

async fn reap_joined(
    result: Option<TrackedTaskResult>,
    active: &Mutex<HashMap<String, CancellationToken>>,
) {
    match result {
        Some(Ok((request_id, outcome))) => {
            active.lock().await.remove(&request_id);
            if let Err(error_value) = outcome {
                error(
                    Some(request_id),
                    "native_task_failed",
                    &error_value.to_string(),
                    false,
                );
            }
        }
        Some(Err(error_value)) => {
            error(None, "native_task_failed", &error_value.to_string(), false);
        }
        None => {}
    }
}

async fn cancel_all(active: &Mutex<HashMap<String, CancellationToken>>) {
    for cancellation in active.lock().await.values() {
        cancellation.cancel();
    }
}

pub fn runtime_status(memory_available: bool) -> RuntimeStatus {
    RuntimeStatus {
        phase: RuntimePhase::Ready,
        detail: Some(format!("rx4 {}", rx4::VERSION)),
        computer_use_available: computer_use_available(),
        local_ai_available: false,
        memory_available,
        agent_harness_available: true,
    }
}

async fn execute(
    command: ClientCommand,
    state: Arc<Mutex<RuntimeState>>,
    cancellation: CancellationToken,
    configuration_generation: Option<u64>,
) {
    let request_id = command.request_id;
    if cancellation.is_cancelled() {
        cancelled(&request_id);
        return;
    }

    match command.command {
        Command::ConfigureMemory {
            database_path,
            tenant_id,
            person_id,
        } => {
            configure_memory(
                &request_id,
                &state,
                database_path,
                tenant_id,
                person_id,
                &cancellation,
                configuration_generation.unwrap_or_default(),
            )
            .await;
        }
        Command::CaptureEvent {
            source,
            occurred_at_ms,
            text,
            application,
            window_title,
        } => {
            capture(
                &request_id,
                &state,
                source,
                occurred_at_ms,
                text,
                application,
                window_title,
                &cancellation,
            )
            .await;
        }
        Command::SearchMemory { query, limit } => {
            search(&request_id, &state, query, limit, &cancellation).await;
        }
        Command::SendMessage { .. } => error(
            Some(request_id),
            "assistant_unavailable",
            "no model provider is configured",
            true,
        ),
        Command::ApprovalDecision { .. } => error(
            Some(request_id),
            "proposal_not_found",
            "no matching action proposal is active",
            false,
        ),
        Command::DeviceState { .. } => progress(
            &request_id,
            "device_state",
            ToolStatus::Complete,
            Some("device state accepted"),
        ),
        Command::Cancel => {}
    }
}

async fn configure_memory(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    database_path: String,
    tenant_id: String,
    person_id: String,
    cancellation: &CancellationToken,
    configuration_generation: u64,
) {
    if database_path.trim().is_empty() {
        error(
            Some(request_id.to_owned()),
            "invalid_memory_configuration",
            "database_path must not be empty",
            false,
        );
        return;
    }
    let tenant_id = match TenantId::new(tenant_id) {
        Ok(value) => value,
        Err(error_value) => {
            error(
                Some(request_id.to_owned()),
                "invalid_memory_configuration",
                &error_value.to_string(),
                false,
            );
            return;
        }
    };
    let person_id = match PersonId::new(person_id) {
        Ok(value) => value,
        Err(error_value) => {
            error(
                Some(request_id.to_owned()),
                "invalid_memory_configuration",
                &error_value.to_string(),
                false,
            );
            return;
        }
    };
    let task = spawn_blocking(move || {
        MemoryDb::open(database_path)
            .map(|database| MemoryContext {
                database,
                tenant_id,
                person_id,
            })
            .map_err(|error_value| error_value.to_string())
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(memory) => {
            let mut state = state.lock().await;
            if !configuration_is_current(&state, configuration_generation) {
                error(
                    Some(request_id.to_owned()),
                    "memory_configuration_superseded",
                    "a newer memory configuration replaced this request",
                    false,
                );
                return;
            }
            state.memory = Some(Arc::new(StdMutex::new(memory)));
            drop(state);
            NativeEvent::RuntimeStatus(runtime_status(true)).send();
            progress(
                request_id,
                "memory",
                ToolStatus::Complete,
                Some("memory ready"),
            );
        }
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_open_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn configuration_is_current(state: &RuntimeState, generation: u64) -> bool {
    state.configuration_generation == generation
}

#[allow(clippy::too_many_arguments)]
async fn capture(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    source: CaptureSource,
    occurred_at_ms: i64,
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
    cancellation: &CancellationToken,
) {
    let Some(text) = capture_text(text, application, window_title) else {
        error(
            Some(request_id.to_owned()),
            "invalid_capture",
            "capture contains no text",
            false,
        );
        return;
    };
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before capturing events",
            true,
        );
        return;
    };
    let ingestion_key = request_id.to_owned();
    let task = spawn_blocking(move || {
        let mut memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        remember_capture(&mut memory, ingestion_key, source, occurred_at_ms, text)
    });
    match await_mutating_blocking(task, cancellation).await {
        BlockingOutcome::Complete(remembered) => NativeEvent::MemoryCaptured(MemoryCaptured {
            request_id: request_id.to_owned(),
            source_id: remembered.source_id.0,
            evidence_id: remembered.evidence_id.0,
        })
        .send(),
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_capture_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

fn remember_capture(
    memory: &mut MemoryContext,
    ingestion_key: String,
    source: CaptureSource,
    occurred_at_ms: i64,
    text: String,
) -> Result<zkr::Remembered, String> {
    memory
        .database
        .remember(RememberInput {
            tenant_id: memory.tenant_id.clone(),
            person_id: memory.person_id.clone(),
            ingestion_key: Some(ingestion_key),
            kind: source_kind(source),
            text,
            captured_at: occurred_at_ms,
            claim: None,
        })
        .map_err(|error_value| error_value.to_string())
}

async fn search(
    request_id: &str,
    state: &Mutex<RuntimeState>,
    query: String,
    limit: u32,
    cancellation: &CancellationToken,
) {
    let Some(memory) = state.lock().await.memory.clone() else {
        error(
            Some(request_id.to_owned()),
            "memory_unavailable",
            "configure memory before searching",
            true,
        );
        return;
    };
    let task = spawn_blocking(move || {
        let memory = memory
            .lock()
            .map_err(|_| "memory database lock was poisoned".to_owned())?;
        memory
            .database
            .search(SearchInput {
                tenant_id: memory.tenant_id.clone(),
                person_id: memory.person_id.clone(),
                query,
                limit,
                query_embedding: None,
            })
            .map_err(|error_value| error_value.to_string())
    });
    match await_blocking(task, cancellation).await {
        BlockingOutcome::Complete(pack) => NativeEvent::MemorySearchResults(MemorySearchResults {
            request_id: request_id.to_owned(),
            query: pack.query,
            items: pack
                .items
                .into_iter()
                .map(|item| {
                    let (kind, id) = match item.memory {
                        MemoryRef::Source(id) => ("source", id.0),
                        MemoryRef::Evidence(id) => ("evidence", id.0),
                        MemoryRef::Claim(id) => ("claim", id.0),
                        MemoryRef::ProfileEntry(id) => ("profile_entry", id.0),
                        MemoryRef::DailyReview(id) => ("daily_review", id.0),
                    };
                    MemorySearchItem {
                        kind: kind.to_owned(),
                        id,
                        excerpt: item.excerpt,
                        relevance_basis_points: item.relevance_basis_points,
                        evidence_ids: item.evidence_ids.into_iter().map(|id| id.0).collect(),
                    }
                })
                .collect(),
            gaps: pack.gaps,
        })
        .send(),
        BlockingOutcome::Failed(error_value) => error(
            Some(request_id.to_owned()),
            "memory_search_failed",
            &error_value,
            false,
        ),
        BlockingOutcome::Cancelled => cancelled(request_id),
    }
}

enum BlockingOutcome<T> {
    Complete(T),
    Failed(String),
    Cancelled,
}

async fn await_blocking<T>(
    mut task: JoinHandle<Result<T, String>>,
    cancellation: &CancellationToken,
) -> BlockingOutcome<T>
where
    T: Send + 'static,
{
    tokio::select! {
        biased;
        () = cancellation.cancelled() => match task.await {
            Ok(_) | Err(_) => BlockingOutcome::Cancelled,
        },
        result = &mut task => match result {
            Ok(Ok(value)) => BlockingOutcome::Complete(value),
            Ok(Err(message)) => BlockingOutcome::Failed(message),
            Err(join_error) => BlockingOutcome::Failed(join_error.to_string()),
        },
    }
}

async fn await_mutating_blocking<T>(
    mut task: JoinHandle<Result<T, String>>,
    cancellation: &CancellationToken,
) -> BlockingOutcome<T>
where
    T: Send + 'static,
{
    tokio::select! {
        biased;
        () = cancellation.cancelled() => match task.await {
            Ok(_) | Err(_) => BlockingOutcome::Cancelled,
        },
        result = &mut task => match result {
            Ok(Ok(value)) => BlockingOutcome::Complete(value),
            Ok(Err(message)) => BlockingOutcome::Failed(message),
            Err(join_error) => BlockingOutcome::Failed(join_error.to_string()),
        },
    }
}

async fn cancel(active: &Mutex<HashMap<String, CancellationToken>>, request_id: &str) {
    if let Some(cancellation) = active.lock().await.get(request_id) {
        cancellation.cancel();
    } else {
        error(
            Some(request_id.to_owned()),
            "request_not_found",
            "no active request matched request_id",
            false,
        );
    }
}

fn capture_text(
    text: Option<String>,
    application: Option<String>,
    window_title: Option<String>,
) -> Option<String> {
    let mut parts = [application, window_title, text]
        .into_iter()
        .flatten()
        .filter_map(|value| {
            let value = value.trim();
            (!value.is_empty()).then(|| value.to_owned())
        });
    let first = parts.next()?;
    Some(parts.fold(first, |mut output, part| {
        output.push_str("\n\n");
        output.push_str(&part);
        output
    }))
}

fn source_kind(source: CaptureSource) -> SourceKind {
    match source {
        CaptureSource::Screen | CaptureSource::Clipboard | CaptureSource::Accessibility => {
            SourceKind::Screen
        }
        CaptureSource::OmiDevice => SourceKind::Audio,
        CaptureSource::Chat => SourceKind::Conversation,
    }
}

fn progress(request_id: &str, tool: &str, status: ToolStatus, detail: Option<&str>) {
    NativeEvent::ToolProgress(ToolProgress {
        request_id: request_id.to_owned(),
        tool: tool.to_owned(),
        status,
        detail: detail.map(str::to_owned),
    })
    .send();
}

fn cancelled(request_id: &str) {
    progress(
        request_id,
        "request",
        ToolStatus::Cancelled,
        Some("request cancelled"),
    );
}

fn error(request_id: Option<String>, code: &str, message: &str, retryable: bool) {
    NativeEvent::Error(NativeError {
        request_id,
        code: code.to_owned(),
        message: message.to_owned(),
        retryable,
    })
    .send();
}

#[cfg(feature = "computer-use")]
fn computer_use_available() -> bool {
    let permissions = rs_peekaboo::Peekaboo::new().permissions();
    permissions
        .get("accessibility")
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false)
        && permissions
            .get("screen_recording")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
}

#[cfg(not(feature = "computer-use"))]
fn computer_use_available() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::signals::AudioEncoding;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn capture_preserves_available_context() {
        assert_eq!(
            capture_text(
                Some("selected text".to_owned()),
                Some("Browser".to_owned()),
                Some("Memory".to_owned())
            ),
            Some("Browser\n\nMemory\n\nselected text".to_owned())
        );
        assert_eq!(capture_text(None, None, None), None);
    }

    #[test]
    fn capture_retry_reuses_one_durable_source_and_evidence() {
        let path = std::env::temp_dir().join(format!(
            "omi-v4-capture-retry-{}-{}.sqlite",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |duration| duration.as_nanos())
        ));
        let open = || {
            MemoryDb::open(&path)
                .map(|database| MemoryContext {
                    database,
                    tenant_id: TenantId::new("tenant-1")
                        .unwrap_or_else(|error_value| panic!("valid tenant: {error_value}")),
                    person_id: PersonId::new("person-1")
                        .unwrap_or_else(|error_value| panic!("valid person: {error_value}")),
                })
                .unwrap_or_else(|error_value| panic!("memory opens: {error_value}"))
        };
        let mut first_database = open();
        let first = remember_capture(
            &mut first_database,
            "capture-1".to_owned(),
            CaptureSource::Screen,
            1,
            "first capture".to_owned(),
        )
        .unwrap_or_else(|error_value| panic!("first capture succeeds: {error_value}"));
        drop(first_database);

        let mut reopened_database = open();
        let replay = remember_capture(
            &mut reopened_database,
            "capture-1".to_owned(),
            CaptureSource::Screen,
            1,
            "first capture".to_owned(),
        )
        .unwrap_or_else(|error_value| panic!("capture replay succeeds: {error_value}"));
        assert_eq!(replay.source_id, first.source_id);
        assert_eq!(replay.evidence_id, first.evidence_id);
        drop(reopened_database);
        std::fs::remove_file(path)
            .unwrap_or_else(|error_value| panic!("test database is removed: {error_value}"));
    }

    #[tokio::test]
    async fn cancellation_targets_active_request() {
        let active = Mutex::new(HashMap::from([(
            "request-1".to_owned(),
            CancellationToken::new(),
        )]));
        cancel(&active, "request-1").await;
        assert!(active.lock().await["request-1"].is_cancelled());
    }

    #[tokio::test]
    async fn cancellation_wins_before_a_blocking_result_is_published() {
        let cancellation = CancellationToken::new();
        cancellation.cancel();
        let task = spawn_blocking(|| Ok::<_, String>("late result"));

        assert!(matches!(
            await_blocking(task, &cancellation).await,
            BlockingOutcome::Cancelled
        ));
    }

    #[tokio::test]
    async fn mutating_cancellation_waits_for_the_side_effect() {
        let cancellation = CancellationToken::new();
        let completed = Arc::new(AtomicBool::new(false));
        let completed_in_task = Arc::clone(&completed);
        let task = spawn_blocking(move || {
            std::thread::sleep(Duration::from_millis(10));
            completed_in_task.store(true, Ordering::SeqCst);
            Ok::<_, String>(())
        });
        cancellation.cancel();

        assert!(matches!(
            await_mutating_blocking(task, &cancellation).await,
            BlockingOutcome::Cancelled
        ));
        assert!(completed.load(Ordering::SeqCst));
    }

    #[test]
    fn active_commands_are_bounded_and_duplicates_are_distinct() {
        let mut active = HashMap::new();
        for index in 0..MAX_ACTIVE_COMMANDS {
            assert_eq!(
                activate(
                    &mut active,
                    format!("request-{index}"),
                    CancellationToken::new()
                ),
                Ok(())
            );
        }
        assert_eq!(
            activate(
                &mut active,
                "request-0".to_owned(),
                CancellationToken::new()
            ),
            Err(ActivationError::Duplicate)
        );
        assert_eq!(
            activate(
                &mut active,
                "request-overflow".to_owned(),
                CancellationToken::new()
            ),
            Err(ActivationError::Capacity)
        );
    }

    #[tokio::test]
    async fn completed_tasks_are_reaped_before_more_work() {
        let active = Mutex::new(HashMap::from([(
            "request-1".to_owned(),
            CancellationToken::new(),
        )]));
        let mut tasks = JoinSet::new();
        tasks.spawn(async {
            let outcome = tokio::spawn(async {}).await;
            ("request-1".to_owned(), outcome)
        });
        tokio::task::yield_now().await;
        reap_ready(&mut tasks, &active).await;
        assert!(tasks.is_empty());
        assert!(active.lock().await.is_empty());
    }

    #[tokio::test]
    async fn panicked_tasks_release_their_active_slot() {
        let active = Mutex::new(HashMap::from([(
            "request-1".to_owned(),
            CancellationToken::new(),
        )]));
        let mut tasks = JoinSet::new();
        tasks.spawn(async {
            let outcome = tokio::spawn(async { panic!("boom") }).await;
            ("request-1".to_owned(), outcome)
        });
        let joined = tasks.join_next().await;
        reap_joined(joined, &active).await;
        assert!(active.lock().await.is_empty());
    }

    #[tokio::test]
    async fn closed_dispatcher_drains_accepted_commands() {
        let (sender, dispatcher) = CommandDispatcher::channel();
        sender
            .send(ClientCommand {
                request_id: "device-1".to_owned(),
                command: Command::DeviceState {
                    device_id: "omi-1".to_owned(),
                    connected: true,
                    battery_percent: Some(80),
                    firmware_version: None,
                },
            })
            .await
            .unwrap_or_else(|_| panic!("dispatcher must accept a command"));
        drop(sender);
        dispatcher.run().await;
    }

    #[test]
    fn newest_memory_configuration_wins() {
        let state = RuntimeState {
            memory: None,
            configuration_generation: 2,
        };
        assert!(!configuration_is_current(&state, 1));
        assert!(configuration_is_current(&state, 2));
    }

    #[test]
    fn audio_consumer_enforces_sequence_and_resets_after_end() {
        let mut sessions = AudioSessions::default();
        let chunk = |sequence, end_of_stream| AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream,
            bytes: vec![1, 2, 3],
        };

        let first = sessions.accept(chunk(0, false));
        assert!(matches!(
            first,
            Ok(Some(AudioProgress {
                status: ToolStatus::Running,
                ..
            }))
        ));
        assert!(sessions.accept(chunk(2, false)).is_err());
        let last = sessions.accept(chunk(1, true));
        assert!(matches!(
            last,
            Ok(Some(AudioProgress {
                status: ToolStatus::Complete,
                ..
            }))
        ));
        assert!(sessions.accept(chunk(0, false)).is_ok());
    }

    #[test]
    fn audio_consumer_bounds_active_sessions() {
        let mut sessions = AudioSessions::default();
        for index in 0..MAX_ACTIVE_AUDIO_SESSIONS {
            assert!(
                sessions
                    .accept(AudioChunk {
                        request_id: format!("voice-{index}"),
                        sequence: 0,
                        sample_rate_hz: 16_000,
                        channels: 1,
                        encoding: AudioEncoding::Opus,
                        end_of_stream: false,
                        bytes: vec![1],
                    })
                    .is_ok()
            );
        }
        assert!(
            sessions
                .accept(AudioChunk {
                    request_id: "one-too-many".to_owned(),
                    sequence: 0,
                    sample_rate_hz: 16_000,
                    channels: 1,
                    encoding: AudioEncoding::Opus,
                    end_of_stream: false,
                    bytes: vec![1],
                })
                .is_err()
        );
    }

    #[test]
    fn audio_consumer_rejects_format_drift() {
        let mut sessions = AudioSessions::default();
        let started = AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: 0,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![1],
        };
        assert!(sessions.accept(started).is_ok());
        let changed = AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: 1,
            sample_rate_hz: 48_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![1],
        };
        let Err(failure) = sessions.accept(changed) else {
            panic!("format drift must fail");
        };
        assert_eq!(failure.code, "audio_format_changed");
    }

    #[test]
    fn abandoned_audio_sessions_expire() {
        let mut sessions = AudioSessions::default();
        let started_at = Instant::now();
        for index in 0..MAX_ACTIVE_AUDIO_SESSIONS {
            assert!(
                sessions
                    .accept_at(
                        AudioChunk {
                            request_id: format!("voice-{index}"),
                            sequence: 0,
                            sample_rate_hz: 16_000,
                            channels: 1,
                            encoding: AudioEncoding::Opus,
                            end_of_stream: false,
                            bytes: vec![1],
                        },
                        started_at,
                    )
                    .is_ok()
            );
        }
        assert!(
            sessions
                .accept_at(
                    AudioChunk {
                        request_id: "replacement".to_owned(),
                        sequence: 0,
                        sample_rate_hz: 16_000,
                        channels: 1,
                        encoding: AudioEncoding::Opus,
                        end_of_stream: false,
                        bytes: vec![1],
                    },
                    started_at + AUDIO_SESSION_IDLE_TIMEOUT,
                )
                .is_ok()
        );
        assert_eq!(sessions.0.len(), 1);
    }

    #[test]
    fn audio_overflow_does_not_partially_advance_a_session() {
        let mut sessions = AudioSessions(HashMap::from([(
            "voice-1".to_owned(),
            AudioSession {
                next_sequence: u64::MAX,
                accepted_bytes: 7,
                sample_rate_hz: 16_000,
                channels: 1,
                encoding: AudioEncoding::Opus,
                last_seen: Instant::now(),
            },
        )]));
        let previous_seen = sessions.0["voice-1"].last_seen;
        let failure = sessions.accept(AudioChunk {
            request_id: "voice-1".to_owned(),
            sequence: u64::MAX,
            sample_rate_hz: 16_000,
            channels: 1,
            encoding: AudioEncoding::Opus,
            end_of_stream: false,
            bytes: vec![1],
        });
        assert!(matches!(
            failure,
            Err(AudioAcceptError {
                code: "audio_counter_overflow",
                ..
            })
        ));
        let session = &sessions.0["voice-1"];
        assert_eq!(session.next_sequence, u64::MAX);
        assert_eq!(session.accepted_bytes, 7);
        assert_eq!(session.last_seen, previous_seen);
    }
}
