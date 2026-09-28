# BotBus 协议

版本 **3.2**（逐版本沿革见附录 A）。所有 JSON 字段 camelCase；时间为 ISO 8601 UTC 字符串，固定格式 `YYYY-MM-DDTHH:MM:SSZ`（秒精度，不带小数）；Relay 依赖该格式做字典序时间比较，Relay 自己生成的时间也遵守此格式。Swift 用 `ProtocolJSON.timestamp()`，TypeScript 用 `nowIso()`；枚举为字符串；可选字段缺省时整个键省略，不写 `null`。

Swift 实现是 `BotBusProtocol` 包，TypeScript 实现是 Relay 的 schema，Kotlin 实现（Android）是 `Protocol.kt`，密封层在同目录的 `Sealing.kt` / `SealedTypes.kt`。在 app 仓库里它们分别位于 `Packages/BotBusProtocol`、`relay/src/protocol.ts` 与 `android/core/src/main/kotlin/io/botbus/core/`；公开仓库 `botbus-io/botbus-protocol` 由 app 仓库自动同步，前两者在那里是 `Sources/BotBusProtocol` 与 `src/protocol.ts`。三端都必须通过 `protocol-fixtures/` 下全部样本的往返测试，且拒绝 `invalid/` 下的样本：顶层是线上的密封形状，`plain/` 是密文里的明文结构（见文末「Fixture 与类型对应」）。Swift 中 `Task` 命名为 `TaskRecord`。

本文按功能分章。总则讲三种载体、加密、帧与版本握手；之后八章各讲一类领域对象，每章末尾附上这一类的命令；附录 A 是逐版本的沿革，附录 B 是样本与类型的对应。

| 章 | 内容 |
|---|---|
| 总则 | Snapshot / Event / Command 三种载体、端到端加密、WebSocket 帧、版本握手、Relay HTTP 一览 |
| 一、电脑与连接器 | AgentInfo、ConnectorInfo、ModelOption、Project、`setConnectorEnabled` |
| 二、任务与状态 | Task、TaskStatus、`startTask` / `followUp` / `interrupt` |
| 三、审批与提问 | PendingRequest、PendingQuestion、`approve`、SystemPermissionNotice |
| 四、对话与附件 | Message、MessageAttachment、MessageFileRef、TaskMessages、`fetchMessages` / `fetchFile` |
| 五、产物与文件 | Artifact、产物字节的加密、WorkingChanges、`fetchChanges` |
| 六、屏幕共享与远程操作 | `remoteControl`、远程操作的加密、预览主机与隧道 |
| 七、通知 | Notify、推送的加密与 APNs / FCM 载荷 |
| 八、配对、凭据与设备 | 配对链接与密钥信封、配对码、多份客户端凭据 |
| 附录 A | 版本沿革：每个版本加了什么、发布顺序 |
| 附录 B | Fixture 与类型对应 |

## 总则：载体、传输与加密

Mac 与手机之间只经三种载体沟通：电脑发出的 **Snapshot**（全量状态）与 **Event**（增量），手机发出的 **Command**（操作，回执是 `CommandResult`）。它们在线上都包在端到端加密的信封里，Relay 只按信封外的 id 与时间路由、合并、截断。

### Snapshot 与 CommandResult

`agents` [AgentInfo]（最多 10，按 name 升序）；`tasks` [Task]（合并全部电脑，最多 400，按 updatedAt 降序）；`projects` [Project]（合并，最多 60）；`recentResults` [CommandResult]（最近 20）；`recentMessages` [TaskMessages]（最多 1，见下）；`seq` integer；`generatedAt` string。

Agent 发出的 Snapshot 中 `agents` 恰好一个元素（自己，`online` 填 true、`lastSeenAt` 填当前时间），`tasks` / `projects` 只含自己的，`recentResults` 与 `recentMessages` 填 `[]`、`seq` 填 0。Relay 保存时按 `agentId` 分片，只采纳该 Agent 的 `name`、`appVersion`、`connectors`、`projectsRoot`、`tasks`、`projects`、`generatedAt`；`online` 与 `lastSeenAt` 由 Relay 按连接状态维护，`seq` 与 `recentResults` 由 Relay 维护。客户端取到的 Snapshot 是全部分片的合并结果。

Agent 掉线时 Relay 保留其最后分片，只把 `online` 置 false，不删除其 tasks；客户端应把离线电脑的任务显示为不可操作。例外是闲置清理：一组 30 天（`PAIR_IDLE_TTL_MS`）没有任何鉴权通过的请求或 Agent 帧、也没有电脑或手机连着时，Relay 清掉各分片的 `tasks` / `projects`、`recentMessages`、`recentResults` 与离线队列并让 seq 加一；`agents` 里的电脑（名字、版本、连接器）与全部凭据保留。客户端此时看到的是一台没有任务的离线电脑，电脑一连上就会重发全量快照。

CommandResult：`commandId` string，`ok` boolean，`error` string?，`taskId` string?，`finishedAt` string，`systemPermission` SystemPermissionNotice?（2.10 起，省略兼容旧结果），`artifactId` string?（2.11 起，只在 `fetchChanges` 成功且有改动时有：改动清单的产物 id；没有改动时省略）。

Relay 另设防御性上限：合并后 `tasks` 最多保留 400 条（按 updatedAt 降序截断），`projects` 最多 60 条，`agents` 最多 10 台。`generatedAt`：`snapshot` 事件沿用 Agent 的值；`taskUpdated` / `taskRemoved` 后由 Relay 改为当前时间；`commandResult` 与 Agent 上下线不改。

### Command 一览

`id` string（客户端生成 UUID）；`createdAt` string；`agentId` string（必填，指明目标电脑，Relay 据此路由）；`kind` `startTask` \| `followUp` \| `approve` \| `interrupt` \| `setConnectorEnabled` \| `fetchMessages` \| `fetchFile` \| `fetchChanges` \| `remoteControl`；与 kind 同名的 payload 字段必须存在（两端解码时校验）；其余 payload 字段应省略，接收方以 kind 为准并忽略多余载荷。

每种命令的载荷在它所属的章里定义：

| kind | 章 |
|---|---|
| `startTask`、`followUp`、`interrupt` | 二、任务与状态 |
| `approve` | 三、审批与提问 |
| `setConnectorEnabled` | 一、电脑与连接器 |
| `fetchMessages`、`fetchFile` | 四、对话与附件 |
| `fetchChanges` | 五、产物与文件 |
| `remoteControl` | 六、屏幕共享与远程操作 |

### Event 一览

`kind` `snapshot` \| `taskUpdated` \| `taskRemoved` \| `commandResult` \| `notify` \| `taskMessages`，配套字段分别为 `snapshot` Snapshot、`task` Task、`taskId` string、`commandResult` CommandResult、`notify` Notify、`taskMessages` TaskMessages。与 Command 相同：与 kind 配套的字段必须存在（两端解码时校验）；其余配套字段应省略，接收方忽略多余字段。

`notify` 的载荷见「七、通知」，`taskMessages` 见「四、对话与附件」。

Relay 收到 `notify` 后按设备平台转成 APNs 或 FCM，不改 Snapshot，不递增 seq。`taskMessages` 不进分片（分片是「当前状态」，它是「一次查询的结果」），只替换那份 `recentMessages` 并让 seq 加一。其余四种 Event 会更新存储的 Snapshot 并让 seq 加一。

### 端到端加密（3.0）

设计与取舍见 `docs/superpowers/specs/2026-09-26-end-to-end-encryption-design.md`。本节是实现契约：Android、Windows 等新客户端照它实现，并用共用的密封样本自证（见本节末）。

#### 钥匙

- 每个组一把 32 字节随机**组密钥 K**，组里所有设备持有同一把。建组时由手机生成；之后经二维码 / 密钥信封传给新电脑、新手机，经 WatchConnectivity（系统加密）传给手表。K 只存在各设备的钥匙串里。
- 用途密钥由 HKDF-SHA256 派生（salt 为空，32 字节，`info` 为下列固定字符串）：`botbus/v1/content`（快照、事件、命令、结果、对话记录、手机名与设备名、产物字节）、`botbus/v1/notify`（推送正文；iPhone 的通知扩展只拿这一把）、`botbus/v1/remote-control`（远程操作的画面与输入）、`botbus/v1/artifact-id`（保留，目前未用）。
- 指纹：SHA-256(K) 的前 4 字节，8 位小写十六进制。电脑配对窗口与手机设置页各显示一份，给人核对两边是不是同一把钥匙。

#### 信封

一段密文在 JSON 里是一个无填充的 base64url 字符串：`0x01 ‖ nonce(12 字节，随机) ‖ AES-256-GCM 密文 ‖ tag(16 字节)`。首字节是格式版本，不认识的版本一律拒绝。明文是规范 JSON（键按字典序、无多余空白，Swift 的 `ProtocolJSON`），产物字节则是原始字节。**只用 AES-256-GCM**：各平台都有原生实现（CryptoKit、WebCrypto、`javax.crypto`、.NET `AesGcm`）。nonce 必须随机；样本里用的是确定性 nonce，只为可比对，生产环境不得照搬。

关联数据（AAD）把密文钉在它的位置上，Relay 挪位置、换电脑都会解密失败；解开后还要核对明文里的 id、`updatedAt` 与信封外面的一致：

| 内容 | AAD |
|---|---|
| 任务 | `task:<agentId>:<taskId>` |
| 电脑（AgentInfo） | `agent:<agentId>` |
| 项目列表 | `projects:<agentId>` |
| 对话记录 | `messages:<agentId>:<taskId>` |
| 命令 | `command:<agentId>:<commandId>` |
| 命令结果 | `result:<commandId>` |
| 推送（用 `K_notify`） | `notify:<agentId>:<taskId>` |
| 手机名、推送注册的设备名 | `client` |
| 产物字节 | `artifact:<agentId>:<artifactId>`（手机上传的图钉的是目标电脑的 agentId） |
| 密钥信封 | `key-envelope:<agentId>` |
| 远程操作（用 `K_rc`） | `rc:<agentId>` |

AAD 不含 pairId：跨组挪密文本来就解不开（K 不同），而 Mac 在收到 hello 之前不知道自己的 pairId。

#### 线上形状

Relay 只解析这些形状（`relay/src/protocol.ts` 的 `Sealed*`），`sealed` 里是上文对应领域对象的完整 JSON：

- `SealedTask {id, agentId, updatedAt, sealed}`：Relay 按 id 合并、按 `updatedAt` 排序并截断（每台 200、合并 400）。
- `SealedAgent {agentId, online, lastSeenAt, sealed?}`：`online` / `lastSeenAt` 由 Relay 维护，以外层为准；`sealed` 缺省 = 刚被认领、还没连上过。合并快照里电脑按 agentId 排序（名字在密文里，客户端自己排）。
- `SealedProjects {agentId, sealed}`：一台电脑的整个项目列表（`[Project]`），只随 snapshot 事件整体替换；截断由 Mac 在发出前做。
- `SealedMessages {taskId, agentId, fetchedAt, sealed}`；`SealedResult {commandId, finishedAt, sealed? | error?}`：两者恰好一个，`error` 只有 Relay 自己造的 `"expired"`（它没有密钥）。
- `SealedNotify {taskId, agentId, category, requestId?, sealed}`：`TASK_APPROVAL` 必带明文 `requestId`。
- `SealedSnapshot {agents, tasks, projects, recentResults, recentMessages, seq, generatedAt}`；`SealedEvent` 同 Event（`kind` 明文，配套字段是密封形状，`taskRemoved.taskId` 明文）；`SealedCommand {id, agentId, createdAt, sealed}`：命令种类与载荷都在密文里，Relay 只路由、限长（整条 ≤ 16 KiB，含 base64 膨胀）。

Relay 仍看得见的元数据：pairId、各电脑的 agentId 与在线状态、任务 id（含来源前缀，如 `codex:`）与更新时间、命令 id 与时间、推送的类别、各段密文的大小。

#### 新客户端怎么自证兼容

