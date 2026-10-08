import Foundation

/// 远程操作的查看页（协议 2.12，3.0 起端到端加密）。内嵌而不是放 bundle 资源：这样 Swift Package 和 Xcode 工程
/// 都不用额外配 resources，也不会出现「装好的 app 里少了一个文件」这种事。
///
/// 放在 Protocol 包里是因为它就是这条链路的另一端实现：**手机从 app 包里加载这一份**（`loadHTMLString`，
/// base URL 指向预览主机），不从 Relay 取——页面若经 Relay 送来，Relay 改一行 JS 就能把密钥带走。
/// Mac 的本机服务在 `/` 上也回它，只给本机调试用。Android、Windows 照同一份做（`loadDataWithBaseURL` 同理）。
///
/// 密钥由 app 在页面加载前注入：`window.__botbus = {key: <K_rc 的 base64url>, agentId}`，不经 URL、不落盘。
/// 3.7：`window.__botbus.embedded = true` 表示嵌在原生的「操作电脑」页里（锁由原生页头管，页面藏起解锁按钮）；
/// 电脑的 `/status` 报了 `features` 时，输入另带通道号 `c`，回复钉在请求上（`SealingContext.remoteControlResponse`）。
/// 画面包、状态、无障碍树、焦点都是密文（`0x01 ‖ nonce ‖ AES-256-GCM 密文 ‖ tag`，AAD `rc:<agentId>`），
/// 输入封好再发，里面带请求路径 `p` 与严格递增的毫秒时间戳 `t`，Mac 据此挡住挪用与重放。
///
/// 画面走 `fetch('/stream')` 的 `ReadableStream` + WebCodecs `VideoDecoder`。
/// **已验证**：Safari 26.6 能解本机 VideoToolbox 编出来的 AVCC 流（52 帧零错误）。
/// 浏览器没有 `VideoDecoder` 时页面会明说，而不是白屏。
public enum RemoteControlPage {
    public static let html = #"""
<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=5,user-scalable=yes">
<title>远程操作</title>
<style>
  :root { --amber:#d98c2b; --bg:#121212; --panel:#1c1c1c; --line:#2c2c2c;
          --dim:#8a8a8a; --text:#e8e8e8; --warn:#e07b5a; }
  * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
  html,body { margin:0; background:var(--bg); color:var(--text);
              font:14px/1.45 -apple-system,system-ui,sans-serif; }
  header { display:flex; align-items:center; gap:8px; padding:8px 12px; background:var(--panel);
           border-bottom:1px solid var(--line); position:sticky; top:0; z-index:10; }
  header b { font-size:13px; font-weight:600; }
  .pill { font-size:11px; padding:3px 8px; border-radius:999px; border:1px solid var(--line);
          color:var(--dim); white-space:nowrap; }
  .pill.live { color:var(--amber); border-color:var(--amber); }
  .pill.warn { color:var(--warn); border-color:var(--warn); }
  .grow { flex:1; }
  button { font:inherit; border-radius:7px; border:1px solid var(--line);
           background:#262626; color:var(--text); padding:7px 11px; }
  button:active { background:#333; }
  button.on { background:var(--amber); color:#1a1200; border-color:var(--amber); font-weight:600; }
  button.sm { padding:4px 9px; font-size:12px; }
  #stage { position:relative; overflow:hidden; touch-action:none; background:#000; }
  #screen { display:block; width:100%; transform-origin:0 0; will-change:transform; }
  #ring { position:absolute; border:2px solid var(--amber); border-radius:4px;
          pointer-events:none; opacity:0; transition:opacity .3s; }
  #mode { position:absolute; left:8px; top:8px; font-size:11px; padding:3px 8px;
          border-radius:999px; background:rgba(0,0,0,.65); color:var(--amber);
          opacity:0; transition:opacity .15s; pointer-events:none; }
  #zoomTag { position:absolute; right:8px; top:8px; font-size:11px; padding:3px 8px;
             border-radius:999px; background:rgba(0,0,0,.65); color:var(--text);
             display:none; pointer-events:none; }
  #log { padding:6px 12px; font-size:11px; color:var(--dim); min-height:20px;
         white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  #keys { display:flex; gap:6px; padding:0 12px 8px; overflow-x:auto; }
  #keys button { flex:none; }
  footer { display:flex; gap:7px; padding:9px 12px calc(9px + env(safe-area-inset-bottom));
           background:var(--panel); border-top:1px solid var(--line);
           position:sticky; bottom:0; z-index:10; }
  #text { flex:1; min-width:0; padding:9px 11px; border-radius:7px;
          border:1px solid var(--line); background:#181818; color:var(--text); font:inherit; }
  #text:focus { outline:none; border-color:var(--amber); }
  #panel { display:none; max-height:45vh; overflow-y:auto; background:var(--panel);
           border-bottom:1px solid var(--line); }
  #panel.open { display:block; }
  .el { display:flex; gap:8px; align-items:baseline; padding:9px 12px; border-bottom:1px solid #242424; }
  .el:active { background:#262626; }
  .el .role { font-size:10px; color:var(--dim); flex:none; }
  .el .label { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  #settings { display:none; gap:10px; padding:10px 12px; background:var(--panel);
              border-bottom:1px solid var(--line); flex-wrap:wrap; align-items:center; font-size:12px; }
  #settings.open { display:flex; }
  #settings label { color:var(--dim); }
  input[type=range] { accent-color:var(--amber); width:104px; vertical-align:middle; }
  #fatal { padding:20px 14px; color:var(--warn); line-height:1.6; display:none; }
</style></head><body>

<header>
  <b>远程操作</b>
  <span class="pill" id="perm">…</span>
  <span class="grow"></span>
  <button class="sm" id="armBtn">解锁输入</button>
  <button class="sm" id="panelBtn">元素</button>
  <button class="sm" id="gearBtn">⚙</button>
</header>

<div id="settings">
  <label>画质 <input type="range" id="bitrate" min="500" max="6000" step="250" value="2000"></label>
  <label>宽度 <input type="range" id="width" min="800" max="2000" step="80" value="1280"></label>
  <label>帧率 <input type="range" id="fps" min="2" max="20" step="1" value="10"></label>
  <span id="stat" style="color:var(--dim)"></span>
  <span id="screens"></span>
</div>

<div id="panel"></div>
<div id="fatal"></div>

<div id="stage">
  <canvas id="screen"></canvas>
  <div id="ring"></div>
  <div id="mode">拖拽</div>
  <div id="zoomTag"></div>
</div>

<div id="log"></div>
<div id="keys">
  <button class="sm mod" data-mod="cmd">⌘</button>
  <button class="sm mod" data-mod="shift">⇧</button>
  <button class="sm mod" data-mod="alt">⌥</button>
  <button class="sm mod" data-mod="ctrl">⌃</button>
  <button class="sm" data-key="escape">esc</button>
  <button class="sm" data-key="tab">⇥</button>
  <button class="sm" data-key="delete">⌫</button>
  <button class="sm" data-key="up">↑</button>
  <button class="sm" data-key="down">↓</button>
  <button class="sm" data-key="left">←</button>
  <button class="sm" data-key="right">→</button>
</div>

<footer>
  <input id="text" placeholder="输入文字，按发送" autocapitalize="off" autocorrect="off" spellcheck="false">
  <button id="send" class="on">发送</button>
  <button id="enter" data-key="return">↵</button>
</footer>

<script>
const $ = id => document.getElementById(id);
const log = m => $('log').textContent = m;

// ---------- 端到端加密（协议 3.0） ----------
// 密钥由 BotBus app 在加载前注入；直接在浏览器里打开这个页面时没有它，什么都解不开，也什么都发不出去。
const BB = window.__botbus || null;
const te = new TextEncoder(), td = new TextDecoder();
let rcKey = null, lastStamp = 0, rcChannel = null;
function b64uDecode(s) {
  s = s.replace(/-/g, '+').replace(/_/g, '/'); while (s.length % 4) s += '=';
  return Uint8Array.from(atob(s), c => c.charCodeAt(0));
}
function b64uEncode(bytes) {
  let s = ''; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const rcAAD = () => te.encode('rc:' + BB.agentId);
async function rcReady() {
  if (rcKey) return true;
  if (!BB || !BB.key || !BB.agentId) return false;
  rcKey = await crypto.subtle.importKey('raw', b64uDecode(BB.key), 'AES-GCM', false, ['encrypt', 'decrypt']);
  return true;
}
async function rcOpen(bytes, aad) {
  if (bytes[0] !== 1) throw new Error('sealed format');
  return new Uint8Array(await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: bytes.slice(1, 13), additionalData: aad || rcAAD(), tagLength: 128 }, rcKey, bytes.slice(13)));
}
async function rcSeal(bytes, aad) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv, additionalData: aad || rcAAD(), tagLength: 128 }, rcKey, bytes));
  const out = new Uint8Array(13 + ct.length);
  out[0] = 1; out.set(iv, 1); out.set(ct, 13);
  return out;
}
// 3.7：电脑报了 features 才带通道号；带了通道号的请求，回复钉在那条请求上。
function newChannel() { return b64uEncode(crypto.getRandomValues(new Uint8Array(16))); }
// 回来的 JSON 是 {"sealed": "..."}：解开后才是真的内容。`aad` 省略时用旧的 rc:<agentId>。
async function openJSON(response, aad) {
  const wrapper = await response.json();
  return JSON.parse(td.decode(await rcOpen(b64uDecode(wrapper.sealed), aad)));
}
async function getJSON(path) { return openJSON(await fetch(path)); }

