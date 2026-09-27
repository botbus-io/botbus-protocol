# Contributing

## What lives here

- `Sources/BotBusProtocol`: the cross-device contract. Changes here can require an iPhone, Android or Watch release; read `docs/compatibility.md` first and explain in the pull request whether installed clients keep working.
- `Sources/BotBusConnectorKit`: connector contracts, `TaskStore`, `CommandDispatcher` and shared local infrastructure. It must not depend on anything Mac-app-private; local services the dispatcher needs are protocols in `DispatcherServices.swift`.
- `Sources/BotBusConnectors`: one directory per agent. A new agent normally uses the existing `acp` source with a distinct `connectorId`; explain why a mobile protocol change would be needed before adding a source or command kind.

## Toolchain

Swift: Xcode 27 on macOS 26 (`swift build`, `swift test`). TypeScript: Node.js 22 (`npm ci`, `npm run typecheck`, `npm test`). Run all of them before opening a pull request, plus `gitleaks git . --config .gitleaks.toml` (CI runs the same scan; the allowlist only covers the synthetic fixtures and test vectors).

## Upstream samples

Connector fixes should come with a small reproducible sample of the upstream format that changed, under `upstream-fixtures/<source>/<upstreamVersion>/input/`, and the mapped BotBus records under `expected/`. Use invented task names, paths, agent IDs, prompts and outputs. Remove access tokens, pair keys, account names, real conversations, file contents and home directories before committing. Tests may also keep small inline samples; either way the expected task ID is part of the contract and must stay stable across versions of a connector.

## Review and release

Most files here are synced from the BotBus app repository, which is the source of truth: `Sources/`, `Tests/`, `PROTOCOL.md`, `protocol-fixtures/*.json`, `upstream-fixtures/`, `src/protocol.ts`, `test/protocol.test.ts`, `scripts/seal-fixtures.mjs`, `scripts/check-remote-page-crypto.mjs` and `scripts/acp-registry-snapshot.py`. Pull requests that touch them are reviewed here, then a maintainer ports the change into the app repository; the next sync pull request brings it back, and it ships in the next signed Mac build. Changes to synced files are not merged here directly, because a change merged here without being ported would be reverted by the next sync.

README, `docs/`, `CHANGELOG.md`, `Package.swift`, CI and `.gitleaks.toml` are maintained in this repository and merged here.

Public pull request CI does not receive BotBus release credentials. Sync pull requests are merged by fast-forward, so every commit keeps its original author and committer. A connector-only change does not bump the wire protocol version or the minimum mobile version.
