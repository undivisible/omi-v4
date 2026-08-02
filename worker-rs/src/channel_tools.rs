//! The tools the channel assistant can invoke, and the pure shaping around
//! them. The D1 work each one does lives in `routes_channels.rs`.
//!
//! These exist to replace phrase matching. The dispatcher used to decide what a
//! message meant by looking at the words in it — a table of sign-in synonyms, a
//! word-count ceiling, a yes/no phrase list — and every one of those was a
//! guess that got "can you send me one of those codes again" wrong while
//! matching "sign in" inside a sentence about something else. The model already
//! reads the message; giving it the actions means it decides, and the code only
//! has to know how to perform them.
//!
//! What is deliberately not here: unlinking, resetting, and paying. Those are
//! destructive or spend money, and a model that mis-reads one sentence should
//! not be able to sign someone out. They stay as typed commands, which are an
//! explicit instruction rather than an inference.

use serde_json::{json, Value};

/// How many times a single inbound message may go back to the model to run
/// tools before it must answer with words.
///
/// Two is enough for every real sequence here — look something up, then answer,
/// or read the account state and then mint the right kind of code. The cap
/// exists because the loop spends a model call per round on an account that may
/// be paying nothing.
pub const MAX_TOOL_ROUNDS: u32 = 2;

/// The name of every tool, in one place, so the catalogue and the executor
/// cannot disagree about what exists.
pub const GET_SIGNIN_CODE: &str = "get_signin_code";
pub const GET_LINK_CODE: &str = "get_link_code";
pub const GET_ACCOUNT_STATUS: &str = "get_account_status";
pub const LIST_COMMANDS: &str = "list_commands";

pub const TOOL_NAMES: &[&str] = &[
    GET_SIGNIN_CODE,
    GET_LINK_CODE,
    GET_ACCOUNT_STATUS,
    LIST_COMMANDS,
];

fn tool(name: &str, description: &str) -> Value {
    json!({
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            // None of these take arguments. Everything a tool needs — which
            // chat, which account — is context the Worker holds and the model
            // does not, which is also what stops it from asking for a code on
            // someone else's behalf.
            "parameters": { "type": "object", "properties": {}, "required": [] },
        },
    })
}

/// The catalogue sent with every channel completion.
pub fn tool_schemas() -> Vec<Value> {
    vec![
        tool(
            GET_SIGNIN_CODE,
            "Mint a short-lived code that signs this person into the Omi app on a phone or \
desktop, as the same account they are talking to you from, with all of their memory. Call \
this whenever they want to use Omi on a device, get set up, add another device, or say they \
have been signed out — however they phrase it. Never invent a code yourself.",
        ),
        tool(
            GET_LINK_CODE,
            "Mint a code that connects this chat to an Omi account they are already signed \
into somewhere else. Call this only when they say they already have an account elsewhere and \
want this chat attached to it. For getting into the app, use get_signin_code instead.",
        ),
        tool(
            GET_ACCOUNT_STATUS,
            "Look up whether this chat is connected to an account, which account that is, and \
whether they have signed in on a device yet. Call this before answering anything about their \
account rather than guessing.",
        ),
        tool(
            LIST_COMMANDS,
            "List the typed commands this chat understands. Call this when they ask what they \
can do here or ask for help, so you quote the real list instead of remembering one.",
        ),
    ]
}

/// The instruction that goes with the catalogue.
///
/// It says "do not describe, do" because the failure this guards against is
/// specific and common: asked for a code, a model happily explains where codes
/// come from and never calls anything, and the user is left holding advice
/// instead of a code.
pub const TOOL_PROMPT: &str = "You have tools for the things you cannot do with words: minting sign-in and link codes, and reading this chat's account state. When someone wants one of those, call the tool — do not describe how they could get it themselves, and never make up a code, a status, or a command. Call a tool at most twice for one message, then answer in words with what it gave you.";

/// What a tool the executor does not recognise gets told.
///
/// A refusal, not an error: an unknown name is the model inventing a tool, and
/// the useful response is one it can recover from inside the same turn.
pub fn unknown_tool_result(name: &str) -> String {
    format!("No tool named {name} exists. Answer using the tools you were given, or in words.")
}

/// The result shape every tool returns. A flat JSON object because that is what
/// survives being read back by a model with no schema to check it against.
pub fn ok_result(fields: Value) -> String {
    let mut value = json!({ "ok": true });
    if let Some(map) = fields.as_object() {
        let obj = value.as_object_mut().expect("object");
        for (key, field) in map {
            obj.insert(key.clone(), field.clone());
        }
    }
    value.to_string()
}

/// A tool that could not do its job. The reason is written for the model to
/// relay, so it reads as something a person can act on.
pub fn failed_result(reason: &str) -> String {
    json!({ "ok": false, "error": reason }).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_named_tool_is_in_the_catalogue_and_vice_versa() {
        let schemas = tool_schemas();
        let names: Vec<String> = schemas
            .iter()
            .map(|s| s["function"]["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(names.len(), TOOL_NAMES.len());
        for name in TOOL_NAMES {
            assert!(names.iter().any(|n| n == name), "{name} has no schema");
        }
    }

    #[test]
    fn no_tool_takes_arguments_from_the_model() {
        // Which chat and which account are the Worker's to know. A tool that
        // accepted them would be a tool the model could point at someone else.
        for schema in tool_schemas() {
            let params = &schema["function"]["parameters"];
            assert_eq!(params["properties"], json!({}));
            assert_eq!(params["required"], json!([]));
        }
    }

    #[test]
    fn nothing_destructive_is_reachable_by_inference() {
        let names = TOOL_NAMES.join(" ");
        for forbidden in ["logout", "unlink", "reset", "delete", "subscribe", "pay"] {
            assert!(!names.contains(forbidden), "{forbidden} is model-invokable");
        }
    }

    #[test]
    fn the_signin_tool_is_described_by_intent_not_by_wording() {
        let schemas = tool_schemas();
        let signin = schemas
            .iter()
            .find(|s| s["function"]["name"] == GET_SIGNIN_CODE)
            .unwrap();
        let description = signin["function"]["description"].as_str().unwrap();
        // The whole point of moving off phrase matching is that the trigger is
        // what the person wants, not which words they used.
        assert!(description.contains("however they phrase it"));
        assert!(description.contains("another device"));
    }

    #[test]
    fn results_are_readable_json() {
        let ok = ok_result(json!({ "code": "ab12cd3", "expiresInMinutes": 10 }));
        let parsed: Value = serde_json::from_str(&ok).unwrap();
        assert_eq!(parsed["ok"], json!(true));
        assert_eq!(parsed["code"], json!("ab12cd3"));
        let failed: Value = serde_json::from_str(&failed_result("no chat")).unwrap();
        assert_eq!(failed["ok"], json!(false));
        assert_eq!(failed["error"], json!("no chat"));
    }

    #[test]
    fn an_invented_tool_is_answerable_rather_than_fatal() {
        let result = unknown_tool_result("delete_everything");
        assert!(result.contains("delete_everything"));
        assert!(result.contains("Answer using the tools"));
    }

    #[test]
    fn the_prompt_insists_on_calling_rather_than_explaining() {
        assert!(TOOL_PROMPT.contains("call the tool"));
        assert!(TOOL_PROMPT.contains("never make up a code"));
    }
}
