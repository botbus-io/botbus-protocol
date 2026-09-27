# Upstream fixtures

One directory per agent source and upstream version:

```
upstream-fixtures/<source>/<upstreamVersion>/
  input/      raw upstream samples (Codex SQLite DDL and rows, app-server JSON-RPC lines,
              Claude hook payloads and transcript JSONL, dsh session logs, ACP session/update sequences…)
  expected/   the mapped BotBus records (TaskRecord, TaskMessages, PendingRequest JSON)
```

Every file is synthetic: invented paths, titles, prompts and outputs, never real conversations, tokens,
cookies or home directories. Tests run once per version directory; `expected/` doubles as the frozen
task-id contract (see `docs/compatibility.md`). Capture a redacted sample of your own installation with
`botbus diagnose <source>` (planned), then add the fix to the connector.
