# Agent connector contract

BotBus 3.2 already has one extensible agent source: `acp`. A connector is identified by `(kind: "acp", connectorId)`; an ACP task uses `source: "acp"`, the same `connectorId`, and the task ID `acp:<connectorId>:<sessionId>`. The ID must match `[a-z0-9-]{1,32}` and must remain stable across updates. `sessionId` can contain colons. The computer's ID remains part of the global task key: `(agentId, taskId)`.

## Which adapter to build

1. If the agent speaks [Agent Client Protocol](https://agentclientprotocol.com), provide a BotBus manifest at `~/.botbus/agents/<connectorId>.json` or use an agent in the registry snapshot.
2. If it has a different protocol, ship a bridge with the BotBus Mac app. The bridge speaks ACP to BotBus and translates to the agent's native API, CLI, or event stream. It remains Mac-side code; the phone never sees the native protocol.
3. Built-in Codex and Claude Code adapters continue to use their existing `codex` and `claude` identities. Upstream changes in these adapters ship in a Mac release.

Example manifest:

```json
{
  "id": "example-agent",
  "name": "Example Agent",
  "command": "/absolute/path/to/example-agent",
  "args": ["--acp"]
}
```

`id` must equal the filename stem. `command` may also be a name discoverable on the user's PATH. `args` and string-valued `env` are optional. The manifest is local to the Mac; it is never downloaded by iOS, Android, or Watch.

## Stable mapping

| Upstream concept | BotBus representation |
|---|---|
| Session | `TaskRecord` with stable `id`, `source`, `connectorId`, title, project, status and timestamps |
| User and assistant output | `Message` with role `user` or `agent` |
| Tool activity | `Message` with role `tool`, as a short summary |
| Permission request or question | `PendingRequest`; answer via `approve` |
| Start, prompt, cancel | Existing `startTask`, `followUp`, `interrupt` commands |
| Command acceptance or failure | `CommandResult` matching the original command ID |

The bridge must preserve the native session ID so an update does not duplicate existing tasks. It must avoid sending reasoning or raw secrets as messages. If an upstream request cannot be safely represented by the existing approval fields, leave it for the agent's local UI and report the limitation; never guess an approval decision.

## ACP behavior BotBus uses

BotBus acts as an ACP client over newline-delimited JSON-RPC 2.0. It sends `initialize` with `protocolVersion: 1` and checks that the response agrees. It uses `session/new`, `session/prompt`, and `session/cancel`; `session/load`, `session/resume`, and `session/list` are used only when advertised. `promptCapabilities.image` determines whether the bridge can receive image blocks. Permission requests use `session/request_permission`; BotBus maps the selected ACP option to its stable phone approval command.

For a bridge that must report sessions opened in the agent's own terminal or IDE, see the [BotBus ACP guide and reverse extension](acp-agents.md). That extension is Mac-local and does not change the phone protocol.

The authoritative field and limit definitions are in [PROTOCOL.md](../PROTOCOL.md). Existing samples are in [`protocol-fixtures/`](../protocol-fixtures/).
