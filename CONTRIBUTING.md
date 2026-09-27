# Contributing

Protocol changes and connector updates should include a small reproducible sample and an explanation of the observed upstream version or behavior. Use invented task names, paths, agent IDs and prompts. Remove access tokens, pair keys, account names, real conversations and file contents before committing a fixture.

Run `npm run typecheck`, `npm test`, and `swift test` before opening a pull request. Changes to the BotBus wire contract need matching Swift, Kotlin and TypeScript tests in the app repository. A new upstream agent should normally use the existing `acp` source and a distinct `connectorId`; explain why a mobile protocol change is needed before adding a new source or command kind.

Public pull request CI does not receive BotBus release credentials. Changes are reviewed and pinned into a Mac app build before they reach users.
