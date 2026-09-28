import { describe, expect, it } from "vitest";
import { z, type ZodType } from "zod";
import * as P from "../src/protocol";

/**
 * `import.meta.glob` 在构建期展开成静态 import，因此 `protocol-fixtures/` 下新增的文件
 * 会自动出现在 `VALID` / `INVALID` 里。下面的 `SCHEMA` / `MUST_REJECT` 表必须逐一覆盖，
 * 覆盖不全会被 "fixture 目录与对照表一一对应" 用例直接判失败——新 fixture 不可能被静默跳过。
 */
declare global {
  interface ImportMeta {
    glob(
      pattern: string,
      options: { eager: true; import: "default" },
    ): Record<string, unknown>;
  }
}

/** 顶层：协议 3.0 的线上形状（密封信封与 Relay 自己的 HTTP 消息）。 */
const VALID = import.meta.glob("../protocol-fixtures/*.json", { eager: true, import: "default" });
const INVALID = import.meta.glob("../protocol-fixtures/invalid/*.json", { eager: true, import: "default" });
/** `plain/`：密文里面的明文领域对象，Relay 不解析，但 schema 与 Swift 同源。 */
const PLAIN = import.meta.glob("../protocol-fixtures/plain/*.json", { eager: true, import: "default" });
const PLAIN_INVALID = import.meta.glob("../protocol-fixtures/plain/invalid/*.json", { eager: true, import: "default" });

function byBasename(modules: Record<string, unknown>): Map<string, unknown> {
  return new Map(Object.entries(modules).map(([path, value]) => [path.split("/").pop()!, value]));
}

const validFixtures = byBasename(VALID);
const invalidFixtures = byBasename(INVALID);
const plainFixtures = byBasename(PLAIN);
const plainInvalidFixtures = byBasename(PLAIN_INVALID);

/** `PROTOCOL.md` 的「Fixture 与类型对应」表，逐条落到 zod schema 上。 */
/** 顶层：线上形状，逐一落到 Relay 真正解析的 schema 上。 */
const SCHEMA: Record<string, ZodType> = {
  "command-approve-answers.json": P.SealedCommand,
  "command-approve-deny.json": P.SealedCommand,
  "command-approve.json": P.SealedCommand,
  "command-fetch-changes.json": P.SealedCommand,
  "command-fetch-file.json": P.SealedCommand,
  "command-fetch-messages.json": P.SealedCommand,
  "command-follow-up-with-attachments.json": P.SealedCommand,
  "command-follow-up-model.json": P.SealedCommand,
  "command-start-task-model.json": P.SealedCommand,
  "command-follow-up-auto-approve.json": P.SealedCommand,
  "command-start-task-auto-approve.json": P.SealedCommand,
  "command-follow-up.json": P.SealedCommand,
  "command-interrupt.json": P.SealedCommand,
  "command-remote-control.json": P.SealedCommand,
  "command-set-connector-enabled-acp.json": P.SealedCommand,
  "command-set-connector-enabled.json": P.SealedCommand,
  "command-start-task-acp.json": P.SealedCommand,
  "command-start-task-new-project.json": P.SealedCommand,
  "command-start-task-outside-project.json": P.SealedCommand,
  "command-start-task.json": P.SealedCommand,
  "command-start-task-worktree.json": P.SealedCommand,
  "command-start-task-worktree-auto-approve.json": P.SealedCommand,
  "command-merge-worktree.json": P.SealedCommand,
  "event-command-result-changes.json": P.SealedEvent,
  "event-command-result-system-permission.json": P.SealedEvent,
  "event-command-result.json": P.SealedEvent,
  "event-notify-done.json": P.SealedEvent,
  "event-notify-failed.json": P.SealedEvent,
  "event-notify-input.json": P.SealedEvent,
  "event-notify.json": P.SealedEvent,
  "event-snapshot.json": P.SealedEvent,
  "event-task-messages-with-attachments.json": P.SealedEvent,
  "event-task-messages.json": P.SealedEvent,
  "event-task-removed.json": P.SealedEvent,
  "event-task-updated.json": P.SealedEvent,
  "frame-agent-event.json": P.AgentFrame,
  "frame-client-changed.json": P.ClientFrame,
  "frame-client-snapshot.json": P.ClientFrame,
  "frame-relay-command.json": P.RelayFrame,
  "frame-relay-hello-with-key.json": P.RelayHelloFrame,
  "frame-relay-hello.json": P.RelayHelloFrame,
  "key-envelope.json": P.KeyEnvelope,
  "relay-agent-devices-response.json": P.AgentDevicesResponse,
  "relay-agent-invite-response.json": P.AgentInviteResponse,
  "relay-agent-register-response.json": P.AgentRegisterResponse,
  "relay-artifact-upload-response.json": P.ArtifactUploadResponse,
  "relay-command-accepted.json": P.CommandAccepted,
  "relay-device-registration-watch.json": P.DeviceRegistration,
  "relay-device-registration-android.json": P.DeviceRegistration,
  "relay-device-registration.json": P.DeviceRegistration,
  "relay-pair-agents-response.json": P.PairAgentsResponse,
  "relay-pair-claim-request-invite.json": P.PairClaimRequest,
  "relay-pair-claim-request.json": P.PairClaimRequest,
  "relay-pair-claim-response.json": P.PairClaimResponse,
  "relay-pair-clients-response.json": P.PairClientsResponse,
  "relay-preview-create-request.json": P.PreviewCreateRequest,
  "relay-preview-create-response.json": P.PreviewCreateResponse,
  "relay-preview-session-response.json": P.PreviewSessionResponse,
  "snapshot-client.json": P.SealedSnapshot,
  "snapshot-dsh.json": P.SealedSnapshot,
  "snapshot-auto-approve.json": P.SealedSnapshot,
  "snapshot-hermes-pi-openclaw.json": P.SealedSnapshot,
  "snapshot-multi-agent.json": P.SealedSnapshot,
  "snapshot.json": P.SealedSnapshot,
  "task-acp.json": P.SealedTask,
  "task-with-model.json": P.SealedTask,
  "task-in-worktree.json": P.SealedTask,
  "task-outside-project.json": P.SealedTask,
  "task-waiting-approval-choices.json": P.SealedTask,
  "task-waiting-approval.json": P.SealedTask,
  "task-waiting-input-questions.json": P.SealedTask,
  "task-waiting-input.json": P.SealedTask,
  "task-with-artifacts.json": P.SealedTask,
  "task-with-system-permission.json": P.SealedTask,
};

