# Bridges

Mac-side bridges for agents that do not speak ACP natively (design §8). A bridge gives `AcpHub` an `AcpAgentSpec` with `origin: .bridge` and an `AcpLauncherFactory`, does its own discovery and observation, and reports sessions through the reverse extension. None ship yet.
