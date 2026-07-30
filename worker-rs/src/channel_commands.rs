//! Pure command-table logic ported from `worker/src/channel-commands.ts`. The
//! table, copy, email masking, and command parsing are host-testable; the DB
//! reads/writes (binding lookup, code issuance, unlink dispatch) live in the
//! wasm glue in `routes_channels.rs`.

use crate::{channel_auth::SIGNIN_CODE_TTL_MS, channel_link::LINK_CODE_TTL_MS};

/// A dispatchable command: primary name plus any aliases and a one-line
/// summary used in `/help` and the system-prompt injection.
pub struct ChannelCommand {
    pub name: &'static str,
    pub aliases: &'static [&'static str],
    pub summary: &'static str,
}

/// The single shared command table used by every channel.
pub const CHANNEL_COMMANDS: &[ChannelCommand] = &[
    ChannelCommand {
        name: "/help",
        aliases: &[],
        summary: "list what I understand here",
    },
    ChannelCommand {
        name: "/start",
        aliases: &[],
        summary: "link this chat to your Omi account",
    },
    ChannelCommand {
        name: "/signin",
        aliases: &[],
        summary: "get a code to sign in with this chat",
    },
    ChannelCommand {
        name: "/signup",
        aliases: &["/new"],
        summary: "how to create an Omi account and link this chat",
    },
    ChannelCommand {
        name: "/subscribe",
        aliases: &["/upgrade"],
        summary: "get a payment link for your subscription",
    },
    ChannelCommand {
        name: "/status",
        aliases: &[],
        summary: "show whether this chat is linked",
    },
    ChannelCommand {
        name: "/whoami",
        aliases: &[],
        summary: "show the account I answer as",
    },
    ChannelCommand {
        name: "/reset",
        aliases: &["/clear"],
        summary: "start a fresh conversation",
    },
    ChannelCommand {
        name: "/logout",
        aliases: &["/unlink"],
        summary: "disconnect this chat from your account",
    },
];

fn command_line(command: &ChannelCommand) -> String {
    if command.aliases.is_empty() {
        format!("{} — {}", command.name, command.summary)
    } else {
        format!(
            "{} (or {}) — {}",
            command.name,
            command.aliases.join(", "),
            command.summary
        )
    }
}

/// `channelHelpText`.
pub fn channel_help_text() -> String {
    let mut lines = vec!["Here is what I understand in this chat:".to_string()];
    lines.extend(CHANNEL_COMMANDS.iter().map(command_line));
    lines.push("Anything else you send goes straight to your assistant.".to_string());
    lines.join("\n")
}

/// `channelCommandPrompt` — injected into channel-origin system prompts only.
pub fn channel_command_prompt() -> String {
    let mut lines = vec![
        "This conversation arrived over a messaging channel that handles these".to_string(),
        "commands itself, typed as ordinary messages:".to_string(),
    ];
    lines.extend(CHANNEL_COMMANDS.iter().map(command_line));
    lines
        .push("Quote a command exactly when it answers the user's question, and never".to_string());
    lines.push("invent one that is not on this list.".to_string());
    lines.join("\n")
}

/// `maskEmail`.
pub fn mask_email(email: Option<&str>) -> String {
    let Some(email) = email else {
        return "your Omi account".to_string();
    };
    match email.rfind('@') {
        Some(at) if at >= 1 => format!("{}***{}", &email[..1], &email[at..]),
        _ => "your Omi account".to_string(),
    }
}

/// `greetingText` — must mention both entry points (mobile app + desktop chat).
pub fn greeting_text(code: &str) -> String {
    [
        "I'm Omi — your assistant. Link this chat to your Omi account and I'll \
answer here with everything I know about your work and your life."
            .to_string(),
        format!("Your link code is {code}"),
        format!(
            "Enter it either in the Omi mobile app under Settings → Account → Link a \
chat, or by typing it straight into the chat box on Omi for desktop. It expires in \
{} minutes and works once.",
            LINK_CODE_TTL_MS / 60_000
        ),
        "Send /help to see everything I understand here.".to_string(),
    ]
    .join("\n\n")
}

/// Reply for `/signin`: this bearer code signs the sender into Omi, rather than
/// binding the chat to an account that is already authenticated.
pub fn signin_code_text(code: &str) -> String {
    [
        format!("Your sign-in code is {code}"),
        format!(
            "Enter it in Omi to sign in. It expires in {} minutes and works once.",
            SIGNIN_CODE_TTL_MS / 60_000
        ),
    ]
    .join("\n\n")
}

/// `notLinkedText`.
pub const NOT_LINKED_TEXT: &str =
    "This chat isn't linked to an Omi account yet. Send /start if you already have one \
and I'll give you a link code, or /signup for how to create an account and link this chat.";

/// `unknownCommandText`.
pub const UNKNOWN_COMMAND_TEXT: &str =
    "I don't know that command. Send /help to see what I understand here.";

/// `linkConfirmationText`.
pub fn link_confirmation_text(email: Option<&str>) -> String {
    format!(
        "Linked — this chat now answers as {}. Send /help to see what I understand here.",
        mask_email(email)
    )
}

/// `linkedOn`: the UTC date (YYYY-MM-DD) of an epoch-millisecond timestamp.
/// Howard Hinnant's civil-from-days algorithm — no calendar crate needed.
pub fn iso_date(epoch_ms: i64) -> String {
    let days = epoch_ms.div_euclid(86_400_000);
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if month <= 2 { year + 1 } else { year };
    format!("{year:04}-{month:02}-{day:02}")
}

