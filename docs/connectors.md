# BotBusConnectors

公开仓库 `botbus-io/botbus-protocol` 的 `Sources/BotBusConnectors`。一档连接器（Codex、Claude Code、Hermes、Pi、OpenClaw、DeepSeek Harness）与 ACP 的全部实现，只依赖 [Kit](connector-kit.md) 与 `BotBusProtocol`；按 app 仓库的开源连接器设计稿（`docs/superpowers/specs/2026-09-27-open-connectors-design.md`） 第二步起随公开仓库 `botbus-io/botbus-protocol` 发布。上游 agent 改了格式只改这里并发 Mac 版；手机只认 Protocol，新 agent 一律走 `acp` + `connectorId`，不加 `TaskSource` 枚举值。以下源码均在 `Sources/BotBusConnectors/`，按来源分子目录。

## 逐层定位

| 层 | 文件 | 职责 |
|---|---|---|
| Codex 观察 | `CodexObserver.swift`、`CodexThreadReader.swift`、`CodexPaths.swift`（`SQLiteDatabase.swift` 在 Kit） | 只读数据库、轮询、任务与项目映射 |
| Codex 控制 | `CodexConnector.swift`、`CodexAppServer.swift`、`CodexSubprocess.swift` | 线程/轮次、stdio RPC、子进程与重启 |
| Codex 桌面桥接 | `CodexBridgeRouter.swift`、`CodexDesktopBridgeHost.swift`、`CodexDesktopBridgeClient.swift`、`CodexBridge/CodexBridgeMain.swift` | 桌面原协议请求复用、ID 隔离、审批竞争、私有回环接入 |
| Codex 编解码 | `CodexAppServerMessages.swift`、`CodexJSON.swift` | JSON RPC 消息、通知、服务端请求；`CodexJSON.swift` 只保留公开 `BotBusConnectorParsers` 包的类型别名（Kit 的 `Reexports.swift` 已整包导出），实际通用 JSON 帧解析在公开仓库 |
| Claude | `ClaudeConnector.swift`、`ClaudeHooks.swift`、`ClaudeHookInstaller.swift`、`ClaudeSessionHistory.swift`、`ClaudeModels.swift` | hook 映射、设置合并、`claude -p` 输出；`StreamJSONReader` 来自公开解析器包（经 Kit 导出）；启动时从 transcript 补回 7 天内的会话；运行中从 transcript 跟进 app 起的标题；手机能选的模型别名与 transcript 模型名的换算（协议 3.2） |
| Pi | `PiSessionReader.swift`、`PiConnector.swift`、`PiMessageReader.swift` | 会话 JSONL（树，当前分支沿 `parentId` 回溯）的解析与带缓存的观察源；`pi --mode json` 子进程；对话记录 |
| Hermes | `HermesStateReader.swift`、`HermesConnector.swift`、`HermesMessageReader.swift` | 只读 `~/.hermes/state.db`（按列存在与否容错、压缩父会话隐藏）；`hermes chat -q --format stream-json` 子进程；对话记录 |
| OpenClaw | `OpenClawConfig.swift`、`OpenClawGateway.swift`、`OpenClawConnector.swift`、`OpenClawMessageReader.swift` | `openclaw.json`（JSON5）；Gateway WebSocket v4 握手与请求关联；连接器既观察又控制（全部 `claimLive`）；`chat.history` |
| ACP（协议 2.13） | `AcpHub.swift`、`AcpConnector.swift`、`AcpConnector+Reverse.swift`、`AcpDiscovery.swift`、`JSONRPCPeer.swift` 等 | 第三方 ACP agent 的发现、子进程驱动与反向扩展，见下方「ACP」一节 |
| DeepSeek Harness（协议 3.1） | `DshConnector.swift`、`DshTaskMapping.swift`、`DshPaths.swift`、`DshWeb*.swift`、`DshSessionScanner.swift`、`DshTranscript.swift` | 一档来源 `dsh`：连接器（ACP 子进程 + `dsh web` + 扫盘）、对账与 waterfall 映射、对话记录，见下方「DeepSeek Harness」一节 |
| 描述符表与终端接续 | `ConnectorDescriptors.swift`、`DesktopResume.swift` | `ConnectorDescriptor.all(...)` 与各一档描述符（探测可执行文件与数据目录），`ConnectorRegistry.init(enabled:acpEnabled:)` 便利构造；`DesktopResume` 按来源拼在终端里接上会话的命令 |
| 桥接器 | `Bridges/` | 预留给不支持 ACP 的 agent（设计 §8）：随 Mac 发布、以 `Origin.bridge` 进 `AcpHub`，目前为空 |

