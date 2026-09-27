# Protocol fixtures

These JSON files contain invented names, paths, task text and identifiers. They are the public BotBus 3.2 conformance corpus. `plain/` contains the domain records encrypted by the Mac and decrypted by the clients. Files at this directory's root are the corresponding sealed envelopes and Relay messages. `invalid/` and `plain/invalid/` must be rejected.

The fixed keys and nonces used for sealed test vectors are for tests only. They are not production credentials. Regenerate the sealed vectors from `plain/` with `npm run seal-fixtures`; the Swift `SealedFixtureTests` and the TypeScript tests both check them, and the app repository keeps a byte-identical copy for its Relay and Android tests.

Run `npm test` at the repository root to validate all samples against the TypeScript schema and `swift test` for the Swift implementation. The app repository additionally validates them with its Kotlin implementation.
