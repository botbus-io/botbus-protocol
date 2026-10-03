#!/usr/bin/env node
// 远程操作查看页的加密层与参考实现互通检查（协议 3.0 第四期）。
//
// 从 `Sources/BotBusProtocol/RemoteControlPage.swift` 里原样抽出页面的
// 「端到端加密」那段 JS，在 Node 的 WebCrypto 上跑：页面封的输入，参考实现（seal-fixtures.mjs，
// 已与 Swift 的 CryptoKit 逐字节一致）解得开；参考实现封的画面包与 JSON，页面解得开。
// 改了页面的加密层就跑一次：node scripts/check-remote-page-crypto.mjs（Node 22）。
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { derive, open, seal, useRandomNonces, base64url } from "./seal-fixtures.mjs";

useRandomNonces();
const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const source = readFileSync(join(ROOT, "Sources/BotBusProtocol/RemoteControlPage.swift"), "utf8");
const start = source.indexOf("// ---------- 端到端加密（协议 3.0） ----------");
const end = source.indexOf("// ---------- 画面 ----------");
if (start < 0 || end < 0) throw new Error("页面里找不到加密层的标记");
const block = source.slice(start, end);

const rcKey = await derive(crypto.getRandomValues(new Uint8Array(32)), "botbus/v1/remote-control");
const agentId = "hV3nQ7pLxK2mR8sTfW4bZQ";
globalThis.window = { __botbus: { key: base64url(rcKey), agentId } };
const page = new Function(`${block}; return { rcReady, rcSeal, rcOpen, b64uEncode, b64uDecode, openJSON, newChannel };`)();
if (!(await page.rcReady())) throw new Error("页面没认出注入的密钥");
const aad = `rc:${agentId}`;
const enc = new TextEncoder(), dec = new TextDecoder();

// 页面 → Mac：输入。
const input = JSON.stringify({ text: "hunter2", p: "/type", t: Date.now() });
const sealedByPage = page.b64uEncode(await page.rcSeal(enc.encode(input)));
const openedByReference = dec.decode(await open(rcKey, sealedByPage, aad));
if (openedByReference !== input) throw new Error("参考实现解不开页面封的输入");

// Mac → 页面：画面包（原始字节）与 JSON。
const packet = Uint8Array.from([1, 0xde, 0xad, 0xbe, 0xef]);
const sealedPacket = (await seal(rcKey, packet, aad));
const openedPacket = await page.rcOpen(page.b64uDecode(sealedPacket));
if (Buffer.compare(Buffer.from(openedPacket), Buffer.from(packet)) !== 0) throw new Error("页面解不开画面包");
const json = { armed: true, displays: [] };
const response = { json: async () => ({ sealed: await seal(rcKey, enc.encode(JSON.stringify(json)), aad) }) };
const openedJSON = await page.openJSON(response);
if (JSON.stringify(openedJSON) !== JSON.stringify(json)) throw new Error("页面解不开 JSON");

// 3.7：带通道号的请求，回复钉在请求上。
const channel = page.newChannel();
if (page.b64uDecode(channel).length !== 16 || channel.length !== 22) throw new Error("通道号不是 16 字节的 base64url");
const stamp = Date.now();
const boundAAD = `rc:${agentId}:res:${channel}:${stamp}`;
const bound = { json: async () => ({ sealed: await seal(rcKey, enc.encode(JSON.stringify(json)), boundAAD) }) };
const openedBound = await page.openJSON(bound, enc.encode(boundAAD));
if (JSON.stringify(openedBound) !== JSON.stringify(json)) throw new Error("页面解不开钉在请求上的回复");
let swapped = false;
try { await page.openJSON(bound, enc.encode(`rc:${agentId}:res:${channel}:${stamp + 1}`)); } catch { swapped = true; }
if (!swapped) throw new Error("页面收下了别的请求的回复");

// 别的电脑（别的 AAD）封的：页面不认。
let rejected = false;
try { await page.rcOpen(page.b64uDecode(await seal(rcKey, packet, "rc:other"))); } catch { rejected = true; }
if (!rejected) throw new Error("页面收下了钉在别的电脑上的密文");

console.log("remote page crypto OK");
