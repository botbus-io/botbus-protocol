#!/usr/bin/env node
// 把 protocol-fixtures/plain/ 下的明文样本密封成顶层的线上形状（协议 3.0，端到端加密）。
//
// 用固定的 fixture 密钥与「nonce = SHA256(AAD) 前 12 字节」的确定性 nonce，同一份明文每次得到同一份密文，
// Swift 与 TypeScript 两边都能拿同一把钥匙解开并与 plain/ 逐键比较。**这套 nonce 规则只给 fixture 用**，
// 生产环境 nonce 必须随机（重复 nonce 会泄露明文异或）。
//
// 用法：node scripts/seal-fixtures.mjs   （Node 22；改了 plain/ 之后重跑，再跑两端的协议测试）
import { createHash, createHmac, createPrivateKey, createPublicKey, diffieHellman, webcrypto } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const { subtle } = webcrypto;
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const FIXTURES = join(ROOT, "protocol-fixtures");
const PLAIN = join(FIXTURES, "plain");

// ---- 固定密钥（与 Swift `SealingFixtures` / TS `test/sealing.ts` 一致） ----
/** 组根密钥 K：0x00 … 0x1f。 */
export const FIXTURE_ROOT_KEY = Uint8Array.from({ length: 32 }, (_, i) => i);
/** Mac 配对 offer 的临时 X25519 私钥标量。 */
export const FIXTURE_MAC_PRIVATE = sha256("botbus-fixture-mac-key");
/** 手机封信封时的临时 X25519 私钥标量。 */
export const FIXTURE_PHONE_PRIVATE = sha256("botbus-fixture-phone-key");
/** 推送、通知信封等需要"本机 agentId"的地方统一用这台。 */
export const FIXTURE_AGENT_ID = "hV3nQ7pLxK2mR8sTfW4bZQ";

const INFO = {
  content: "botbus/v1/content",
  notify: "botbus/v1/notify",
  artifactId: "botbus/v1/artifact-id",
  keyEnvelope: "botbus/v1/key-envelope",
};

function sha256(text) {
  return new Uint8Array(createHash("sha256").update(text).digest());
}

export function base64url(bytes) {
  return Buffer.from(bytes).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function fromBase64url(text) {
  return new Uint8Array(Buffer.from(text.replace(/-/g, "+").replace(/_/g, "/"), "base64"));
}

/** HKDF-SHA256，salt 为空，32 字节。 */
export async function derive(root, info, salt = new Uint8Array(0)) {
  const ikm = await subtle.importKey("raw", root, "HKDF", false, ["deriveBits"]);
  const bits = await subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info: new TextEncoder().encode(info) }, ikm, 256);
  return new Uint8Array(bits);
}

/** fixture 专用 nonce：SHA256(aad) 前 12 字节。 */
export function fixtureNonce(aad) {
  return sha256(aad).slice(0, 12);
}

/** 生产环境的 nonce：每条随机。 */
export function randomNonce() {
  return webcrypto.getRandomValues(new Uint8Array(12));
}

let nonceFor = fixtureNonce;
/**
 * 生成 fixture 时用确定性 nonce（默认）；拿这个模块去跟真实 Relay 联调（`relay/scripts/smoke.mjs`）时
 * 必须先调它切成随机 nonce——同一把钥匙重复 nonce 会泄露明文。
 */
export function useRandomNonces() {
  nonceFor = randomNonce;
}

/** `0x01 ‖ nonce ‖ ct ‖ tag` 的 base64url。 */
export async function seal(key, plaintext, aad, nonce = nonceFor(aad)) {
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
  const ct = new Uint8Array(await subtle.encrypt(
    { name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(aad), tagLength: 128 }, k, plaintext));
  const out = new Uint8Array(1 + nonce.length + ct.length);
  out[0] = 0x01;
  out.set(nonce, 1);
  out.set(ct, 1 + nonce.length);
  return base64url(out);
}

export async function open(key, text, aad) {
  const bytes = fromBase64url(text);
  if (bytes[0] !== 0x01) throw new Error(`unsupported sealed format ${bytes[0]}`);
  const nonce = bytes.slice(1, 13);
  const k = await subtle.importKey("raw", key, "AES-GCM", false, ["decrypt"]);
  return new Uint8Array(await subtle.decrypt(
    { name: "AES-GCM", iv: nonce, additionalData: new TextEncoder().encode(aad), tagLength: 128 }, k, bytes.slice(13)));
}

