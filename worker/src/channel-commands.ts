import { issueLinkCode, linkCodeTtlMs } from "./channel-link";
import { dispatchChannelUnlink } from "./delivery";
import { consumeRateLimit } from "./rate-limit";
import type { Bindings, Channel } from "./types";

export type ChannelCommand = {
  name: string;
  aliases: string[];
  summary: string;
};

export const channelCommands: ChannelCommand[] = [
  { name: "/help", aliases: [], summary: "list what I understand here" },
  {
    name: "/start",
    aliases: [],
    summary: "link this chat to your Omi account",
  },
  {
    name: "/status",
    aliases: [],
    summary: "show whether this chat is linked",
  },
  { name: "/whoami", aliases: [], summary: "show the account I answer as" },
  {
    name: "/reset",
    aliases: ["/clear"],
    summary: "start a fresh conversation",
  },
  {
    name: "/logout",
    aliases: ["/unlink"],
    summary: "disconnect this chat from your account",
  },
];

const commandLine = (command: ChannelCommand): string =>
  command.aliases.length === 0
    ? `${command.name} — ${command.summary}`
    : `${command.name} (or ${command.aliases.join(", ")}) — ${command.summary}`;

export const channelHelpText = [
  "Here is what I understand in this chat:",
  ...channelCommands.map(commandLine),
  "Anything else you send goes straight to your assistant.",
].join("\n");

// Injected into the system prompt of channel-origin turns only, so the model
// can point at a real command instead of inventing one.
export const channelCommandPrompt = [
  "This conversation arrived over a messaging channel that handles these",
  "commands itself, typed as ordinary messages:",
  ...channelCommands.map(commandLine),
  "Quote a command exactly when it answers the user's question, and never",
  "invent one that is not on this list.",
].join("\n");

export const maskEmail = (email: string | null): string => {
  if (!email) return "your Omi account";
  const at = email.lastIndexOf("@");
  if (at < 1) return "your Omi account";
  return `${email.slice(0, 1)}***${email.slice(at)}`;
};

const linkedOn = (verifiedAt: number): string =>
  new Date(verifiedAt).toISOString().slice(0, 10);

export const greetingText = (code: string): string =>
  [
    "I'm Omi — your assistant. Link this chat to your Omi account and I'll " +
      "answer here with everything I know about your work and your life.",
    `Your link code is ${code}`,
    "Enter it either in the Omi mobile app under Settings → Account → Link a " +
      "chat, or by typing it straight into the chat box on Omi for desktop. " +
      `It expires in ${Math.round(linkCodeTtlMs / 60_000)} minutes and works once.`,
    "Send /help to see everything I understand here.",
  ].join("\n\n");

export const notLinkedText =
  "This chat isn't linked to an Omi account yet. Send /start and I'll give " +
  "you a code to type into the app.";

export const unknownCommandText =
  "I don't know that command. Send /help to see what I understand here.";

export const linkConfirmationText = (email: string | null): string =>
  `Linked — this chat now answers as ${maskEmail(email)}. Send /help to see ` +
  "what I understand here.";

type Binding = {
  uid: string;
  verified_at: number;
  email: string | null;
};

const bindingFor = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
): Promise<Binding | null> =>
  db
    .prepare(
      `SELECT b.uid AS uid, b.verified_at AS verified_at, u.email AS email
       FROM channel_bindings b LEFT JOIN users u ON u.uid = b.uid
       WHERE b.channel = ?1 AND b.channel_user_id = ?2 AND b.revoked_at IS NULL`,
    )
    .bind(channel, channelUserId)
    .first<Binding>();

// One bucket for every outbound reply to a sender we cannot attribute to an
// account: it caps code issuance and stops the bot being used to relay
// messages to an arbitrary phone number or chat id.
const unlinkedReplyAllowed = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
): Promise<boolean> => {
  const { allowed } = await consumeRateLimit(
    env,
    `channel-link-code:${channel}:${channelUserId}`,
    5,
    60 * 60_000,
  );
  return allowed;
};

export type ChannelMessageOutcome = { reply: string | null; enqueue: boolean };

