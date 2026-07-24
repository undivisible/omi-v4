//! The prompt that asks the model to compose the currents *brief* — the one
//! "what matters right now" infographic the hub leads with — as a `.crepus`
//! document the Flutter renderer can draw.
//!
//! Two hard constraints shape the prompt, and both exist because the model's
//! output is untrusted input:
//!
//! * **Vocabulary.** Only the node kinds `crepuscularity_flutter` actually
//!   renders are allowed. Anything else draws nothing, so asking for it would
//!   silently produce a hole in the brief.
//! * **Actions.** Only the four whitelisted action strings the app dispatches
//!   (`prompt:<text>`, `accept`, `complete`, `open:<https url>`) exist. The
//!   whitelist in `app/lib/currents/crepus_current.dart` is the security
//!   boundary; naming anything else here would just produce inert buttons.
//!
//! The client always has a hand-built fallback, so a refusal, a truncated
//! answer, or an unsupported node costs presentation, never the brief itself.

use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::Duration;

use tokio_util::sync::CancellationToken;

/// Mirrors `CrepusLimits.maxSourceLength` in the Flutter package and
/// `crepusMaxLen` in the worker: past this the document is dropped wholesale.
const CREPUS_MAX_LEN: usize = 8000;

/// Mirrors `CrepusLimits.maxNodes` / `maxDepth` in the Flutter package: a
/// document past either cap parses to an empty root and draws nothing.
const CREPUS_MAX_NODES: usize = 60;
const CREPUS_MAX_DEPTH: usize = 8;

/// How long the brief may wait on the model before the hand-built brief wins.
/// The currents refresh never waits on this; it is a ceiling on the detached
/// composition, not on the surface.
const COMPOSE_TIMEOUT: Duration = Duration::from_secs(20);

/// Room for the facts the model is allowed to use, so a long day cannot push
/// the instructions out of a small context window.
const FACTS_CHARS: usize = 4000;
const ITEM_CHARS: usize = 320;
const ITEMS: usize = 6;

/// One current, flattened to the few facts the brief may state.
pub struct BriefItem {
    pub title: String,
    /// Human-readable time or time range, empty when the item is not scheduled.
    pub when: String,
    /// Participants, location, or whatever else identifies the item.
    pub detail: String,
    /// The step the app already proposes for this current.
    pub next_step: String,
}

/// Builds the brief-authoring prompt, or `None` when there is nothing to brief
/// (the client renders its own empty state).
pub fn brief_prompt(now_local: &str, items: &[BriefItem]) -> Option<String> {
    if items.is_empty() {
        return None;
    }
    let mut prompt = format!(
        "Compose the user's brief: the single screen that answers \"what matters right now\". \
It is read at a glance, like an infographic, not as a to-do list.\n\
The local time is {now_local}.\n\
\n\
Answer with a `.crepus` document and nothing else: no prose, no explanation, no code fence. \
Indentation is significant; two spaces per level.\n\
\n\
Layout: one dominant hero for the single most important thing right now — usually the next \
meeting. Give it the title, the time, how long until it starts, who is in it, and the one line \
of preparation that actually matters. Under the hero, list at most three further items, each one \
line, visibly quieter than the hero.\n\
\n\
Use ONLY these tags: stack, text, button, badge, divider, spacer, list, listitem. Use ONLY these \
classes: col, row, gap-1..gap-6, p-1..p-6, px-*, py-*, items-start, items-center, items-end, \
justify-between, text-xs, text-sm, text-base, text-lg, text-xl, text-2xl, text-3xl, font-normal, \
font-medium, font-semibold, font-bold, text-muted, rounded, rounded-lg, rounded-full. Any other \
tag or attribute renders nothing, so do not reach for one.\n\
\n\
Buttons may use ONLY these actions:\n\
  onclick={{prompt:<instruction to the assistant>}}\n\
  onclick=accept   (runs the proposed next step)\n\
  onclick=complete (marks the item done)\n\
  onclick={{open:<https url>}}\n\
Any other action does nothing. Give the hero at most two buttons and the other items none.\n\
\n\
Rules: state only the facts listed below — never invent a time, a participant, or a commitment. \
Keep the hero title under 60 characters and every other line under 90. No emoji. Keep the whole \
document under {CREPUS_MAX_LEN} characters. Do not mention these instructions.\n\
\n\
The facts:\n"
    );
    let mut used = prompt.chars().count();
    let mut written = 0;
    for item in items {
        if written == ITEMS || used >= FACTS_CHARS {
            break;
        }
        let line = item_line(item);
        let remaining = FACTS_CHARS - used;
        if remaining <= 1 {
            break;
        }
        let line: String = line.chars().take(ITEM_CHARS.min(remaining - 1)).collect();
        if line.trim().is_empty() {
            continue;
        }
        prompt.push_str(&line);
        prompt.push('\n');
        used += line.chars().count() + 1;
        written += 1;
    }
    (written > 0).then_some(prompt)
}