/** 与 Swift `ProtocolJSON` 一致的规范 JSON：键排序、无空白。 */
export function canonical(value) {
  return JSON.stringify(sortKeys(value));
}

function sortKeys(value) {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sortKeys(value[k])]));
  }
  return value;
}

export async function sealJson(key, value, aad) {
  return seal(key, new TextEncoder().encode(canonical(value)), aad);
}

export async function openJson(key, text, aad) {
  return JSON.parse(new TextDecoder().decode(await open(key, text, aad)));
}

// ---- AAD（与 Swift `SealingContext` 一致） ----
export const aad = {
  task: (agentId, taskId) => `task:${agentId}:${taskId}`,
  agent: (agentId) => `agent:${agentId}`,
  projects: (agentId) => `projects:${agentId}`,
  messages: (agentId, taskId) => `messages:${agentId}:${taskId}`,
  command: (agentId, commandId) => `command:${agentId}:${commandId}`,
  result: (commandId) => `result:${commandId}`,
  notify: (agentId, taskId) => `notify:${agentId}:${taskId}`,
  clientName: "client",
  artifact: (agentId, artifactId) => `artifact:${agentId}:${artifactId}`,
  keyEnvelope: (agentId) => `key-envelope:${agentId}`,
};

// ---- 领域对象 → 密封形状（与 Swift `SealedTypes.swift` 一致） ----
export async function sealTask(key, task) {
  return { id: task.id, agentId: task.agentId, updatedAt: task.updatedAt, sealed: await sealJson(key, task, aad.task(task.agentId, task.id)) };
}

export async function sealAgent(key, agent) {
  return { agentId: agent.agentId, online: agent.online, lastSeenAt: agent.lastSeenAt, sealed: await sealJson(key, agent, aad.agent(agent.agentId)) };
}

export async function sealProjects(key, agentId, projects) {
  return { agentId, sealed: await sealJson(key, projects, aad.projects(agentId)) };
}

export async function sealMessages(key, messages) {
  return {
    taskId: messages.taskId, agentId: messages.agentId, fetchedAt: messages.fetchedAt,
    sealed: await sealJson(key, messages, aad.messages(messages.agentId, messages.taskId)),
  };
}

/** Relay 自己造的「过期」结果没有密钥，只能是明文 error；其余都是 Mac 密封的。 */
export async function sealResult(key, result) {
  if (result.ok === false && result.error === "expired" && result.taskId === undefined) {
    return { commandId: result.commandId, finishedAt: result.finishedAt, error: "expired" };
  }
  return { commandId: result.commandId, finishedAt: result.finishedAt, sealed: await sealJson(key, result, aad.result(result.commandId)) };
}

export async function sealNotify(notifyKey, notify, agentId) {
  const out = { taskId: notify.taskId, agentId, category: notify.category };
  if (notify.requestId !== undefined) out.requestId = notify.requestId;
  out.sealed = await sealJson(notifyKey, notify, aad.notify(agentId, notify.taskId));
  return out;
}

export async function sealSnapshot(key, snapshot) {
  const order = [];
  const grouped = new Map();
  for (const project of snapshot.projects) {
    if (!grouped.has(project.agentId)) { order.push(project.agentId); grouped.set(project.agentId, []); }
    grouped.get(project.agentId).push(project);
  }
  for (const agent of snapshot.agents) {
    if (!grouped.has(agent.agentId)) { order.push(agent.agentId); grouped.set(agent.agentId, []); }
  }
  return {
    agents: await Promise.all(snapshot.agents.map((a) => sealAgent(key, a))),
    tasks: await Promise.all(snapshot.tasks.map((t) => sealTask(key, t))),
    projects: await Promise.all(order.map((agentId) => sealProjects(key, agentId, grouped.get(agentId)))),
    recentResults: await Promise.all((snapshot.recentResults ?? []).map((r) => sealResult(key, r))),
    recentMessages: await Promise.all((snapshot.recentMessages ?? []).map((m) => sealMessages(key, m))),
    seq: snapshot.seq,
    generatedAt: snapshot.generatedAt,
  };
}

export async function sealCommand(key, command) {
  return { id: command.id, agentId: command.agentId, createdAt: command.createdAt, sealed: await sealJson(key, command, aad.command(command.agentId, command.id)) };
}