/// A parsed command: canonical (lower-cased, `@botname`-stripped) name plus the
/// trailing argument. `None` when the text is not a `/command`.
#[derive(Debug, PartialEq, Eq)]
pub struct ParsedCommand {
    pub command: String,
    pub argument: String,
}

/// `parseCommand`: split on whitespace, drop a `@botname` suffix Telegram adds
/// in group chats, and lower-case the command.
pub fn parse_command(text: &str) -> Option<ParsedCommand> {
    if !text.starts_with('/') {
        return None;
    }
    let mut parts = text.split_whitespace();
    let head = parts.next()?;
    let command = head.split('@').next().unwrap_or(head).to_ascii_lowercase();
    let argument = parts.collect::<Vec<_>>().join(" ").trim().to_string();
    Some(ParsedCommand { command, argument })
}

/// Resolve a canonical command name (or alias) to its table entry.
pub fn resolve_command(command: &str) -> Option<&'static ChannelCommand> {
    CHANNEL_COMMANDS
        .iter()
        .find(|entry| entry.name == command || entry.aliases.contains(&command))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_strips_the_group_botname_suffix() {
        assert_eq!(
            parse_command("/status@omi_bot"),
            Some(ParsedCommand {
                command: "/status".into(),
                argument: String::new(),
            })
        );
        assert_eq!(
            parse_command("/logout confirm"),
            Some(ParsedCommand {
                command: "/logout".into(),
                argument: "confirm".into(),
            })
        );
        assert_eq!(parse_command("hello"), None);
    }

    #[test]
    fn aliases_resolve_to_their_entry() {
        assert_eq!(resolve_command("/clear").unwrap().name, "/reset");
        assert_eq!(resolve_command("/unlink").unwrap().name, "/logout");
        assert!(resolve_command("/frobnicate").is_none());
    }

    #[test]
    fn signin_is_a_shared_channel_command() {
        let command = resolve_command("/signin").expect("sign-in command");
        assert_eq!(command.name, "/signin");
        assert!(command.summary.contains("sign in"));
        assert!(channel_help_text().contains("/signin"));
        assert!(channel_command_prompt().contains("/signin"));
    }

    #[test]
    fn signin_reply_uses_the_short_lived_code_interface() {
        let reply = signin_code_text("K7QP2RM");
        assert!(reply.contains("K7QP2RM"));
        assert!(reply.contains("3 minutes"));
        assert!(reply.contains("sign in"));
        assert!(!reply.contains("Link this chat"));
    }

    #[test]
    fn mask_email_hides_the_local_part() {
        assert_eq!(mask_email(Some("sam@example.test")), "s***@example.test");
        assert_eq!(mask_email(None), "your Omi account");
    }

    #[test]
    fn the_command_prompt_lists_every_command() {
        let prompt = channel_command_prompt();
        for command in CHANNEL_COMMANDS {
            assert!(prompt.contains(command.name));
        }
    }

    #[test]
    fn greeting_names_both_entry_points() {
        let greeting = greeting_text("K7QP2RM");
        assert!(greeting.contains("mobile app"));
        assert!(greeting.contains("desktop"));
        assert!(greeting.contains("K7QP2RM"));
    }

    #[test]
    fn the_help_text_lists_every_command_with_its_aliases() {
        let help = channel_help_text();
        assert!(help.starts_with("Here is what I understand in this chat:"));
        for command in CHANNEL_COMMANDS {
            assert!(help.contains(command.name), "missing {}", command.name);
            assert!(
                help.contains(command.summary),
                "missing {}",
                command.summary
            );
            for alias in command.aliases {
                assert!(help.contains(alias), "missing {alias}");
            }
        }
        assert!(help.contains("/help — list what I understand here"));
        assert!(help.contains("/reset (or /clear) — start a fresh conversation"));
        assert!(help.contains("/logout (or /unlink) — disconnect this chat from your account"));
        assert!(help.ends_with("Anything else you send goes straight to your assistant."));
        assert_eq!(help.lines().count(), CHANNEL_COMMANDS.len() + 2);
    }

    #[test]
    fn link_confirmation_names_the_masked_account_and_points_at_help() {
        assert_eq!(
            link_confirmation_text(Some("sam@example.test")),
            "Linked — this chat now answers as s***@example.test. Send /help to see what I understand here."
        );
        assert_eq!(
            link_confirmation_text(None),
            "Linked — this chat now answers as your Omi account. Send /help to see what I understand here."
        );
        assert_eq!(
            link_confirmation_text(Some("@example.test")),
            "Linked — this chat now answers as your Omi account. Send /help to see what I understand here."
        );
    }

    #[test]
    fn iso_date_renders_the_utc_calendar_date() {
        assert_eq!(iso_date(0), "1970-01-01");
        // Leap day, and the instant before and after a year rollover.
        assert_eq!(iso_date(1_709_164_800_000), "2024-02-29");
        assert_eq!(iso_date(1_704_067_199_999), "2023-12-31");
        assert_eq!(iso_date(1_704_067_200_000), "2024-01-01");
        // Month-boundary rollover away from a leap day.
        assert_eq!(iso_date(1_709_251_199_999), "2024-02-29");
        assert_eq!(iso_date(1_709_251_200_000), "2024-03-01");
        // Pre-epoch timestamps floor to the previous day.
        assert_eq!(iso_date(-1), "1969-12-31");
        assert_eq!(iso_date(-86_400_000), "1969-12-31");
        assert_eq!(iso_date(-86_400_001), "1969-12-30");
    }
}