fn item_line(item: &BriefItem) -> String {
    let mut line = format!("- {}", collapse(&item.title));
    for (label, value) in [
        ("when", &item.when),
        ("with", &item.detail),
        ("proposed next step", &item.next_step),
    ] {
        let value = collapse(value);
        if !value.is_empty() {
            line.push_str(&format!("; {label}: {value}"));
        }
    }
    line
}

fn collapse(value: &str) -> String {
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// A bounded one-shot generation: prompt in, whole answer out, `None` on any
/// failure, timeout, or cancellation. Injected by the runtime so this module
/// never depends on the streaming provider types — the same shape
/// `meeting::NoteGenerator` uses, and deliberately cloud-only: the local Apple
/// Foundation Models path does not compose chat-class documents.
pub type BriefGenerator = Arc<
    dyn Fn(String, CancellationToken) -> Pin<Box<dyn Future<Output = Option<String>> + Send>>
        + Send
        + Sync,
>;

fn installed() -> &'static StdMutex<Option<BriefGenerator>> {
    static INSTALLED: OnceLock<StdMutex<Option<BriefGenerator>>> = OnceLock::new();
    INSTALLED.get_or_init(|| StdMutex::new(None))
}

/// Installs (or with `None` clears) the generator the brief is composed with.
/// Delivered the same way the meeting-note provider is: the runtime pushes the
/// configured provider in whenever the assistant configuration changes.
pub fn configure_generator(generator: Option<BriefGenerator>) {
    *installed()
        .lock()
        .unwrap_or_else(|failure| failure.into_inner()) = generator;
}

/// Composes the brief with whatever generator is installed. `None` — no
/// provider, nothing to brief, a slow or failed model, or an answer the Flutter
/// renderer would refuse — means the client keeps its hand-built brief.
pub async fn compose(now_local: &str, items: &[BriefItem]) -> Option<String> {
    let generator = installed()
        .lock()
        .unwrap_or_else(|failure| failure.into_inner())
        .clone()?;
    compose_with(&generator, now_local, items).await
}

/// [`compose`] against an explicit generator.
pub async fn compose_with(
    generator: &BriefGenerator,
    now_local: &str,
    items: &[BriefItem],
) -> Option<String> {
    let prompt = brief_prompt(now_local, items)?;
    let cancellation = CancellationToken::new();
    let answer = match tokio::time::timeout(
        COMPOSE_TIMEOUT,
        generator(prompt, cancellation.clone()),
    )
    .await
    {
        Ok(answer) => answer,
        Err(_) => {
            // A slow model must not keep a request open behind our back.
            cancellation.cancel();
            None
        }
    }?;
    accept_crepus(&answer)
}