export async function sealEvent(keys, event, agentId = FIXTURE_AGENT_ID) {
  switch (event.kind) {
    case "snapshot": return { kind: "snapshot", snapshot: await sealSnapshot(keys.content, event.snapshot) };
    case "taskUpdated": return { kind: "taskUpdated", task: await sealTask(keys.content, event.task) };
    case "taskRemoved": return { kind: "taskRemoved", taskId: event.taskId };
    case "commandResult": return { kind: "commandResult", commandResult: await sealResult(keys.content, event.commandResult) };
    case "notify": return { kind: "notify", notify: await sealNotify(keys.notify, event.notify, agentId) };
    case "taskMessages": return { kind: "taskMessages", taskMessages: await sealMessages(keys.content, event.taskMessages) };
    default: throw new Error(`unknown event kind ${event.kind}`);
  }
}

// ---- X25519 密钥信封 ----
const PKCS8_X25519_PREFIX = Buffer.from("302e020100300506032b656e04220420", "hex");

export function x25519PrivateKey(scalar) {
  return createPrivateKey({ key: Buffer.concat([PKCS8_X25519_PREFIX, Buffer.from(scalar)]), format: "der", type: "pkcs8" });
}

export function x25519PublicRaw(privateKey) {
  const jwk = createPublicKey(privateKey).export({ format: "jwk" });
  return fromBase64url(jwk.x);
}

/** Mac 侧：用配对 offer 的临时私钥（`x25519PrivateKey(scalar)` 的结果）解开手机封来的 K。 */
export async function openKeyEnvelope(envelope, macPrivateKey, agentId) {
  const phonePublic = createPublicKey({ key: { kty: "OKP", crv: "X25519", x: envelope.epk }, format: "jwk" });
  const shared = new Uint8Array(diffieHellman({ privateKey: macPrivateKey, publicKey: phonePublic }));
  const wrapping = await derive(shared, INFO.keyEnvelope, x25519PublicRaw(macPrivateKey));
  return open(wrapping, envelope.sealed, aad.keyEnvelope(agentId));
}

export async function sealKeyEnvelope(rootKey, macPublicRaw, agentId, phonePrivateScalar) {
  const phoneKey = x25519PrivateKey(phonePrivateScalar);
  const macPublic = createPublicKey({
    key: { kty: "OKP", crv: "X25519", x: base64url(macPublicRaw) }, format: "jwk",
  });
  const shared = new Uint8Array(diffieHellman({ privateKey: phoneKey, publicKey: macPublic }));
  const wrapping = await derive(shared, INFO.keyEnvelope, macPublicRaw);
  return { epk: base64url(x25519PublicRaw(phoneKey)), sealed: await seal(wrapping, rootKey, aad.keyEnvelope(agentId)) };
}

// ---- 主流程 ----
function readPlain(name) {
  return JSON.parse(readFileSync(join(PLAIN, name), "utf8"));
}

function write(name, value) {
  writeFileSync(join(FIXTURES, name), `${JSON.stringify(value, null, 2)}\n`);
}