`protocol-fixtures/` 的密封样本由 `scripts/seal-fixtures.mjs` 用固定钥匙（K = 0x00…0x1f；电脑临时私钥 = SHA-256("botbus-fixture-mac-key")，手机临时私钥 = SHA-256("botbus-fixture-phone-key")）与确定性 nonce（SHA-256(AAD) 的前 12 字节）生成。新实现照 Swift 的 `SealedFixtureTests` 做三件事：顶层样本往返不变；用固定钥匙解开后与 `plain/` 同名样本逐键相等；把明文重新密封后与样本逐键相等（信封逐字节一致）。密钥信封同理（`key-envelope.json`）。远程操作页的 JS 加密层用 `node scripts/check-remote-page-crypto.mjs` 核对。演示模式的组密钥是公开的固定值 SHA-256("botbus-demo-group-key")。

### WebSocket 帧

- Agent → Relay：`{"type":"ready"}`（3.0 起，连上后的第一帧），之后是 `{"type":"event","event":SealedEvent}`
- Relay → Agent：`{"type":"command","command":SealedCommand}`，以及 `{"type":"hello","pairId":string,"keyEnvelope":KeyEnvelope?}`
- Relay → 客户端（`/client/ws`）：`{"type":"snapshot","snapshot":SealedSnapshot}` 或 `{"type":"changed","seq":integer}`

3.0 起 Agent 连上后先发 `ready`（Relay 收到第一帧才发 hello 与命令），本机还没有组密钥时等 hello 里的 `keyEnvelope`，用这次配对 offer 的临时私钥解开、存好，再发 `kind = snapshot` 的全量快照；已经有组密钥的可以紧跟着 `ready` 发快照。hello 里没有信封而本机又没有组密钥（3.0 之前的配对），这份配对无法加密通信，Agent 按「已撤销」处理、提示重新配对。

连接语义（Agent 实现必读）：
- 同一 `agentId` 只保留一条连接；新连接被接受后旧连接以 **4000** 关闭。不同 `agentId` 的连接并存，互不影响。来自旧连接的迟到帧被忽略；收到 4000 不应自动重连（是本机的新进程顶掉了旧进程）。
- 本 Agent 被移除或整个 Pair 被撤销时 Relay 以 **4001** 关闭，此后该 agentToken 一律 401。收到 4001 或 401 应清除凭据并提示重新配对。
- `agentId` 有效但尚未被任何客户端认领时 `/agent/ws` 返回 **409**。Agent 应固定每 5 秒重试，不进指数退避，并在界面显示"等待手机扫码"。
- **Agent 发出第一帧之前，Relay 不向它发任何数据帧**（协议 2.4 起）。Mac 用一次 ping 确认握手，而 `URLSessionWebSocketTask` 只在有挂起的 `receive()` 时才处理 pong：握手刚完成就到的数据帧会挡住 pong，让握手超时、连接被丢弃，帧里的命令也就丢了。第一帧（协议规定是全量快照）到了之后，Relay 先发 `hello`，再投递离线队列；这期间到达的新命令先入队。Agent 仍应能在初始化完成前缓冲命令。
- Relay 不对 `event` 帧回 ack，也不回错误帧；校验失败的帧被丢弃并只记录字段路径。Agent 靠下一次全量 snapshot 自愈。
- Relay 不按 `id` 去重命令：客户端重试可能导致同一命令投递两次，Agent 应按 `id` 去重。
- Relay 不发心跳、不做空闲超时。Agent 每 30 秒发一次协议层 ping（`URLSessionWebSocketTask.sendPing`），断线后指数退避重连（1、2、4… 最大 60 秒）。
- `Snapshot.projects` 只随 `snapshot` 事件更新，`taskUpdated`/`taskRemoved` 不碰它；Agent 在项目列表变化时必须重发全量 snapshot。
- `commandResult` 经 WebSocket 至多送达一次，Relay 不会在后续 snapshot 里补 `recentResults`；Agent 若在断线期间产生结果，应在重连并发出快照后补发。
- 每次连上、收到 Agent 的第一帧后，Relay 发出的**第一帧**是 `hello`，带本 Agent 所属组的 `pairId`（排在离线命令之前）。Agent 应记下它，之后所有请求（WebSocket 握手与 HTTP 的 agent 端点）带 `X-Pair-Hint: <pairId>`。这只是路由提示，不是凭据：Relay 凭它直接去该组核对 agentToken，省掉一次全局 Directory 查询；提示不对（过期、伪造）时 Relay 回落到 Directory，**不会因为提示不对回 401**。旧版 Agent 解不开 hello 帧，按"校验失败的帧忽略"处理即可。
- 断线重连的退避应乘一个随机系数（Mac 用 0.5–1.5）：Relay 部署时全部 Agent 同一秒掉线，不抖动就会同一秒重连。

客户端推送连接（`/client/ws`，协议 2.4）：
- 游标语义与长轮询相同：`since` 与服务端当前 `seq` 不同时 Relay 立即推一帧，相同则等下一次变化；此后每次 `seq` 变化推一帧，严格按 `seq` 递增顺序。连续的多次变化可能合并成一帧（只推最新那份）。
- `snapshot` 帧带全量快照，和 `GET /client/snapshot` 的 200 响应体相同。快照序列化后超过 512 KiB 时改推 `changed`，只带新 `seq`，客户端应改用 `GET /client/snapshot?since=-1` 取全量。
- 关闭码 **4001**：这份 clientToken 被 `DELETE /pair/clients/:id` 踢掉，或整组被撤销——应清凭据回配对页。其他关闭码（含 Relay 部署时的断开）退避重连，重连时带上最新 `seq`。同一组同时存活的推送连接超过 30 条时，Relay 以 1008 关掉最早的那条。
- 客户端不发数据帧（发了也被忽略），每 30 秒发一次协议层 ping 保活。
- 与 Agent 连接不同，Relay **一连上就可能推首帧**。客户端必须从握手起就一直挂着 `receive()`（iPhone 的传输有常驻的接收泵），否则首帧会挡住握手 ping 的 pong。
- 旧版 Relay 没有这个端点（握手 404），客户端应回落到长轮询。**手表只用长轮询**：watchOS 不允许普通 app 使用 `URLSessionWebSocketTask`（Apple TN3135）。

### 版本握手

2.8 起，Mac、手机、手表发往 Relay 的**每个**请求（HTTP 与 WebSocket 握手，包括预览隧道）都带 `X-Protocol-Version: <版本>`；Relay 在 API 主机上的**每个**响应（含错误与 101）都带 `X-Protocol-Version: <Relay 的版本>`。预览主机上给浏览器的响应不带。版本是点分整数，逐段按数值比（`2.10` 比 `2.9` 新），缺的段当 0。**没带这个头的一方按 2.7 算**——头是 2.8 才有的。

两个方向各有一条最低线：

- **app 太旧**：Relay 按调用方角色比最低版本——`/agent/*` 与带 `X-Agent-Id` 的请求是电脑（`MIN_AGENT_PROTOCOL`），其余是手机与手表（`MIN_CLIENT_PROTOCOL`，手表沿用手机凭据，同一条线）。低于最低线时在任何鉴权与副作用之前回 **412** `{error:"upgrade required", minProtocol, protocol}`，另带 `X-Min-Protocol-Version: <最低版本>`。客户端**只认 412 这个状态码**，头与响应体只供日志；412 不清凭据，按最长退避继续重试（Relay 回滚或降线后自己恢复），界面提示「请更新 BotBus」。不用 426，是因为它已经表示「缺 `Upgrade: websocket`」，WebSocket 握手失败后的探测请求正好会拿到它。
- **Relay 太旧**：本端要求 Relay 至少是 `ProtocolVersion.minimumRelay`。只在**成功**响应（2xx、101、304）上判 Relay 的版本头——Cloudflare 边缘或代理自己回的 502 也不带这个头，拿它判会把一次抖动说成要升级。低于最低线时同样不清凭据、按最长退避重试，界面提示「请升级 Relay」。

目前 `MIN_CLIENT_PROTOCOL` 是 **3.1**，`MIN_AGENT_PROTOCOL` 与 `minimumRelay` 是 **3.0**：端到端加密换掉了整个线上形状，2.x 的 app 既发不出 Relay 认得的帧，也解不开 Relay 合并的快照，所以 Relay 3.0 上线即对 2.x 回 412。3.1 的 `dsh` 是旧手机与手表接不住的新枚举（整份快照拒收），所以 `MIN_CLIENT_PROTOCOL` 抬到了 3.1；抬线一部署就生效，所以当时先部署只改了版本号的 Relay，等 3.1 的 iOS 上了 TestFlight 再抬线，**然后**才发 3.1 的 Mac——Mac 一发版，装了 DeepSeek Harness 的电脑就会上报 `dsh`。`MIN_AGENT_PROTOCOL` 与 `minimumRelay` 不动：旧 Mac 不上报 `dsh`，Relay 只见密文。3.2 的模型与思考强度都是旧端能忽略的可选字段（3.1 的手机不认 `models` 就不画入口，旧 Mac 忽略 `followUp.model`），三条线都不动。以下是 2.x 期间的记录：`minimumRelay` 曾是 2.15。2.15 只是电脑一侧的新能力，旧手机与旧 Mac 都不受影响，不抬 app 最低线；但新版 Mac 要解 `/agent/devices` 里的 `clients`、要用电脑凭据移除手机，旧 Relay 两样都不行。2.14 的 `questions` / `answers` 都是旧端能忽略的可选字段（旧手机只看得到 `question` 纯文字，照旧打字回答），不抬 app 最低线；但旧 Relay 会把它们剥掉，新版 app 要求 Relay 2.14。2.13 的 `acp` 是旧端接不住的新枚举值：旧手机与手表见到 `source = acp` 的任务会整条拒收、解不开整份快照，按下面的规则应把 `MIN_CLIENT_PROTOCOL` 抬到 2.13；但抬线一部署就立刻生效，而新版 iOS 还没上 TestFlight，现在抬会把所有现有装机 412 掉，所以和 2.9 一样先保持 2.7——**新版 Mac 发布时必须同时把 `MIN_CLIENT_PROTOCOL` 抬到 2.13**（新版 iOS 先上 TestFlight，再发 Mac 并抬线）：Mac 一发版，装了 ACP agent 的用户就会上报 `acp`。`MIN_AGENT_PROTOCOL` 不用抬——旧 Mac 不上报 ACP agent，手机也就不会给它发带 `connectorId` 的命令。旧 Relay 会拒收 `acp` 来源、剥掉 `connectorId` / `canStartTask`，所以新版 app 要求 Relay 2.13。2.12 的 `remoteControl` 只由新手机发出（旧 Mac 解不开这条命令，手机等不到结果），所以不抬 app 最低线；但旧 Relay 的 kind 枚举会拒收整条命令，新版 app 要求 Relay 2.12。2.11 的 `fetchChanges` 只由新手机发出（旧 Mac 解不开这条命令，手机等不到结果，60 秒后显示「未收到确认」），`CommandResult.artifactId` 旧端忽略即可，所以同样不抬 app 最低线；但旧 Relay 会拒收这条命令、剥掉新字段，新版 app 要求 Relay 2.11。2.10 只新增旧 app 可以忽略的可选字段，不抬高这两条 app 最低线；新版 app 要求 Relay 2.10，以免旧 schema 剥掉系统授权提示。2.9 的 app 依赖 Relay 2.9 的上传端点（`PUT /client/uploads`、`GET /agent/uploads`）与不剥附件字段的 schema，所以 `minimumRelay` 抬到了 2.9（Relay 先部署，不影响现有用户）。2.9 同时新增了旧端接不住的枚举值——`ArtifactKind.video`（旧手机与手表解快照会整条拒收）与命令 `fetchFile`（旧 Mac 解命令会拒收）——按下面的规则应把两条最低线都抬到 2.9；但为了不在新版 Mac / iOS 发布前挡住现有装机，暂时保持 2.7，待新版 Mac 与 iOS 发布后再把 `MIN_AGENT_PROTOCOL`、`MIN_CLIENT_PROTOCOL` 抬到 2.9。在此期间，新 Mac 分享的视频会让旧手机与手表解不开快照（已知风险）；`fetchFile` 只由新手机发出，旧 Mac 解不开这条命令。什么时候抬线：