let pointWidth = 0, pointHeight = 0;   // 远端显示器的逻辑尺寸，手势坐标按它换算
let displayId = null, displays = [];
let isArmed = false, bytesIn = 0, framesOut = 0;

// ---------- 画面 ----------
const canvas = $('screen');
const ctx = canvas.getContext('2d');
let decoder = null, streamAbort = null, restartTimer = null;
// 重连退避：0.8 秒起翻倍到 30 秒，乘 0.5–1.5 的抖动；一条流活够 10 秒才从头算。
// 预览过期或被拒（401 / 403 / 404）不再重试：停掉所有定时器，回到 app 重新打开。
let streamFailures = 0, streamOpenedAt = 0, stopped = false, statusTimer = null;
const GONE = [401, 403, 404];

function fatal(message) {
  $('fatal').style.display = 'block';
  $('fatal').textContent = message;
  $('stage').style.display = 'none';
}

function concat(a, b) {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0); out.set(b, a.length);
  return out;
}

async function configureDecoder(header, avcc) {
  if (decoder) { try { decoder.close(); } catch (e) {} }
  canvas.width = header.width;
  canvas.height = header.height;
  decoder = new VideoDecoder({
    output: frame => {
      framesOut++;
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
      frame.close();
    },
    error: e => { log('解码出错，正在重连…'); restartStream(); }
  });
  decoder.configure({
    codec: header.codec, description: avcc,
    codedWidth: header.width, codedHeight: header.height,
    optimizeForLatency: true
  });
}

