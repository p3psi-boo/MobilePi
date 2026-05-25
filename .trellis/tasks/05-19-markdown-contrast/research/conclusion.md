# Conclusion

`usage` is lost because MobilePi's data model (`PiSessionMessageInfo`) has no `usage` field, so every parser that reads upstream session JSONL necessarily drops it.

**Certain paths (100%):**
- `PiSessionIndex.getSessionMessages()` — chat history fetch
- `PiSessionIndex.buildSessionInfo()` — session list + active session messages

**Likely path (80%):**
- `NodeDaemon._extractDeltaFromSessionLine()` — live streaming tail (text-only by design)

**MobilePi does NOT write session JSONL** — only the external `pi` CLI does. The repo is a read-only consumer.

**Fix required:** Add `usage` to `PiSessionMessageInfo`, extract it in `PiSessionIndex`, and decide if the client should display it.
