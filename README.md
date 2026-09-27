# BotBus Protocol

BotBus lets a phone or watch follow and control AI agents running on a computer. This repository is the public half of the BotBus computer app: the stable wire contract the mobile apps decode, and the Swift code that adapts each upstream agent (Codex, Claude Code, Hermes, Pi, OpenClaw, DeepSeek Harness, any ACP agent) into that contract. The Mac app compiles these packages directly at a pinned commit; there is no second, display-only copy.

When an upstream agent changes its files, CLI or protocol, the fix lands here and ships in a Mac update. iPhone, Android and Apple Watch never parse an agent's native format, so they do not need a release for that.

## Packages

| Product | What it holds | Who links it |
|---|---|---|
| `BotBusProtocol` | Wire types, envelopes, version rules, fixture round-trip tests | Mac, iPhone, Watch (Android has a Kotlin port in the app repository) |
| `BotBusConnectorKit` | Connector contracts (`TaskConnector`, `MessageReader`), `TaskStore`, `CommandDispatcher`, local infrastructure (SQLite, JSON-RPC, hooks server, task tokens) | Mac |
| `BotBusConnectors` | One connector per agent plus ACP discovery, the reverse extension and the registry snapshot | Mac |

Dependency direction: `BotBusProtocol` ← `BotBusConnectorKit` ← `BotBusConnectors`. The Mac app's private code (Relay client, pairing keys, artifact upload, previews, remote control) sits on top and is not here.

## Start here

- [Wire protocol](PROTOCOL.md): the BotBus 3.2 message and envelope contract.
- [Agent integration](docs/connector-contract.md): how ACP agents, Mac-side bridges and the built-in connectors map onto the mobile contract.
- [Compatibility policy](docs/compatibility.md): which changes ship in a Mac update and which need a client release; frozen enums and stable task IDs.
- [Public fixtures](protocol-fixtures/README.md) and [upstream fixtures](upstream-fixtures/README.md): synthetic samples checked against Swift, Kotlin and TypeScript.
- [ACP guide](docs/acp-agents.md): manifests, the ACP subset BotBus uses and the reverse extension.

## Build and test

Swift needs Xcode 27 on macOS 26 (the packages target the 26.0 SDKs); TypeScript needs Node.js 22.

```sh
swift build
swift test
npm ci && npm run typecheck && npm test
```

`protocol-fixtures/` sealed vectors are regenerated from `plain/` with `npm run seal-fixtures`; `npm run check:remote-page` checks the remote-control page's JavaScript crypto against the Swift implementation.

## Contributing a connector fix

1. Reproduce the upstream change with a synthetic sample under `upstream-fixtures/<source>/<version>/` (see its README) — never real conversations, tokens, cookies or home directories.
2. Fix the connector in `Sources/BotBusConnectors/<Source>/` and add or update tests.
3. Keep task IDs, statuses, request kinds and command kinds unchanged; `ProtocolFreezeTests` fails if a frozen enum moves.
4. Open a pull request. CI runs without any BotBus credentials; maintainers pin the reviewed commit into the next Mac build.

See [CONTRIBUTING.md](CONTRIBUTING.md). Code and documentation are licensed under [Apache-2.0](LICENSE).