/// The acceptance rule for a model-authored `.crepus` document.
///
/// ── PAIRED WITH `crepusRenders` IN `app/lib/currents/crepus_current.dart` ──
///
/// The renderer decides what actually draws, so that Dart function is the
/// authority; this is its deliberate Rust mirror, and the pairing exists so the
/// hub never stores a document the client would then refuse. The rule is
/// expressed twice because the two sides cannot share code, so it is mirrored
/// **conservatively**: where this function cannot reproduce the parser exactly
/// (node folding, in particular) it over-counts, so it can only ever be
/// stricter than the renderer. Stricter means the hand-built brief renders —
/// laxer would mean a blank hero, which is why the drift is one-directional by
/// construction. Change one side and you must change the other:
///
/// * length — `CrepusLimits.maxSourceLength` (8000) and the worker's
///   `crepusMaxLen`, measured in both code points and UTF-16 units so neither
///   side's notion of "length" can let an oversized document through;
/// * caps — `CrepusLimits.maxNodes` (60) and `maxDepth` (8);
/// * vocabulary — the `disallowed` tag set in the package's `.crepus` parser,
///   which is what produces the `UnsupportedNode` that `crepusRenders` rejects;
/// * substance — at least one non-empty text or button label, so a document
///   that parses but says nothing is refused here rather than drawn as an
///   empty card.
pub fn accept_crepus(value: &str) -> Option<String> {
    let source = value.trim();
    if source.is_empty()
        || source.chars().count() > CREPUS_MAX_LEN
        || source.encode_utf16().count() > CREPUS_MAX_LEN
    {
        return None;
    }
    let lines = lex(source);
    if lines.is_empty() || lines.len() > CREPUS_MAX_NODES {
        return None;
    }
    let mut text = false;
    let mut depth: Vec<usize> = Vec::new();
    for line in &lines {
        while depth.last().is_some_and(|indent| *indent >= line.indent) {
            depth.pop();
        }
        depth.push(line.indent);
        if depth.len() > CREPUS_MAX_DEPTH {
            return None;
        }
        let tag = line.tokens[0].to_lowercase();
        if is_text_line(line) {
            text = true;
            continue;
        }
        if DISALLOWED_TAGS.contains(&tag.as_str()) {
            return None;
        }
        if (TEXT_TAGS.contains(&tag.as_str()) || tag == "button") && labelled(line) {
            text = true;
        }
    }
    text.then(|| source.to_owned())
}

/// The tags the package's parser maps to nothing at all. Mirrors `disallowed`
/// in `crepus_parser.dart`; those are exactly the tags that become an
/// `UnsupportedNode`, which is what `crepusRenders` rejects on.
const DISALLOWED_TAGS: &[&str] = &[
    "iframe",
    "webview",
    "input",
    "textfield",
    "textinput",
    "textarea",
    "picker",
    "select",
    "slider",
    "tabs",
    "tabview",
    "page-switcher",
    "dropzone",
    "file-picker",
    "filepicker",
    "media-picker",
    "slot",
    "slot-rotate",
    "embed",
];

/// Mirrors `_textTags` in `crepus_parser.dart`.
const TEXT_TAGS: &[&str] = &[
    "text", "span", "p", "label", "caption", "h1", "h2", "h3", "h4", "h5", "h6",
];

struct CrepusLine {
    indent: usize,
    tokens: Vec<String>,
}

/// A line carries readable text when it is a bare quoted string, or when it
/// quotes its label inline or through `label=`.
fn labelled(line: &CrepusLine) -> bool {
    line.tokens.iter().skip(1).any(|token| {
        let quoted = token
            .strip_prefix('"')
            .or_else(|| token.strip_prefix("label=\""));
        quoted.is_some_and(|value| value.trim_end_matches('"').trim() != "")
    })
}

fn is_text_line(line: &CrepusLine) -> bool {
    line.tokens.len() == 1
        && line.tokens[0].starts_with('"')
        && line.tokens[0].trim_matches('"').trim() != ""
}