function restartStream() {
  if (restartTimer || stopped) return;
  if (streamOpenedAt && Date.now() - streamOpenedAt >= 10000) streamFailures = 0;
  streamOpenedAt = 0;
  const delay = Math.min(30000, 800 * Math.pow(2, streamFailures)) * (0.5 + Math.random());
  streamFailures++;
  restartTimer = setTimeout(() => { restartTimer = null; openStream(); }, delay);
}

function stopAll() {
  stopped = true;
  if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
  if (statusTimer) { clearInterval(statusTimer); statusTimer = null; }
  if (streamAbort) { streamAbort.abort(); streamAbort = null; }
  if (decoder) { try { decoder.close(); } catch (e) {} decoder = null; }
  fatal('预览链接已失效：请回到 BotBus 重新打开预览。');
}

async function openStream() {
  if (stopped) return;
  if (restartTimer) { clearTimeout(restartTimer); restartTimer = null; }
  if (!(await rcReady())) {
    fatal('请在 BotBus app 里打开远程操作：画面是端到端加密的，浏览器里没有密钥。');
    return;
  }
  if (typeof VideoDecoder === 'undefined') {
    fatal('这个浏览器不支持 WebCodecs，放不了画面。iOS 请用 Safari 16.4 以上。');
    return;
  }
  if (streamAbort) { streamAbort.abort(); streamAbort = null; }
  const controller = new AbortController();
  streamAbort = controller;

  const params = new URLSearchParams({
    w: $('width').value, fps: $('fps').value,
    bitrate: String(+$('bitrate').value * 1000)
  });
  if (displayId !== null) params.set('display', displayId);

  let response;
  try {
    response = await fetch('/stream?' + params, { signal: controller.signal });
  } catch (e) { if (!controller.signal.aborted) restartStream(); return; }
  if (GONE.includes(response.status)) { stopAll(); return; }
  if (!response.ok || !response.body) { restartStream(); return; }
  streamOpenedAt = Date.now();

  const reader = response.body.getReader();
  let buf = new Uint8Array(0);
  let timestamp = 0;
  const frameDuration = Math.round(1e6 / +$('fps').value);

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytesIn += value.length;
      buf = concat(buf, value);

      // 包格式：[u32 大端 长度][密封的 [u8 类型][负载]]
      while (buf.length >= 5) {
        const view = new DataView(buf.buffer, buf.byteOffset, buf.length);
        const length = view.getUint32(0);
        if (buf.length < 4 + length) break;
        const plain = await rcOpen(buf.slice(4, 4 + length));
        buf = buf.slice(4 + length);
        const kind = plain[0];
        const payload = plain.slice(1);

        if (kind === 0) {
          const headerLength = (payload[0] << 8) | payload[1];
          const header = JSON.parse(new TextDecoder().decode(payload.slice(2, 2 + headerLength)));
          await configureDecoder(header, payload.slice(2 + headerLength));
        } else if (decoder && decoder.state === 'configured') {
          try {
            decoder.decode(new EncodedVideoChunk({
              type: kind === 1 ? 'key' : 'delta',
              timestamp, duration: frameDuration, data: payload
            }));
            timestamp += frameDuration;
          } catch (e) { log('丢帧，等下一个关键帧'); }
        }
      }
    }
  } catch (e) {
    if (!controller.signal.aborted) restartStream();
    return;
  }
  if (!controller.signal.aborted) restartStream();
}