- 做了旧 app 接不住的改动（新增枚举值、改字段语义、删字段）时，部署 Relay 的同时把对应角色的 `MIN_*_PROTOCOL` 抬到新版本；只加可选字段这类旧端能忽略的改动不用抬。
- app 开始依赖 Relay 的新行为时，把 `ProtocolVersion.minimumRelay` 抬上去再发版（部署顺序仍是先 Relay 后 app，所以正常不会触发，它防的是自建或回滚的 Relay）。
- 每次协议版本号变化都同步改 Swift 的 `ProtocolVersion.current` 与 Relay 的 `PROTOCOL_VERSION`。

### Relay HTTP

鉴权头：`Authorization: Bearer <token>`；客户端另带 `X-Pair-Id: <pairId>`，Agent 另带 `X-Agent-Id: <agentId>`，知道自己所属组时再带 `X-Pair-Hint: <pairId>`（见上文 hello 帧）。

| 方法 | 路径 | 鉴权 | 请求 | 响应 |
|---|---|---|---|---|
| POST | /agent/register | 无，按 IP 每分钟 10 次 | 空 | 201 `{agentId, agentToken, code, expiresAt}`；429 限速 |
| POST | /agent/invite | agent，按 IP 每分钟 10 次 | 空 | 201 `{code, expiresAt}`；409 本 Agent 尚未被认领；429 限速 |
| POST | /pair/claim | 无，按 IP 每分钟 10 次 | `{code, sealedName?, keyEnvelope?}`（3.0：注册码建新组时 `keyEnvelope` 必填，邀请码时省略；`sealedName` 是手机名的密文） | 201 `{pairId, clientToken, agents:[SealedAgent]}`；400 格式错，或注册码缺 `keyEnvelope`（码已消费）；404 码不存在或过期；409 该组已有 10 台手机；429 限速，或该来源猜错太多次被锁（见「配对码」） |
| POST | /pair/agents | client | `{code, keyEnvelope}`（3.0 起信封必填，缺了 400 且码不消费） | 201 `{agent: SealedAgent}`；400 这是手机邀请码（码不消费）；404 码无效；409 已有 10 台电脑；429 该来源猜错太多次被锁 |
| DELETE | /pair/agents/:agentId | client | | 204；404 不属于本 Pair |
| GET | /pair/clients | client | | 200 `{clients:[{id, sealedName?, addedAt, current}]}`（3.0：名字是各手机自己封的密文，v2 时代的记录没有） |
| DELETE | /pair/clients/:id | client 或 agent（agent 2.15 起） | | 204，这份凭据的推送连接以 4001 关闭，它（与同步了它的手表）注册的推送设备一并删除；404 不属于本 Pair；409 这是最后一份凭据 |
| GET | /agent/ws | agent（Bearer + `X-Agent-Id`） | `Upgrade: websocket` | 101；409 尚未被认领 |
| GET | /agent/devices | agent | | 200 `{devices:[{sealedName, platform, lastSeenAt, clientId?}], clients:[{id, sealedName?, addedAt}]}`（3.0：两处名字都是手机自己封的密文，AAD `client`；`clients` 与 `clientId` 2.15 起；所属手机已不在组里的注册不列出） |
| GET | /client/snapshot?since=N | client | | 200 SealedSnapshot；304 无变化（最多挂 25 秒）；401 |
| GET | /client/ws?since=N | client | `Upgrade: websocket` | 101，之后推送 ClientFrame（见「WebSocket 帧」）；401；403 角色不符；426 缺 `Upgrade: websocket` |
| POST | /client/commands | client | SealedCommand | 202 `{commandId, delivered}`；400 格式错（含 2.x 的明文命令）；404 `agentId` 不属于本 Pair；413 单条超过 16 KiB；503 该 Agent 的离线队列已满（50 条） |
| POST | /client/devices | client | `{token, platform: ios\|watchos\|android, environment: sandbox\|production, sealedName}`（3.0：设备名是密文，AAD `client`；Android 固定传 `production`，FCM 不使用该字段） | 204；400 格式错或 token 超过 4096 字符；409 已有 10 台设备 |
| DELETE | /client/devices/:token | client | | 204；400 token 百分号编码非法 |
| PUT | /agent/artifacts/:artifactId | agent，按 agentId 每小时 120 次 | 密封字节，`Content-Type: application/octet-stream`（3.0） | 201 ArtifactUploadResponse `{id, size, expiresAt}`；400 id 格式错或缺 `Content-Type`；415 不是 octet-stream（明文不落 Relay）；409 该 id 已被别的 Agent 占用（本 Agent 尚未被认领也是 409）；413 超过 10 MiB；429 限速。同一 Agent 重传同一 id 即覆盖并重新计 TTL |
| GET | /client/artifacts/:agentId/:artifactId | client（该电脑须属于本 Pair） | | 200 存下的（密封）字节 + 原 `Content-Type`（3.0 起总是 octet-stream）+ `Cache-Control: private, max-age=86400`（另带 `X-Content-Type-Options: nosniff`、`Content-Security-Policy: sandbox`）；404 不存在、已过期或不属于该电脑 |
| PUT | /client/uploads/:agentId/:artifactId | client（该电脑须属于本 Pair），按组每小时 60 次 | 密封字节，`Content-Type` 必须是 `application/octet-stream`（3.0；真实类型在命令的 attachments 里） | 201 ArtifactUploadResponse `{id, size, expiresAt}`；400 id 格式错或缺 `Content-Type`；401/403/404 鉴权与归属同 `GET /client/artifacts`；409 该 id 已被占用（同组手机重传同一 id 直接覆盖并重新计 TTL）；413 超过 10 MiB；415 不是 octet-stream；429 限速 |
| GET | /agent/uploads/:artifactId | agent | | 200 原始字节 + 原 `Content-Type`（响应头同 `GET /client/artifacts`）；404 不存在、已过期，或不是手机传给这台电脑的 |
| POST | /agent/previews | agent，按 agentId 每小时 60 次 | PreviewCreateRequest `{title?}`，可为空 | 201 PreviewCreateResponse `{previewId, expiresAt}`；400 不是合法 JSON；413 超过 4 KiB；429 限速 |
| DELETE | /agent/previews/:previewId | agent（须是创建者） | | 204，隧道以 4001 关闭、浏览器 WebSocket 以 1001 关闭并删除预览状态；404 不存在、已过期或不是创建者 |
| GET | /agent/previews/:previewId/tunnel | agent（须是创建者） | `Upgrade: websocket` | 101；同一预览的新连接以 4000 顶掉旧连接；404 不存在、已过期或不是创建者；426 缺 `Upgrade: websocket` |
| POST | /client/previews/:previewId/session | client（预览须属于本 Pair） | 空 | 201 PreviewSessionResponse `{url, expiresAt}`：`url` 是带一次性 ticket 的预览入口，`expiresAt` 是 ticket 的失效时间（签发后 60 秒）；404 不存在、已过期或不属于本 Pair |
| POST | /pair/revoke | agent 或 client | | 204，解散整个 Pair，所有 Agent 连接以 4001 关闭 |
| GET | /health | 无，不查版本 | | 200 `{ok:true}` |

- `since` 与服务端当前 `seq` 相等时挂起最多 25 秒：期间有变化返回 200 全量，无变化返回 304；不相等（缺失、-1、落后、超前或非法）一律立即返回 200 全量。首次请求用 `since=-1`。
- `delivered: true` 仅表示帧已写入 Agent 连接，不代表 Agent 已处理；处理结果以后续 Snapshot `recentResults` 中同 `commandId` 的 CommandResult 为准。
- 离线队列中超过 10 分钟未投递的命令由 Relay 记为 `CommandResult{ok:false, error:"expired"}`。
- 组闲置 30 天（`PAIR_IDLE_TTL_MS`）清内容不清凭据，见 Snapshot 一节。
- 412：调用方的 `X-Protocol-Version` 低于它那个角色的最低线，见「版本握手」。适用于除 `/health` 外的全部 API 路由，排在鉴权之前。
- 401：凭据无效、缺少或格式错误的 `X-Pair-Id` / `X-Agent-Id`，或本 Agent 已被移除、整个 Pair 已撤销（应清空凭据回到配对页）。403：凭据有效但角色不符。409：`/agent/ws` 的 `agentId` 有效但尚未被任何客户端认领。426：`/agent/ws` 缺少 `Upgrade: websocket`。
- `POST /pair/create` 已移除。`X-Pair-Id` 仅客户端使用；Agent 一侧改用 `X-Agent-Id`。
- 产物与预览（2.3）：单个产物 ≤ 10 MiB，默认保留 7 天（`ARTIFACT_TTL_MS`）；预览默认存活 2 小时（`PREVIEW_TTL_MS`）。同时存活的预览数由 Mac 限制（≤ 5），Relay 不做跨预览计数。每次打开预览都要重新取 session——ticket 用过即废；每个预览同时有效的 ticket 最多 20 张，再签发会挤掉最早的一张。
- 手机上传图片（2.9）：`PUT /client/uploads` 按组每小时 60 次（`CLIENT_UPLOADS_PER_HOUR`），保留期与产物相同（7 天），到期规则复用同一套 `ArtifactObject` TTL。
- 产物与预览端点的 agent 鉴权与 `/agent/invite` 相同：Directory 只负责 agentId → pairId 路由，agentToken 由该 Pair 的 PairObject 校验（401 凭据不对，403 拿手机凭据调 agent 端点，409 尚未被认领）。

## 一、电脑与连接器

手机据此画电脑列表、连接器开关、模型选择器和项目分组。目前没有「能力」字段：发图、中断这类差异手机按连接器的 `kind` 决定。

### AgentInfo

| 字段 | 类型 | 说明 |
|---|---|---|
| agentId | string | 22 字符 base64url，Agent 首次注册时由 Relay 生成 |
| name | string | 电脑名，截断 60 字 |
| platform | `macos` | 目前只有 macOS |
| online | boolean | 由 Relay 维护，Agent 上报时固定 true |
| lastSeenAt | string | 由 Relay 维护 |
| appVersion | string | Agent 版本，截断 20 字 |
| connectors | [ConnectorInfo] | 2.13 起最多 16 个（此前 8 个；3.1 起按一档 6 个 + ACP 最多 10 个算），按 `(kind, connectorId)` 去重：两个 `connectorId` 不同的 ACP agent 不算重复。空数组合法（刚被认领、还没连上过的电脑） |
| projectsRoot | string? | 2.6 起。手机新建项目时 Agent 在这个目录（绝对路径）下建子文件夹；省略表示这台电脑不接受新建项目，手机不显示「新建项目」。Mac 默认是「文稿」里的 `BotBusProjects`，可在设置里改。这个目录本身算「不在项目中」 |

### ConnectorInfo

| 字段 | 类型 | 说明 |
|---|---|---|
| kind | `codex` \| `claude` \| `hermes` \| `pi` \| `openclaw` \| `acp` \| `dsh` | `hermes` / `pi` / `openclaw` 2.5 起，`acp` 2.13 起，`dsh` 3.1 起；接收方遇未知值必须拒绝整条。Agent 对这几个只在本机检测到时才上报（没装不占位） |
| connectorId | string? | 2.13 起。ACP agent 的 id（`[a-z0-9-]`，1–32 字符，不含冒号）。`kind = acp` 时必填，其余 kind 省略；填反了整条拒绝 |
| displayName | string | 截断 40 字 |
| available | boolean | 本机是否检测到该 agent（可执行文件或数据库） |
| enabled | boolean | 用户是否启用 |
| status | `ok` \| `degraded` \| `error` | |
| taskCount | integer | ≥ 0 |
| lastError | string? | 截断 200 字 |
| models | [ModelOption]? | 3.2 起。手机续聊时能换的模型，电脑排好序（默认的在前），1–24 个、按 `id` 不重复；省略 = 不能从手机换模型，手机不画入口。Codex 取 app-server 的 `model/list`（去掉 hidden，每代子进程握手完问一次），Claude Code 报 `--model` 认的别名 `fable` / `opus` / `sonnet` / `haiku`，强度从本机 `claude --help` 读取（Haiku 不报强度；CLI 不可用或未列出强度时省略 models），`displayName` 带别名当前指向的版本（「Opus 5.5」：取 transcript 里见过的完整模型名，只往高处抬；没见过的只显示系列名）；其余 agent 省略 |
| canAutoApprove | boolean? | 3.3 起。**只写 `true`**：这个 agent 支持项目级自动批准（见「项目级自动批准」），不支持时整个键省略。目前 Codex 与 Claude Code 报；手机只对报了的 agent 画「审批」开关 |
| canStartTask | boolean? | 2.13 起。**只写 `false`**：这个 agent 不能从手机新建任务（ACP agent 没有启动命令、反向连接也没声明 `newSession`；3.1 起一档的 `dsh` 在电脑上找不到可执行文件、只看得见会话时也写）；能新建时整个键省略（不写 `true`）。手机的新建任务选择器不列 `false` 的 agent |