/** 明文帧只在 `plain/` 里用来对照：线上只有密封帧。 */
const PlainAgentFrame = z.object({ type: z.literal("event"), event: P.Event });
const PlainRelayFrame = z.object({ type: z.literal("command"), command: P.Command });
const PlainClientFrame = z.object({ type: z.literal("snapshot"), snapshot: P.Snapshot });

/** `plain/`：`PROTOCOL.md` 的「Fixture 与类型对应」表里的明文领域对象。 */
const PLAIN_SCHEMA: Record<string, ZodType> = {
  "agent-info.json": P.AgentInfo,
  "agent-info-acp.json": P.AgentInfo,
  "agent-info-models.json": P.AgentInfo,
  "agent-info-worktrees.json": P.AgentInfo,
  "connector-info-unavailable.json": P.ConnectorInfo,
  "snapshot.json": P.Snapshot,
  "snapshot-client.json": P.Snapshot,
  "snapshot-multi-agent.json": P.Snapshot,
  "snapshot-hermes-pi-openclaw.json": P.Snapshot,
  "snapshot-dsh.json": P.Snapshot,
  "snapshot-auto-approve.json": P.Snapshot,
  "task-waiting-approval.json": P.Task,
  "task-waiting-approval-choices.json": P.Task,
  "task-waiting-input.json": P.Task,
  "task-waiting-input-questions.json": P.Task,
  "task-with-artifacts.json": P.Task,
  "task-outside-project.json": P.Task,
  "task-in-worktree.json": P.Task,
  "task-with-system-permission.json": P.Task,
  "task-acp.json": P.Task,
  "task-with-model.json": P.Task,
  "artifact-image.json": P.Artifact,
  "artifact-video.json": P.Artifact,
  "command-start-task.json": P.Command,
  "command-start-task-outside-project.json": P.Command,
  "command-start-task-new-project.json": P.Command,
  "command-follow-up.json": P.Command,
  "command-follow-up-with-attachments.json": P.Command,
  "command-follow-up-model.json": P.Command,
  "command-start-task-model.json": P.Command,
  "command-follow-up-auto-approve.json": P.Command,
  "command-start-task-auto-approve.json": P.Command,
  "command-approve.json": P.Command,
  "command-approve-deny.json": P.Command,
  "command-approve-answers.json": P.Command,
  "command-interrupt.json": P.Command,
  "command-set-connector-enabled.json": P.Command,
  "command-fetch-messages.json": P.Command,
  "command-fetch-file.json": P.Command,
  "command-fetch-changes.json": P.Command,
  "command-remote-control.json": P.Command,
  "command-start-task-acp.json": P.Command,
  "command-set-connector-enabled-acp.json": P.Command,
  "command-start-task-worktree.json": P.Command,
  "command-start-task-worktree-auto-approve.json": P.Command,
  "command-merge-worktree.json": P.Command,
  "event-snapshot.json": P.Event,
  "event-task-updated.json": P.Event,
  "event-task-removed.json": P.Event,
  "event-command-result.json": P.Event,
  "event-command-result-system-permission.json": P.Event,
  "event-command-result-changes.json": P.Event,
  "event-notify.json": P.Event,
  "event-notify-done.json": P.Event,
  "event-notify-input.json": P.Event,
  "event-notify-failed.json": P.Event,
  "event-task-messages.json": P.Event,
  "event-task-messages-with-attachments.json": P.Event,
  "frame-agent-event.json": PlainAgentFrame,
  "frame-relay-command.json": PlainRelayFrame,
  "frame-client-snapshot.json": PlainClientFrame,
  "working-changes.json": P.WorkingChanges,
  "working-changes-merge-target.json": P.WorkingChanges,
};