// ---------- 状态 ----------
async function refreshStatus() {
  try {
    if (stopped || !(await rcReady())) return;
    const response = await fetch('/status');
    if (GONE.includes(response.status)) { stopAll(); return; }
    if (stopped) return;
    const s = await openJSON(response);
    if (s.features && !rcChannel) rcChannel = newChannel();
    displays = s.displays || [];
    if (displayId === null && displays.length) displayId = displays[0].id;
    const display = displays.find(d => d.id === displayId) || displays[0];
    if (display) { pointWidth = display.width; pointHeight = display.height; }
    if (s.armed !== isArmed) { isArmed = s.armed; hint(); }

    const perm = $('perm');
    if (!s.screenCapture) { perm.textContent = '缺录屏权限'; perm.className = 'pill warn'; }
    else if (!s.accessibility) { perm.textContent = '只读 · 缺辅助功能权限'; perm.className = 'pill warn'; }
    else if (!s.armed) { perm.textContent = '输入已锁定'; perm.className = 'pill'; }
    else { perm.textContent = s.secureInput ? '已解锁 · 密码框' : '已解锁'; perm.className = 'pill live'; }

    $('armBtn').textContent = s.armed ? '锁定输入' : '解锁输入';
    $('armBtn').className = 'sm' + (s.armed ? ' on' : '');

    if (displays.length > 1) {
      $('screens').innerHTML = displays.map(d =>
        '<button class="sm scr' + (d.id === displayId ? ' on' : '') + '" data-id="' + d.id + '">' +
        d.width + '×' + d.height + '</button>').join(' ');
    }
  } catch (e) {}
}