## 必须保留的行为

- Codex 的数据库只读；文件名版本号由 `CodexPaths` 选择。改 schema 映射时优先扩充测试数据库，不能修改用户的 `~/.codex` 来适配测试。
- 注意路径配置的实际作用域：AgentModel 将自定义 Codex 目录传给观察者/探测器，分发器的读取器由 app 装配（`CommandDispatcher` 不再默认带 Codex / Claude 读取器），`CodexMessageReader` 默认仍用默认路径，子进程 launcher 默认继承进程环境。处理自定义目录问题时分别核对三条链路，不能假定改设置已同步到所有读取与控制路径。
- Codex 服务端请求可能是审批或用户输入；RPC request ID、线程 ID、轮次 ID 和协议任务 ID 不可混用。子进程重启的代际检查、in-flight 请求完成与控制权恢复需一起考虑。
- 桌面共享模式下只有桌面进行上游 initialize；Agent 的请求 ID 独立映射。工具和鉴权请求只交给桌面；四类手机可回答的审批先答者生效。Agent 断线不终止桌面上游，也不能自动重试在途写命令；重新接入补回运行轮次和未答审批。桥接目录/文件分别限 `0700`/`0600`，每个客户端请求带 Bearer token。
- Claude 没有数据库观察者，连接器是实时状态权威。hooks 只看得见启动之后有动静的会话，所以连接器每次启动调一次 `restoreRecentSessions()`：只读扫 `~/.claude/projects/*/*.jsonl`（不进 `subagents/`），取 7 天内最新的 ≤ 200 条，只读头 64 KB 与尾 256 KB；跳过 `entrypoint` 为 `sdk-py` / `sdk-ts` 的脚本会话（保留 `sdk-cli`）与没有 prompt 的空会话；标题优先 `custom-title`，其次 `ai-title`、首条真实 prompt（先剥 `<system-reminder>`）、`last-prompt`；状态记 `completed`，超过 24 小时记 `idle`；静默写入不推通知。合并时 hook 已建的会话以 hook 为准，只补更高来源的标题（`TitleSource`：占位 < prompt < `ai-title` < `custom-title`）与最后一条消息。补历史不轮询。**一轮从 `UserPromptSubmit` 算起**：`SessionStart` 在桌面 app 里点开旧会话、`/clear`、压缩上下文时都会发，只更新已知会话的目录与 transcript 路径，不改状态、不顶 updatedAt，没见过的会话不建（与补历史一致）。收尾靠 `Stop`（completed）、`StopFailure`（API 报错，failed）、`SessionEnd`（一轮中途或挂着审批 / 提问时关掉记 interrupted 并放掉挂起的 hook，空闲等输入记 completed，静默发布；本连接器自己的子进程不管，由 `finish` 收尾）。电脑上按停止或在权限框里拒绝不发任何 hook，只写一行中断标记，所以电脑上的会话处于 running / waitingApproval 时，`checkTurnEndings` 每 30 秒读一次 transcript 尾 64 KB（`ClaudeSessionHistory.turnEnding`）：最后一条对话行是中断标记记 interrupted、是 `stop_hook_summary` 记 completed（补送丢的 Stop），标记时间早于这一轮开始 2 秒以上的算上一轮、不理；没有要盯的会话时循环自己退出。老版本装的 hooks 少 `StopFailure` / `SessionEnd`，app 起 Claude 连接器时 `ClaudeHookInstaller.upgradeIfNeeded` 给装过的补齐（没装过的不碰）。hook 负载里没有 app 起的标题，所以每条带 `transcript_path` 的 hook 进来后在后台读 transcript 尾 256 KB 找 `custom-title` / `ai-title`（`refreshAppTitle`，不阻塞 hook 回包）：还没取到时按 `titleRetryDelays` 追约 100 秒，取到后只在 Stop 时再看一眼以接住改名。桌面会话续聊可能通过 `--resume` 分出新 session，回执必须使用实际 session ID；中断只适用于本连接器启动并持有的进程。本连接器自己那一轮还在跑（含起进程到拿到 session id 的几秒）时到达的续聊排队、立即回执，上一轮结束再按到达顺序 `--resume`，中间不报 completed；中断清空队列。不要同时对一个 session 起两个 `claude -p --resume`，transcript 会分叉。子进程环境总是传完整一份：`Process.environment = nil` 在 macOS 26 上是空环境，没有 HOME 的 claude 只会回 "Not logged in"。对话读取与最后一条消息都跳过 `ClaudeConnector.isFiller`（`isMeta` 行、resume 时补的非报错 `<synthetic>` 回复、中断时以 user 身份写的 "[Request interrupted by user]"）。
- Claude 权限 hook 挂起 HTTP 响应等待用户决定；超时/停机回空响应，由 Claude 自身处理权限，不能把超时变成允许。`AskUserQuestion`（协议 2.14）也走这条 hook：`ClaudeAskedQuestions` 解出问题，任务记 `waitingInput`、`pendingRequest` 是带 `questions` 的 `.input`；`approve` 带 `answers` 时回 `allow` + `updatedInput`（原入参整份带回再加 `answers`，键是问题原文、多选用 `, ` 连接——`updatedInput` 会整份替换入参），`deny` 是跳过（任务仍 `running`，不是中断），没带答案的 `allow` 报错且不放掉挂起；挂着提问时的 `followUp` 就是回答（所有问题同一句话，带图拒绝），不另起 `claude -p`。`-p` 模式没有这个工具，只在桌面 app / 交互会话里出现。Codex 的 `requestUserInput` 同样把选项放进 `questions`，`approve` 的 `answers` 按问题 id 回；连接器接口的 `approve(…answers:)` 默认忽略答案。审批也能带 `questions`——那是「允许」的范围：OpenClaw 的 exec 审批带一道 `scope`（`scopeQuestion`：只这一次 / 以后都允许），`gatewayDecision` 把选中的「以后都允许」映射成 `allow-always`（OpenClaw 写成绑定 argv 与工作目录的白名单条目），其余一律 `allow-once`——认不出、没带、旧手机都按最保守的算。ACP 同理：`AcpPermissionRequest.pendingQuestions` 把 `allow_once` / `allow_always` 选项（按这个顺序、同名去重）列成一道 `scope`，`optionId(for:answers:)` 按选中的名字对回 `optionId`，对不上就回落到只选一次性的老规则；拒绝类选项不列。安装器仅合并/移除带本工具标记的 hook，保留用户其他配置。
- 注入只在 `AgentToolsConfiguration.isUsable`（CLI 可执行、地址非空）时发生，否则与没有此功能时完全一致。Claude：环境变量合并进子进程，`--append-system-prompt` / `--mcp-config` / `--allowedTools` 排在 prompt 之后、由 `--output-format` 收尾（可变参数）；session id 到手即 `bind`，`--resume` 分支出的新 id 改绑同一个 token。Codex：`thread/start` / `thread/resume` 加 `developerInstructions` 与点路径到叶子的 `config`（不要整表覆盖用户的 `mcp_servers` / `shell_environment_policy`）；已在本代子进程加载的线程续聊不重复注入；`CodexAppServer` 重启后自动 resume 的线程不带注入。
- Pi / Hermes 的连接器在自己起的一轮里认领所有权，结束后交还并催观察者 `pollOnce()`；一轮若在回执之前就结束，回执用 `retainsLiveOwnership: false` 交给分发器 claim/release，另外 1 秒后补放一次，挡住"连接器 release 早于分发器 claim"的空当。登记（`begin` / `markRunning`）期间到达的收尾只排队，不然登记里的 `upsert(running)` 会盖掉最终状态。
- 手机发图（协议 2.9，`start` / `followUp` 的 `images` 是已下载到本机的文件 URL）只有 Codex 与 Claude 接：Codex 在 `turn/start` 的 `input` 里文字之后追加 `localImage {path}`，线程挂着 `requestUserInput` 时带图续聊直接报错（回答只收文字，不能把图丢掉）；Claude 带图时 prompt 不再是位置参数，改为 `--input-format stream-json` 并在 stdin 写一行 user 消息（图 base64 在前、文字在后）后关闭，该 flag 同时给注入的可变参数收尾，不带图时参数逐项不变。Hermes / Pi / OpenClaw / DeepSeek Harness 收到图直接报「这个 Agent 暂不支持发图」，不能只发文字；分发器在下载之前就按 `ConnectorKind.acceptsImages`（与 ClientCore `TaskSource.acceptsImages` 一致）拒掉，连接器里的同一道检查留作兜底。分发器没有 inbox 时带图命令报「本机无法接收图片」；`followUp` 的下载放在 `onTask` 里，失败照常交还所有权；没带图时不碰 inbox。Codex 与 Claude 只发图新建任务时标题记「图片」。
- 换模型与思考强度（协议 3.2）：`ConnectorRegistry.setModels` 存各连接器报给手机的 `ConnectorInfo.models`（清掉不合法的 id / 强度，本机没装时不报）。Codex 每代 app-server 握手完在后台问一次 `model/list`（不含 hidden），变了就 `broadcastSnapshot`；`followUp(…selection:)` 先对照列表校验，随 `turn/start` 发 `model` / `effort`，`turn/steer` 与回答提问时不换；任务上的 `model` / `effort` 来自 `thread/start` / `thread/resume` 应答，只读观察读 `threads.model` / `reasoning_effort`。Claude 在 init 里写入 `ClaudeModels.options`，手机选的记在 `Session.chosenModel` / `chosenEffort`，每次 `--resume` 都带 `--model` / `--effort`（`resolve` 只收列表里的别名与该模型的档，换到 Haiku 清掉强度），分支出的新 session 继承；显示用的模型在 Stop 时读 transcript 尾 64 KB、补历史时取最后一条 assistant 的模型名换成别名。新建任务同理（`startTask.model` / `effort`）：`CommandDispatcher` 对没报 `models` 的来源（含 ACP）在下载图、建新项目文件夹之前就拒；Codex 在 `thread/start` 之前校验（新建时只换强度按列表第一个模型查），随第一轮 `turn/start` 发；Claude 用 `resolve(_, current: nil)` 校验后第一次 `claude -p` 就带 `--model` / `--effort` 并记进 `chosenModel` / `chosenEffort`。别的连接器走 `TaskConnector` 的默认实现：带了选择就报错，不悄悄用原模型跑。
- OpenClaw 与 Claude 一样是唯一权威：每次发布都先 `claimLive` 再 `reconcile(tasks: [])`；Gateway 断开时任务保留、`controllable` 置 false，健康状态经 `ConnectorRegistry.reportRuntime` 回报。Pi 没有审批，Hermes 的 `-q` 模式没有审批通道（本期不做 ACP），`approve` 都回明确的错误。