/** invalid/ 下每个样本都必须被指定 schema 拒绝。 */
const MUST_REJECT: Record<string, ZodType> = {
  "client-frame-payload-mismatch.json": P.ClientFrame,
  "command-missing-agent-id.json": P.SealedCommand,
  "event-payload-mismatch.json": P.SealedEvent,
};

const PLAIN_MUST_REJECT: Record<string, ZodType> = {
  "agent-info-acp-missing-connector-id.json": P.AgentInfo,
  "agent-info-bad-connector-kind.json": P.AgentInfo,
  "agent-info-duplicate-acp-connector.json": P.AgentInfo,
  "artifact-bad-kind.json": P.Artifact,
  "command-payload-mismatch.json": P.Command,
  "command-start-task-acp-missing-connector-id.json": P.Command,
  "command-follow-up-bad-model.json": P.Command,
  "command-start-task-bad-effort.json": P.Command,
  "command-start-task-worktree-new-project.json": P.Command,
  "command-start-task-worktree-openclaw.json": P.Command,
  "command-start-task-worktree-outside-project.json": P.Command,
  "agent-info-worktrees-false.json": P.AgentInfo,
  "connector-info-effort-not-listed.json": P.ConnectorInfo,
  "event-system-permission-missing-dialog-text.json": P.Event,
  "pending-question-missing-options.json": P.Task,
  "pending-request-bad-kind.json": P.Task,
  "task-acp-missing-connector-id.json": P.Task,
  "task-bad-status.json": P.Task,
};

describe("fixture 目录与对照表一一对应", () => {
  it("每个 valid fixture 都在 SCHEMA / PLAIN_SCHEMA 表里，且表里没有已删除的文件", () => {
    expect([...validFixtures.keys()].sort()).toEqual(Object.keys(SCHEMA).sort());
    expect(validFixtures.size).toBe(74);
    expect([...plainFixtures.keys()].sort()).toEqual(Object.keys(PLAIN_SCHEMA).sort());
    expect(plainFixtures.size).toBe(63);
  });
  it("每个 invalid fixture 都在 MUST_REJECT / PLAIN_MUST_REJECT 表里", () => {
    expect([...invalidFixtures.keys()].sort()).toEqual(Object.keys(MUST_REJECT).sort());
    expect(invalidFixtures.size).toBe(3);
    expect([...plainInvalidFixtures.keys()].sort()).toEqual(Object.keys(PLAIN_MUST_REJECT).sort());
    expect(plainInvalidFixtures.size).toBe(18);
  });
});

describe("protocol schemas accept every fixture", () => {
  /** parse 后必须与原样本深度相等：既证明接受，也证明没有未知键被静默丢弃。 */
  it.each([...Object.keys(SCHEMA)])("%s 往返不变", (name) => {
    const fixture = validFixtures.get(name);
    expect(fixture).toBeDefined();
    expect(SCHEMA[name].parse(fixture)).toEqual(fixture);
  });
  it.each([...Object.keys(PLAIN_SCHEMA)])("plain/%s 往返不变", (name) => {
    const fixture = plainFixtures.get(name);
    expect(fixture).toBeDefined();
    expect(PLAIN_SCHEMA[name].parse(fixture)).toEqual(fixture);
  });
});