ModelOption（3.2）：`id` string（原样回到 `followUp.model`，会成为 agent 命令行的参数值，所以限定 1–64 个 `[A-Za-z0-9._:/-]` 且不以 `-` 开头），`displayName` string（截断 40 字），`efforts` [string]?（能选的强度，从低到高，1–8 个不重复；每个 1–16 个 `[a-z0-9-]`、不以 `-` 开头；省略 = 这个模型不能调强度），`defaultEffort` string?（不指定时 agent 用哪一档，必须是 `efforts` 里的一个）。强度是 agent 自己的词，协议不定闭集：目前见到的是 `none`、`minimal`、`low`、`medium`、`high`、`xhigh`、`max`、`ultra`，客户端认得的翻成本地文案，不认得的原样显示。

同一台电脑上 `(kind, connectorId)` 唯一，客户端可直接拿它当列表标识；Swift 里这对值封成 `ConnectorRef`，文本形式是 `codex`、`claude`…，ACP 是 `acp:<connectorId>`。

### Project

Project：`agentId`、`path`、`name`、`lastUsedAt` string，`pinned` boolean，`autoApprove` boolean?（3.3 起，**只写 `true`**：这个项目开了自动批准，见「项目级自动批准」；没开时整个键省略）。`agentId` 指明该项目路径所属的电脑——项目路径只在其所属电脑上有意义。`projects` 按 `lastUsedAt` 降序排列后再截断，使被丢弃的总是最久未用的；同值时按 `agentId`、`path` 次序稳定排序。

### 命令：setConnectorEnabled

- setConnectorEnabled：`connector` ConnectorKind，`enabled` boolean，`connectorId` string?（2.13 起，开关哪个 ACP agent：`connector = acp` 时必填，其余 kind 必须省略）

## 二、任务与状态

### Task

| 字段 | 类型 | 说明 |
|---|---|---|
| id | string | `<source>:<原生 id>`：`codex:<threadId>`、`claude:<sessionId>`、`hermes:<sessionId>`、`pi:<sessionId>`、`openclaw:<sessionKey>`。原生 id 本身可以含冒号（OpenClaw 的 sessionKey 形如 `agent:main:main`），解析时只按**第一个**冒号切。2.13 起 ACP 任务是 `acp:<connectorId>:<sessionId>`：`connectorId` 不含冒号，所以按**前两个**冒号切，`sessionId` 自己仍可以带冒号。3.1 起 DeepSeek Harness 任务是 `dsh:<sessionId>`（一档，按第一个冒号切，不带 `connectorId`） |
| agentId | string | 所属电脑，全局唯一键为 `(agentId, id)` |
| source | `codex` \| `claude` \| `hermes` \| `pi` \| `openclaw` \| `acp` \| `dsh` | `hermes` / `pi` / `openclaw` 2.5 起，`acp` 2.13 起（所有第三方 ACP agent 共用这一个值，具体是哪个看 `connectorId`），`dsh`（DeepSeek Harness）3.1 起 |
| title | string | Codex 取 thread title 或首条用户消息；Claude 优先取 transcript 里的桌面端会话标题 `custom-title`，其次 Claude Code 生成的 `ai-title`，都没有时取首条 prompt（去掉 `<system-reminder>` 注入块）截断 80 字；运行中也会跟进标题变化；Hermes 取会话 `title`、Pi 取 `session_info.name`、OpenClaw 取 label / displayName、DeepSeek Harness 取会话标题（`dsh web` 的 `session/list`，web 不在时读投影缓存的 `title`），都没有时取首条用户消息截断 80 字 |
| projectPath | string | 会话所属项目的绝对路径，客户端按它分组。一般就是 cwd；2.7 起会话在 git worktree 里时是**主仓库**的路径，真实 cwd 见 `worktreePath` |
| projectName | string | `projectPath` 最后一段 |
| status | TaskStatus | 见下 |
| lastMessage | string? | 最后一条 agent 文本，截断 500 字 |
| pendingRequest | PendingRequest? | 待处理请求 |
| systemPermission | SystemPermissionNotice? | 2.10 起。任务失败后检测到的系统授权弹窗历史证据，缺省时省略；不改变任务状态或待审批请求 |
| origin | `watch` \| `desktop` | 由谁发起 |
| controllable | boolean | 能否接受 followUp / approve / interrupt |
| startedAt | string | |
| updatedAt | string | |
| artifacts | [Artifact]? | 2.3 起。最多 10 个，**新的在前**；没有产物时整个键省略（不写 `[]`）。由 Agent 的 `TaskStore` 附加，连接器与观察者不感知。旧 Relay 的 schema 会剥掉这个键，所以先部署 Relay 再发 Mac |
| outsideProject | boolean? | 2.6 起。`true` = 这条会话不在任何项目里；在项目里时整个键省略（不写 `false`）。由 Agent 的 `TaskStore` 按本机规则判定：路径为空、`/`、`/tmp`（含 `/private/tmp`）、主目录本身、主目录下的 `Desktop` / `Downloads` / `Documents` 本身（子目录仍算项目），以及 Agent 的默认工作区（目前是 OpenClaw 的 workspace）。这些路径同时不进 `Snapshot.projects`。客户端把这类任务归进「不在项目中」，不要为它们的目录补出项目 |
| worktreePath | string? | 2.7 起。会话真实的工作目录，只在它是某个仓库的 git worktree 时出现（此时 `projectPath` 是主仓库），否则整个键省略。由 Agent 的 `TaskStore` 解析，连接器与观察者不感知：`<仓库>/.claude/worktrees/<名字>`（Claude app）按路径归到 `<仓库>`；其余路径里有一层 `worktrees` 目录的，读 worktree 自己的 `.git` 文件（`gitdir: <仓库>/.git/worktrees/<名字>`）得出主仓库，认出的对应关系在 Agent 本机持久化；已删掉又没记过的，在见过的主仓库与项目里恰好只有一个同名目录时归过去（Codex 的 worktree 以仓库命名），同名的有多个时不猜；submodule、bare 仓库和不在 `worktrees` 目录下的手动 worktree 原样当项目。`Snapshot.projects` 里同样换成主仓库并去重。续聊仍在这个目录里跑；目录已被删掉时 `followUp` 回 `ok: false`，不退回主仓库 |
| connectorId | string? | 2.13 起。是哪个 ACP agent，值取自清单或注册表里的 id：`[a-z0-9-]`，1–32 字符，不含冒号。只在 `source = acp` 时出现，且必须出现；其余来源带上它即整条拒绝 |
| model | string? | 3.2 起。这条会话下一轮会用的模型，写法同 `ModelOption.id`；电脑知道时才有。Codex 取线程上记的（`thread/start` / `thread/resume` 的应答，只读观察读 `threads.model`），Claude 取手机选过的，其次 transcript 里最后一条 assistant 消息的模型换成的别名（`claude-opus-5-5` → `opus`），认不出时省略 |
| autoApprove | boolean? | 3.3 起。**只写 `true`**：这条会话的 `projectPath` 开了自动批准（同 `Project.autoApprove`，任务所在项目不在 `projects` 里时手机也看得到）；没开或 `outsideProject` 时整个键省略。由 Agent 的 `TaskStore` 附加，连接器与观察者不感知 |
| effort | string? | 3.2 起。下一轮的思考强度，写法同 `ModelOption.efforts` 的值；省略 = 不知道或按模型默认（不是"不思考"）。Codex 取线程上的 `reasoningEffort`，Claude 只在手机选过时有 |

TaskStatus：`running` 有轮次进行中；`waitingApproval` 有 pendingRequest 且 kind ≠ input；`waitingInput` agent 等用户回复；`completed` 最近一轮正常结束；`failed` 最近一轮出错；`interrupted` 被中断；`idle` 超过 24 小时无活动。

### 命令：startTask、followUp、interrupt