const parseCommand = (
  text: string,
): { command: string; argument: string } | null => {
  if (!text.startsWith("/")) return null;
  const [head, ...rest] = text.split(/\s+/);
  const command = head.split("@")[0].toLowerCase();
  return { command, argument: rest.join(" ").trim() };
};

const resolveCommand = (command: string): ChannelCommand | null =>
  channelCommands.find(
    (entry) => entry.name === command || entry.aliases.includes(command),
  ) ?? null;

const startLink = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now: number,
): Promise<ChannelMessageOutcome> => {
  if (!(await unlinkedReplyAllowed(env, channel, channelUserId)))
    return { reply: null, enqueue: false };
  const issued = await issueLinkCode(
    env,
    channel,
    channelUserId,
    channelChatId,
    now,
  );
  if (!issued) return { reply: null, enqueue: false };
  return { reply: greetingText(issued.code), enqueue: false };
};

const resetConversation = async (
  db: D1Database,
  channel: Channel,
  channelUserId: string,
  uid: string,
): Promise<void> => {
  await db
    .prepare(
      `UPDATE channel_bindings SET conversation_reset_cursor =
         (SELECT COALESCE(MAX(cursor), 0) FROM conversation_messages
          WHERE uid = ?1 AND conversation_id = ?1)
       WHERE channel = ?2 AND channel_user_id = ?3 AND revoked_at IS NULL`,
    )
    .bind(uid, channel, channelUserId)
    .run();
};

// Runs before the message reaches the assistant: it either answers the sender
// itself (`reply`) or lets the message through to the inbox (`enqueue`).
export const handleChannelMessage = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  text: string,
  now = Date.now(),
): Promise<ChannelMessageOutcome> => {
  const binding = await bindingFor(env.DB, channel, channelUserId);
  const parsed = parseCommand(text);
  if (!parsed)
    return binding
      ? { reply: null, enqueue: true }
      : startLink(env, channel, channelUserId, channelChatId, now);
  const command = resolveCommand(parsed.command);
  if (!command) {
    if (!binding && !(await unlinkedReplyAllowed(env, channel, channelUserId)))
      return { reply: null, enqueue: false };
    return { reply: unknownCommandText, enqueue: false };
  }
  if (!binding && command.name !== "/start") {
    if (!(await unlinkedReplyAllowed(env, channel, channelUserId)))
      return { reply: null, enqueue: false };
    return {
      reply: command.name === "/help" ? channelHelpText : notLinkedText,
      enqueue: false,
    };
  }
  if (!binding)
    return startLink(env, channel, channelUserId, channelChatId, now);
  const masked = maskEmail(binding.email);
  if (command.name === "/help")
    return { reply: channelHelpText, enqueue: false };
  if (command.name === "/start")
    return {
      reply:
        `This chat is already linked to ${masked}. Just send me a message ` +
        "and I'll answer. /help lists what else I understand here.",
      enqueue: false,
    };
  if (command.name === "/status")
    return {
      reply:
        `Linked to ${masked} since ${linkedOn(Number(binding.verified_at))}. ` +
        "Send /logout to disconnect this chat.",
      enqueue: false,
    };
  if (command.name === "/whoami")
    return {
      reply: `I'm answering as ${masked} — the Omi account this chat is linked to.`,
      enqueue: false,
    };
  if (command.name === "/reset") {
    await resetConversation(env.DB, channel, channelUserId, binding.uid);
    return {
      reply:
        "Fresh start — I've dropped the earlier conversation from this " +
        "chat's context. Your account stays linked.",
      enqueue: false,
    };
  }
  if (parsed.argument.toLowerCase() !== "confirm")
    return {
      reply:
        `Unlinking disconnects this chat from ${masked}: I'll stop answering ` +
        "here until you link again. Send /logout confirm to go ahead.",
      enqueue: false,
    };
  try {
    await dispatchChannelUnlink(env, binding.uid, channel);
  } catch {
    return {
      reply:
        "I couldn't unlink this chat just now. Try again in a moment, or " +
        "unlink it from Omi's settings.",
      enqueue: false,
    };
  }
  return {
    reply:
      "Unlinked. This chat is no longer connected to your Omi account — " +
      "send /start whenever you want to link it again.",
    enqueue: false,
  };
};