describe("protocol schemas reject every invalid fixture", () => {
  it.each([...Object.keys(MUST_REJECT)])("invalid/%s 被拒绝", (name) => {
    const fixture = invalidFixtures.get(name);
    expect(fixture).toBeDefined();
    expect(MUST_REJECT[name].safeParse(fixture).success).toBe(false);
  });
  it.each([...Object.keys(PLAIN_MUST_REJECT)])("plain/invalid/%s 被拒绝", (name) => {
    const fixture = plainInvalidFixtures.get(name);
    expect(fixture).toBeDefined();
    expect(PLAIN_MUST_REJECT[name].safeParse(fixture).success).toBe(false);
  });
});

describe("协议 v2 的新约束", () => {
  const agentInfo = plainFixtures.get("agent-info.json") as P.AgentInfo;
  const connector = plainFixtures.get("connector-info-unavailable.json") as P.ConnectorInfo;
  const setConnectorEnabled = plainFixtures.get("command-set-connector-enabled.json") as P.Command;
  const commandApprove = plainFixtures.get("command-approve.json") as P.Command;
  const snapshotMulti = plainFixtures.get("snapshot-multi-agent.json") as P.Snapshot;

  it("未知的 connectors[].kind 被拒绝", () => {
    const bad = { ...agentInfo, connectors: [{ ...connector, kind: "gpt" }] };
    expect(P.AgentInfo.safeParse(bad).success).toBe(false);
    const issue = P.AgentInfo.safeParse(bad);
    if (!issue.success) expect(issue.error.issues[0]?.path).toEqual(["connectors", 0, "kind"]);
  });

  it("未知的 connectors[].status 与负的 taskCount 被拒绝", () => {
    expect(P.ConnectorInfo.safeParse({ ...connector, status: "meh" }).success).toBe(false);
    expect(P.ConnectorInfo.safeParse({ ...connector, taskCount: -1 }).success).toBe(false);
    expect(P.ConnectorInfo.safeParse({ ...connector, taskCount: 1.5 }).success).toBe(false);
  });

  it("未知的 platform 被拒绝", () => {
    expect(P.AgentInfo.safeParse({ ...agentInfo, platform: "linux" }).success).toBe(false);
  });

  it("connectors 允许为空数组（刚被认领、还没连上的 Agent）", () => {
    expect(P.AgentInfo.safeParse({ ...agentInfo, connectors: [] }).success).toBe(true);
    // 刚认领、还没连上的电脑在线上只有 id：Relay 手里没有它的密文。
    const claim = validFixtures.get("relay-pair-claim-response.json") as { agents: P.SealedAgent[] };
    const joined = validFixtures.get("relay-pair-agents-response.json") as { agent: P.SealedAgent };
    expect(claim.agents[0].sealed).toBeUndefined();
    expect(joined.agent.sealed).toBeUndefined();
  });

  it("connectors 最多 8 个且按 kind 去重", () => {
    const nine = Array.from({ length: 9 }, () => ({ ...connector }));
    expect(P.AgentInfo.safeParse({ ...agentInfo, connectors: nine }).success).toBe(false);
    const dup = [{ ...connector, kind: "codex" as const }, { ...connector, kind: "codex" as const }];
    expect(P.AgentInfo.safeParse({ ...agentInfo, connectors: dup }).success).toBe(false);
    const distinct = [{ ...connector, kind: "codex" as const }, { ...connector, kind: "claude" as const }];
    expect(P.AgentInfo.safeParse({ ...agentInfo, connectors: distinct }).success).toBe(true);
  });

  it("Command 缺少 agentId 被拒绝，且错误指向 agentId", () => {
    const { agentId: _omitted, ...withoutAgentId } = commandApprove;
    const parsed = P.Command.safeParse(withoutAgentId);
    expect(parsed.success).toBe(false);
    if (!parsed.success) expect(parsed.error.issues.some((i) => i.path[0] === "agentId")).toBe(true);
  });

  it("setConnectorEnabled 的 kind 与 payload 必须匹配", () => {
    expect(setConnectorEnabled.kind).toBe("setConnectorEnabled");
    expect(setConnectorEnabled.setConnectorEnabled).toEqual({ connector: "codex", enabled: false });
    const { setConnectorEnabled: _dropped, ...withoutPayload } = setConnectorEnabled;
    const missing = P.Command.safeParse(withoutPayload);
    expect(missing.success).toBe(false);
    if (!missing.success) expect(missing.error.issues[0]?.path).toEqual(["setConnectorEnabled"]);
    const badConnector = {
      ...setConnectorEnabled,
      setConnectorEnabled: { connector: "gpt", enabled: true },
    };
    expect(P.Command.safeParse(badConnector).success).toBe(false);
  });

  it("Task 与 Project 必须带 agentId，且合并快照里每个任务都能找到归属", () => {
    const task = snapshotMulti.tasks[0];
    const { agentId: _t, ...taskWithout } = task;
    expect(P.Task.safeParse(taskWithout).success).toBe(false);
    const project = snapshotMulti.projects[0];
    const { agentId: _p, ...projectWithout } = project;
    expect(P.Project.safeParse(projectWithout).success).toBe(false);
    expect(new Set(snapshotMulti.tasks.map((t) => t.agentId)).size).toBe(2);
    expect(
      snapshotMulti.tasks.every((t) => snapshotMulti.agents.some((a) => a.agentId === t.agentId)),
    ).toBe(true);
  });

  it("Snapshot 用 agents 取代 agentOnline", () => {
    expect(snapshotMulti.agents.map((a) => a.online)).toEqual([true, false]);
    const withOldShape = { ...snapshotMulti, agents: undefined, agentOnline: true };
    expect(P.Snapshot.safeParse(withOldShape).success).toBe(false);
  });

  const device = validFixtures.get("relay-device-registration.json") as P.DeviceRegistration;

  it("accepts an Android FCM registration with a long token", () => {
    expect(P.DeviceRegistration.parse({ ...device, token: "f".repeat(512), platform: "android", environment: "production" }).platform)
      .toBe("android");
  });

  it("DeviceRegistration 必须带密封的 sealedName；明文 name 不再被接受，超长密文 400", () => {
    const { sealedName: _dropped, ...withoutName } = device;
    expect(P.DeviceRegistration.safeParse(withoutName).success).toBe(false);
    expect(P.DeviceRegistration.safeParse({ ...withoutName, name: "Demo 的 iPhone" }).success).toBe(false);
    expect(P.DeviceRegistration.safeParse({ ...device, sealedName: "Demo 的 iPhone" }).success).toBe(false);
    const tooLong = `AQ${"A".repeat(P.MAX_SEALED_DEVICE_NAME_LENGTH)}`;
    expect(P.DeviceRegistration.safeParse({ ...device, sealedName: tooLong }).success).toBe(false);
  });

  it("lastSeenAt 不属于请求体：客户端报的值被丢弃，由 Relay 维护", () => {
    const parsed = P.DeviceRegistration.parse({ ...device, lastSeenAt: "2020-01-01T00:00:00Z" });
    expect("lastSeenAt" in parsed).toBe(false);
    // 它只出现在 GET /agent/devices 的安全视图里，且那里没有 token。
    const listed = validFixtures.get("relay-agent-devices-response.json") as P.AgentDevicesResponse;
    expect(listed.devices.every((d) => d.lastSeenAt.length > 0)).toBe(true);
    expect(listed.devices.some((d) => "token" in d)).toBe(false);
  });
});