- startTask：`source` TaskSource，`projectPath` string，`prompt` string，`newProject` string?，`attachments` [MessageAttachment]?，`connectorId` string?（2.13 起，发给哪个 ACP agent：`source = acp` 时必填，其余来源必须省略，两者不符即整条拒绝），`model` string?，`effort` string?，`autoApprove` boolean?。2.6 起 `projectPath` 可为空串，表示「不在项目中」：Agent 在主目录下运行，OpenClaw 用它的默认工作区。`newProject`（2.6）是新项目的文件夹名：Agent 在自己的 `projectsRoot` 下建这个子文件夹再开始，`projectPath` 忽略（填空串）。名字只能是一层（去掉首尾空白后 1–80 字，不含 `/`、`\`、`:` 与控制字符，不以 `.` 开头）；同名目录已存在、名字不合法或 Agent 没有 `projectsRoot` 时回 `ok: false`，不复用已有目录。`attachments`（2.9 起）是手机发图开新任务，最多 4 张；带附件时 `prompt` 可为空串。`model` / `effort`（3.2 起，写法同 ModelOption）指定这条会话从第一轮起用的模型与思考强度，之后的续聊沿用，省略 = agent 默认；和 followUp 一样只有报了 `ConnectorInfo.models` 的 agent 收，其余带上它们回 `ok: false`（Agent 在建新项目文件夹、下载图之前就拒）。Codex 随第一轮 `turn/start` 发，Claude 在第一次 `claude -p` 就带 `--model` / `--effort` 并记在会话上。`autoApprove`（3.3 起）把这条会话所在项目（`newProject` 时是新建的文件夹）的自动批准设为开（`true`）或关（`false`），从第一轮起生效、之后沿用，省略 = 不动；只有报了 `ConnectorInfo.canAutoApprove` 的 agent 收，其余带上它回 `ok: false`，「不在项目中」（`projectPath` 为空串）带 `true` 也回 `ok: false`，都在建新项目文件夹、下载图之前就拒
- followUp：`taskId` string，`prompt` string，`attachments` [MessageAttachment]?，`model` string?，`effort` string?，`autoApprove` boolean?。2.7 起 worktree 里的会话在原 worktree 里续聊；worktree 已被删掉时回 `ok: false`。`attachments`（2.9 起）同上，追问带图。`model` / `effort`（3.2 起，写法同 ModelOption）从这一轮起换模型与思考强度，之后的续聊沿用，省略 = 不换；只有报了 `ConnectorInfo.models` 的 agent 收，其余 agent 带上它们回 `ok: false`。Codex 随 `turn/start` 的 `model` / `effort` 发（app-server 记在线程上）；回答挂着的提问、或共用桌面时插进正在跑的那一轮（`turn/steer` 不收模型）时不换，`Task.model` 照旧，手机的选择跟着快照退回。Claude 只收 `ClaudeModels` 的别名与该模型支持的档，Agent 记在会话上，之后每次 `claude -p --resume` 都带 `--model` / `--effort`（换到 Haiku 时不再带强度）；`--resume` 分支出新 session 时跟过去。不认识的模型、这个模型没有的档位回 `ok: false`。`autoApprove`（3.3 起）把这条会话 `projectPath` 的自动批准设为开或关，从这一轮起生效、之后沿用，省略 = 不动；规则同 startTask（`outsideProject` 的会话带 `true` 回 `ok: false`）。设置在这一轮开始之前落地，这一轮失败也不回滚
- interrupt：`taskId` string

## 三、审批与提问

### PendingRequest 与 PendingQuestion

PendingRequest：`id` string，`kind` `command` \| `fileChange` \| `permission` \| `input`，`summary` string（一行），`detail` string?（截断 2000 字），`question` string?（kind = input 时 agent 的提问），`questions` [PendingQuestion]?（2.14 起，1–8 道：kind = input 时是要用户回答的问题；挂在审批上时是「允许」的几种范围，见下）。

PendingQuestion（2.14）：`id` string（同一请求内唯一，作 `approve.answers` 的键；Claude 是问题下标 `"0"`、`"1"`…，Codex 是它自己的问题 id），`question` string，`header` string?（短标签），`multiSelect` `true`?（单选时整个键省略），`options` [{`label` string, `description` string?}]（最多 16 个，可以为空——只能打字答的问题）。有 `questions` 时 `question` 仍是写好选项的纯文字，给不认新字段的旧客户端看。客户端在**每道题都有选项**时画点选，选好后发 `approve {decision: allow, answers}`，`deny` 表示跳过不答；也可以照旧 `followUp` 一段文字，Agent 把它当作所有问题的回答（带图的 `followUp` 此时被拒，免得图被丢掉）。Claude 的 AskUserQuestion 经 `PermissionRequest` hook 到达，Agent 把它记为 `waitingInput`（不再是要批准的 `permission`），回答写进 hook 的 `updatedInput.answers`（问题原文 → label，多选用 `, ` 连接），与电脑上的提问框先答者生效；`allow` 却没带任何认得的答案时回 `ok: false`，请求继续挂着。

审批（kind = `command` / `fileChange` / `permission`）也可以带 `questions`：那是「允许」的几种范围，不是要回答的问题——OpenClaw 的 exec 审批带一道单选 `scope`（「只这一次」/「以后都允许」，后者写进它的白名单）；ACP 的 `session/request_permission` 把 agent 的 `allow_once` / `allow_always` 选项按这个顺序列出（拒绝类的不列，那是「拒绝」按钮；agent 一个允许选项都没给时不带 `questions`）。客户端照旧显示命令与「拒绝」/「批准」，选项默认选第一个（第一个总是最保守的一次性允许），「批准」带 `answers`，「拒绝」不带；`answers` 缺失或认不出时 Agent 按第一个选项处理，所以旧客户端点「批准」的效果和 2.13 之前完全一样。

### 项目级自动批准（3.3）

手机可以给一个项目（`(agentId, projectPath)`，worktree 里的会话按主仓库算）开「自动批准」：之后 Agent 替手机跑的轮次——`startTask`、`followUp` 起的那一轮，包括在桌面会话上续聊——里遇到审批（`kind` 为 `command` / `fileChange` / `permission`）直接按「只这一次允许」放行，不建 `pendingRequest`、不推 `TASK_APPROVAL`；提问（`kind = input`：Claude 的 AskUserQuestion、Codex 的 requestUserInput）照旧交给手机。电脑上自己跑的轮次不受影响，照旧由电脑处理；共用 Codex 桌面时，也只放行手机那一轮里的审批。

开关没有单独的命令：随下一条 `startTask` / `followUp` 的 `autoApprove` 一起发，之后沿用，状态从 `Project.autoApprove` / `Task.autoApprove` 读回。设置由 Agent 按项目路径持久化在本机（重启后仍在），对这台电脑上所有报了 `canAutoApprove` 的 agent 一起生效；只在这台电脑上，与别的电脑上同名路径无关。Codex 放行命令与改文件时回 `accept`，`permissions` 请求授出它要的那些、范围 `turn`；Claude Code 在 Agent 起的 `claude -p`（带 `--permission-prompt-tool stdio`）里经控制协议回 `allow`（手机那一轮的审批一律走这条，不靠 `PermissionRequest` hook：Claude Code 2.1.268 之前的 `-p` 不发它）。

### 命令：approve

- approve：`taskId` string，`requestId` string，`decision` `allow` \| `deny`，`answers` {string: [string]}?（2.14 起，回答 `PendingRequest.questions`：问题 id → 选中的 label，或自己打的字；只和 `allow` 一起出现）

### SystemPermissionNotice

2.10 起，Agent 在任务或命令执行失败后检测到系统授权弹窗时，随 `Task.systemPermission` 或 `CommandResult.systemPermission` 返回一次检测证据，并发一条提醒手机回电脑处理的 `TASK_FAILED` 通知；同一弹窗的额外通知按 id 去重。任务尚未创建（没有 `taskId`）时也可通过命令结果返回，通知的 `taskId` 为 `""`，点开只进入 App 首页。它不证明弹窗导致了失败，也不表示弹窗当前仍在等待处理；不能据此生成 `pendingRequest`、改成 `waitingApproval` 或提供远程批准操作。客户端提供本地化说明，提示用户回电脑确认；`dialogText` 保留电脑系统弹窗原文。

| 字段 | 类型 | 说明 |
|---|---|---|
| id | string | Agent 生成的本次检测标识 |
| detectedAt | string | 检测时间，秒精度 UTC |
| dialogText | string | 原始弹窗文字，生产方负责限制长度；不拼接客户端说明文案 |
| screenshot | Artifact? | 可选的 `kind = image` 截图引用，仅包含匹配的授权窗口；缺少截图权限、窗口消失或截图/上传失败时省略，仍保留文字提示 |

截图字节通过现有 `PUT /agent/artifacts/:id` 上传，客户端以任务或命令所属电脑的 `agentId` 经 `GET /client/artifacts/:agentId/:artifactId` 按需读取；复用产物 TTL 与鉴权，不新增端点。截图只挂在该提示中，不必重复放进 `Task.artifacts`。历史提示里的截图可能已过期，客户端仍可显示文字。通知继续使用既有 `taskFailed` 类别。

## 四、对话与附件

### Message 与 TaskMessages

对话记录**不进常规快照**，只由 `fetchMessages` 按需下发。原因是快照每次变化都全量重发，
而一份记录动辄几十 KB——常驻其中等于给手表的每一次长轮询都加上这份体积。

Message：`id` string（同一条消息重复拉取时必须稳定，客户端据此去重）；`role` `user` \| `agent` \| `tool`
（`tool` 是工具调用的一行摘要：执行了什么命令、改了哪个文件）；`text` string（user/agent 全文不截断，tool 截到 200 字）；`createdAt` string；
`attachments` [MessageAttachment]?（2.9 起，消息里的图：用户发的图，或 Agent 生成的图（如 Codex `imageGeneration`），最多 4 张，`maxAttachmentsPerMessage`）；
`files` [MessageFileRef]?（2.9 起，Agent 回复里提到的本机文件，最多 4 个，只出现在 `role = agent`）。
2.9 起只要有 `attachments` 或 `files`，`text` 可以是空串——只发图不带文字的用户消息就是这样。例外：图还在 Mac 上排队上传时，Mac 先发一份空 `text`、不带 `attachments` 的同 id 消息，传完补发一份带图的；客户端对这种消息画「图片」占位，不画空气泡。图永远拿不到（文件已删、解不出）的空消息 Mac 不发。

MessageAttachment（协议 2.9）：字节已上传到 Relay 的产物存储，用 `GET /client/artifacts/:agentId/:artifactId` 取。
`artifactId` string；`contentType` string；`size` integer（上传后的字节数）；`width` integer?、`height` integer?（像素宽高，客户端先按比例占位）。
`StartTask.attachments` / `FollowUp.attachments`（见下）复用同一个类型。

MessageFileRef（协议 2.9）：`path` string（Mac 上的绝对路径，`fetchFile` 命令原样带回）；`name` string；`contentType` string；
`size` integer（原文件字节数）；`artifactId` string?（已上传时才有）。没有 `artifactId` 时手机点了发 `fetchFile` 让 Mac 按路径读盘上传，
成功后 Mac 先重发一次带上 `artifactId` 的 `taskMessages`，再回 `CommandResult` ok。

TaskMessages：`taskId` string；`agentId` string（由 Relay 按发来这一帧的连接盖章，负载里冒充别人不生效）；
`messages` [Message]（**按时间升序**）：最近至多 40 条**对话**（`role` 为 `user` / `agent`，`maxMessages`），外加夹在它们之间、以及最旧那条对话之前紧挨着的工具行（`role = tool`）——工具行不占对话名额，另有 160 行的上限（`maxToolMessages`，超了丢最旧的），所以数组总长不超过 200（`maxEntries`）；`hasMore` boolean（更早的对话被截掉了）；`fetchedAt` string。
Mac 把工具行的 `text` 截到 200 字（它只是一行摘要）；user/agent 消息的 `text` 保留全文，不设上限。
总长上限从 40 放宽到 200 时没有抬协议版本，但旧 Relay 的 schema 会拒收超过 40 条的整份结果，所以先部署 Relay 再发 Mac。
客户端把连续两条以上的工具行折成一组（`ToolCallGroup`），默认收起、点开逐条展开。

Relay 只保留**最近一份**，且只留 5 分钟；过期后在读路径上被滤掉，不再出现在快照里。
客户端收到后必须自己缓存——否则用户正看着记录，它会突然空掉。

数据来源（2.5 新增的三个来源：Hermes 读 `~/.hermes/state.db` 的 `messages`、Pi 读会话 JSONL 的当前分支、OpenClaw 经本机 Gateway 的 `chat.history`；3.1 的 DeepSeek Harness 依次取 BotBus 自己的 ACP 进程、`dsh web` 的 follow 快照、`~/.dsh/sessions` 里的 zstd JSONL，`reasoning` 不显示；同样排除思考过程）：Codex 读 `~/.codex/thread_history_*.sqlite` 的 `thread_items`（`reasoning` **不算**对话，
它在真实库里是最多的一类，混进来会把一问一答淹掉）；Claude 读 `~/.claude/projects/<目录>/<sessionId>.jsonl`
——transcript 的文件名就是 session id，所以不依赖 hook 负载里的 `transcript_path`。思考块同样不算，唯一例外是签名里标着 `narration` 的
（桌面 app 在工具调用之间给用户看的过程说明，桌面上当正文显示），按 agent 正文算。
两者都不经过连接器：看记录在连接器没跑的时候也必须能用。

### 命令：fetchMessages、fetchFile

- fetchMessages：`taskId` string，`limit` integer?（只数对话，工具行不算；省略或超过 40 时按 40 算）
- fetchFile：`taskId` string，`messageId` string，`path` string（2.9 起。手机点了消息里尚未上传的文件卡片，让 Mac 按路径读盘上传；Mac 只接受出现在该消息 `files` 里、且在任务项目目录内的路径；项目目录等于或包含用户 home、`/Users` 等系统目录时一律拒绝。Mac 只在最近 40 条对话（`TaskMessages` 的上限，工具行不算）里找 `messageId`，消息已滚出这 40 条时同样以「这个文件不在对话里」失败，客户端应提示用户重新拉取对话后再试。成功时先重发一次带上 `artifactId` 的 `taskMessages`，再回 `CommandResult` ok）

## 五、产物与文件

### Artifact

agent 回传给手机的一件产物（2.3 起），挂在 `Task.artifacts` 上。2.9 起加入 `video`。

| 字段 | 类型 | 说明 |
|---|---|---|
| id | string | image / file / video / link：Agent 生成，22 字符 base64url（16 随机字节）；preview：Relay 分配的 26 字符小写 base32（`[a-z2-7]`），同时是预览主机名 `p-<id>` 的一部分 |
| kind | `image` \| `file` \| `video` \| `preview` \| `link` | 闭集，未知值拒绝整条 |
| title | string | 截断 80 字。image / file / video 的客户端拿它当下载后的文件名，没有扩展名时按 `contentType` 补；Agent 保证 file 的标题带原文件的扩展名 |
| createdAt | string | |
| contentType | string? | image / file / video 必填，如 `image/png` |
| size | integer? | image / file / video 必填，字节数，≥ 0 |
| url | string? | link 必填，`http` / `https` |
| port | integer? | preview 来自端口时填写（1–65535）；来自静态目录时省略 |
| expiresAt | string? | preview 必填；image / file / video 可选（Relay 侧 TTL 到期时间） |
| posterId | string? | video 可选（2.9 起）：封面图的产物 id；只上传到 Relay，不进 `Task.artifacts` |
| duration | number? | video 可选（2.9 起）：时长，单位秒 |
| remoteControl | boolean? | 3.0 起，仅 preview。只写 true 或省略：这份预览是远程操作的电脑屏幕，客户端用 app 里的加密查看页打开（见「端到端加密」） |

两端解码只校验字段类型（`size`、`port` 须为整数）与 kind 闭集。上表的"必填"、"≥ 0"、"1–65535"由生产方（Agent）保证，消费方遇缺失或越界按"不可用"显示，不拒绝整条——一件坏产物不该让整份快照解不出来。`id` 也不按 kind 校验格式。

产物本身不进快照：image / file 的字节用 `GET /client/artifacts/:agentId/:artifactId` 取，preview 用 `POST /client/previews/:previewId/session` 换一次性入口，link 直接打开 `url`。

### 产物字节的加密

产物、附件、按需取回的文件、改动清单一律以密文上传下载：字节是 `0x01 ‖ nonce ‖ 密文 ‖ tag` 的**原始字节**（不是 base64），`Content-Type` 固定 `application/octet-stream`，其余类型两个上传端点都 415。真实类型在密封的任务 / 对话记录里（`Artifact.contentType` 等）；客户端只拿到字节时可以按文件头认常见类型。Mac 对话图片的确定性 id 用只存在本机的随机钥匙做 HMAC，Relay 拿一张已知图片算不出同样的 id。

### WorkingChanges

`fetchChanges` 的结果（2.11），**不走帧**：作为一份 JSON 产物上传，手机按 `CommandResult.artifactId` 经 `GET /client/artifacts/:agentId/:artifactId` 取。Relay 不解析它。

`directory` string（Mac 上的工作目录，绝对路径）；`branch` string?（当前分支，detached HEAD 时省略）；`generatedAt` string；`files` [ChangedFile]（按路径的字节序排列，最多 300 个）；`totalFiles` integer（实际改动的文件数，大于 `files` 长度时说明被截了）。

ChangedFile：`path` string（相对 `directory`）；`oldPath` string?（改名前的路径）；`status` `modified` \| `added` \| `deleted` \| `renamed` \| `untracked` \| `conflicted`；`added` / `removed` integer?（增删行数，二进制文件省略）；`binary` boolean?（二进制文件，没有 diff）；`patch` string?（unified diff 正文：从第一个 `@@` 开始，不带 `diff --git`、`---`、`+++` 文件头；二进制、只改名或只改权限、或总量用完时省略）；`truncated` boolean?（`patch` 被截断，或因为总量用完被省略）。单个文件的 `patch` 最多 200,000 字节（在行边界截断），全部加起来最多 4,000,000 字节。未跟踪的文件由 Mac 自己读：软链接不跟随、超过 1 MB 或二进制的只列名字。

### 命令：fetchChanges

- fetchChanges：`taskId` string（2.11 起。看任务所在目录里还没提交的改动：Mac 在任务的工作目录——worktree 会话是 `worktreePath`，其余是 `projectPath`——里跑只读的 git 命令，范围是 `git diff HEAD`（已暂存与未暂存）加未跟踪的文件，限定在这个目录之内；把结果编码成 WorkingChanges JSON，经 `PUT /agent/artifacts/:artifactId` 上传（`application/json`，不进 `Task.artifacts`），产物 id 放进 `CommandResult.artifactId`；目录里一个改动都没有时不上传，回 `ok: true` 且不带 `artifactId`——手机打开任务详情就会先问一次，据此决定显不显示入口，所以这一问要便宜。「不在项目中」的会话、不是 git 仓库的目录、等于或包含用户 home 与 `/Users` 等系统目录时回 `ok: false`。改动与上次相同、上次的产物也没过期时 Mac 可以直接回上次的 id。只读：不认领任务、不改任务状态）

## 六、屏幕共享与远程操作

两条路径共用预览产物与隧道：开发者预览把电脑上的本地网页经 Relay 代理给手机的浏览器，**不在端到端加密范围内**；远程操作把电脑屏幕当成一份带 `remoteControl: true` 的预览，画面与输入都加密。

### 命令：remoteControl

- remoteControl：`enabled` boolean（2.12 起。远程操作这台电脑的桌面——人不在电脑前、agent 卡在只有人能做的那一步时（登录、密码、确认弹窗），在手机上接管鼠标键盘。`true` 时 Mac 起本机的远程操作服务并按 `.port` 分享成一个预览，预览产物 id 放进 `CommandResult.artifactId`，手机换一次性入口打开它就是电脑屏幕；`false` 时停服务、撤分享。重复开启复用同一份，不叠开第二个。Relay 只转发，画面与输入都走既有的预览隧道，没有新端点。没允许录屏时回 `ok: false`；**没有辅助功能权限仍然成功**，只是那个预览只能看不能操作，页面顶部会说明。回执不带 `taskId`：它不属于任何一个任务）

远程操作的画面是 H.264（VideoToolbox 编码，AVCC + `avcC` 参数集，浏览器侧用 WebCodecs `VideoDecoder` 解），不是一帧帧的图片。**实测**（1280 宽 10fps）：静止桌面 JPEG 逐帧要 982 KB/s（3.4 GB/小时）而 H.264 只要 38 KB/s，打字 19 倍、持续滚动 7 倍。JPEG 几乎不随内容变化——它每帧都重传整张图；而「盯着一个卡住的页面想下一步」正是这个功能的主要姿势。靠比较字节来跳过没变的帧在真实桌面上无效：光标闪烁与菜单栏时钟让空闲帧常年为 0。

输入默认锁着，要在手机上显式解锁，闲置 10 分钟自动锁回；能看是无害的，能打字不是。注入走 `CGEvent` 的 `.cghidEventTap`，网页登录框、1Password 原生弹窗、`sudo` 提示都收得到——**Chrome 的密码框会打开 macOS 的 Secure Input，但它挡的是监听不是注入**，远程输密码因此成立。**TCC 授权弹窗按不动**（macOS 不允许合成事件点权限授权框），只能读出来给人看，必须本人回电脑处理，这也是 `SystemPermissionNotice` 一直只做提示的原因。

Agent 停下来等人（`waitingInput`）而电脑上正好有密码框聚焦时，Mac 会自动开一份挂在那条任务上的远程操作预览，`TASK_INPUT` 通知的正文随之改成「电脑上有个密码框在等着填，可以直接在手机上操作电脑」。判据取 Secure Input 而不是猜消息内容：由应用自己打开，不会误判，也不分语言。没有辅助功能权限时不自动开。

### 远程操作

查看页（`RemoteControlPage`，在 Protocol 包里）由客户端从自己的 app 包里加载，base URL 是预览主机，**不执行 Relay 送来的任何 HTML**：客户端先在原生层请求一次性入口（不跟随重定向），从 `Set-Cookie` 取会话 cookie 放进 WebView，再在文档开始前注入 `window.__botbus = {key: <K_rc 的 base64url>, agentId}`。之后：

- Mac 回的 JSON（`/status`、`/focus`、`/elements`、输入的回执）是 `{"sealed": <信封>}`；`/stream` 的每个包是 `[u32 大端长度][密封的 [u8 类型][负载]]`（类型与负载同 2.12）。
- 输入是 `POST` `{"sealed": <信封>}`，明文 JSON 里除原有字段外必须有请求路径 `p` 与严格递增的毫秒时间戳 `t`：Mac 拒绝路径对不上（把 `/click` 的密文挪到 `/type`）、时间戳不比上一条新（重放）、或偏离本机时钟两分钟以上的请求，一律 403。明文输入一律 403。
- 没有组密钥时 Mac 的远程操作服务整个不可用；远程操作的预览产物带 `Artifact.remoteControl = true`，客户端据此选用加密查看页。

### 预览主机与隧道

预览入口是 `https://p-<previewId>.<PREVIEW_DOMAIN>`（线上为 `botbus.io`；只用一级通配子域，免费 Universal SSL 才覆盖得到）。Worker 在所有路径路由之前按 `Host` 分流（主机名不区分大小写）：