setInterval(() => {
  $('stat').textContent = (bytesIn / 1024).toFixed(0) + ' KB · ' + framesOut + ' 帧';
  bytesIn = 0; framesOut = 0;
}, 1000);

// ---------- 坐标与手势 ----------
function toPoint(clientX, clientY) {
  const rect = canvas.getBoundingClientRect();
  return {
    x: (clientX - rect.left) / rect.width * pointWidth,
    y: (clientY - rect.top) / rect.height * pointHeight
  };
}

function flash(clientX, clientY) {
  const rect = stage.getBoundingClientRect(), ring = $('ring');
  ring.style.left = (clientX - rect.left - 15) + 'px';
  ring.style.top = (clientY - rect.top - 15) + 'px';
  ring.style.width = ring.style.height = '30px';
  ring.style.opacity = 1;
  setTimeout(() => ring.style.opacity = 0, 380);
}

const activeMods = () => [...document.querySelectorAll('.mod.on')].map(b => b.dataset.mod).join(',');
const clearMods = () => document.querySelectorAll('.mod.on').forEach(b => b.classList.remove('on'));

// 输入封好再发：路径 p 与严格递增的时间戳 t 进密文，Mac 据此拒绝被挪用、被重放的请求。
// 3.7 的电脑另带通道号 c：防重放按通道记，回复钉在这条请求上。
async function call(path, body) {
  if (!(await rcReady())) return null;
  lastStamp = Math.max(lastStamp + 1, Date.now());
  const stamp = lastStamp, channel = rcChannel;
  const fields = { p: path, t: stamp };
  if (channel) fields.c = channel;
  const plain = JSON.stringify(Object.assign({}, body || {}, fields));
  const sealed = b64uEncode(await rcSeal(te.encode(plain)));
  const response = await fetch(path, { method: 'POST', body: JSON.stringify({ sealed }) });
  if (!response.ok) return null;
  return openJSON(response, channel ? te.encode('rc:' + BB.agentId + ':res:' + channel + ':' + stamp) : undefined);
}

// 焦点决定手机怎么弹键盘。Chrome 不给网页内容建 AX 树，读不到焦点是常态，
// 这时靠 secureInput 判断是不是密码框——它对所有 app 都准。
function applyFocus(f) {
  if (!f) return;
  if (f.locked) { log('输入已锁定 — 点右上角解锁'); return; }
  if (f.trusted === false) { log('发不出去：缺辅助功能权限'); return; }
  const field = $('text');
  if (f.isSecure || f.secureInput) {
    field.type = 'password';
    field.setAttribute('autocomplete', 'current-password');
    field.focus();
    log('密码框 · 可用 iPhone 钥匙串填充');
  } else if (f.isTextField) {
    field.type = 'text';
    field.removeAttribute('autocomplete');
    field.focus();
    log('输入框' + (f.title ? ' · ' + f.title : ''));
  } else if (f.focused) {
    log('焦点：' + (f.role || '?') + (f.title ? ' · ' + f.title : ''));
  } else {
    field.type = 'text';
    log('已点击（这个 app 不暴露辅助功能树，用下面的键盘打字）');
  }
}