## ACP

第三方 agent 经 ACP 接入（协议 2.13，`kind = acp` + `connectorId`）。对外规范写在 [acp-agents.md](acp-agents.md)，改行为时同步它；设计与落地差异见 app 仓库的 ACP 设计稿。

| 文件 | 职责 |
|---|---|
| `AcpHub.swift` | 全部 ACP agent 的总入口（`MultiAgentConnector` + `MessageReader`）：按 `connectorId` 分命令、合并 `.acp` 对账、周期刷新 `session/list`、写 `ConnectorRegistry` 条目、接反向握手；注册表 agent 首次握手失败时隐藏（`unverified`） |
| `AcpConnector.swift` | 每个 agent 一个 actor：按需拉起子进程、`initialize`、命令对应、审批挂起、空闲关进程、`session/load` |
| `AcpConnector+Reverse.swift` | 反向连接挂上/摘下、`_botbus/session` / `_botbus/turn` / `_botbus/permission_resolved`、经反向连接续聊/中断/新建 |
| `AcpSession.swift` | 会话状态与对话记录：`session/update` → `TaskRecord`、轮次收尾、审批前后的状态复原、回显丢弃 |
| `AcpMessages.swift`、`AcpClient.swift`、`JSONRPCPeer.swift` | ACP 消息解析、client 一侧的调用、按行分帧的 JSON-RPC 2.0 peer |
| `AcpDiscovery.swift`、`AcpRegistrySnapshot.swift`、`AcpManifestWatcher.swift` | 清单与注册表快照合并（`reservedIds`、npm 真实路径校验）；快照由 `scripts/acp-registry-snapshot.py` 生成，不要手改；FSEvents 监视约定目录 |
| `AcpReverseServer.swift`、`UnixSocket.swift` | `~/.botbus/run/acp.sock` 监听、hello 闸门（10 秒超时、握手前通知最多攒 100 条）、目录/socket 权限与同 uid 校验 |
| `AcpSessionArchive.swift` | BotBus 拉起的会话记到 `acp-sessions.json`，只存元数据（标题是首条提示词前 80 字），只留 7 天窗口内的 |
| `AcpAgentCommand.swift` | `botbus agent list / check`（`CLI/main.swift` 转过来），不写 `TaskStore` |