- `^p-([a-z2-7]{26})\.<PREVIEW_DOMAIN>$` 交给该预览——这个主机上的任何路径都属于预览，不会落到 API；`<PREVIEW_DOMAIN>` 本身与其他子域原样回源，不拦截别的站点；其余主机（`*.workers.dev`）照常是 API。
- 预览不存在或已过期 → 404 HTML 页（预览已结束）。
- `GET /__botbus/auth?ticket=<t>`：ticket 一次性、60 秒有效。通过后签发会话 token（Relay 只存哈希，有效到预览过期），回 `302 Location: /` 与 `Set-Cookie: __botbus_preview=<token>; Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=<剩余秒数>`（cookie 不带 `Domain`，只对这一个预览主机有效）；失败回 401 简短 HTML 说明页。这个路径不会转给 Mac。
- 其余请求先校验这个 cookie（无效 → 401 HTML 页，提示回 BotBus 重新打开），把 `__botbus_preview` 从转发的 `Cookie` 头里删掉后经隧道转给 Mac；隧道未连接 → 503 HTML 页（电脑离线或已停止分享）。
- 所有预览响应带 `X-Robots-Tag: noindex`。Relay 自己回的说明页：401 链接或会话失效、404 预览已结束、413 请求体过大、502 Mac 回 `error` / 隧道中途断开 / 本地 WebSocket 连不上、503 隧道未连接或在途请求已满、504 等 `res` 超时。

隧道是 `GET /agent/previews/:previewId/tunnel` 升级出的 WebSocket，每条都是二进制消息：

```
[u32 大端：头部长度 N][N 字节 UTF-8 JSON 头部][负载字节]
```

头部的 `t` 是帧类型；`id` 是 Relay 为每个 HTTP 请求 / WebSocket 分配的非负整数，在一条隧道连接内唯一（单调递增、不连续，DO 休眠醒来后也不会回到用过的值）。负载单块 ≤ 256 KiB，更大的拆成多条 `data`；`wsmsg` 的负载是一整条 WebSocket 消息，不拆分。解码方遇到坏帧（长度越界、头部不是 JSON、未知的 `t`）丢掉这一帧即可，不断开隧道。

| t | 方向 | 头部字段 | 负载 |
|---|---|---|---|
| `req` | R→M | `id, method, path`（含 query）, `headers: [[name, value]]` | 无 |
| `data` | 双向 | `id` | 请求体 / 响应体分块 |
| `end` | 双向 | `id` | 无（该方向 body 结束） |
| `abort` | R→M | `id` | 无（浏览器断开，Mac 取消本地请求） |
| `res` | M→R | `id, status, headers: [[name, value]]` | 无 |
| `error` | M→R | `id, message` | 无（Relay 回 502 HTML 页） |
| `wsopen` | R→M | `id, path, headers, protocols: [string]` | 无（三期） |
| `wsaccept` | M→R | `id, protocol?` | 无（三期） |
| `wsmsg` | 双向 | `id, text: boolean` | 消息内容（三期） |
| `wsclose` | 双向 | `id, code?, reason?` | 无（三期；本地连不上时 M→R 以 1011 关闭） |

限制：每条隧道同时在途请求 ≤ 64（HTTP 请求与浏览器 WebSocket 合计，超出 503）；请求体 ≤ 16 MiB（声明的 `Content-Length` 超限直接 413；分块上传超限时 Relay 发 `abort` 并回 413）；等 `res` 最多 30 秒（504）；响应体边收边流给浏览器，不整体缓冲。Relay 转发请求前去掉 hop-by-hop 头（`connection`、`keep-alive`、`transfer-encoding`、`upgrade`、`te`、`trailer`、`proxy-*`）、`cf-*`、`x-forwarded-*`、`host` 与 `__botbus_preview` cookie；转回响应时去掉 hop-by-hop 与 `content-length`（流式重新分块），以及本地服务试图设置的同名 `__botbus_preview` cookie。

