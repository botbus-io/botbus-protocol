# Protocol fixtures

These JSON files contain invented names, paths, task text and identifiers. They are the public BotBus 3.2 conformance corpus. `plain/` contains the domain records encrypted by the Mac and decrypted by the clients. Files at this directory's root are the corresponding sealed envelopes and Relay messages. `invalid/` and `plain/invalid/` must be rejected.

The fixed keys and nonces used for sealed test vectors are for tests only. They are not production credentials. Until the separate encryption repository is published, the BotBus app repository regenerates sealed vectors from the plain fixtures and checks that the public files match.

Run `npm test` at the repository root to validate all samples against the public TypeScript schema. The app repository additionally validates them with its Swift and Kotlin implementations.