- **有反向连接在报的会话绝不再拉子进程 `session/load` 或发 prompt**：`load()` 前后都查 `reverseOwner`，被接管抛 `TakenOverByReverse`，续聊改走反向连接；`commitTurn` 发 prompt 前同步复查。改这块时保持"先改完状态再 await"的写法。
- **每个 agent 的开关在 `AcpHub` 把关**：`ConnectorRegistry.isEnabled(.acp)` 恒为 true，分发器那一道拦不住单个 agent，所以命令、对话记录、对账与列表刷新都先查 `isActive(_:)`（没被隐藏且 `isAcpEnabled(id)`）；`TaskStore` 也按 `connectorId` 过滤停用 agent 的任务。开关变化后 app 必须调 `applyEnabledState()`，停用的 agent 关进程、断反向连接。
- **`JSONRPCPeer.receive(_:)` 只能由一个读循环串行调用**（DEBUG 下有 assert）；通知处理器不能对同一个 peer 发请求并等应答（应答要靠同一个循环解出来）。agent 发来的请求各在独立 Task 里处理，审批不堵后面的通知。
- 反向连接上 BotBus 没有答案时回 `-32001`（`AcpPermissionOutcome.noAnswer`），只有真正的取消才回 `cancelled`；子进程上一律回 `cancelled`。
- 退出用 `AcpHub.shutdown()`（不可逆，之后迟到的命令与刷新拉不起进程）；解除配对或被接管用 `stopSubprocesses()`（只关子进程，反向连接和列表刷新照旧）。
- **通知基线按 agent 走**：`AcpHub.reconcile()` 调 `TaskStore.reconcileAcp(tasks:projects:baselined:)`，`baselined` 是列表基线已就绪的 agent（`AcpConnector.isListBaselined`：成功列过一次 `session/list`，或没有启动命令 / 握手说不支持列表）。store 只为上一轮已就绪、且此刻启用的 agent 推对账里的变化，所以重启后本机记录先到、第一次列表才拉回的历史会话不会被推成一堆「任务完成」；停用、消失、被藏的 agent 自动出局，回来重新静默一轮。实时 `upsert` 不受影响。`reconcile(source: .acp, …)` 等于全都没就绪。
- stderr 只留尾巴给 `lastError` 与 `CommandResult.error`，不进公开日志：带 stderr 或 agent 自己错误文本的 `ConnectorError` 标 `containsPrivateDetail`，分发器据此按 `.private` 记；`AcpConnector` 自己的日志只记 `logCategory(_:)`。JSON-RPC 日志只记方法名与字节数，不记 params / result。

