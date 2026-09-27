# Changelog

Two kinds of entries: **Wire protocol** changes move `ProtocolVersion.current` and may need a client release; **Connectors** entries ship in a Mac update only.

## Unreleased

### Process
- The BotBus app repository is the source of truth for the synced files and brings changes here in sync pull requests merged by fast-forward, see `CONTRIBUTING.md`. The app no longer depends on this repository at a pinned commit.

### Wire protocol
- `PROTOCOL.md` names where the implementations live in both repositories.

### Connectors
- `Sources/BotBusConnectors/Bridges/` holds a Swift comment file instead of a README, which removes SwiftPM's unhandled-file warning.
- `docs/connector-kit.md` and `docs/connectors.md` describe the packages as they are after v0.2.0: `JSONValue` and `StreamJSONReader` live in Kit, the Codex frame types in Connectors.

## v0.2.0 (2026-09-27)

### Wire protocol
- `BotBusProtocol` is published as a Swift package here, including its sealing types and the fixture round-trip tests; the protocol version stays 3.2.
- `ProtocolFreezeTests` pins `TaskSource`, `ConnectorKind`, `TaskStatus`, `TaskOrigin`, `PendingRequest.Kind`, `ArtifactKind`, `Command.Kind`, `Event.Kind`, `Notify.Category`, `Message.Role` and `ConnectorInfo.Status`.

### Connectors
- New `BotBusConnectorKit`: `TaskConnector`, `MessageReader`, `TaskStore`, `CommandDispatcher`, `ConnectorRegistry` and the local infrastructure they share.
- New `BotBusConnectors`: Codex, Claude Code, Hermes, Pi, OpenClaw, DeepSeek Harness and ACP connectors, the ACP registry snapshot and the descriptor table.
- `BotBusConnectorParsers` is folded into the two packages above and removed.
- `scripts/seal-fixtures.mjs`, `scripts/acp-registry-snapshot.py` and `scripts/check-remote-page-crypto.mjs` are published here from the app repository.

## v0.1.0

- Published the BotBus 3.2 protocol contract, fixtures, TypeScript schema and the first two upstream parsers (`CodexJSON`, `StreamJSONReader`).
