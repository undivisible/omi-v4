import type { Channel } from "./types";

// A linked channel must be a one-to-one chat. Telegram groups use negative chat
// ids; Blooio and Sendblue/iMessage group threads use a `group_id` distinct from
// the sender, which becomes the stored `channel_chat_id`.
export const isGroupChannelChat = (
  channel: Channel,
  channelUserId: string,
  channelChatId: string,
): boolean => {
  if (channel === "telegram") {
    const chatNum = Number(channelChatId);
    return Number.isSafeInteger(chatNum) && chatNum < 0;
  }
  return channelChatId !== channelUserId;
};

export const groupChannelLinkError =
  "Group chats cannot be linked as your Omi channel. Message me in a direct chat to link.";