测试：`AcpTestSupport.swift` 提供内存里的假 agent（`FakeAcpAgent` 实现 `CodexProcessHandle`，行为由 `FakeAcpBehavior` 脚本化）、`FakeAgentQueue`（取完即报错，用来断言"没有再起进程"）、背靠背的 `PeerWire` 与 `AcpHarness`；`AcpConnectorTests`、`AcpHubTests`、`AcpReverseTests`（真 Unix socket）、`AcpDiscoveryTests`、`AcpSessionStateTests`、`AcpMessagesTests`、`AcpAgentCommandTests`、`ConnectorRegistryAcpTests`、`TaskStoreAcpTests`。没有任何测试会起真实 agent。

## DeepSeek Harness

一档来源 `dsh`（协议 3.1，spec `docs/superpowers/specs/2026-09-27-deepseek-harness-design.md`）。`DshConnector` 一个 actor：BotBus 的活走内含的 `AcpConnector`（`identity: .builtin(.dsh)`，任务 id `dsh:<sessionId>`、不带 `connectorId`；spec id 为 `dsh`，已在 `AcpDiscovery.reservedIds` 里），电脑上的会话经 `dsh web` 的内部接口看见与控制，web 不在时扫盘。对外说明在 app 仓库的 `docs/agent.md`。

