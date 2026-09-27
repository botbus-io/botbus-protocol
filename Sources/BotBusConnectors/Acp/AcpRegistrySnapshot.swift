// 由 scripts/acp-registry-snapshot.py 生成，不要手改。
// 来源：https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json（registry version 1.0.0）
import Foundation
import BotBusConnectorKit

public enum AcpRegistrySnapshot {
    public static let entries: [AcpRegistryEntry] = [
        AcpRegistryEntry(id: "agoragentic-acp", name: "Agoragentic", binaries: ["agoragentic-mcp"], args: ["--acp"], defaultEnabled: true, npmPackage: "agoragentic-mcp", website: "https://agoragentic.com"),
        AcpRegistryEntry(id: "amp-acp", name: "Amp", binaries: ["amp-acp"], args: [], defaultEnabled: true, website: "https://github.com/tao12345666333/amp-acp"),
        AcpRegistryEntry(id: "antigravity-acp", name: "Google Antigravity", binaries: ["agy_acp_server.par"], args: [], defaultEnabled: true, website: "https://antigravity.google/docs/ide/extensions"),
        AcpRegistryEntry(id: "auggie", name: "Auggie CLI", binaries: ["auggie"], args: ["--acp"], defaultEnabled: true, npmPackage: "@augmentcode/auggie", website: "https://www.augmentcode.com/"),
        AcpRegistryEntry(id: "autohand", name: "Autohand Code", binaries: ["autohand-acp"], args: [], defaultEnabled: true, npmPackage: "@autohandai/autohand-acp", website: "https://www.autohand.ai/cli/"),
        AcpRegistryEntry(id: "cline", name: "Cline", binaries: ["cline"], args: ["--acp"], defaultEnabled: true, npmPackage: "cline", website: "https://cline.bot/cli"),
        AcpRegistryEntry(id: "codebuddy-code", name: "Codebuddy Code", binaries: ["codebuddy-code", "cbc"], args: ["--acp"], defaultEnabled: true, npmPackage: "@tencent-ai/codebuddy-code", website: "https://www.codebuddy.cn/cli/"),
        AcpRegistryEntry(id: "cortex-code", name: "Cortex Code", binaries: ["cortex"], args: ["acp", "serve"], defaultEnabled: true, website: "https://docs.snowflake.com/en/user-guide/cortex-code/cortex-code"),
        AcpRegistryEntry(id: "corust-agent", name: "Corust Agent", binaries: ["corust-agent-acp"], args: [], defaultEnabled: true, website: "https://corust.ai/"),
        AcpRegistryEntry(id: "crow-cli", name: "crow-cli", binaries: ["crow-cli"], args: ["acp"], defaultEnabled: true, website: "https://crow-ai.dev"),
        AcpRegistryEntry(id: "cursor", name: "Cursor", binaries: ["cursor-agent"], args: ["acp"], defaultEnabled: true, website: "https://cursor.com/docs/cli/acp"),
        AcpRegistryEntry(id: "deepagents", name: "DeepAgents", binaries: ["deepagents-acp"], args: [], defaultEnabled: true, npmPackage: "deepagents-acp", website: "https://docs.langchain.com/oss/javascript/deepagents/overview"),
        AcpRegistryEntry(id: "devin", name: "Devin", binaries: ["devin"], args: ["acp"], defaultEnabled: true, website: "https://docs.devin.ai/cli"),
        AcpRegistryEntry(id: "dimcode", name: "DimCode", binaries: ["dimcode", "dim"], args: ["acp"], defaultEnabled: true, npmPackage: "dimcode", website: "https://dimcode.dev/docs/acp.html"),
        AcpRegistryEntry(id: "dirac", name: "Dirac", binaries: ["dirac"], args: ["--acp"], defaultEnabled: true, npmPackage: "dirac-cli", website: "https://dirac.run"),
        AcpRegistryEntry(id: "factory-droid", name: "Factory Droid", binaries: ["droid"], args: ["exec", "--output-format", "acp-daemon"], defaultEnabled: true, npmPackage: "droid", website: "https://factory.ai/product/cli"),
        AcpRegistryEntry(id: "fast-agent", name: "fast-agent", binaries: ["fast-agent-acp"], args: ["-x"], defaultEnabled: true, website: "https://fast-agent.ai"),
        AcpRegistryEntry(id: "gemini", name: "Gemini CLI", binaries: ["gemini"], args: ["--acp"], defaultEnabled: true, npmPackage: "@google/gemini-cli", website: "https://geminicli.com"),
        AcpRegistryEntry(id: "github-copilot-cli", name: "GitHub Copilot", binaries: ["copilot"], args: ["--acp"], defaultEnabled: true, npmPackage: "@github/copilot", website: "https://github.com/features/copilot/cli/"),
        AcpRegistryEntry(id: "glm-acp-agent", name: "GLM Agent", binaries: ["glm-acp-agent"], args: [], defaultEnabled: true, npmPackage: "glm-acp-agent", website: "https://github.com/stefandevo/glm-acp-agent"),
        AcpRegistryEntry(id: "goose", name: "goose", binaries: ["goose"], args: ["acp"], defaultEnabled: true, website: "https://block.github.io/goose/"),
        AcpRegistryEntry(id: "grok-build", name: "Grok Build", binaries: ["grok"], args: ["agent", "stdio"], defaultEnabled: true, npmPackage: "@xai-official/grok", website: "https://x.ai/cli"),
        AcpRegistryEntry(id: "harn", name: "Harn", binaries: ["harn"], args: ["serve", "acp"], defaultEnabled: true, website: "https://harnlang.com"),
        AcpRegistryEntry(id: "junie", name: "Junie", binaries: ["junie"], args: ["--acp=true"], defaultEnabled: true, website: "https://junie.jetbrains.com"),
        AcpRegistryEntry(id: "kilo", name: "Kilo", binaries: ["kilo"], args: ["acp"], defaultEnabled: true, website: "https://kilo.ai/"),
        AcpRegistryEntry(id: "kimchi", name: "Kimchi", binaries: ["kimchi"], args: ["--mode", "acp"], defaultEnabled: true, website: "https://kimchi.dev"),
        AcpRegistryEntry(id: "kimi", name: "Kimi CLI", binaries: ["kimi"], args: ["acp"], defaultEnabled: true, website: "https://moonshotai.github.io/kimi-cli/"),
        AcpRegistryEntry(id: "minimax-code", name: "MiniMax Code", binaries: ["mcode"], args: ["acp"], defaultEnabled: true, npmPackage: "@minimax-ai/code", website: "https://agent.minimax.io"),
        AcpRegistryEntry(id: "minion-code", name: "Minion Code", binaries: ["minion-code"], args: ["acp"], defaultEnabled: true, website: "https://github.com/femto/minion-code"),
        AcpRegistryEntry(id: "mistral-vibe", name: "Mistral Vibe", binaries: ["vibe-acp"], args: [], defaultEnabled: true, website: "https://mistral.ai/products/vibe"),
        AcpRegistryEntry(id: "nova", name: "Nova", binaries: ["nova", "compass"], args: ["acp"], defaultEnabled: true, npmPackage: "@compass-ai/nova", website: "https://www.compassap.ai/portfolio/nova.html"),
        AcpRegistryEntry(id: "opencode", name: "OpenCode", binaries: ["opencode"], args: ["acp"], defaultEnabled: true, website: "https://opencode.ai"),
        AcpRegistryEntry(id: "poolside", name: "Poolside", binaries: ["pool-darwin-arm64"], args: ["acp"], defaultEnabled: true, website: "https://poolside.ai"),
        AcpRegistryEntry(id: "qoder", name: "Qoder CLI", binaries: ["qoder", "qodercli"], args: ["--acp"], defaultEnabled: true, npmPackage: "@qoder-ai/qodercli", website: "https://qoder.com"),
        AcpRegistryEntry(id: "qwen-code", name: "Qwen Code", binaries: ["qwen"], args: ["--acp", "--experimental-skills"], defaultEnabled: true, npmPackage: "@qwen-code/qwen-code", website: "https://qwenlm.github.io/qwen-code-docs/en/users/overview"),
        AcpRegistryEntry(id: "sigit", name: "siGit Code", binaries: ["sigit"], args: [], defaultEnabled: true, website: "https://github.com/getsigit/sigit"),
        AcpRegistryEntry(id: "stakpak", name: "Stakpak", binaries: ["stakpak"], args: ["acp"], defaultEnabled: true, website: "https://stakpak.dev"),
        AcpRegistryEntry(id: "vtcode", name: "VT Code", binaries: ["vtcode"], args: ["acp"], defaultEnabled: true, website: "https://github.com/vinhnx/VTCode/blob/main/docs/guides/zed-acp.md"),
    ]
}