describe("协议 2.3：任务产物", () => {
  const taskWithArtifacts = plainFixtures.get("task-with-artifacts.json") as P.Task;
  const taskWithout = plainFixtures.get("task-waiting-approval.json") as P.Task;
  const snapshot = plainFixtures.get("snapshot.json") as P.Snapshot;
  const image = plainFixtures.get("artifact-image.json") as P.Artifact;
  const badKind = plainInvalidFixtures.get("artifact-bad-kind.json");

  it("fixture 四种 kind 各一，且新的在前", () => {
    const artifacts = taskWithArtifacts.artifacts!;
    expect(artifacts.map((a) => a.kind)).toEqual(["preview", "image", "file", "link"]);
    const createdAt = artifacts.map((a) => a.createdAt);
    expect(createdAt).toEqual([...createdAt].sort().reverse());
    expect(artifacts[0].id).toMatch(P.PREVIEW_ID_PATTERN);
    for (const a of artifacts.slice(1)) expect(a.id).toMatch(P.ARTIFACT_ID_PATTERN);
  });

  it("2.3 之前的任务没有 artifacts 也照常解析，输出里不凭空出现这个键", () => {
    expect("artifacts" in taskWithout).toBe(false);
    const parsed = P.Task.parse(taskWithout);
    expect("artifacts" in parsed).toBe(false);
    expect(JSON.parse(JSON.stringify(parsed))).toEqual(taskWithout);
  });

  it("带产物任务的快照往返不变", () => {
    const withArtifacts = { ...snapshot, tasks: [taskWithArtifacts, ...snapshot.tasks] };
    const parsed = P.Snapshot.parse(withArtifacts);
    expect(parsed).toEqual(withArtifacts);
    expect(parsed.tasks[0].artifacts).toEqual(taskWithArtifacts.artifacts);
    expect("artifacts" in parsed.tasks[1]).toBe(false);
    // 同一份快照作为 Agent 发来的 snapshot 事件也一样。
    const event = { kind: "snapshot", snapshot: withArtifacts };
    expect(P.Event.parse(event)).toEqual(event);
  });

  it("未知 kind 挂在任务上时整条任务被拒绝，错误指向那一件产物", () => {
    const parsed = P.Task.safeParse({ ...taskWithArtifacts, artifacts: [badKind] });
    expect(parsed.success).toBe(false);
    if (!parsed.success) expect(parsed.error.issues[0]?.path).toEqual(["artifacts", 0, "kind"]);
  });

  it(`每个任务最多 ${P.MAX_TASK_ARTIFACTS} 件产物`, () => {
    const ten = Array.from({ length: P.MAX_TASK_ARTIFACTS }, () => ({ ...image }));
    expect(P.Task.safeParse({ ...taskWithout, artifacts: ten }).success).toBe(true);
    expect(P.Task.safeParse({ ...taskWithout, artifacts: [...ten, image] }).success).toBe(false);
  });

  it(`一次对话记录最多 ${P.MAX_MESSAGES} 条对话加 ${P.MAX_TOOL_MESSAGES} 行工具`, () => {
    const message = (role: "agent" | "tool") => ({ id: "m", role, text: "t", createdAt: "2026-09-25T00:00:00Z" });
    const base = { taskId: "claude:s", agentId: "a", hasMore: true, fetchedAt: "2026-09-25T00:00:00Z" };
    const full = [
      ...Array.from({ length: P.MAX_MESSAGES }, () => message("agent")),
      ...Array.from({ length: P.MAX_TOOL_MESSAGES }, () => message("tool")),
    ];
    expect(P.TaskMessages.safeParse({ ...base, messages: full }).success).toBe(true);
    expect(P.TaskMessages.safeParse({ ...base, messages: [...full, message("tool")] }).success).toBe(false);
  });

  it("只校验字段类型：缺了 kind 专属字段的产物照样接受，由生产方保证", () => {
    const { contentType: _c, size: _s, expiresAt: _e, ...bare } = image;
    expect(P.Artifact.safeParse(bare).success).toBe(true);
    expect(P.Artifact.safeParse({ ...image, size: 1.5 }).success).toBe(false);
    expect(P.Artifact.safeParse({ ...image, size: "318522" }).success).toBe(false);
    // 可选键缺省是省略，不是 null。
    expect(P.Artifact.safeParse({ ...image, url: null }).success).toBe(false);
  });

  it("预览与上传响应的 id 格式", () => {
    const created = validFixtures.get("relay-preview-create-response.json") as P.PreviewCreateResponse;
    const session = validFixtures.get("relay-preview-session-response.json") as P.PreviewSessionResponse;
    expect(session.url.startsWith(`https://p-${created.previewId}.botbus.io/__botbus/auth?ticket=`)).toBe(true);
    expect(P.PreviewCreateResponse.safeParse({ ...created, previewId: created.previewId.toUpperCase() }).success)
      .toBe(false);
    const uploaded = validFixtures.get("relay-artifact-upload-response.json") as P.ArtifactUploadResponse;
    expect(P.ArtifactUploadResponse.safeParse({ ...uploaded, id: `${uploaded.id}=` }).success).toBe(false);
    expect(P.PreviewCreateRequest.parse({})).toEqual({});
  });
});