| 文件 | 职责 |
|---|---|
| `DshConnector.swift` | `TaskConnector` + 观察循环（每拍找 web / 扫盘 / 对账）、命令路由、follow 与 waterfall、健康回报；`DshMessageReader`（`.dsh` 的 `MessageReader`） |
| `DshTaskMapping.swift` | 纯映射：`DshSessionFacts`（web 列表 / 扫盘的一项）、`DshLiveState`（follow 流累积）、全量对账合并、waterfall → `PendingRequest`、手机回答 → `DshQuestionAnswer` |
| `DshPaths.swift` | `~/.dsh`（不认 shell 里的 `DSH_HOME`，子进程显式带 `DSH_HOME`）；`dsh` 先 `AgentBinary.detect`，再 npx 缓存里挑最高 semver 用 `<node> lib/bin.js` 起；node 要 ≥ 22.15（`zstdDecompressSync`），版本按路径 + 修改时间记住；`DshInstallationProbe` 是描述符与连接器共用的探测缓存（注册表 `refresh()` 时重新找） |
| `DshWebAuth.swift` | 只读 `.credentials.yaml` 里 `client-connection/browser-session` 的签名密钥（不碰 API key、不打日志），自签 `dsh-auth-*` cookie |
| `DshWebClient.swift`、`DshWebMessages.swift` | 一元调用、mux WebSocket（`item` / `error` / `end` 按 `streamId` 分发，传输复用 `OpenClawWebSocketTransport`：不查 Relay 版本头、帧上限 32 MiB）、各种帧与会话事件的解析 |
| `DshWebLocator.swift` | libproc / `KERN_PROCARGS2` 找同用户的 `dsh web`，按 `DSH_HOME`（没设就是它 `HOME` 下的 `.dsh`）过滤，读回环监听端口 |
| `DshSessionScanner.swift`、`DshTranscript.swift` | web 不在时扫 `sessions/` 与投影缓存（缓存按修改时间记住）；内嵌 node 脚本逐帧解 zstd；事件 → `TranscriptEntry` |

