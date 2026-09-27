# BotBus Protocol

BotBus lets a phone or watch follow and control AI agents running on a computer. This repository documents the stable messages between the BotBus computer app and its clients, and the ACP contract used to add agents without changing the mobile apps.

The computer app adapts each upstream agent to BotBus tasks, messages, approval requests, and commands. It encrypts those records before sending them through the Relay. iPhone, Android, and Apple Watch clients read the same BotBus messages; they do not parse Codex, Claude Code, or another agent's native protocol.

## Start here

- [Wire protocol](PROTOCOL.md): current BotBus 3.2 message and envelope contract.
- [Agent integration](docs/connector-contract.md): how ACP agents and Mac-side bridges use the existing mobile client protocol.
- [Compatibility policy](docs/compatibility.md): which changes can ship in a Mac update and which require a client release.
- [Public fixtures](protocol-fixtures/README.md): synthetic examples checked against Swift, Kotlin, and TypeScript implementations.

The BotBus app repository contains the Mac host, mobile apps, Relay, and most connector orchestration. The [Swift parser package](Package.swift) contains the Codex app-server JSON parser and Claude Code stream-json reader that the Mac app actually compiles. More parsing and mapping code can move here in stages. The encryption implementation is planned for a separate repository. The TypeScript schema in [`src/protocol.ts`](src/protocol.ts) and this fixture corpus are checked against the app repository at a pinned public commit.

This repository does not publish a runtime code update for iOS or Android. New agent support normally ships as a full Mac app update, or as an ACP agent discovered through a local manifest.

## Check the published contract

Use Node.js 22 or later:

```sh
npm test
npm run typecheck
swift test
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before submitting upstream protocol samples. Do not include real conversations, credentials, or local files in fixtures.

Code and documentation are licensed under [Apache-2.0](LICENSE).
