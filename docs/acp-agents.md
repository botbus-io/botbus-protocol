# 把你的 agent 接进 BotBus（ACP）

写给第三方 agent 的开发者。BotBus 电脑端用 [Agent Client Protocol](https://agentclientprotocol.com)（ACP，v1）驱动本机的 agent，另加一个很小的「反向扩展」，让 agent 自己的终端或 IDE 里开的会话也实时出现在手机和手表上。你的 agent 只要实现 ACP，就能被手机新建任务、续聊、审批、中断和查看对话记录；配对、凭据和 Relay 都由 BotBus 处理，agent 不用管。

**现状**（2026-09-26）：下文描述的是仓库里已经实现的行为（协议 2.13 第一期），单测覆盖了清单、注册表、子进程驱动与反向扩展的全部流程，但第三方 agent 的清单、注册表与反向扩展**还没有用任何真实 agent 端到端跑通过**（2026-09-27 起，同一个 `AcpConnector` 驱动 DeepSeek Harness 的 `dsh --profile acp` 在真机上跑通了新建、续聊与 `session/resume`），也还没有随 BotBus 发版。只支持 macOS 电脑端；agent 只能跑在装着 BotBus 的那台电脑上。

## 三种接入方式

| 你的情况 | 怎么接 | 需要做什么 |
|---|---|---|
| 已进 [ACP 官方注册表](https://agentclientprotocol.com/registry) | BotBus 内置一份注册表快照，按快照里的可执行文件名在本机找 | 什么都不用做。快照随 BotBus 发版更新，新进注册表的 agent 要等下一版 |
| 自己做的、按需启动的 agent | 安装程序往 `~/.botbus/agents/` 放一份清单 | 写清单（见下） |
| 常驻进程 / 想让终端里的会话也实时可见 | 反向扩展：agent 进程主动连 `~/.botbus/run/acp.sock` | 清单 + 实现反向扩展；常驻型的清单可以不写 `command` |

发现规则：

- BotBus 内置深度适配的 agent（Codex、Claude Code、Hermes、Pi、OpenClaw、DeepSeek Harness）优先，注册表里对应它们的适配器（`claude-acp`、`codex-acp`、`pi-acp`）直接跳过。保留 id 共 10 个（`AcpDiscovery.reservedIds`）：`codex`、`claude`、`hermes`、`pi`、`openclaw`、`dsh`、`acp`、`claude-acp`、`codex-acp`、`pi-acp`，清单不能用。
- DeepSeek Harness（`dsh`，协议 3.1）是一档来源，**不经清单或注册表**：BotBus 自己找 `dsh`（PATH 类目录或 npx 缓存），内部同样用 ACP 驱动 `dsh --profile acp` 起手机任务，电脑上的会话另经它的网页端（`dsh web`）实时看见。给它写清单会因为 id 被占用而不生效。
- 同一个 id 清单优先于注册表。
- 注册表条目要本机真装了才算：按快照里的可执行文件名去 PATH 和常见的全局安装目录（Homebrew、npm / pnpm / bun / volta 的全局 bin、`~/.local/bin` 等）找。npm 分发的条目还要求可执行文件的真实路径（跟随软链接）落在 `node_modules/<包名>/` 下，防止同名的无关程序被当成 agent 启动。
- 注册表 agent 的**第一次**握手就是验证：起不来、握手前退出、回的不是 ACP 或版本不对，就从手机和菜单里隐藏，直到发现结果变化、它经反向扩展连进来或 BotBus 重启。`initialize` 超时（冷启动慢）和要求登录不算失败。清单 agent 失败照常显示并报错。
- 发现到的 agent 默认启用；用户可以在电脑的 BotBus 设置（「本机 Agent」）或手表的设备页逐个开关。iPhone 不能开关，停用的 agent 在手机上显示「没有启用」卡片，指向电脑设置。
- 一台电脑最多同时接入 10 个 ACP agent（加上内置的 6 个正好是协议允许的 16 个连接器），超出的按显示名排序后丢掉；被丢掉的 agent 经反向扩展连进来时，拒绝原因会说明。

## 清单

`~/.botbus/agents/<id>.json`，文件名必须等于 `id`。BotBus 监视这个目录，增删改都不用重启。安装程序请直接把文件写进已有的目录，不要先删整个目录再换一个进来。

```json
{
  "id": "my-agent",
  "name": "My Agent",
  "command": "/usr/local/bin/my-agent",
  "args": ["--acp"],
  "env": { "MY_AGENT_LOG": "warn" }
}
```

| 字段 | 规则 |
|---|---|
| `id` | 必填。小写字母、数字、`-`，1–32 个字符，不含冒号；等于文件名；不能是保留 id |
| `name` | 必填，非空，超过 40 字截断。手机和菜单里显示它 |
| `command` | 可选。绝对路径（可以用 `~`，必须可执行），或 PATH / 常见安装目录里能找到的名字。不写 = 只能经反向扩展接入 |
| `args` | 可选，字符串数组 |
| `env` | 可选，字符串到字符串。合并在 BotBus 自己的环境之上；可执行文件所在目录会补到 `PATH` 最前（node 脚本需要） |

子进程的工作目录是用户主目录，会话目录经 `session/new` 的 `cwd` 给出。清单暂不支持自定义图标。

清单有问题时这个 agent 不会出现；BotBus 设置窗口的通用页会多出一节「这些 ACP 清单没有生效」，逐个列出文件和原因（例如「文件名必须是 my-agent.json」「找不到 command：my-agent」），旁边有「打开清单文件夹」和「重新检测」。命令行里 `botbus agent list` 也会打印同样的原因。

## BotBus 用到的 ACP 子集

**`initialize`**：BotBus 发 `protocolVersion: 1`，并声明**不提供** `fs` 和 `terminal`——工具由 agent 自己执行，BotBus 只看和批。agent 回的版本必须正好是 1，否则报「不支持的 ACP 版本」。10 秒没回应算超时。BotBus 读取并按进程缓存 `agentCapabilities.loadSession`、`promptCapabilities.image`、`sessionCapabilities.list`、`sessionCapabilities.resume` 和 `authMethods`。

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{
  "protocolVersion":1,
  "clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false},"terminal":false},
  "clientInfo":{"name":"botbus","version":"1.0"}}}
```

**`botbus` MCP**：BotBus 从手机发起的 `session/new`、`session/load` 与 `session/resume` 会在 `mcpServers` 里带一个 stdio server，agent 照常启动它，就能把截图、文件、链接和 localhost 预览分享回手机，不用做任何适配。token 只对这条手机任务有效。开发构建的 BotBus 没有内嵌 CLI 时 `mcpServers` 是空数组。

```json
{"name":"botbus","command":"/Applications/BotBus.app/Contents/Helpers/botbus","args":["mcp"],
 "env":[{"name":"BOTBUS_CLI","value":"…"},{"name":"BOTBUS_TASK_TOKEN","value":"…"},{"name":"BOTBUS_TOOLS_URL","value":"http://127.0.0.1:…"}]}
```

### 命令对应

| 手机上的操作 | ACP | 说明 |
|---|---|---|
| 新建任务 | 按需拉起 → `initialize` → `session/new`（cwd、botbus MCP）→ `session/prompt` | `session/new` 一返回，手机就能看到这个任务。有反向连接声明了 `newSession`（或清单没写 `command`）时改走反向连接 |
| 续聊 | 会话在当前进程里：`session/prompt`；不在：先 `session/load` 再 prompt；没有 `loadSession`、只声明了 `sessionCapabilities.resume` 时先 `session/resume {sessionId, cwd, mcpServers}` 再 prompt（不期待重放历史） | 两样都不支持时失败；同一会话正在跑一轮时也失败。`session/resume` 回 -32603、`data.details` 里有 `already owned by an active write handle`（会话正被别的进程写着，DeepSeek Harness 的会话锁）时报「这个会话正开在电脑上的 … 里」 |
| 审批 | 回复挂起的 `session/request_permission` | 允许：优先 `allow_once`，没有才 `allow_always`；拒绝：优先 `reject_once`，其次 `reject_always`；都没有就失败 |
| 中断 | `session/cancel` | 同时把挂起的审批回成 `cancelled`（ACP 规定） |
| 带图的消息 | `image` 内容块（base64） | agent 没声明 `promptCapabilities.image` 时直接失败，不悄悄只发文字 |
| 看对话记录 | 用收集到的 `session/update` 拼 | 内存里没有时用 `session/load` 重放；不支持就失败。读记录**从不** `session/resume`（它不重放，还会占住会话） |
| 看未提交的改动 | 不经过 ACP | BotBus 在 cwd 里只读 git |

子进程空闲 10 分钟后关掉；崩溃后不自动重启，下一条命令来时再拉起。

### 状态对应

| 任务状态 | 条件 |
|---|---|
| `running` | `session/prompt` 还没返回（反向连接：`_botbus/turn started` 之后） |
| `waitingApproval` | 有挂起的 `session/request_permission`。工具类型 `execute` 显示为命令，`edit` / `delete` / `move` 显示为改文件，其余显示为一般权限；摘要取工具调用的标题，详情取原始输入，截断到 2000 字 |
| `completed` | `stopReason = end_turn` |
| `interrupted` | `stopReason = cancelled`；反向连接断开时正在跑的一轮 |
| `failed` | `refusal`、`max_tokens`、`max_turn_requests`、JSON-RPC 报错、进程崩溃 |
| `completed` / `idle` | `session/list` 列出、不是 BotBus 在驱动的会话：24 小时内更新过是 `completed`，否则 `idle` |

- 标题：`session_info_update` 优先，其次 `session/list` 的标题，最后取首条 prompt 前 80 字。最后一条消息：这一轮拼起来的 `agent_message_chunk`，前 500 字。
- 对话记录：连续的同角色消息合成一条；每个 `tool_call` 变成一行工具摘要（以 `toolCallId` 为 id，后续 `tool_call_update` 合进去）；思考过程不显示。审批请求里的 `toolCall` 往往只有 `toolCallId`，所以请先发对应的 `tool_call` 通知，手机上才有标题可看。
- 返回了 `authMethods`、调用时又报 `auth_required`（-32000）的，BotBus 显示「请在电脑上登录 <name>」，不从手机上登录。
- `session/list`（声明了 `sessionCapabilities.list` 才用）：进程在跑时每 60 秒刷新，没在跑时每 10 分钟短暂拉起一次；只列 7 天内更新过的。BotBus 自己拉起的会话另在本机记一份（`acp-sessions.json`：会话 id、目录、标题、时间和状态；标题是第一条提示词的前 80 个字，不存 agent 的回复和其余对话内容），不支持 `session/list` 的 agent 重启后也能列出来。本机记录和列表一样只显示 7 天内更新过的，更早的存盘时就删掉。
- 通知：BotBus 启动或刚发现、刚启用一个 agent 时，要等它第一次 `session/list` 成功（或确定它不支持列表）之后才开始为列表里的会话推通知，这一批历史会话不会被逐条推成「任务完成」。BotBus 自己跑的一轮和反向连接报的会话不受影响，照常提醒。

## 反向扩展 v1

用来让 agent 自己界面里开的会话实时出现在手机上。连接方向反过来，但角色不变：你的进程仍是 ACP 的 agent，BotBus 仍是 client。所有消息都是 JSON-RPC 2.0，**每行一条**（UTF-8，`\n` 结尾，和 ACP stdio 一样），单行上限 16 MiB。

### 连接与握手

开始会话时检查 `~/.botbus/run/acp.sock` 在不在：在就连上，不在（BotBus 没运行）就什么都不做。连上后先发 `_botbus/hello`：

```json
→ {"jsonrpc":"2.0","id":1,"method":"_botbus/hello",
   "params":{"id":"my-agent","version":1,"pid":4321,
             "capabilities":{"prompt":true,"cancel":true,"newSession":false}}}
← {"jsonrpc":"2.0","id":1,"result":{"accepted":true}}
← {"jsonrpc":"2.0","id":1,"result":{"accepted":false,"reason":"用户在 BotBus 里停用了这个 agent"}}
```

- `id` 必须是 BotBus 已发现的 agent（清单或注册表），并且用户没有停用它。`version` 是扩展自己的版本号，目前只认 `1`。`capabilities` 缺省的项都当 `false`。
- 缺 `id` 或 `version` 时回 JSON-RPC 错误（-32602）。被拒绝或出错时，BotBus 发完应答就断开；10 秒内没握上手也断开。同一条连接再发一次 hello 只回拒绝，不断开。
- **收到 `accepted: true` 之后再开始上报。** 握手前到的通知 BotBus 会先攒着（最多 100 条），通过后按顺序处理，但这只是尽力而为；握手前发的请求一律回错误。
- 用户之后在 BotBus 里停用这个 agent、删掉清单或 BotBus 退出时，BotBus 直接断开连接。断开后请停止上报，下次开始会话时再试着连。
- 通过反向扩展握手成功也算验证：之前被隐藏的注册表 agent 会重新出现。

### agent → BotBus

先用 `_botbus/session` 宣告会话，之后这个会话的消息 BotBus 才认：

```json
{"jsonrpc":"2.0","method":"_botbus/session","params":{"sessionId":"s-42","cwd":"/Users/me/proj","title":"修登录页"}}
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s-42","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"好的，我先看看"}}}}
{"jsonrpc":"2.0","method":"_botbus/turn","params":{"sessionId":"s-42","state":"started"}}
{"jsonrpc":"2.0","method":"_botbus/turn","params":{"sessionId":"s-42","state":"ended","stopReason":"end_turn"}}
{"jsonrpc":"2.0","id":7,"method":"session/request_permission","params":{"sessionId":"s-42","toolCall":{"toolCallId":"call-1"},"options":[{"optionId":"a1","name":"允许","kind":"allow_once"},{"optionId":"r1","name":"拒绝","kind":"reject_once"}]}}
{"jsonrpc":"2.0","method":"_botbus/permission_resolved","params":{"sessionId":"s-42","toolCallId":"call-1"}}
```

| 消息 | 含义 |
|---|---|
| `_botbus/session {sessionId, cwd, title?}` | 宣告一个会话，从此它是实时任务。`cwd` 必填。每条连接最多 50 个会话；另一条活着的连接正在报的、或 BotBus 自己的子进程正在跑一轮的会话不会被接管 |
| `session/update` | 和 ACP 一样，按「状态对应」推算 |
| `_botbus/turn {sessionId, state, stopReason?}` | 反向连接没有 `session/prompt` 的返回可等，轮次开始（`started`）和结束（`ended`）要单独报；`stopReason` 取 ACP 的值 |
| `session/request_permission`（请求） | 同时在终端里照常问用户，谁先答用谁的 |
| `_botbus/permission_resolved {sessionId, toolCallId}` | 终端先答了：BotBus 撤掉手机上的审批，之后手机再批会提示「这个请求已在电脑上处理」 |

审批请求的应答：

- 手机做了决定：`{"outcome":{"outcome":"selected","optionId":"a1"}}`。
- **真正的取消**（手机上点了中断、用户停用了这个 agent、BotBus 退出）：`{"outcome":{"outcome":"cancelled"}}`。
- **BotBus 没有答案**（会话不归这条连接、被同一会话的新审批顶掉、这一轮已经结束、终端先答了）：JSON-RPC 错误 `{"code":-32001,"message":"BotBus 没有答案"}`。收到它请继续等终端里的回答，不要当成用户取消。

可以把用户在你自己界面里敲的 prompt 转成 `user_message_chunk` 发过来；但**不要回显 BotBus 经 `session/prompt` 发给你的 prompt**——那句话 BotBus 已经记过了，这一轮里再收到的 `user_message_chunk` 会被当成回显丢掉。

### BotBus → agent

按 hello 里声明的能力发，都是标准 ACP 消息：

```json
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"s-42","prompt":[{"type":"text","text":"再加个单测"}]}}
{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s-42"}}
{"jsonrpc":"2.0","id":4,"method":"session/new","params":{"cwd":"/Users/me/proj","mcpServers":[{"name":"botbus","command":"…","args":["mcp"],"env":[…]}]}}
```

- `prompt`：手机续聊时发 `session/prompt`，请让消息出现在你的界面里，就像用户在电脑上敲的。照常用 `{"stopReason":"end_turn"}` 应答，或者报 `_botbus/turn ended`，两者都到也只算一次。反向连接上的消息暂不带图。
- `cancel`：手机点中断时发 `session/cancel`。
- `newSession`：手机新建任务时发 `session/new`，拿到 `sessionId` 后紧接着发 `session/prompt`。给常驻守护进程型 agent 用，它们的清单可以不写 `command`。没有 `command` 也没声明 `newSession` 的 agent 不会出现在手机的新建任务列表里。
- 没声明 `prompt` 时手机续聊提示「请在电脑上继续」，没声明 `cancel` 时中断提示「只能在电脑上中断」。

### 所有权

- 反向连接在报的会话由这条连接实时驱动，BotBus **绝不**再为它拉子进程做 `session/load`，免得两个进程写同一个会话。
- 连接断开时交还：正在跑的一轮记成 `interrupted`，挂着的审批撤掉，任务保留最后的状态；之后能不能从手机续聊看子进程那边（有 `command` 且支持 `loadSession`）。

### 安全

- socket 所在目录 `~/.botbus/run` 权限 0700，socket 0600，BotBus 还会核对对端进程的 uid 与自己相同；目录是软链接或属于别的用户时 BotBus 拒绝监听。已经有进程在听这个 socket 时 BotBus 不抢，反向扩展不可用（只记日志）。
- 反向连接不需要 task token（token 只管 `botbus` 工具）。已知弱点：同一用户下的恶意进程可以冒充已启用的 agent，往手机上推假任务和假审批。批准一个假审批不会在电脑上执行任何东西，所以接受这个风险。

## 自查

`botbus` 在 `BotBus.app/Contents/Helpers/botbus`。这两个子命令不需要 BotBus 在运行，也不需要 task token。

```text
$ botbus agent list
gemini	Gemini CLI	注册表	已启用	/opt/homebrew/bin/gemini --acp
my-agent	My Agent	清单	已启用	/usr/local/bin/my-agent --acp
my-daemon	My Daemon	清单	已停用	（没有启动命令，只能经反向扩展接入）
✗ /Users/me/.botbus/agents/bad.json：文件名必须是 my-bad.json
```

`list` 只读清单、注册表快照和 BotBus 的开关设置，不起进程；列表里有不等于能用，注册表 agent 可能在第一次握手后被隐藏。

```text
$ botbus agent check my-agent --prompt "hi"
ACP 协议版本: 1
loadSession: 是
图片: 否
session/list: 否
登录方式: 0 种
会话: 7f3c…
agent: 你好！
结束原因: end_turn
```

- `check` 真的拉起 agent 跑 `initialize`（10 秒超时）并打印协商到的能力；加 `--prompt` 时在一个临时目录里 `session/new` + `session/prompt` 跑一轮，打印 agent 的回复与工具调用，最多等 5 分钟。
- `check` 模式下不注入 `botbus` MCP，审批请求一律回 `cancelled`，也不管用户有没有停用这个 agent。
- 没有 `command` 的 agent 不能 `check`；退出码 0 成功，1 失败，2 用法错误。

## 已知限制

- `session/list` 已进 ACP v1 稳定 schema，但是可选能力；不实现它的 agent，BotBus 只看得到自己拉起的会话和经反向扩展报的会话。经 `session/list` 看到的会话只有静态信息（标题、目录、时间）。
- ACP 没有「agent 在向用户提问」的信号，所以 ACP 任务不会出现「等待回复」状态；提问只会作为一条普通回复出现。
- 反向连接断开时，正在跑的一轮记成 `interrupted`，即使 agent 那边其实还在跑。
- 手机和手表上只有注册表里的 10 个常见 agent 有品牌图标（Gemini CLI、goose、OpenCode、Qwen Code、Kimi CLI、Cursor、GitHub Copilot、Cline、Mistral Vibe、Kilo），其余注册表 agent 和自己写清单的 agent 一律显示默认的 `>_` 图标。
- stderr 只在内存里留最后一小段，用来在菜单和手机上显示出错原因，不写日志。