// ---------- 手势 ----------
// 双指永远是缩放与平移画面，锁不锁输入都一样；单指看输入锁：锁着时拖动画面、双击复原，
// 解锁后直接当鼠标（点 = 点击、划 = 滚动、长按后拖 = 拖拽）。画面缩放只是本地的
// CSS transform，toPoint 读的 getBoundingClientRect 已含变换，点到哪就是远端哪。
const stage = $('stage');
let view = { s: 1, x: 0, y: 0 };            // canvas 相对 stage：先平移再缩放
const MAX_ZOOM = 5;

function clampView() {
  const w = stage.clientWidth, h = stage.clientHeight;
  view.s = Math.min(MAX_ZOOM, Math.max(1, view.s));
  view.x = Math.min(0, Math.max(w - w * view.s, view.x));
  view.y = Math.min(0, Math.max(h - h * view.s, view.y));
}

function applyView() {
  clampView();
  canvas.style.transform = view.s === 1 ? '' :
    'translate(' + view.x + 'px,' + view.y + 'px) scale(' + view.s + ')';
  const tag = $('zoomTag');
  tag.style.display = view.s > 1.01 ? 'block' : 'none';
  tag.textContent = view.s.toFixed(1) + '×';
}

new ResizeObserver(applyView).observe(stage);

function hint() {
  if (isArmed) log('单指点 = 点击 · 单指划 = 滚动 · 长按后拖 = 拖拽 · 双指缩放');
  else log('输入已锁定：单指拖动画面 · 双指缩放 · 双击复原');
}

const pointers = new Map();                 // pointerId → {x, y}，stage 内坐标
let gesture = null;                         // 'pan' | 'pinch' | 'input'
let panFrom = null, pinchFrom = null, lastTap = 0;
let start = null, moved = false, dragMode = false, holdTimer = null, lastScroll = 0, acc = { x: 0, y: 0 };

function local(ev) {
  const rect = stage.getBoundingClientRect();
  return { x: ev.clientX - rect.left, y: ev.clientY - rect.top };
}

function beginPan(id, p, moved) {
  gesture = 'pan';
  panFrom = { id, px: p.x, py: p.y, vx: view.x, vy: view.y, t: Date.now(), moved: !!moved };
}

function beginPinch() {
  const [a, b] = [...pointers.values()];
  const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
  gesture = 'pinch';
  pinchFrom = {
    d: Math.max(1, Math.hypot(a.x - b.x, a.y - b.y)), s: view.s,
    // 两指中点下面那一点在未缩放画面上的位置，缩放时让它跟着手指走
    cx: (mx - view.x) / view.s, cy: (my - view.y) / view.s
  };
}

function cancelInput() {
  clearTimeout(holdTimer);
  $('mode').style.opacity = 0;
  start = null; gesture = null;
}

stage.addEventListener('pointerdown', ev => {
  if (ev.pointerType === 'mouse' && ev.button !== 0) return;
  if (gesture === 'input') {
    // 已经进了长按拖拽就只认第一根手指，别让误碰的第二根把拖拽冲掉；
    // 否则第二根手指落下就是双指缩放，这次点击 / 滚动作废（点击在抬手时才发，还没发出去）
    if (dragMode) return;
    cancelInput();
  }
  pointers.set(ev.pointerId, local(ev));
  try { stage.setPointerCapture(ev.pointerId); } catch (e) {}

  if (pointers.size === 2) { beginPinch(); return; }
  if (pointers.size !== 1) return;

  if (!isArmed) { beginPan(ev.pointerId, local(ev)); return; }

  gesture = 'input';
  start = { id: ev.pointerId, x: ev.clientX, y: ev.clientY, t: Date.now(), lastX: ev.clientX, lastY: ev.clientY };
  moved = false; dragMode = false; acc = { x: 0, y: 0 };
  holdTimer = setTimeout(() => {
    dragMode = true;
    $('mode').style.opacity = 1;
    if (navigator.vibrate) navigator.vibrate(18);
  }, 500);
});