describe("protocol schemas reject bad input", () => {
  const eventNotify = plainFixtures.get("event-notify.json") as P.Event;
  const eventNotifyDone = plainFixtures.get("event-notify-done.json") as P.Event;
  const commandApprove = plainFixtures.get("command-approve.json") as P.Command;
  const invalidCommandMismatch = plainInvalidFixtures.get("command-payload-mismatch.json");
  const invalidEventMismatch = invalidFixtures.get("event-payload-mismatch.json");

  it("mismatch errors point at the missing payload key", () => {
    const command = P.Command.safeParse(invalidCommandMismatch);
    expect(command.success).toBe(false);
    if (!command.success) expect(command.error.issues[0]?.path).toEqual(["approve"]);
    const event = P.Event.safeParse(invalidEventMismatch);
    expect(event.success).toBe(false);
    if (!event.success) expect(event.error.issues[0]?.path).toEqual(["task"]);
  });
  it("TASK_APPROVAL notify without requestId is rejected, other categories are fine", () => {
    const { requestId: _omitted, ...withoutRequestId } = eventNotify.notify!;
    expect(P.Notify.safeParse(withoutRequestId).success).toBe(false);
    expect(P.Notify.safeParse(eventNotifyDone.notify).success).toBe(true);
  });
  it("command whose payload does not match kind", () => {
    expect(P.Command.safeParse({ ...commandApprove, kind: "interrupt" }).success).toBe(false);
  });
  it("claim code must be six digits", () => {
    expect(P.PairClaimRequest.safeParse({ code: "12345" }).success).toBe(false);
    expect(P.PairClaimRequest.safeParse({ code: "123456" }).success).toBe(true);
  });
});