控制（spec「控制」一表）：新建一律 ACP（没有可执行文件时报错，`ConnectorProbe.canStartTask` 为 false）。续聊：`acp.isInProcess` → ACP；否则 web 连着 → web `session/prompt`（不带 botbus 工具，先乐观地记运行中，20 秒没开跑就交还）；否则 ACP `session/resume`，撞 `.sessionBusyElsewhere` 时立刻找一次 web，找到改走 web，找不到把错误报给手机。审批：`acp.isRunningTurn` → ACP；否则按最近一条 waterfall 的 `eventId`（即 `PendingRequest.id`）回 `$events/result`——审批只有允许这一次 / 拒绝；提问的「允许」带 `answers`（值是选项名的进 `selected`，其余拼进 `custom`；单选有 `custom` 时 `selected` 为空），一个都没答报错且不放掉挂起，「拒绝」= 跳过（每题 `selected: []`，这一轮接着跑）；挂着提问时的续聊就是回答（每题 `custom` 为这句话）。中断：ACP 或 web `session/cancel`。

- **只 follow web 已经在跑（`running` / `api-session/status true`）或挂着 waterfall 的会话**：`session/follow` 会让 web 载入并一直锁住冷会话，之后 ACP resume 必撞锁。只读历史走读盘或 `session/page`（`latestPage`：`asOfSeq` 来自投影缓存，ACP 进程写的缓存常停在会话开头，不可信）。`DshMessageReader` 的顺序：`acp.completeTranscript`（本次 BotBus 建的会话）→ 读盘 + `DshTranscriptParser.window` → web `latestPage`；从不 follow、从不 resume。
- **所有权**：web 在跑 / 挂着 waterfall / 刚经 web 续聊的会话由 `DshConnector` `claimLive` 并实时 upsert；收尾（follow 流的 `turn/end`，或 status false 后 `settleGrace` 3 秒）先写最终记录再 `releaseLive`。`api-session/status false` 常比 `turn/end` 先到；实测 `session/cancel` 打在一轮两步之间时 web 根本不写 `turn/end`，等不到就按 interrupted 算。`$events` 与每条 follow 各由一个任务消费，彼此没有先后：status false 甚至会比 snapshot 先到，所以 web 说在跑的会话一开 follow 就记成在跑、收尾未知，照样等宽限；收尾（停掉 follow）之后才轮到的帧一概不理。`publishLive` 的记录在最后一个 `await` 之后才定稿，交还了就不再写，免得先算好的旧记录晚到盖掉最终状态。ACP 的轮次由 `AcpConnector` 自己认领。
- **全量对账**（`reconcile(source: .dsh)`）：底子是 web 列表（连着时）或扫盘，7 天窗口，跳过空白与 subagent；并上 `acp.staticTasks()`：同一会话来源（`.watch`）与非占位标题以 ACP 为准，状态与最后一条消息取更新的一份，只在 ACP 里的照样列。状态：挂着 waterfall → 待审批 / 待回答；web 在跑或 follow 看见开着的一轮 → running；扫盘看到开着的一轮且日志 5 分钟内还在写（比我们跟到的收尾新）→ running；否则最后一次 `turn/end`；都不知道按 24 小时 completed / idle。`controllable` = web 连着或有可执行文件。**拿到完整列表（web 列表或第一次扫盘）之前不对账**，那一次是 store 的静默基线；不要调 `AcpConnector.refreshList()`（dsh 的 ACP `session/list` 不带时间）。
- **web 链接**：每拍（5 秒）没连上就找；`DshWebLocator` 只给用同一主目录的实例，签名密钥读不到或 401 时 `lastError` 说明、30 秒后再试；连上后先订 `$events` 等 `ready`（拿 `clientId`），再拉 `session/list`；每 30 秒 ping、每 60 秒重拉列表，列表里还没有的会话有动静也重拉。找 web 同一时间只有一次（节拍与续聊撞锁时的"立刻找一次"会先等进行中的那次，还没连上再自己找）。断开（对端关、ping 失败、`$events` 流结束）：任务留着、认领全部交还、立刻扫盘对账，`controllable` 随之改；实时状态在第一个 `await` 之前同步清掉，连着 web 期间扫盘结果作废（`scanned = nil`），重新扫过之前不对账；健康经 `onHealth` → `ConnectorRegistry.reportRuntime`（同 OpenClaw，注册表 `refresh()` 后 `reannounceHealth()` 再报一次）。
- subagent 会话与父会话同目录，只有会话头（`origin: "subagent"`）认得出，扫描要借 node 读头；fork 有 `parentSession` 但照常列。`user/message` 只认 `source.kind == "user"`（运行时上下文是 `plugin`、技能目录是 `skill-catalog`）；带非 `append` `surfaceOp` 的是压缩时的替换副本，不进对话。
- `AcpConnector` 对只有 `sessionCapabilities.resume`、没有 `loadSession` 的 agent 续聊前先 `session/resume`（不重放历史，`completeTranscript` 为 nil）；读记录从不 resume，抛 `AcpConnectorError(.transcriptUnavailable)` 交外层兜底；dsh 的会话锁错误（-32603，`already owned by an active write handle`）是 `.sessionBusyElsewhere`。
- 依赖 dsh 0.1.5-rc 的**内部接口**（web 的 RPC 名、参数名、错误文案 `past cursor N`、会话日志格式），升级可能要跟着改；坏了只影响 BotBus（退回扫盘），不改 dsh 的任何配置、不往里装插件。
- 测试：`DshConnectorTests`（假 ACP `AcpTestSupport` + `FakeDshWeb`：假 HTTP 与 `FakeTransport`；路由、follow 收尾、waterfall、提问回答、断开退回扫盘、读取器顺序、401。计时器都经注入的 `sleep`：节拍照真实时间走，等 `ready`、收尾宽限、等续聊开跑由 `DshTimers` 按时长放行，不靠墙钟；两条流之间要先后的，等前一条的效果（如认领）出现了再发下一条）、`DshTaskMappingTests`（纯规则）、`DshPathsTests`、`DshWebTests`（cookie 向量是 node 用假密钥算的）、`DshSessionScannerTests`、`DshTranscriptTests`（有够新的 node 时真解一份多帧 zstd，没有就跳过）、`AcpConnectorBuiltinTests`、`ConnectorRegistryTests.testDshProbe`。`DshSmokeTests` 默认跳过，`BOTBUS_DSH_SMOKE_HOME=<隔离的 dsh 主目录>` 时连这个主目录的 `dsh web`（只读：列表、`$events`、page）并比对读盘与 web 的记录；不要指向日常用的 `~/.dsh`。

## 验证

仓库根目录 `swift test --filter BotBusConnectorsTests`（各连接器测试、`ConnectorRegistryTests`、`MessageReaderTests`、`AgentToolsInjectionTests`（起一个假的 `claude` shell 脚本核对参数与环境，不运行真实 Claude）、`PhoneStartedTasksTests`）。transport、launcher、时钟和测试 SQLite 都可注入，没有任何测试会起真实 agent；`DshSmokeTests`、`RealCodexSmokeTests` 默认跳过，显式启用方式见 [CONTRIBUTING.md](../CONTRIBUTING.md)。经分发器走完整命令链路的用例直接用 Kit 的 `CommandDispatcher`（假连接器与假 agent 在 `TestSupport.swift`、`AcpTestSupport.swift`）。
