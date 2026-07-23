import {
  alreadySubscribedText,
  checkoutOfferText,
  checkoutUnavailableText,
  issueChannelCheckout,
} from "./channel-checkout";
import { issueLinkCode, linkCodeTtlMs } from "./channel-link";
import {
  firstContactState,
  isChannelAccount,
  markFirstContactAnswered,
  parseSignupAnswer,
  recordFirstContact,
  retireChannelAccount,
  signUpChannelSender,
} from "./channel-signup";
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
    name: "/signup",
    aliases: ["/new"],
    summary: "create an Omi account from this chat",
  },
  {
    name: "/subscribe",
    aliases: ["/upgrade"],
    summary: "get a payment link for your subscription",
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

// First contact asks one question and accepts however a person types the
// answer, because the alternative is a stranger guessing at command syntax.
export const firstContactText = [
  "I'm Omi — an assistant that remembers your work and your life.",
  "Do you already have an Omi account? Reply yes or no.",
].join("\n\n");

export const clarifyAnswerText =
  "Reply yes if you already have an Omi account, or no and I'll set one up " +
  "for you here.";

export const signupWelcomeText = [
  "Done — this chat is your Omi account now. No password, no sign-up form: " +
    "the account belongs to this chat.",
  "Talk to me here and I'll remember. When you want Omi on your phone or " +
    "desktop, sign in there and send /start here to move this account across.",
  "Send /help to see everything I understand here.",
].join("\n\n");

// The subscription offer rides along with the welcome rather than arriving as
// a separate nag, so a new sender sees one message and one link.
const offerCheckout = async (
  env: Bindings,
  uid: string,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now: number,
): Promise<string | null> => {
  const checkout = await issueChannelCheckout(
    env,
    uid,
    channel,
    channelUserId,
    channelChatId,
    now,
  );
  if (checkout.status === "issued" || checkout.status === "reused")
    return checkoutOfferText(checkout.url, checkout.priceCents);
  if (checkout.status === "subscribed") return alreadySubscribedText;
  if (checkout.status === "unavailable") return checkoutUnavailableText;
  return null;
};

export const signupUnavailableText =
  "I can't set up a new account right now. Try again a little later, or send " +
  "/start if you already have one.";

export const notLinkedText =
  "This chat isn't linked to an Omi account yet. Send /start and I'll give " +
  "you a code to type into the app, or /signup and I'll set an account up " +
  "for you right here.";

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

const startSignup = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now: number,
): Promise<ChannelMessageOutcome> => {
  const result = await signUpChannelSender(
    env,
    channel,
    channelUserId,
    channelChatId,
    now,
  );
  if (result.status === "rate-limited") return { reply: null, enqueue: false };
  if (result.status !== "created" && result.status !== "existing")
    return { reply: signupUnavailableText, enqueue: false };
  const offer = await offerCheckout(
    env,
    result.uid,
    channel,
    channelUserId,
    channelChatId,
    now,
  );
  return {
    reply:
      offer === null ? signupWelcomeText : `${signupWelcomeText}\n\n${offer}`,
    enqueue: false,
  };
};

const askFirstContact = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  now: number,
): Promise<ChannelMessageOutcome> => {
  if (!(await unlinkedReplyAllowed(env, channel, channelUserId)))
    return { reply: null, enqueue: false };
  await recordFirstContact(env.DB, channel, channelUserId, channelChatId, now);
  return { reply: firstContactText, enqueue: false };
};

// Plain text from someone we do not recognise: ask the one question, then read
// whatever they type back as an answer to it.
const unrecognizedSender = async (
  env: Bindings,
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
  text: string,
  now: number,
): Promise<ChannelMessageOutcome> => {
  const state = await firstContactState(env.DB, channel, channelUserId);
  if (!state)
    return askFirstContact(env, channel, channelUserId, channelChatId, now);
  if (state.answeredAt !== null)
    return startLink(env, channel, channelUserId, channelChatId, now);
  const answer = parseSignupAnswer(text);
  if (answer === null) {
    if (!(await unlinkedReplyAllowed(env, channel, channelUserId)))
      return { reply: null, enqueue: false };
    return { reply: clarifyAnswerText, enqueue: false };
  }
  await markFirstContactAnswered(env.DB, channel, channelUserId, now);
  return answer === "has-account"
    ? startLink(env, channel, channelUserId, channelChatId, now)
    : startSignup(env, channel, channelUserId, channelChatId, now);
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
      : unrecognizedSender(
          env,
          channel,
          channelUserId,
          channelChatId,
          text,
          now,
        );
  const command = resolveCommand(parsed.command);
  if (!command) {
    if (!binding && !(await unlinkedReplyAllowed(env, channel, channelUserId)))
      return { reply: null, enqueue: false };
    return { reply: unknownCommandText, enqueue: false };
  }
  if (!binding && command.name === "/signup") {
    await markFirstContactAnswered(env.DB, channel, channelUserId, now);
    return startSignup(env, channel, channelUserId, channelChatId, now);
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
  // An account created from this chat has no email and no other way in, so
  // several commands have to say something different to it.
  const channelAccount =
    binding.email === null && (await isChannelAccount(env.DB, binding.uid));
  if (command.name === "/help")
    return { reply: channelHelpText, enqueue: false };
  if (command.name === "/signup")
    return {
      reply: channelAccount
        ? "This chat already is your Omi account. Sign in on your phone or " +
          "desktop and send /start here to move it across."
        : `This chat is already linked to ${masked}, so there's nothing to ` +
          "sign up for.",
      enqueue: false,
    };
  if (command.name === "/start")
    return {
      reply:
        `This chat is already linked to ${masked}. Just send me a message ` +
        "and I'll answer. /help lists what else I understand here.",
      enqueue: false,
    };
  if (command.name === "/subscribe")
    return {
      reply: await offerCheckout(
        env,
        binding.uid,
        channel,
        channelUserId,
        channelChatId,
        now,
      ),
      enqueue: false,
    };
  if (command.name === "/status")
    return {
      reply: channelAccount
        ? `This chat is your Omi account, set up here on ${linkedOn(Number(binding.verified_at))}. ` +
          "Sign in on your phone or desktop and send /start to move it across."
        : `Linked to ${masked} since ${linkedOn(Number(binding.verified_at))}. ` +
          "Send /logout to disconnect this chat.",
      enqueue: false,
    };
  if (command.name === "/whoami")
    return {
      reply: channelAccount
        ? "I'm answering as the account that lives in this chat — it was " +
          "created here and has no email yet."
        : `I'm answering as ${masked} — the Omi account this chat is linked to.`,
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
      reply: channelAccount
        ? "This chat is the account, so there's no separate login to sign out " +
          "of. To keep what I know, sign in on your phone or desktop and send " +
          "/start here first. Send /logout confirm to close it instead — I'll " +
          "stop answering here and this account won't be handed to anyone else."
        : `Unlinking disconnects this chat from ${masked}: I'll stop answering ` +
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
  if (channelAccount) {
    await retireChannelAccount(env.DB, binding.uid, now);
    return {
      reply:
        "Closed. This chat no longer has an Omi account — send /signup if you " +
        "ever want a fresh one, or /start to link an account you sign in to.",
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