/**
 * 协议 3.0：密封样本用 Workers 的 WebCrypto 解开，必须和 `plain/` 里的明文逐键相等。
 * 生成脚本用的是 Node 的 WebCrypto、Swift 用 CryptoKit——三处实现对同一份样本给出同一个结果，格式才算一致。
 */
describe("协议 3.0：密封样本能用固定密钥解开", () => {
  const ROOT = Uint8Array.from({ length: 32 }, (_, i) => i);

  async function derive(info: string): Promise<CryptoKey> {
    const ikm = await crypto.subtle.importKey("raw", ROOT, "HKDF", false, ["deriveBits"]);
    const bits = await crypto.subtle.deriveBits(
      { name: "HKDF", hash: "SHA-256", salt: new Uint8Array(0), info: new TextEncoder().encode(info) }, ikm, 256);
    return crypto.subtle.importKey("raw", bits, "AES-GCM", false, ["decrypt"]);
  }

  function fromBase64url(text: string): Uint8Array {
    const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
    return Uint8Array.from(atob(padded), (c) => c.charCodeAt(0));
  }

  async function open(key: CryptoKey, sealed: string, aad: string): Promise<unknown> {
    const bytes = fromBase64url(sealed);
    expect(bytes[0]).toBe(0x01);
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.slice(1, 13), additionalData: new TextEncoder().encode(aad), tagLength: 128 },
      key, bytes.slice(13));
    return JSON.parse(new TextDecoder().decode(plain));
  }

  it("任务、命令、对话记录、推送与整份快照都解得开，且与明文一致", async () => {
    const content = await derive("botbus/v1/content");
    const notifyKey = await derive("botbus/v1/notify");
    let opened = 0;
    for (const [name, sealed] of validFixtures) {
      const plain = plainFixtures.get(name) as Record<string, any> | undefined;
      if (!plain) continue;
      const wire = sealed as Record<string, any>;
      if (name.startsWith("task-")) {
        expect(await open(content, wire.sealed, `task:${wire.agentId}:${wire.id}`)).toEqual(plain);
      } else if (name.startsWith("command-")) {
        expect(await open(content, wire.sealed, `command:${wire.agentId}:${wire.id}`)).toEqual(plain);
      } else if (name.startsWith("event-") && wire.kind === "notify") {
        const n = wire.notify;
        expect(await open(notifyKey, n.sealed, `notify:${n.agentId}:${n.taskId}`)).toEqual(plain.notify);
      } else if (name.startsWith("event-") && wire.kind === "taskMessages") {
        const m = wire.taskMessages;
        expect(await open(content, m.sealed, `messages:${m.agentId}:${m.taskId}`)).toEqual(plain.taskMessages);
      } else if (name.startsWith("snapshot")) {
        for (const [i, t] of (wire.tasks as any[]).entries()) {
          expect(await open(content, t.sealed, `task:${t.agentId}:${t.id}`)).toEqual(plain.tasks[i]);
        }
        for (const [i, a] of (wire.agents as any[]).entries()) {
          expect(await open(content, a.sealed, `agent:${a.agentId}`)).toEqual(plain.agents[i]);
        }
      } else continue;
      opened++;
    }
    expect(opened).toBeGreaterThanOrEqual(30);
  });

  it("手机名、设备名（配对、手机表、推送注册、电脑侧设备表）都用 AAD `client` 解得开", async () => {
    const content = await derive("botbus/v1/content");
    const names = async (name: string, pick: (f: any) => string[]) =>
      Promise.all(pick(validFixtures.get(name)).map((sealed) => open(content, sealed, "client")));
    expect(await names("relay-device-registration.json", (f) => [f.sealedName])).toEqual(["Demo 的 iPhone"]);
    expect(await names("relay-device-registration-watch.json", (f) => [f.sealedName])).toEqual(["Demo 的 Apple Watch"]);
    expect(await names("relay-device-registration-android.json", (f) => [f.sealedName])).toEqual(["Demo 的 Android"]);
    expect(await names("relay-agent-devices-response.json", (f) => f.devices.map((d: any) => d.sealedName)))
      .toEqual(["Demo 的 iPhone", "Demo 的 Apple Watch", "旧 iPad", "Demo 的 Android"]);
    expect(await names("relay-agent-devices-response.json", (f) => f.clients.map((c: any) => c.sealedName)))
      .toEqual(["Demo 的 iPhone", "备用机", "Demo 的 Android"]);
    expect(await names("relay-pair-clients-response.json", (f) => f.clients.flatMap((c: any) => c.sealedName ?? [])))
      .toEqual(["Demo 的 iPhone", "备用机"]);
  });

  it("AAD 钉住位置：同一段密文挪到别的任务 id 下解不开", async () => {
    const content = await derive("botbus/v1/content");
    const task = validFixtures.get("task-waiting-approval.json") as P.SealedTask;
    await expect(open(content, task.sealed, `task:${task.agentId}:codex:other`)).rejects.toThrow();
  });
});