stage.addEventListener('pointermove', ev => {
  if (!pointers.has(ev.pointerId)) return;
  const p = local(ev);
  pointers.set(ev.pointerId, p);
  if (gesture === 'input') { inputMove(ev); return; }

  if (gesture === 'pinch' && pointers.size >= 2) {
    const [a, b] = [...pointers.values()];
    const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
    view.s = Math.min(MAX_ZOOM, Math.max(1, pinchFrom.s * Math.hypot(a.x - b.x, a.y - b.y) / pinchFrom.d));
    view.x = mx - pinchFrom.cx * view.s;
    view.y = my - pinchFrom.cy * view.s;
    applyView();
  } else if (gesture === 'pan' && ev.pointerId === panFrom.id) {
    if (Math.hypot(p.x - panFrom.px, p.y - panFrom.py) > 8) panFrom.moved = true;
    view.x = panFrom.vx + p.x - panFrom.px;
    view.y = panFrom.vy + p.y - panFrom.py;
    applyView();
  }
});

function inputMove(ev) {
  if (!start || ev.pointerId !== start.id) return;
  if (!moved && Math.hypot(ev.clientX - start.x, ev.clientY - start.y) > 8) {
    moved = true; clearTimeout(holdTimer);
  }
  if (!moved || dragMode) return;

  const rect = canvas.getBoundingClientRect();
  acc.x += (ev.clientX - start.lastX) / rect.width * pointWidth;
  acc.y += (ev.clientY - start.lastY) / rect.height * pointHeight;
  start.lastX = ev.clientX; start.lastY = ev.clientY;

  const now = Date.now();
  if (now - lastScroll > 60 && (Math.abs(acc.x) > 1 || Math.abs(acc.y) > 1)) {
    lastScroll = now;
    const p = toPoint(start.x, start.y);
    call('/scroll', { x: p.x, y: p.y, dx: Math.round(acc.x), dy: Math.round(acc.y), mods: activeMods() });
    acc = { x: 0, y: 0 };
  }
}

async function inputUp(ev) {
  if (!start || ev.pointerId !== start.id) return;
  clearTimeout(holdTimer);
  $('mode').style.opacity = 0;
  const from = start, held = Date.now() - start.t;
  start = null; gesture = null;

  if (dragMode) {
    const a = toPoint(from.x, from.y), b = toPoint(ev.clientX, ev.clientY);
    log('拖拽…');
    applyFocus(await call('/drag', { x1: a.x, y1: a.y, x2: b.x, y2: b.y, mods: activeMods() }));
  } else if (!moved && held < 700) {
    flash(ev.clientX, ev.clientY);
    const p = toPoint(ev.clientX, ev.clientY);
    applyFocus(await call('/click', { x: p.x, y: p.y, mods: activeMods() }));
    clearMods();
  }
}

function viewUp(ev) {
  if (!pointers.delete(ev.pointerId)) return;
  // 抬起一指后剩下那根接着拖，不跳
  if (gesture === 'pinch' || (gesture === 'pan' && ev.pointerId === panFrom.id && pointers.size)) {
    const [id, p] = pointers.entries().next().value || [];
    if (id !== undefined) beginPan(id, p, true); else gesture = null;
    return;
  }
  if (gesture !== 'pan' || pointers.size) return;
  gesture = null;
  if (panFrom.moved || Date.now() - panFrom.t > 700) return;

  // 轻点：锁着时双击复原缩放，单击提示怎么才能点（解锁后单指是鼠标，走不到这里）
  if (isArmed) return;
  const now = Date.now();
  if (view.s > 1.01 && now - lastTap < 320) {
    view = { s: 1, x: 0, y: 0 }; applyView(); lastTap = 0;
  } else {
    lastTap = now;
    log('输入已锁定 — 点右上角「解锁输入」后才能点击');
  }
}