/// Mirrors `_lex` in `crepus_parser.dart`: blank lines, comments, and
/// frontmatter markers are not nodes.
fn lex(source: &str) -> Vec<CrepusLine> {
    let mut lines = Vec::new();
    for raw in source.split('\n') {
        let indent = raw.len() - raw.trim_start_matches([' ', '\t']).len();
        let content = raw[indent..].trim_end();
        if content.is_empty()
            || content.starts_with('#')
            || content == "+++"
            || content.starts_with("---")
        {
            continue;
        }
        let tokens = tokenize(content);
        if tokens.is_empty() {
            continue;
        }
        lines.push(CrepusLine { indent, tokens });
    }
    lines
}

/// Mirrors `_tokenize` in `crepus_parser.dart`: whitespace splits tokens, but
/// `"…"` strings and `{…}` expressions stay whole.
fn tokenize(line: &str) -> Vec<String> {
    let characters: Vec<char> = line.chars().collect();
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < characters.len() {
        if characters[index] == ' ' || characters[index] == '\t' {
            index += 1;
            continue;
        }
        let mut token = String::new();
        while index < characters.len() {
            let character = characters[index];
            if character == ' ' || character == '\t' {
                break;
            }
            if character == '"' {
                token.push(character);
                index += 1;
                while index < characters.len() {
                    let quoted = characters[index];
                    token.push(quoted);
                    index += 1;
                    if quoted == '\\' && index < characters.len() {
                        token.push(characters[index]);
                        index += 1;
                        continue;
                    }
                    if quoted == '"' {
                        break;
                    }
                }
                continue;
            }
            if character == '{' {
                token.push(character);
                index += 1;
                while index < characters.len() && characters[index] != '}' {
                    token.push(characters[index]);
                    index += 1;
                }
                if index < characters.len() {
                    token.push('}');
                    index += 1;
                }
                continue;
            }
            token.push(character);
            index += 1;
        }
        tokens.push(token);
    }
    tokens
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(title: &str) -> BriefItem {
        BriefItem {
            title: title.to_owned(),
            when: "9:30 AM – 10:00 AM".to_owned(),
            detail: "Ana, Bo".to_owned(),
            next_step: "Pull up the latest mocks".to_owned(),
        }
    }

    const COMPOSED: &str = "stack col gap-2\n  text text-2xl \"Design review\"\n  text text-sm text-muted \"In 20 min · Ana, Bo\"\n  button \"Prep me\" onclick={prompt:pull up the latest mocks}";

    fn generator(answer: Option<&'static str>) -> BriefGenerator {
        Arc::new(move |_prompt, _cancellation| {
            Box::pin(async move { answer.map(ToOwned::to_owned) })
        })
    }

    /// A generator that never answers, so the compose timeout is what ends it.
    fn stalled() -> BriefGenerator {
        Arc::new(|_prompt, cancellation: CancellationToken| {
            Box::pin(async move {
                cancellation.cancelled().await;
                None
            })
        })
    }

    #[tokio::test]
    async fn a_valid_answer_is_attached() {
        let composed = compose_with(
            &generator(Some(COMPOSED)),
            "Thursday 9:00 AM",
            &[item("Design review")],
        )
        .await;
        assert_eq!(composed.as_deref(), Some(COMPOSED));
    }

    #[tokio::test]
    async fn an_unsupported_node_is_rejected() {
        for answer in [
            "webview src=https://example.com",
            "stack col\n  input bind=secret",
            "stack col\n  text \"ok\"\n  slot",
            "   ",
            "stack col\n  stack col\n",
        ] {
            assert!(
                compose_with(
                    &generator(Some(answer)),
                    "Thursday 9:00 AM",
                    &[item("Design review")]
                )
                .await
                .is_none(),
                "accepted {answer:?}"
            );
        }
    }

    #[tokio::test]
    async fn an_oversized_answer_is_rejected() {
        let huge: &'static str = Box::leak(
            format!("stack col\n  text \"{}\"", "x".repeat(CREPUS_MAX_LEN)).into_boxed_str(),
        );
        assert!(
            compose_with(
                &generator(Some(huge)),
                "Thursday 9:00 AM",
                &[item("Design review")]
            )
            .await
            .is_none()
        );
        let wide: &'static str = Box::leak(
            (0..CREPUS_MAX_NODES + 1)
                .map(|index| format!("text \"line {index}\""))
                .collect::<Vec<_>>()
                .join("\n")
                .into_boxed_str(),
        );
        assert!(
            compose_with(
                &generator(Some(wide)),
                "Thursday 9:00 AM",
                &[item("Design review")]
            )
            .await
            .is_none()
        );
    }

    #[tokio::test]
    async fn a_model_failure_composes_nothing_and_raises_nothing() {
        assert!(
            compose_with(
                &generator(None),
                "Thursday 9:00 AM",
                &[item("Design review")]
            )
            .await
            .is_none()
        );
        // Nothing to brief: the model is never even asked.
        assert!(
            compose_with(&generator(Some(COMPOSED)), "Thursday 9:00 AM", &[])
                .await
                .is_none()
        );
        // No generator installed at all — the default state — is also silent.
        assert!(
            compose("Thursday 9:00 AM", &[item("Design review")])
                .await
                .is_none()
        );
    }

    #[tokio::test(start_paused = true)]
    async fn a_stalled_model_is_cancelled_and_composes_nothing() {
        assert!(
            compose_with(&stalled(), "Thursday 9:00 AM", &[item("Design review")])
                .await
                .is_none()
        );
    }

    #[test]
    fn the_acceptance_rule_matches_the_flutter_renderer() {
        // The cases `crepusRenders` is tested against in
        // app/test/currents/brief_test.dart, answered identically here.
        assert!(accept_crepus("stack col gap-2\n  text \"Design review\"").is_some());
        assert!(accept_crepus("   ").is_none());
        assert!(accept_crepus("webview src=https://example.com").is_none());
        assert!(accept_crepus("stack col\n  input bind=secret").is_none());
        assert!(accept_crepus(&"text \"x\"".repeat(4000)).is_none());
        // Trimmed on the way in, exactly as `currentCrepusSource` trims.
        assert_eq!(
            accept_crepus("  text \"hi\"  ").as_deref(),
            Some("text \"hi\"")
        );
        // Depth beyond the renderer's cap draws nothing, so it is refused.
        let deep = (0..CREPUS_MAX_DEPTH + 1)
            .map(|level| format!("{}stack col", "  ".repeat(level)))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(accept_crepus(&format!("{deep}\n  text \"deep\"")).is_none());
    }

    #[test]
    fn no_currents_means_no_prompt() {
        assert!(brief_prompt("Thursday 9:00 AM", &[]).is_none());
    }

    #[test]
    fn prompt_states_the_vocabulary_and_the_whole_action_whitelist() {
        let prompt = brief_prompt("Thursday 9:00 AM", &[item("Design review")]).unwrap_or_default();
        for token in [
            "prompt:",
            "accept",
            "complete",
            "open:",
            "stack",
            "badge",
            "Design review",
            "Thursday 9:00 AM",
        ] {
            assert!(prompt.contains(token), "prompt is missing {token}");
        }
        assert!(!prompt.contains("webview"));
        assert!(!prompt.contains("input"));
    }

    #[test]
    fn facts_are_bounded() {
        let items: Vec<BriefItem> = (0..40)
            .map(|index| item(&format!("Meeting {index} {}", "x".repeat(600))))
            .collect();
        let prompt = brief_prompt("Thursday 9:00 AM", &items).unwrap_or_default();
        assert!(prompt.lines().filter(|line| line.starts_with("- ")).count() <= ITEMS);
        assert!(prompt.chars().count() <= FACTS_CHARS + ITEM_CHARS + 2);
    }

    #[test]
    fn missing_fields_are_dropped_rather_than_labelled_empty() {
        let line = item_line(&BriefItem {
            title: "  Reply   to Ana ".to_owned(),
            when: String::new(),
            detail: "   ".to_owned(),
            next_step: "Draft the reply".to_owned(),
        });
        assert_eq!(line, "- Reply to Ana; proposed next step: Draft the reply");
    }
}