HTTP 往返的细节：

- 每个请求都以 `end` 收尾，没有请求体（GET）时 `req` 之后紧跟 `end`。Mac 可以在请求体发完之前回 `res`；它发出响应的 `end` 后 Relay 不再发剩余的请求体。
- Relay 发 `abort` 的时机：浏览器断开（响应头之前或流式读 body 途中）、等 `res` 超时、请求体超限、`res` 的状态码不在 200–599。收到 `abort` 后 Mac 取消本地请求，之后为这个 id 发的帧会被丢弃。
- `res` 之前收到 `error`（或没有 `res` 就 `end`）→ 浏览器得到 502 页；`res` 之后收到 `error` 或隧道断开 → 浏览器读到的 body 以错误结束，而不是看起来完整。
- HEAD 请求与 204 / 205 / 304 响应没有 body：Relay 收到 `res` 就结束这个请求，之后的 `data` / `end` 被忽略。
- Relay 不对响应体做编码转换：字节与 `content-encoding` 头都原样转发。Mac 应请求 `Accept-Encoding: identity` 并去掉 `content-encoding`；万一带着，字节必须与这个头一致。

WebSocket（三期）的细节：

- Relay 收到浏览器的升级请求后发 `wsopen`，**等到 `wsaccept` 才回浏览器 101**；10 秒内没有答复 → 502，并给 Mac 发 `wsclose {code: 1001}` 让它放弃本地连接；Mac 以 `wsclose` 答复 → 502。`wsopen.headers` 不含 `sec-websocket-*`（握手头由 Mac 的 WebSocket 客户端自己生成），子协议在 `protocols` 里；`wsaccept.protocol` 只有在浏览器提议过时才回给浏览器。
- Mac 的 `wsclose.code` 不能出现在关闭帧里（如 1005 / 1006）时浏览器收到 1011，缺省时 1000。Mac 先关的连接 Relay 不再回 `wsclose`。
- 隧道关闭或被顶掉时，属于它的浏览器 WebSocket 以 1011 关闭、在途 HTTP 请求 502；停止分享或过期时浏览器 WebSocket 以 1001 关闭。

隧道关闭码：4000 被同一预览的新连接顶掉；4001 预览被停止或已过期（之后重连得到 404，Mac 不应再重连）。

## 七、通知

### Notify

Notify：`taskId` string，`category` `TASK_APPROVAL` \| `TASK_INPUT` \| `TASK_DONE` \| `TASK_FAILED`，`title` string，`body` string，`requestId` string?（TASK_APPROVAL 必填，Relay 收到时校验信封外面那一份），`agentName` string?（3.0 起：发通知的电脑名，由 Mac 在密封前填上，Relay 读不到）。

### 推送

Relay 发给 APNs 的只有 `aps.alert.loc-key`（按类别选一句固定文案，key 是简体中文原文：`有任务在等你审批`、`有任务在等你回复`、`任务完成了`、`任务失败了`，app 的词条表里有各语言译文）、`mutable-content: 1`、`category`、`thread-id`，以及顶层的 `taskId`、`requestId?`、`agentId`、`sealed`。iPhone 的通知服务扩展用 `K_notify` 解开 `sealed`，换上电脑发来的标题、正文与电脑名（`Notify.agentName`）；解不开或没有扩展（手表）时停在固定文案。

Android 登记 Firebase Installation ID 后，Relay 用 FCM HTTP v1 发高优先级 data message，保留 600 秒。`message.data` 只有字符串 `agentId`、`taskId`、`category`、可选 `requestId` 和 `sealed`；标题、正文和电脑名仍在 `K_notify` 密文里，Relay 和 Firebase 都读不到。Android 在本机核对信封外字段与解密结果后才显示系统通知；解不开时不显示。收到第一条有效 FCM 消息之前，Android 每 15 分钟查一次快照作为后备提醒；Relay 没配 FCM 凭据时也能提醒。

## 八、配对、凭据与设备

### 配对链接与密钥信封

电脑的二维码（也是配对窗口里「复制配对链接」的内容）是唯一的配对入口，6 位码本身装不下钥匙，**手动输码配不了对**（`000000` 仍是审核演示）：

- 注册码：`botbus://pair?relay=<Relay 根地址>&code=<6 位码>&agent=<agentId>&pk=<临时 X25519 公钥，base64url 32 字节>`。电脑每次配对 offer 生成一对临时密钥，私钥存本机钥匙串，拿到 K 后删掉。
- 邀请码：`botbus://pair?relay=…&code=…&key=<K 的 base64url>`。已在组里的电脑把 K 直接交给新手机。

手机扫到注册码时生成 K（已有凭据、在加第二台电脑时用已有的 K），做一个**密钥信封** `KeyEnvelope {epk, sealed}`：手机另生成一对临时 X25519 密钥，`epk` 是其公钥；共享秘密 = X25519(手机临时私钥, 电脑的 pk)；HKDF-SHA256（salt = 电脑 pk 的原始 32 字节，info = `botbus/v1/key-envelope`）得到 32 字节包裹键；`sealed` = 用包裹键按上文信封格式封 K 的原始 32 字节，AAD `key-envelope:<agentId>`。信封随 `/pair/claim` 或 `/pair/agents` 上传，Relay 存进 agents 表、在 hello 帧里原样转交；电脑的 pk 只在二维码里，Relay 算不出共享秘密。手机认领后必须核对 Relay 回来的电脑就是二维码上的 `agent`，不一致即作废。

### 配对码

6 位码有两种，共用一个码空间、共用一次性的原子消费与 5 分钟有效期，因此同一个码不可能同时是两种。

| 种类 | 谁印 | 谁用 | 效果 |
|---|---|---|---|
| 电脑注册码 | `POST /agent/register` | `/pair/claim`（手机尚无凭据）或 `/pair/agents`（手机已有凭据） | 建一个新组，或把这台电脑加进已有的组 |
| 手机邀请码 | `POST /agent/invite` | `/pair/claim` | 把这台手机加进印码那台电脑所在的组，发一份新的 `clientToken` |

`000000` 保留给客户端的审核演示模式：手机在配对页输入它时不请求 Relay，直接进进程内的示例数据（见 `SharedUI/DemoMode.swift`）。Relay 印码时跳过这个值，永远不会把它发给真实电脑。

`/pair/claim` 两种码都收。3.0 起二维码载荷按种类带不同的另一半（注册码带 `agent` 与 `pk`，邀请码带 `key`，见「端到端加密」），手机据此决定要不要做密钥信封；6 位码仍是一次性的认领凭据。`/pair/agents` 只收注册码；扫到邀请码时返回 400 且**不消费**该码，用户换个入口还能用同一个码。

猜码防护按来源计数（IPv4 按地址，IPv6 按 /64）：同一来源 10 分钟内猜错满 10 次后，这个来源的认领一律 429，别的来源不受影响。全局 5 分钟内猜错满 100 次时进入压力模式，每个来源的额度降到 3 次。过期的码与种类不符的码不算猜错。`/pair/claim` 与 `/pair/agents` 共用这套计数。

`/agent/invite` 的鉴权不能只看 `agentId`：Agent 被认领后 Directory 里只剩归属，agentToken 的哈希只在该 Pair 的 agents 表里，所以 Relay 必须把 token 交给 PairObject 校验。`agentId` 随每份快照发给所有客户端，是标识不是秘密。

### 多份客户端凭据

一个 Pair 最多 10 份 `clientToken`，每台手机一份；手表沿用配它的那台手机的凭据，不单独占名额。组内不做权限隔离——任一份凭据都能操作组里任一台电脑，对应的止损手段是 `DELETE /pair/clients/:id`（被踢掉的那份立即 401，连同同步了它的手表；2.15 起组里的电脑也能调，Mac 设置里按 `/agent/devices` 的 `clients` 列出每台手机供移除）。最后一份拒绝删除（409）：要彻底解散走 `/pair/revoke`。`GET /pair/clients` 与 `/agent/devices` 一样是安全视图，不外发 token，连哈希也不给。

## 附录 A：版本沿革

每个版本加了什么、要不要抬最低线、先发谁后发谁。最早在前。