stage.addEventListener('pointerup', ev => {
  if (gesture === 'input') { pointers.delete(ev.pointerId); inputUp(ev); } else viewUp(ev);
});

stage.addEventListener('pointercancel', ev => {
  pointers.delete(ev.pointerId);
  if (gesture === 'input' && start && ev.pointerId === start.id) { cancelInput(); return; }
  if (!pointers.size) gesture = null;
});

// ---------- 文字与按键 ----------
async function send() {
  const field = $('text');
  if (!field.value) return;
  const result = await call('/type', { text: field.value });
  if (result && result.locked) { log('输入已锁定'); return; }
  log('已输入 ' + field.value.length + ' 个字符');
  field.value = '';
}
$('send').onclick = send;
$('text').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); send(); } });

document.addEventListener('click', async ev => {
  const mod = ev.target.closest('.mod');
  if (mod) { mod.classList.toggle('on'); return; }

  const key = ev.target.closest('[data-key]');
  if (key) {
    const result = await call('/key', { key: key.dataset.key, mods: activeMods() });
    if (result && result.locked) log('输入已锁定'); else log('按下 ' + key.dataset.key);
    clearMods();
    return;
  }

  const screen = ev.target.closest('.scr');
  if (screen) { displayId = +screen.dataset.id; refreshStatus(); openStream(); return; }

  const element = ev.target.closest('.el');
  if (element && element.dataset.x !== undefined) {
    const result = await call('/press', { x: +element.dataset.x, y: +element.dataset.y });
    log(result && result.method === 'pressed' ? '已按下（AXPress）' : '已点击（坐标回落）');
    $('panel').classList.remove('open');
  }
});

// ---------- 元素面板 ----------
$('panelBtn').onclick = async () => {
  const panel = $('panel');
  if (panel.classList.contains('open')) { panel.classList.remove('open'); return; }
  panel.innerHTML = '<div class="el"><span class="label">读取中…</span></div>';
  panel.classList.add('open');
  const data = await getJSON('/elements');
  if (!data.trusted) {
    panel.innerHTML = '<div class="el"><span class="label">需要辅助功能权限</span></div>';
    return;
  }
  const rows = (data.elements || []).filter(e => e.label);
  panel.innerHTML =
    '<div class="el"><span class="role">窗口</span><span class="label">' +
      (data.app || '') + ' · ' + (data.title || '') + '</span></div>' +
    (rows.length ? rows.map(e =>
      '<div class="el" data-x="' + e.x + '" data-y="' + e.y + '">' +
      '<span class="role">' + e.role.replace('AX', '') + '</span>' +
      '<span class="label">' + e.label.replace(/</g, '&lt;') + '</span></div>').join('')
      : '<div class="el"><span class="label">这个窗口没暴露可点元素</span></div>');
};

$('gearBtn').onclick = () => $('settings').classList.toggle('open');
$('armBtn').onclick = async () => {
  const s = await call('/arm', { on: !isArmed });
  if (!s) { log('发不出去，稍后再试'); return; }
  isArmed = s.armed;
  log(isArmed ? '输入已解锁（10 分钟无操作自动锁回）' : '输入已锁定：单指拖动画面');
  refreshStatus();
};

for (const id of ['width', 'fps', 'bitrate']) {
  $(id).addEventListener('change', () => openStream());
}

// 嵌在「操作电脑」页里时锁由原生页头管：藏起自己的解锁按钮和标题。单独打开（旧客户端、自动开的预览）不受影响。
if (BB && BB.embedded) {
  $('armBtn').style.display = 'none';
  document.querySelector('header b').style.display = 'none';
}

hint();
refreshStatus();
openStream();
// 页面在后台时不问状态；回到前台立刻问一次。
statusTimer = setInterval(() => { if (!document.hidden) refreshStatus(); }, 4000);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && !stopped) { refreshStatus(); openStream(); }
});
</script></body></html>
"""#
}