describe("协议 3.0：Relay 只认密封形状", () => {
  const task = validFixtures.get("task-waiting-approval.json") as P.SealedTask;
  const plainTask = plainFixtures.get("task-waiting-approval.json") as P.Task;
  const command = validFixtures.get("command-approve.json") as P.SealedCommand;

  it("明文任务、明文命令不再被 Relay 接受", () => {
    expect(P.SealedTask.safeParse(plainTask).success).toBe(false);
    expect(P.SealedCommand.safeParse(plainFixtures.get("command-approve.json")).success).toBe(false);
    expect(P.SealedEvent.safeParse(plainFixtures.get("event-task-updated.json")).success).toBe(false);
  });

  it("信封必须像 base64url 且够长", () => {
    expect(P.SealedTask.safeParse({ ...task, sealed: "not base64!" }).success).toBe(false);
    expect(P.SealedTask.safeParse({ ...task, sealed: "AQ" }).success).toBe(false);
    expect(P.SealedCommand.safeParse({ ...command, sealed: command.sealed }).success).toBe(true);
  });

  it("命令结果要么是 Mac 的密文、要么是 Relay 自己写的 error，不能两个都有或都没有", () => {
    const base = { commandId: "c", finishedAt: "2026-09-26T00:00:00Z" };
    expect(P.SealedResult.safeParse({ ...base, error: "expired" }).success).toBe(true);
    expect(P.SealedResult.safeParse({ ...base, sealed: task.sealed }).success).toBe(true);
    expect(P.SealedResult.safeParse(base).success).toBe(false);
    expect(P.SealedResult.safeParse({ ...base, sealed: task.sealed, error: "expired" }).success).toBe(false);
  });

  it("审批推送必须带明文 requestId：点开通知要直达那一次审批", () => {
    const event = validFixtures.get("event-notify.json") as P.SealedEvent;
    const { requestId: _dropped, ...without } = event.notify!;
    expect(P.SealedNotify.safeParse(without).success).toBe(false);
  });

  it("密钥信封的 epk 必须是 32 字节 X25519 公钥", () => {
    const envelope = validFixtures.get("key-envelope.json") as P.KeyEnvelope;
    expect(P.KeyEnvelope.safeParse({ ...envelope, epk: envelope.epk.slice(1) }).success).toBe(false);
  });
});
