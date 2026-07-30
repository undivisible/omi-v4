-- `/logout` asks for confirmation before it does anything, which is right:
-- for a chat-owned account it is the only copy of that account. What was wrong
-- is that every repeat of a bare `/logout` printed the same three-line
-- explanation, so a user who sent it four times got the same wall four times.
--
-- Remembering when the explanation was last given lets a repeat be answered in
-- one line instead. Nullable, because a binding that has never been asked to
-- confirm has no answer to this and should not pretend to.
ALTER TABLE channel_bindings ADD COLUMN logout_prompted_at INTEGER;