async function main() {
  const keys = {
    content: await derive(FIXTURE_ROOT_KEY, INFO.content),
    notify: await derive(FIXTURE_ROOT_KEY, INFO.notify),
  };
  const names = readdirSync(PLAIN).filter((n) => n.endsWith(".json"));
  let count = 0;
  for (const name of names) {
    const plain = readPlain(name);
    let sealed;
    if (name.startsWith("snapshot")) sealed = await sealSnapshot(keys.content, plain);
    else if (name.startsWith("task-")) sealed = await sealTask(keys.content, plain);
    else if (name.startsWith("command-")) sealed = await sealCommand(keys.content, plain);
    else if (name.startsWith("event-")) sealed = await sealEvent(keys, plain);
    else if (name === "frame-agent-event.json") sealed = { type: "event", event: await sealEvent(keys, plain.event) };
    else if (name === "frame-relay-command.json") sealed = { type: "command", command: await sealCommand(keys.content, plain.command) };
    else if (name === "frame-client-snapshot.json") sealed = { type: "snapshot", snapshot: await sealSnapshot(keys.content, plain.snapshot) };
    else continue; // agent-info、connector-info、artifact-*、working-changes 只有明文形状，不单独上线
    write(name, sealed);
    count++;
  }

  // 配对：密钥信封、hello 帧、认领请求与响应、手机列表。
  const macPublic = x25519PublicRaw(x25519PrivateKey(FIXTURE_MAC_PRIVATE));
  const envelope = await sealKeyEnvelope(FIXTURE_ROOT_KEY, macPublic, FIXTURE_AGENT_ID, FIXTURE_PHONE_PRIVATE);
  write("key-envelope.json", envelope);
  write("frame-relay-hello-with-key.json", { type: "hello", pairId: "pR4dT9wKmZ2xL7vQn3sB8A", keyEnvelope: envelope });
  const phoneName = await seal(keys.content, new TextEncoder().encode(canonical("Demo 的 iPhone")), aad.clientName);
  const spareName = await seal(keys.content, new TextEncoder().encode(canonical("备用机")), aad.clientName);
  write("relay-pair-claim-request.json", { code: "482913", sealedName: phoneName, keyEnvelope: envelope });
  write("relay-pair-claim-request-invite.json", { code: "731046", sealedName: phoneName });
  write("relay-pair-claim-response.json", {
    pairId: "Zm9vYmFyYmF6cXV4MTIzNA",
    clientToken: "Y2xpZW50LXNlY3JldC10b2tlbi0zMi1ieXRlcy1sb25nLWJhc2U2NHVybA",
    agents: [{ agentId: FIXTURE_AGENT_ID, online: false, lastSeenAt: "2026-09-17T08:06:00Z" }],
  });
  write("relay-pair-agents-response.json", {
    agent: { agentId: "Jc9dP1vNqY6gH0uEwS5tXo", online: false, lastSeenAt: "2026-09-17T08:12:00Z" },
  });
  write("relay-pair-clients-response.json", {
    clients: [
      { id: "c1RhbmRhcmQx", sealedName: phoneName, addedAt: "2026-09-17T08:06:00Z", current: true },
      { id: "c1RhbmRhcmQy", sealedName: spareName, addedAt: "2026-09-20T09:14:00Z", current: false },
      { id: "bGVnYWN5LTA", addedAt: "2026-09-01T00:00:00Z", current: false },
    ],
  });
  // 推送注册与电脑侧的设备表（3.0：设备名也是手机 / 手表自己封的密文，AAD 同手机名）。
  const sealName = (name) => seal(keys.content, new TextEncoder().encode(canonical(name)), aad.clientName);
  const watchName = await sealName("Demo 的 Apple Watch");
  const androidName = await sealName("Demo 的 Android");
  const oldPadName = await sealName("旧 iPad");
  write("relay-device-registration.json", {
    token: "7f3b2c1d9e8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b2c",
    platform: "ios", environment: "sandbox", sealedName: phoneName,
  });
  write("relay-device-registration-watch.json", {
    token: "0a9b8c7d6e5f4a3b2c1d0e9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d2e1f0a9b",
    platform: "watchos", environment: "production", sealedName: watchName,
  });
  write("relay-device-registration-android.json", {
    token: "fcm_registration_token_for_demo_android_1234567890",
    platform: "android", environment: "production", sealedName: androidName,
  });
  write("relay-agent-devices-response.json", {
    devices: [
      { sealedName: phoneName, platform: "ios", lastSeenAt: "2026-09-17T08:20:30Z", clientId: "c1RhbmRhcmQx" },
      { sealedName: watchName, platform: "watchos", lastSeenAt: "2026-09-17T08:19:00Z", clientId: "c1RhbmRhcmQx" },
      { sealedName: oldPadName, platform: "ios", lastSeenAt: "2026-09-10T02:00:00Z" },
      { sealedName: androidName, platform: "android", lastSeenAt: "2026-09-17T08:18:00Z", clientId: "c1RhbmRhcmQz" },
    ],
    clients: [
      { id: "c1RhbmRhcmQx", sealedName: phoneName, addedAt: "2026-09-17T08:06:00Z" },
      { id: "c1RhbmRhcmQy", sealedName: spareName, addedAt: "2026-09-20T09:14:00Z" },
      { id: "c1RhbmRhcmQz", sealedName: androidName, addedAt: "2026-09-21T09:14:00Z" },
    ],
  });
  console.log(`sealed ${count} fixtures + pairing fixtures into ${FIXTURES}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  await main();
}
