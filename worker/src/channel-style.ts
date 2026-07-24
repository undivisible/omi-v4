import type { Channel } from "./types";

const sharedMessagingRules = [
  "You are replying in a personal messaging app, not writing a document.",
  "Write like a normal person texting: short sentences, warm and direct.",
  "Plain text only — no markdown, no headings, no bullet lists, no numbered lists, no code fences, no backticks, no bold/italic markers, no links formatted as markdown.",
  "Keep replies compact (usually 1–4 short sentences). Break long answers into a few messages worth of prose, not a wall of text.",
  "Do not mention being an AI unless the user asks. Do not use crepus artifacts or interactive widgets — the channel UI cannot render them.",
].join(" ");

export const channelStylePrompt = (channel: Channel): string => {
  if (channel === "telegram") {
    return [
      "Delivery channel: Telegram.",
      sharedMessagingRules,
      "Telegram allows a little structure, but still avoid markdown — use line breaks sparingly instead of bullets.",
    ].join(" ");
  }
  return [
    "Delivery channel: iMessage/SMS.",
    sharedMessagingRules,
    "iMessage reads best as casual texts — no lists, no tables, no emoji spam unless the user uses them first.",
  ].join(" ");
};

/** Strip common markdown so channel replies stay plain even if the model slips. */
export const sanitizeChannelReply = (channel: Channel, text: string): string => {
  let value = text.trim();
  if (value.length === 0) return value;

  // Drop fenced crepus/code blocks entirely.
  value = value.replace(/```[\s\S]*?```/g, "").trim();

  // Links: keep label, drop markdown wrapper.
  value = value.replace(/\[([^\]]+)\]\(([^)]+)\)/g, "$1 ($2)");

  // Headings and list markers.
  value = value.replace(/^#{1,6}\s+/gm, "");
  value = value.replace(/^\s*[-*+]\s+/gm, "");
  value = value.replace(/^\s*\d+\.\s+/gm, "");

  // Inline emphasis/code.
  value = value.replace(/\*\*([^*]+)\*\*/g, "$1");
  value = value.replace(/\*([^*]+)\*/g, "$1");
  value = value.replace(/__([^_]+)__/g, "$1");
  value = value.replace(/_([^_]+)_/g, "$1");
  value = value.replace(/`([^`]+)`/g, "$1");

  // Collapse excessive blank lines from removals.
  value = value.replace(/\n{3,}/g, "\n\n").trim();

  // Telegram tolerates slightly longer plain replies; iMessage stays tighter.
  const limit = channel === "telegram" ? 4096 : 2000;
  if (value.length > limit) value = `${value.slice(0, limit - 1)}…`;
  return value;
};
