# Changelog

Two kinds of entries: **Wire protocol** changes move `ProtocolVersion.current` and may need a client release; **Connectors** entries ship in a Mac update only.

## v0.2.0 (unreleased)

### Wire protocol
- `BotBusProtocol` is published as a Swift package here, including its sealing types and the fixture round-trip tests; the protocol version stays 3.2.
- `ProtocolFreezeTests` pins `TaskSource`, `ConnectorKind`, `TaskStatus`, `TaskOrigin`, `PendingRequest.Kind`, `ArtifactKind`, `Command.Kind`, `Event.Kind`, `Notify.Category`, `Message.Role` and `ConnectorInfo.Status`.

### Connectors
- New `BotBusConnectorKit`: `TaskConnector`, `MessageReader`, `TaskStore`, `CommandDispatcher`, `ConnectorRegistry` and the local infrastructure they share.
- New `BotBusConnectors`: Codex, Claude Code, Hermes, Pi, OpenClaw, DeepSeek Harness and ACP connectors, the ACP registry snapshot and the descriptor table.
- `BotBusConnectorParsers` is folded into the two packages above and removed.
- `scripts/seal-fixtures.mjs`, `scripts/acp-registry-snapshot.py` and `scripts/check-remote-page-crypto.mjs` moved here from the app repository.

## v0.1.0

- Published the BotBus 3.2 protocol contract, fixtures, TypeScript schema and the first two upstream parsers (`CodexJSON`, `StreamJSONReader`).
