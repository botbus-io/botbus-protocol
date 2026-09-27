# Compatibility and release policy

The mobile clients decode the BotBus protocol, not upstream agent protocols. A connector update is compatible with an installed iPhone, Android, or Watch app when the Mac continues to emit records and accept commands those clients already know.

## Mac-only release

- Repair parsing of a changed Codex, Claude Code, or other upstream format.
- Change observation, process control, reconnect, or error handling inside a connector.
- Add an ACP agent or a Mac-side bridge under `source = acp` with a new `connectorId`.
- Add optional information that old clients can ignore without changing the meaning of existing fields.

Keep task IDs stable and use existing task statuses, message roles, request kinds, artifact kinds, and command kinds. Show unsupported behavior as a connector error rather than emitting a new mandatory enum value. A `202` from Relay only acknowledges receipt; the Mac must still publish a `CommandResult`.

## Client release required

- A new phone interaction or command that cannot be expressed by the current command and approval model.
- A new required field, changed meaning of an existing field, or a new enum value that installed clients reject.
- A change to the encrypted envelope, key derivation, or AAD rules.
- Raising protocol limits beyond what installed clients validate. BotBus 3.2 currently allows at most 10 ACP connectors per Mac within 16 total connectors.

For these changes, deploy a compatible Relay first, release iOS/Android/Watch, then raise `MIN_CLIENT_PROTOCOL` only when the clients are available, and finally enable the new Mac output. Relay cannot translate old and new task payloads because it only has ciphertext.

## Release checklist for a connector change

1. Add synthetic, credential-free upstream samples for the broken and fixed formats.
2. Add parser and mapping tests. Check stable task IDs, status, message order, approval mapping, and command results.
3. Run public conformance tests and the app repository's Swift, Kotlin, and Relay fixture tests.
4. Tag this repository; pin the reviewed commit in the app repository. Do not load connector code from GitHub at runtime.
5. Build, sign, notarize, and test the Mac app, then publish it through the existing update channel. A bad release is corrected with a newer Mac build.

The repository's code version, BotBus wire version, and Mac app version are separate. A connector-only patch does not raise the wire version or minimum mobile version.

## Known BotBus 3.2 presentation limit

Current mobile clients offer image sending for ACP sources before knowing an individual agent's image capability. The Mac rejects an image prompt if that agent did not advertise image support; it must not silently send text without the image. A future optional, per-connector capability field can improve this UI in a normal mobile release. Text tasks and existing commands remain usable without that field.