- 版本 2 起 Agent 以 `agentId` 而非 `pairId` 标识自身；一个 Pair 可挂多台 Agent。
- 版本 2.1 起一个 Pair 还可以有多份 `clientToken`——一组 = N 台手机 ↔ M 台电脑，组内全互见；`PairClaimResponse.agent` 随之改为 `agents`。
- 版本 2.2 加入**按需拉取的对话记录**（`fetchMessages` / `taskMessages`）。
- 版本 2.3 加入**任务产物**（`Task.artifacts`：截图、文件、链接、localhost 预览）以及产物上传下载与预览隧道的 HTTP 端点。
- 版本 2.4 为扩容做了三处向后兼容的改动：Agent 连上时收到 `hello` 帧并在之后带 `X-Pair-Hint`（跳过全局 Directory）；手机改用可休眠的 `GET /client/ws` 收快照推送（手表仍长轮询）；猜码锁由全局总闸改为按来源计数。
- 版本 2.5 加入三个任务来源 `hermes`、`pi`、`openclaw`（枚举扩展，旧实现会拒收，Relay、Mac、手机需一起升级）。
- 版本 2.6 加入 `Task.outsideProject`，标出**不在项目中**的会话（开在主目录、下载目录、临时目录或 Agent 的默认工作区），并允许 `startTask.projectPath` 为空串（由电脑决定在哪里跑）；同时加入**从手机新建项目**：电脑在 `AgentInfo.projectsRoot` 里报新项目的存放目录，`startTask.newProject` 带文件夹名，电脑在那个目录下建好子文件夹再开始；旧 Relay 会剥掉新键，所以先部署 Relay 再发 Mac。
- 版本 2.7 把开在 **git worktree** 里的会话归到主仓库：`Task.projectPath` 填主仓库路径（客户端照旧按它分组），真实工作目录放进新的 `Task.worktreePath`；同样要先部署 Relay 再发 Mac。
- 版本 2.8 加入**版本握手**（见「版本握手」）：三端每个请求报自己的协议版本，Relay 对低于最低线的 app 回 412，客户端据此提示升级，而不是解不开新协议后一直「正在连接」。
- 版本 2.9 加入**消息附件**：`Message.attachments`（消息里的图：用户发的图，或 Agent 生成的图，如 Codex `imageGeneration`）与 `Message.files`（Agent 回复提到的本机文件，按需经 `fetchFile` 命令上传）；手机发图经 `StartTask` / `FollowUp.attachments` 与新端点 `PUT /client/uploads`、`GET /agent/uploads`；新增 `video` 产物（`posterId`、`duration`）。新字段会被旧 Relay 的 zod schema 剥掉，必须先部署 Relay，再发 Mac 与手机；新枚举值 `video` 与 `fetchFile` 旧端接不住，按规则应抬高最低线，目前暂缓（见「版本握手」）。
- 版本 2.10 加入可选的系统授权弹窗证据 `Task.systemPermission` / `CommandResult.systemPermission`，截图复用现有 Artifact 与产物端点；字段含义见「SystemPermissionNotice」。
- 版本 2.11 加入**未提交的改动**：命令 `fetchChanges` 让电脑在任务的工作目录里读 git，把改动清单（见「WorkingChanges」）作为一份 JSON 产物上传，产物 id 随新字段 `CommandResult.artifactId` 返回；旧 Relay 不认这条命令、也会剥掉新字段，所以 `minimumRelay` 抬到 2.11，先部署 Relay 再发 app。
- 版本 2.12 加入**远程操作**：命令 `remoteControl` 让手机开关这台电脑桌面的远程操作，画面与输入走既有的预览隧道、没有新端点，预览产物 id 随 `CommandResult.artifactId` 返回；旧 Relay 的 kind 枚举不认这条命令，所以 `minimumRelay` 抬到 2.12。
- 版本 2.13 加入**第三方 ACP agent**：`TaskSource` 与 `ConnectorKind` 新增 `acp`，所有 ACP agent 共用这一个值、以新字段 `connectorId` 区分（`Task.connectorId`、`ConnectorInfo.connectorId`、`startTask.connectorId`、`setConnectorEnabled.connectorId`，都只在 acp 上出现且必须出现，值是 `[a-z0-9-]` 的 1–32 字符）；ACP 任务 id 为 `acp:<connectorId>:<sessionId>`；`ConnectorInfo.canStartTask`（只写 false）标出不能从手机新建任务的 agent；`AgentInfo.connectors` 上限从 8 提到 16，去重键从 `kind` 改为 `(kind, connectorId)`。旧 Relay 不认 `acp` 来源、也会剥掉新字段，所以 `minimumRelay` 抬到 2.13；`acp` 这个新枚举值旧手机与手表接不住，客户端最低线要等新版手机 app 发布后再抬（见「版本握手」）。
- 版本 2.14 加入**带选项的提问**：`PendingRequest.questions` 把 Claude 的 AskUserQuestion、Codex 的 requestUserInput 的选项交给手机，手机点选后以 `approve.answers` 回答；旧 Relay 会剥掉这两个键，`minimumRelay` 抬到 2.14，先部署 Relay 再发 app。
- 版本 2.15 让**电脑移除一台手机**（Mac 设置里的「已配对设备」）：`GET /agent/devices` 多返回本组手机表 `clients`，每条推送注册带上注册它的那份手机凭据 `clientId`（手表与配它的手机相同），`DELETE /pair/clients/:id` 也接受电脑的凭据，移除时连同那台手机与手表的推送注册一起删掉。
- **
- 版本 3.0 是端到端加密**（见「端到端加密」）：组密钥经电脑的配对二维码（或本人剪贴板上的配对链接）传给手机，Relay 从头到尾见不到；Relay 收发、存储的只剩密封形状——路由、合并、截断要用的 id 与时间是明文，任务、电脑、项目、对话、命令、结果、推送正文、产物字节、远程操作的画面与输入全部是密文。下面「Task」到「Event」各节描述的是**密文里面**的明文结构，它们在线上都包在信封里。三端与 Relay 同批升级，不做兼容层：两条最低线都抬到 3.0，2.x 的配对必须重新扫码。
- 版本 3.1 加入一档来源 `dsh`（DeepSeek Harness）：`TaskSource` 与 `ConnectorKind` 新增 `dsh`，任务 id 为 `dsh:<sessionId>`，不带 `connectorId`；`AgentInfo.connectors` 上限仍是 16（一档 6 个 + ACP 最多 10 个）。Relay 只见密文、不解析这个枚举，只改版本号；但 3.0 的手机与手表见到 `dsh` 会拒收整份快照，所以发布顺序是 Relay → 新版 iOS / Android 上架 → `MIN_CLIENT_PROTOCOL` 抬到 3.1 → 发 Mac（见「版本握手」）。
- 版本 3.3 加入**项目级自动批准**（见「项目级自动批准」）：`ConnectorInfo.canAutoApprove` 标出支持的 agent，`Project.autoApprove` / `Task.autoApprove` 报项目是否开着，`startTask` / `followUp` 的 `autoApprove` 设开或关、之后沿用。都是旧端能忽略的可选字段、都在密文里：Relay 只改版本号，两条最低线不动；旧 Mac 不报 `canAutoApprove`，手机也就不画这个开关。
- 版本 3.2 加入**续聊时换模型与思考强度**：`ConnectorInfo.models` 报这个 agent 在手机上能选的模型（各带可选的强度与默认档），`Task.model` / `effort` 报这条会话下一轮会用的，`followUp.model` / `effort` 从这一轮起换掉、之后沿用，`startTask.model` / `effort` 让新会话从第一轮起就用选定的。都是旧端能忽略的可选字段，都在密文里：Relay 只改版本号，两条最低线不动；旧 Mac 不报 `models`，手机也就不给换模型的入口。

## 附录 B：Fixture 与类型对应

3.0 起样本分两层：`protocol-fixtures/` 顶层是**线上形状**（密封信封，由 `scripts/seal-fixtures.mjs` 从 `plain/` 生成，改了明文样本就重跑它），`plain/` 是密文里的**明文结构**。下表按明文结构列出；同名文件在顶层的密封版分别是 SealedSnapshot / SealedTask / SealedCommand / SealedEvent / AgentFrame / RelayFrame / ClientFrame（`plain/frame-*.json` 是明文帧，只作对照）。只有明文形状、不单独上线的（agent-info、connector-info、artifact、working-changes）只在 `plain/` 里。配对与 Relay 自己的 HTTP 消息只在顶层：`key-envelope.json`（KeyEnvelope）、`frame-relay-hello-with-key.json`（带信封的 hello）、`relay-pair-claim-request.json`（注册码认领，带信封与手机名密文）、`relay-pair-claim-request-invite.json`（邀请码认领，不带信封）、`relay-pair-clients-response.json`（手机名为密文，含一条 v2 时代无名记录）、`relay-device-registration*.json` 与 `relay-agent-devices-response.json`（设备名为密文）。`invalid/` 下是线上形状的反例，`plain/invalid/` 下是明文结构的反例。

| 文件 | 类型 |
|---|---|
| snapshot.json | Snapshot |
| task-waiting-approval.json | Task |
| task-waiting-approval-choices.json | Task（2.14 OpenClaw 审批带「允许范围」选项） |
| task-waiting-input.json | Task |
| task-waiting-input-questions.json | Task（2.14 带选项的提问：一道单选、一道多选） |
| snapshot-client.json | Snapshot |
| snapshot-multi-agent.json | Snapshot（两台电脑的合并结果） |
| snapshot-hermes-pi-openclaw.json | Snapshot（2.5 新增的三个来源） |
| snapshot-dsh.json | Snapshot（3.1 的 `dsh` connector 与 `dsh:` 任务，不带 `connectorId`） |
| snapshot-auto-approve.json | Snapshot（3.3 的 `canAutoApprove`，带与不带 `autoApprove` 的项目，带 `autoApprove` 的任务） |
| agent-info.json | AgentInfo |
| connector-info-unavailable.json | ConnectorInfo |
| command-*.json | Command |
| command-approve-deny.json | Command |
| command-approve-answers.json | Command（2.14 approve 带 answers） |
| command-set-connector-enabled.json | Command |
| event-*.json | Event |
| event-notify-done.json | Event |
| event-notify-input.json | Event |
| event-notify-failed.json | Event |
| frame-agent-event.json | AgentFrame |
| frame-relay-command.json | RelayFrame |
| frame-relay-hello.json | RelayHelloFrame |
| frame-client-snapshot.json | ClientFrame |
| frame-client-changed.json | ClientFrame |
| relay-agent-register-response.json | AgentRegisterResponse |
| relay-pair-claim-response.json | PairClaimResponse |
| relay-pair-agents-response.json | PairAgentsResponse |
| relay-agent-invite-response.json | AgentInviteResponse |
| relay-pair-clients-response.json | PairClientsResponse |
| command-fetch-messages.json | Command |
| event-task-messages.json | Event |
| event-task-messages-with-attachments.json | Event（TaskMessages 带 attachments / files，含一条空 text 的用户消息） |
| command-follow-up-with-attachments.json | Command（followUp 带 attachments，prompt 为空串） |
| command-fetch-file.json | Command |
| relay-agent-devices-response.json | AgentDevicesResponse（2.15 带 `clients` 与 `clientId`：手机与手表同一个 `clientId`，另有一条 2.15 之前注册、没有 `clientId` 的设备） |
| relay-device-registration.json | DeviceRegistration |
| relay-device-registration-watch.json | DeviceRegistration |
| relay-device-registration-android.json | DeviceRegistration |
| relay-command-accepted.json | CommandAccepted |
| relay-pair-claim-request.json | PairClaimRequest |
| task-with-artifacts.json | Task（四种 kind 的产物各一，新的在前） |
| task-with-system-permission.json | Task（2.10 系统授权弹窗证据，带截图引用） |
| event-command-result-system-permission.json | Event（2.10 失败结果带文字证据，无截图或 taskId） |
| command-fetch-changes.json | Command（2.11 看未提交的改动） |
| command-remote-control.json | Command（2.12 开启远程操作） |
| event-command-result-changes.json | Event（2.11 fetchChanges 成功，带 artifactId） |
| working-changes.json | WorkingChanges（2.11 改动清单产物：删除、二进制、未跟踪、修改、改名且截断） |
| task-outside-project.json | Task（2.6 不在项目中） |
| command-start-task-outside-project.json | Command（2.6 空 projectPath） |
| task-in-worktree.json | Task（2.7 worktree 里的会话，projectPath 是主仓库） |
| command-start-task-new-project.json | Command（2.6 新建项目） |
| artifact-image.json | Artifact |
| artifact-video.json | Artifact（kind = video，含 posterId / duration） |
| relay-artifact-upload-response.json | ArtifactUploadResponse |
| relay-preview-create-request.json | PreviewCreateRequest |
| relay-preview-create-response.json | PreviewCreateResponse |
| relay-preview-session-response.json | PreviewSessionResponse |
| task-acp.json | Task（2.13 ACP 任务，id 为 `acp:<connectorId>:<sessionId>`，带 connectorId） |
| agent-info-acp.json | AgentInfo（2.13 一档 + 两个 ACP connector，其中一个带 `canStartTask: false`） |
| agent-info-models.json | AgentInfo（3.2 Codex 与 Claude 带 `models`，Haiku 不带强度） |
| task-with-model.json | Task（3.2 带 `model` / `effort`） |
| command-follow-up-model.json | Command（3.2 followUp 换模型与强度） |
| command-start-task-model.json | Command（3.2 startTask 指定模型与强度） |
| command-follow-up-auto-approve.json | Command（3.3 followUp 关掉项目的自动批准） |
| command-start-task-auto-approve.json | Command（3.3 startTask 打开项目的自动批准） |
| command-start-task-acp.json | Command（2.13 startTask 发给某个 ACP agent，带 connectorId） |
| command-set-connector-enabled-acp.json | Command（2.13 开关某个 ACP agent，带 connectorId） |
| invalid/task-bad-status.json | 必须被拒绝：未知 status |
| invalid/command-payload-mismatch.json | 必须被拒绝 |
| invalid/command-missing-agent-id.json | 必须被拒绝：Command 缺少必填的 agentId |
| invalid/event-payload-mismatch.json | 必须被拒绝：Event 的 kind 与配套字段不匹配 |
| invalid/pending-request-bad-kind.json | 必须被拒绝 |
| invalid/agent-info-bad-connector-kind.json | 必须被拒绝：未知 connector kind |
| invalid/artifact-bad-kind.json | 必须被拒绝：未知 artifact kind |
| invalid/client-frame-payload-mismatch.json | 必须被拒绝：ClientFrame 的 type 与配套字段不匹配 |
| invalid/event-system-permission-missing-dialog-text.json | 必须被拒绝：系统授权提示缺少必填 dialogText |
| invalid/task-acp-missing-connector-id.json | 必须被拒绝：`source = acp` 却没有 connectorId |
| invalid/agent-info-acp-missing-connector-id.json | 必须被拒绝：`kind = acp` 的 connector 没有 connectorId |
| invalid/agent-info-duplicate-acp-connector.json | 必须被拒绝：同一台电脑上 `(kind, connectorId)` 重复 |
| invalid/command-start-task-acp-missing-connector-id.json | 必须被拒绝：startTask 的 `source = acp` 却没有 connectorId |
| invalid/command-follow-up-bad-model.json | 必须被拒绝：followUp 的 `model` 以 `-` 开头（会被 agent 命令行当成选项） |
| invalid/command-start-task-bad-effort.json | 必须被拒绝：startTask 的 `effort` 以 `-` 开头 |
| invalid/connector-info-effort-not-listed.json | 必须被拒绝：ModelOption 的 `defaultEffort` 不在 `efforts` 里 |
