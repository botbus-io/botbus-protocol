# Protocol fixtures

These JSON files contain invented names, paths, task text and identifiers. They are the public BotBus 3.2 conformance corpus. `plain/` contains the domain records encrypted by the Mac and decrypted by the clients. Files at this directory's root are the corresponding sealed envelopes and Relay messages. `invalid/` and `plain/invalid/` must be rejected.

The fixed keys and nonces used for sealed test vectors are for tests only. They are not production credentials. Regenerate the sealed vectors from `plain/` with `npm run seal-fixtures`; the Swift `SealedFixtureTests` and the TypeScript tests both check them. The JSON files are synced from the BotBus app repository, where the Relay and Android tests use the same corpus; change them there, or propose the change here and a maintainer ports it.

Run `npm test` at the repository root to validate all samples against the TypeScript schema and `swift test` for the Swift implementation. The app repository additionally validates them with its Kotlin implementation.
