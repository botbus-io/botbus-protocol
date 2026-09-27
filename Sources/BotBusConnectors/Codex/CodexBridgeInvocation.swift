import BotBusConnectorKit
/// Finds the Codex subcommand after global options. The desktop currently passes
/// `-c <override>` before `app-server`, so inspecting the first argument misses it.
public enum CodexBridgeInvocation {
    private static let valueOptions: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote",
        "--remote-auth-token-env", "-i", "--image", "-m", "--model",
        "--local-provider", "-p", "--profile", "-s", "--sandbox",
        "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
    ]

    private static let flagOptions: Set<String> = [
        "--strict-config", "--oss", "--approve-for-me",
        "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust",
        "--worktree", "--search", "--no-alt-screen", "--no-daemon",
    ]

    public static func isAppServer(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return false }
            if valueOptions.contains(argument) {
                index += 2
                continue
            }
            if argument.hasPrefix("--"), let name = argument.split(separator: "=", maxSplits: 1).first,
               valueOptions.contains(String(name)), argument.contains("=") {
                index += 1
                continue
            }
            if argument.hasPrefix("-c"), argument != "-c", !argument.hasPrefix("--") {
                index += 1
                continue
            }
            if flagOptions.contains(argument) {
                index += 1
                continue
            }
            return argument == "app-server"
        }
        return false
    }
}
