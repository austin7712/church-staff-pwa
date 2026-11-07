// IPCF 同工 LINE 服事提醒
//
// 單一檔案的 Cloudflare Worker，可直接貼進 Cloudflare 後台的程式編輯器。
//
// 功能：
//   1. LINE webhook：同工對官方帳號傳「綁定 名字」，把 LINE 帳號和服事表上的名字對起來。
//      也支援「解除綁定」、「我的服事」、「說明」、「換班」、「申請進度」。回覆訊息不計入 LINE 免費額度。
//   2. 排程（Cron）：每週三、週六晚上 8 點（教會時區）讀 Firestore 服事表，
//      只私訊接下來 4 天內有服事的人。
//   3. 管理用網址（加 ?key=ADMIN_KEY）：/admin/preview 預覽會發給誰（不發送）、/admin/run 立即發送、
//      /admin/richmenu 建立下方圖文選單（我的服事／本週服事表／換班代班／申請進度／使用說明／開啟同工 App）。
//   4. 換班／代班：LINE 裡申請，App 管理者用 /api/swaps 核准（見「換班／代班」一節）。
//
// 需要的設定（Cloudflare Worker → Settings）：
//   KV 綁定        BINDINGS
//   變數           FIREBASE_PROJECT_ID、FIREBASE_API_KEY、SITE_URL、TIME_ZONE（預設 America/Los_Angeles）
//   Secrets        LINE_CHANNEL_SECRET、LINE_CHANNEL_ACCESS_TOKEN、ADMIN_KEY、
//                  BOT_EMAIL、BOT_PASSWORD（App 裡一個一般同工帳號，用來讀服事表）
//                  （或改用 GOOGLE_SERVICE_ACCOUNT_JSON：需 Cloud Datastore Viewer 權限的服務帳戶）
//   Cron Triggers  0 3 * * 4,0   和   0 4 * * 4,0   （UTC；程式會挑出當地晚上 8 點那一次）

const SEND_HOUR = 20; // 當地時間晚上 8 點
const SEND_WEEKDAYS = [3, 6]; // 週三、週六（0 = 週日）
const LOOKAHEAD_DAYS = 4; // 提醒接下來幾天內的聚會
const PLACEHOLDERS = new Set(['台語', '待定', 'tbd', 'n/a']);
const WEEKDAY_ZH = ['日', '一', '二', '三', '四', '五', '六'];

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    try {
      if (request.method === 'POST' && url.pathname === '/line/webhook') {
        return await handleWebhook(request, env, ctx);
      }
      if (url.pathname === '/api/swaps' || url.pathname.startsWith('/api/swaps/')) {
        return await handleSwapApi(request, env, url);
      }
      if (url.pathname === '/admin/richmenu') {
        if (!isAdmin(request, env)) return new Response('Unauthorized', { status: 401 });
        return json(await setupRichMenu(env, url.searchParams.get('image') || RICH_MENU_IMAGE));
      }
      if (url.pathname === '/admin/preview' || url.pathname === '/admin/run') {
        if (!isAdmin(request, env)) return new Response('Unauthorized', { status: 401 });
        const send = url.pathname === '/admin/run';
        const result = await runReminders(env, { send, now: new Date(), force: true });
        return json(result);
      }
      return new Response('IPCF LINE reminder is running.', { status: 200 });
    } catch (err) {
      console.error('fetch error', err?.stack || err);
      return new Response('Internal error', { status: 500 });
    }
  },

  async scheduled(event, env, ctx) {
    ctx.waitUntil(
      runReminders(env, { send: true, now: new Date(event.scheduledTime) }).then(
        (r) => console.log('scheduled result', JSON.stringify(r)),
        (e) => console.error('scheduled error', e?.stack || e),
      ),
    );
  },
};

// ───────────────────────── 時間 ─────────────────────────

function tz(env) {
  return env.TIME_ZONE || 'America/Los_Angeles';
}

/** 回傳教會時區的 { dateKey: 'YYYY-MM-DD', weekday: 0-6, hour: 0-23 } */
export function localParts(date, timeZone) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat('en-US', {
      timeZone,
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      hourCycle: 'h23',
      weekday: 'short',
    })
      .formatToParts(date)
      .map((p) => [p.type, p.value]),
  );
  const weekday = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'].indexOf(parts.weekday);
  return { dateKey: `${parts.year}-${parts.month}-${parts.day}`, weekday, hour: Number(parts.hour) };
}

export function addDays(dateKey, days) {
  const d = new Date(`${dateKey}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function dayDiff(fromKey, toKey) {
  return Math.round((Date.parse(`${toKey}T12:00:00Z`) - Date.parse(`${fromKey}T12:00:00Z`)) / 86400000);
}

function describeDate(dateKey, todayKey) {
  const d = new Date(`${dateKey}T12:00:00Z`);
  const label = `${d.getUTCMonth() + 1}/${d.getUTCDate()}（${WEEKDAY_ZH[d.getUTCDay()]}）`;
  const diff = dayDiff(todayKey, dateKey);
  if (diff === 0) return `今天 ${label}`;
  if (diff === 1) return `明天 ${label}`;
  if (d.getUTCDay() === 0 && diff <= 6) return `本週日 ${label}`;
  return label;
}

// ───────────────────────── 名字 ─────────────────────────

export function normalizeName(name) {
  return String(name || '').trim().toLowerCase();
}

function isRealPerson(name) {
  const n = normalizeName(name);
  return n.length > 0 && !PLACEHOLDERS.has(n);
}

// ───────────────────────── Firestore ─────────────────────────

const TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
let cachedGoogleToken = null;
let cachedBotToken = null;

function b64url(bytes) {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** 讀取 Firestore 用的 token：優先用「LINE 小幫手」同工帳號登入，沒設定才用服務帳戶 */
async function firestoreToken(env, fetchImpl = fetch) {
  if (env.BOT_EMAIL && env.BOT_PASSWORD) return botIdToken(env, fetchImpl);
  return googleToken(env, fetchImpl);
}

/** 用一般同工帳號（Email/密碼）登入 Firebase，受資料庫規則限制，只能讀同工看得到的資料 */
async function botIdToken(env, fetchImpl = fetch) {
  const now = Date.now();
  if (cachedBotToken && cachedBotToken.expiresAt > now + 60000) return cachedBotToken.token;
  const headers = { 'content-type': 'application/json' };
  if (env.SITE_URL) headers.referer = env.SITE_URL;
  const res = await fetchImpl(
    `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${encodeURIComponent(env.FIREBASE_API_KEY)}`,
    {
      method: 'POST',
      headers,
      body: JSON.stringify({ email: env.BOT_EMAIL, password: env.BOT_PASSWORD, returnSecureToken: true }),
    },
  );
  if (!res.ok) throw new Error(`Firebase sign-in error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  cachedBotToken = { token: data.idToken, expiresAt: now + Number(data.expiresIn || 3600) * 1000 };
  return cachedBotToken.token;
}

async function googleToken(env, fetchImpl = fetch) {
  const now = Date.now();
  if (cachedGoogleToken && cachedGoogleToken.expiresAt > now + 60000) return cachedGoogleToken.token;
  const account = JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_JSON);
  const iat = Math.floor(now / 1000);
  const enc = (o) => b64url(new TextEncoder().encode(JSON.stringify(o)));
  const unsigned = `${enc({ alg: 'RS256', typ: 'JWT' })}.${enc({
    iss: account.client_email,
    scope: 'https://www.googleapis.com/auth/datastore',
    aud: TOKEN_ENDPOINT,
    iat,
    exp: iat + 3600,
  })}`;
  const pem = account.private_key.replace(/\\n/g, '\n');
  const der = Uint8Array.from(
    atob(pem.replace(/-----[A-Z ]+-----/g, '').replace(/\s+/g, '')),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    'pkcs8',
    der,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = new Uint8Array(
    await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned)),
  );
  const res = await fetchImpl(TOKEN_ENDPOINT, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${unsigned}.${b64url(sig)}`,
    }),
  });
  if (!res.ok) throw new Error(`Google token error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const data = await res.json();
  cachedGoogleToken = { token: data.access_token, expiresAt: now + (data.expires_in || 3600) * 1000 };
  return cachedGoogleToken.token;
}

function fsValue(v) {
  if (!v) return null;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return Number(v.doubleValue);
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('nullValue' in v) return null;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(fsValue);
  if ('mapValue' in v) {
    const out = {};
    for (const [k, val] of Object.entries(v.mapValue.fields || {})) out[k] = fsValue(val);
    return out;
  }
  return null;
}

// 跟 app 一致的服事項目名稱（lib/features/roster/domain/role_names.dart）
const ROLE_ALIASES = {
  報告: '司會報告', 司會: '司會報告', 敬拜主領: '敬拜讚美', 收奉: '奉獻點算', 收奉獻: '奉獻點算',
  奉獻: '奉獻點算', 聖餐: '聖餐長老', 兒童主日學: '兒童主日', 幼兒主日學: '幼兒主日',
  愛餐整潔: '愛餐整理', 愛餐: '愛餐整理',
};
const canonicalRole = (r) => ROLE_ALIASES[(r || '').trim()] || (r || '').trim();

/** 讀取 dateKey 在 [fromKey, toKey] 之間的服事表 */
export async function fetchRosters(env, fromKey, toKey, fetchImpl = fetch) {
  const token = await firestoreToken(env, fetchImpl);
  const url = `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents:runQuery`;
  const res = await fetchImpl(url, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({
      structuredQuery: {
        from: [{ collectionId: 'rosters' }],
        where: {
          compositeFilter: {
            op: 'AND',
            filters: [
              { fieldFilter: { field: { fieldPath: 'dateKey' }, op: 'GREATER_THAN_OR_EQUAL', value: { stringValue: fromKey } } },
              { fieldFilter: { field: { fieldPath: 'dateKey' }, op: 'LESS_THAN_OR_EQUAL', value: { stringValue: toKey } } },
            ],
          },
        },
        orderBy: [{ field: { fieldPath: 'dateKey' } }],
      },
    }),
  });
  if (!res.ok) throw new Error(`Firestore error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const rows = await res.json();
  return rows.filter((r) => r.document).map((r) => parseRosterDoc(r.document));
}

export function parseRosterDoc(document) {
  const f = document.fields || {};
  return {
    id: String(document.name || '').split('/').pop(),
    dateKey: fsValue(f.dateKey),
    serviceName: fsValue(f.serviceName) || '主日崇拜',
    duties: (fsValue(f.duties) || []).map((d) => ({
      role: canonicalRole(d?.role),
      people: d?.people || [],
      locked: d?.locked === true,
    })),
  };
}

function firestoreBase(env) {
  return `https://firestore.googleapis.com/v1/projects/${env.FIREBASE_PROJECT_ID}/databases/(default)/documents`;
}

/** 讀一筆服事表（核准換班時確認服事表已經改好） */
export async function fetchRoster(env, rosterId, fetchImpl = fetch) {
  const token = await firestoreToken(env, fetchImpl);
  const res = await fetchImpl(`${firestoreBase(env)}/rosters/${encodeURIComponent(rosterId)}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (res.status === 404) return null;
  if (!res.ok) throw new Error(`Firestore error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  return parseRosterDoc(await res.json());
}

/** 同工名單（settings/auto_assign）：每個聚會的名單合併成 服事項目 → 名單，及服事比例 */
export async function fetchPools(env, fetchImpl = fetch) {
  const token = await firestoreToken(env, fetchImpl);
  const res = await fetchImpl(`${firestoreBase(env)}/settings/auto_assign`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (res.status === 404) return { roles: {}, ratios: {} };
  if (!res.ok) throw new Error(`Firestore error ${res.status}: ${(await res.text()).slice(0, 300)}`);
  const doc = await res.json();
  return parsePools(Object.fromEntries(Object.entries(doc.fields || {}).map(([k, v]) => [k, fsValue(v)])));
}

export function parsePools(data) {
  const roles = {};
  const ratios = {};
  for (const value of Object.values(data || {})) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) continue;
    for (const [role, people] of Object.entries(value.pool || {})) {
      const list = (roles[canonicalRole(role)] ||= []);
      for (const p of Array.isArray(people) ? people : []) {
        const name = String(p || '').trim();
        if (name && !list.some((x) => normalizeName(x) === normalizeName(name))) list.push(name);
      }
    }
    for (const e of Array.isArray(value.ratios) ? value.ratios : []) {
      if (e && typeof e.role === 'string' && typeof e.person === 'string' && typeof e.ratio === 'number') {
        (ratios[canonicalRole(e.role)] ||= {})[normalizeName(e.person)] = e.ratio;
      }
    }
  }
  return { roles, ratios };
}

// ───────────────────────── KV 綁定 ─────────────────────────
// name:<正規化名字>  → [LINE userId, ...]
// user:<LINE userId> → [服事表名字, ...]

async function getList(kv, key) {
  const raw = await kv.get(key);
  return raw ? JSON.parse(raw) : [];
}

export async function bindName(kv, userId, name) {
  const n = normalizeName(name);
  const users = await getList(kv, `name:${n}`);
  if (!users.includes(userId)) users.push(userId);
  await kv.put(`name:${n}`, JSON.stringify(users));
  const names = await getList(kv, `user:${userId}`);
  if (!names.map(normalizeName).includes(n)) names.push(name.trim());
  await kv.put(`user:${userId}`, JSON.stringify(names));
  return names;
}

export async function unbindAll(kv, userId) {
  const names = await getList(kv, `user:${userId}`);
  for (const name of names) {
    const key = `name:${normalizeName(name)}`;
    const users = (await getList(kv, key)).filter((u) => u !== userId);
    if (users.length) await kv.put(key, JSON.stringify(users));
    else await kv.delete(key);
  }
  await kv.delete(`user:${userId}`);
  return names;
}

// ───────────────────────── 提醒內容 ─────────────────────────

// 一格兩人時分老師、助教的項目（跟 app 的 kTeacherAssistantRoles 一樣）
const TEACHER_ASSISTANT_ROLES = new Set(['幼兒主日']);
function personTag(duty, person) {
  if (!TEACHER_ASSISTANT_ROLES.has(duty.role)) return null;
  const real = duty.people.map((p) => String(p || '').trim()).filter(isRealPerson);
  if (real.length < 2) return null;
  const i = real.map(normalizeName).indexOf(normalizeName(person));
  if (i < 0) return null;
  return i === 0 ? '老師' : '助教';
}

/** 把服事表整理成 { 正規化名字: [{ dateKey, serviceName, roles: [...] }] } */
export function assignmentsByName(rosters) {
  const map = new Map();
  for (const roster of rosters) {
    for (const duty of roster.duties) {
      for (const person of duty.people) {
        if (!isRealPerson(person)) continue;
        const n = normalizeName(person);
        if (!map.has(n)) map.set(n, { display: person.trim(), items: new Map() });
        const entry = map.get(n);
        const k = `${roster.dateKey}|${roster.serviceName}`;
        if (!entry.items.has(k)) entry.items.set(k, { dateKey: roster.dateKey, serviceName: roster.serviceName, roles: [], team: roster.duties });
        const roles = entry.items.get(k).roles;
        const tag = personTag(duty, person);
        const label = tag ? `${duty.role}（${tag}）` : duty.role;
        if (!roles.includes(label)) roles.push(label);
      }
    }
  }
  return map;
}

// 跟 app 的服事項目設定同一個順序（講員 → 司會報告 → … → 愛餐整理）
const ROLE_ORDER = ['台語講員', '華語講員', '司會報告', '敬拜讚美', '音控', '奉獻點算', '聖餐長老', '兒童主日', '幼兒主日', '幼兒助教', '愛餐整理', '招待'];

/** 當天一起服事的同工：每一項服事一行，自己的名字後面標（你）。 */
export function teamLines(team, myNames) {
  const mine = new Set(myNames.map(normalizeName));
  const order = (r) => {
    const i = ROLE_ORDER.indexOf(r);
    return i < 0 ? ROLE_ORDER.length : i;
  };
  const lines = [];
  for (const duty of [...(team || [])].sort((a, b) => order(a.role) - order(b.role))) {
    const people = duty.people.map((p) => String(p || '').trim()).filter(Boolean);
    const shown = people
      .map((p) => {
        if (normalizeName(p) === '台語') return '台語堂';
        if (!isRealPerson(p)) return null;
        const tag = personTag(duty, p);
        const name = tag ? `${p}${tag === '老師' ? '・老師' : '・助教'}` : p;
        return mine.has(normalizeName(p)) ? `${name}（你）` : name;
      })
      .filter(Boolean);
    if (!shown.length) continue;
    lines.push(`　${duty.role}：${[...new Set(shown)].join('、')}`);
  }
  return lines;
}

export function buildMessage(displayName, items, todayKey, myNames = [displayName]) {
  const lines = [`🙏 ${displayName} 平安！提醒你接下來的服事：`];
  for (const it of [...items].sort((a, b) => a.dateKey.localeCompare(b.dateKey))) {
    lines.push('', `📅 ${describeDate(it.dateKey, todayKey)}${it.serviceName}`);
    lines.push(`你的服事：${it.roles.join('、')}`);
    const team = teamLines(it.team, myNames);
    if (team.length) lines.push('當天同工：', ...team);
  }
  lines.push('', '如果無法服事，請盡早告知同工協調，謝謝！');
  return lines.join('\n');
}

/** 計算這次要發給誰，send=true 才真的發送 */
export async function runReminders(env, { send, now, force = false }, fetchImpl = fetch) {
  const local = localParts(now, tz(env));
  if (!force && (local.hour !== SEND_HOUR || !SEND_WEEKDAYS.includes(local.weekday))) {
    return { skipped: `not send time (local ${local.dateKey} weekday ${local.weekday} ${local.hour}:00)` };
  }
  const sentKey = `sent:${local.dateKey}`;
  if (send && !force && (await env.BINDINGS.get(sentKey))) {
    return { skipped: `already sent for ${local.dateKey}` };
  }

  const fromKey = addDays(local.dateKey, 1);
  const toKey = addDays(local.dateKey, LOOKAHEAD_DAYS);
  const rosters = await fetchRosters(env, fromKey, toKey, fetchImpl);
  const byName = assignmentsByName(rosters);

  // 一位 LINE 使用者可能綁了好幾個名字，合併成一則訊息
  const perUser = new Map();
  const unbound = [];
  for (const [n, entry] of byName) {
    const userIds = await getList(env.BINDINGS, `name:${n}`);
    if (!userIds.length) {
      unbound.push(entry.display);
      continue;
    }
    for (const uid of userIds) {
      if (!perUser.has(uid)) perUser.set(uid, { names: [], items: [] });
      const u = perUser.get(uid);
      u.names.push(entry.display);
      u.items.push(...entry.items.values());
    }
  }

  const results = [];
  for (const [uid, u] of perUser) {
    // 同一場聚會、不同名字的職務合併
    const merged = new Map();
    for (const it of u.items) {
      const k = `${it.dateKey}|${it.serviceName}`;
      if (!merged.has(k)) merged.set(k, { ...it, roles: [] });
      for (const r of it.roles) if (!merged.get(k).roles.includes(r)) merged.get(k).roles.push(r);
    }
    const text = buildMessage(u.names.join('／'), merged.values(), local.dateKey, u.names);
    let status = 'preview';
    if (send) {
      const res = await linePush(env, uid, text, fetchImpl);
      status = res.ok ? 'sent' : `failed ${res.status}`;
    }
    results.push({ names: u.names, status, text });
  }

  if (send && !force) await env.BINDINGS.put(sentKey, '1', { expirationTtl: 60 * 60 * 24 * 3 });
  return {
    window: [fromKey, toKey],
    rosters: rosters.map((r) => `${r.dateKey} ${r.serviceName}`),
    messages: results.length,
    results,
    unbound,
  };
}

// ───────────────────────── LINE ─────────────────────────

async function linePush(env, to, text, fetchImpl = fetch) {
  const res = await fetchImpl('https://api.line.me/v2/bot/message/push', {
    method: 'POST',
    headers: { authorization: `Bearer ${env.LINE_CHANNEL_ACCESS_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ to, messages: [{ type: 'text', text }] }),
  });
  if (!res.ok) console.error('LINE push failed', res.status, (await res.text()).slice(0, 300));
  return res;
}

async function lineReply(env, replyToken, text, fetchImpl = fetch) {
  const res = await fetchImpl('https://api.line.me/v2/bot/message/reply', {
    method: 'POST',
    headers: { authorization: `Bearer ${env.LINE_CHANNEL_ACCESS_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ replyToken, messages: [{ type: 'text', text }] }),
  });
  if (!res.ok) console.error('LINE reply failed', res.status, (await res.text()).slice(0, 300));
}

export async function verifySignature(body, signature, secret) {
  if (!signature || !secret) return false;
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const mac = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(body)));
  let s = '';
  for (const b of mac) s += String.fromCharCode(b);
  const expected = btoa(s);
  if (expected.length !== signature.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) diff |= expected.charCodeAt(i) ^ signature.charCodeAt(i);
  return diff === 0;
}

const HELP = [
  '🙌 歡迎使用 IPCF 服事小幫手！',
  '',
  '【第一步：綁定名字】',
  '傳「綁定 你的名字」，名字要跟服事表上的寫法一樣（大小寫不拘），例如：',
  '綁定 Crispin',
  '負責愛餐整理的小組也可以綁：綁定 喜樂小組',
  '一個 LINE 可以綁好幾個名字（例如夫妻共用）。',
  '',
  '【之後會收到】',
  '每週三、週六晚上 8 點，若接下來幾天有你的服事，會私訊提醒你，並列出當天一起服事的同工。',
  '',
  '【其他指令】（也可以按下方選單）',
  '・我的服事：接下來 4 週的服事',
  '・本週服事表：這週所有同工',
  '・換班：找人代班或互換，小幫手會推薦人選，送出後由管理者在 App 核准',
  '・申請進度：查看或取消換班申請',
  '・解除綁定：停止提醒',
  '・說明：再看一次這段說明',
  '',
  '如果無法服事，請盡早告知同工協調。',
].join('\n');

// 下方圖文選單用的圖片（2500×1686，3×2 六格），放在 GitHub 上讓 Worker 抓。
const RICH_MENU_IMAGE =
  'https://raw.githubusercontent.com/austin7712/church-staff-pwa/dev/ipcf/line-reminder/richmenu.png';

/** 建立下方的圖文選單並設成預設（舊的預設選單會一併刪掉）。 */
async function setupRichMenu(env, imageUrl, fetchImpl = fetch) {
  const auth = { authorization: `Bearer ${env.LINE_CHANNEL_ACCESS_TOKEN}` };
  const site = env.SITE_URL || 'https://ipcf-church-staff.pages.dev';
  const W = 2500;
  const H = 1686;
  const cols = 3;
  const cw = W / cols;
  const ch = H / 2;
  const actions = [
    { type: 'message', label: '我的服事', text: '我的服事' },
    { type: 'message', label: '本週服事表', text: '本週服事表' },
    { type: 'postback', label: '換班代班', data: 'sw:start', displayText: '換班' },
    { type: 'message', label: '申請進度', text: '申請進度' },
    { type: 'message', label: '使用說明', text: '說明' },
    { type: 'uri', label: '開啟同工 App', uri: `${site}/?openExternalBrowser=1` },
  ];
  const menu = {
    size: { width: W, height: H },
    selected: true,
    name: 'IPCF 服事小幫手',
    chatBarText: '服事選單',
    areas: actions.map((action, i) => ({
      bounds: {
        x: Math.round((i % cols) * cw),
        y: Math.round(Math.floor(i / cols) * ch),
        width: Math.round(cw),
        height: Math.round(ch),
      },
      action,
    })),
  };
  const created = await fetchImpl('https://api.line.me/v2/bot/richmenu', {
    method: 'POST',
    headers: { ...auth, 'content-type': 'application/json' },
    body: JSON.stringify(menu),
  });
  if (!created.ok) return { step: 'create', status: created.status, body: await created.text() };
  const { richMenuId } = await created.json();

  const img = await fetchImpl(imageUrl);
  if (!img.ok) return { step: 'image', status: img.status };
  const up = await fetchImpl(`https://api-data.line.me/v2/bot/richmenu/${richMenuId}/content`, {
    method: 'POST',
    headers: { ...auth, 'content-type': 'image/png' },
    body: await img.arrayBuffer(),
  });
  if (!up.ok) return { step: 'upload', status: up.status, body: await up.text() };

  const old = await fetchImpl('https://api.line.me/v2/bot/user/all/richmenu', { headers: auth });
  const oldId = old.ok ? (await old.json()).richMenuId : null;
  const def = await fetchImpl(`https://api.line.me/v2/bot/user/all/richmenu/${richMenuId}`, { method: 'POST', headers: auth });
  if (!def.ok) return { step: 'default', status: def.status, body: await def.text() };
  if (oldId && oldId !== richMenuId) {
    await fetchImpl(`https://api.line.me/v2/bot/richmenu/${oldId}`, { method: 'DELETE', headers: auth });
  }
  return { ok: true, richMenuId, replaced: oldId || null };
}

/** 「本週服事表」：最近一個有服事表的聚會日，每個聚會列出全部同工。 */
export function weekRosterMessage(rosters, todayKey) {
  const dates = [...new Set(rosters.map((r) => r.dateKey))].sort();
  const day = dates.find((d) => d >= todayKey);
  if (!day) return '這週還沒有服事表。';
  const lines = [`📋 ${describeDate(day, todayKey)}服事表`];
  for (const r of rosters.filter((x) => x.dateKey === day)) {
    const team = teamLines(r.duties, []);
    if (!team.length) continue;
    lines.push('', `【${r.serviceName}】`, ...team);
  }
  return lines.length > 1 ? lines.join('\n') : `${describeDate(day, todayKey)}還沒有排人。`;
}

async function handleWebhook(request, env, ctx, fetchImpl = fetch) {
  const body = await request.text();
  const ok = await verifySignature(body, request.headers.get('x-line-signature'), env.LINE_CHANNEL_SECRET);
  if (!ok) return new Response('Bad signature', { status: 401 });
  const payload = JSON.parse(body || '{}');
  ctx.waitUntil(Promise.all((payload.events || []).map((e) => handleEvent(env, e, fetchImpl).catch((err) => console.error('event error', err?.stack || err)))));
  return new Response('OK');
}

export async function handleEvent(env, event, fetchImpl = fetch) {
  const uid = event.source?.userId;
  if (!uid || !event.replyToken) return;
  // 只處理一對一聊天；群組裡不回應，避免洗版
  if (event.source.type !== 'user') return;

  if (event.type === 'follow') return lineReply(env, event.replyToken, HELP, fetchImpl);
  if (event.type === 'postback') {
    const data = String(event.postback?.data || '');
    if (data.startsWith('sw:')) return handleSwapPostback(env, uid, data, event.replyToken, fetchImpl);
    return;
  }
  if (event.type !== 'message' || event.message?.type !== 'text') return;

  const text = event.message.text.trim();
  const today = localParts(new Date(), tz(env)).dateKey;

  if (/^(換班|代班|換班代班|換班\/代班|換班／代班|我要換班|我要代班|找人代班)$/.test(text)) {
    return startSwap(env, uid, event.replyToken, fetchImpl);
  }
  if (text === '申請進度' || text === '換班進度' || text === '我的申請') {
    return replyMessages(env, event.replyToken, [await statusMessage(env, uid)], fetchImpl);
  }
  if (text === '取消') {
    await clearFlow(env.BINDINGS, uid);
    return lineReply(env, event.replyToken, '已取消。', fetchImpl);
  }
  // 換班選人那一步：直接打名字
  const flow = await getFlow(env.BINDINGS, uid);
  if (flow?.step === 'cand' && !/^(綁定|解除綁定|我的服事|本週服事|說明)/.test(text)) {
    return typedCandidate(env, uid, flow, text, event.replyToken, fetchImpl);
  }

  const bind = text.match(/^綁定\s*(.+)$/);
  if (bind) {
    const name = bind[1].trim();
    // 只接受服事表上出現過的名字，避免打錯字之後默默收不到提醒
    const rosters = await fetchRosters(env, addDays(today, -120), addDays(today, 365), fetchImpl);
    const known = assignmentsByName(rosters);
    const hit = known.get(normalizeName(name));
    if (!hit) {
      const names = await bindName(env.BINDINGS, uid, name);
      return lineReply(env, event.replyToken, `✅ 已綁定「${name}」\n目前綁定：${names.join('、')}\n\n⚠️ 目前的服事表上還沒有「${name}」。請確認寫法跟服事表一樣（大小寫不拘），之後排到你就會收到提醒。\n寫錯的話，傳「解除綁定」再重新綁定。`, fetchImpl);
    }
    const names = await bindName(env.BINDINGS, uid, hit.display);
    return lineReply(env, event.replyToken, `✅ 已綁定「${hit.display}」\n目前綁定：${names.join('、')}\n\n傳「我的服事」可以查看接下來的服事。`, fetchImpl);
  }

  if (text === '解除綁定') {
    const names = await unbindAll(env.BINDINGS, uid);
    return lineReply(env, event.replyToken, names.length ? `已解除綁定：${names.join('、')}，之後不會再收到提醒。` : '你目前沒有綁定任何名字。', fetchImpl);
  }

  if (text === '本週服事表' || text === '本週服事' || text === '這週服事表') {
    const rosters = await fetchRosters(env, today, addDays(today, 7), fetchImpl);
    return lineReply(env, event.replyToken, weekRosterMessage(rosters, today), fetchImpl);
  }

  if (text === '我的服事') {
    const names = await getList(env.BINDINGS, `user:${uid}`);
    if (!names.length) return lineReply(env, event.replyToken, '你還沒有綁定名字，請先傳「綁定 你的名字」。', fetchImpl);
    const rosters = await fetchRosters(env, today, addDays(today, 28), fetchImpl);
    const byName = assignmentsByName(rosters);
    const items = names.flatMap((n) => [...(byName.get(normalizeName(n))?.items.values() || [])]);
    if (!items.length) return lineReply(env, event.replyToken, `${names.join('／')}：接下來 4 週沒有排到服事 🙂`, fetchImpl);
    return lineReply(env, event.replyToken, buildMessage(names.join('／'), items, today, names).replace('提醒你接下來的服事', '你接下來 4 週的服事'), fetchImpl);
  }

  return lineReply(env, event.replyToken, HELP, fetchImpl);
}

// ───────────────────────── 換班／代班 ─────────────────────────
//
// 流程（全部在 LINE 對話裡用按鈕完成）：
//   1. 同工傳「換班」→ 選自己接下來的一項服事 → 選「代班」或「互換」。
//   2. 小幫手從那一項的同工名單推薦人選：當天沒有不能兼任的服事、前後一週沒有
//      同一項服事、服事比例不是 0%，今年服事天數少的排前面。
//   3. 已經私下講好就直接送出；或請小幫手私訊對方按「同意／婉拒」。
//      婉拒的話，小幫手把（去掉婉拒者的）推薦名單再傳給申請人。
//   4. 申請存在 KV（swapreq:<id>），管理者在 App 的「換班申請」核准：App 用管理者
//      的權限改服事表，再呼叫 /api/swaps/<id> 通知雙方。
//
// 申請狀態：asking（等對方回覆）→ pending（等管理者）→ approved／rejected；
//           declined（對方婉拒）、cancelled（申請人取消）。

const SWAP_LOOKAHEAD_DAYS = 112; // 可以申請接下來 16 週的服事
const FLOW_TTL = 60 * 30; // 對話步驟保留 30 分鐘
const MAX_CANDIDATES = 6;
const REQUEST_TTL = 60 * 60 * 24 * 200; // 處理完的申請保留約半年
const SPEAKER_ROLES = ['台語講員', '華語講員'];

/** 同一天同一人可以兼任的兩項服事（跟 app 的 rolesCanShare 一樣） */
export function rolesCanShare(a, b) {
  const x = canonicalRole(a);
  const y = canonicalRole(b);
  if (x === y) return false;
  if (x === '奉獻點算' || y === '奉獻點算') return true;
  const pair = new Set([x, y]);
  if (pair.has('聖餐長老') && pair.has('司會報告')) return true;
  if (pair.has(SPEAKER_ROLES[0]) && pair.has(SPEAKER_ROLES[1])) return true;
  return false;
}

const slotKey = (s) => `${s.rosterId}|${s.role}`;
const hasPerson = (duty, name) => duty.people.some((p) => normalizeName(p) === normalizeName(name));

function shortDate(dateKey) {
  const d = new Date(`${dateKey}T12:00:00Z`);
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()}`;
}

function longDate(dateKey) {
  const d = new Date(`${dateKey}T12:00:00Z`);
  return `${d.getUTCMonth() + 1}/${d.getUTCDate()}（${WEEKDAY_ZH[d.getUTCDay()]}）`;
}

export function slotLabel(slot) {
  return `${longDate(slot.dateKey)}${slot.serviceName} ${slot.role}`;
}

/** 今年每個人的服事天數（同一天兼任多項只算一天）與每項服事的次數 */
export function personStats(rosters, year) {
  const stats = new Map();
  for (const r of rosters) {
    if (!String(r.dateKey).startsWith(String(year))) continue;
    for (const duty of r.duties) {
      for (const p of duty.people) {
        if (!isRealPerson(p)) continue;
        const n = normalizeName(p);
        if (!stats.has(n)) stats.set(n, { days: new Set(), roles: {} });
        const s = stats.get(n);
        s.days.add(r.dateKey);
        s.roles[duty.role] = (s.roles[duty.role] || 0) + 1;
      }
    }
  }
  return stats;
}

/**
 * [name] 能不能接 [slot]：
 *   ok          當天沒有不能兼任的服事、也還沒在這一格
 *   present     當天本來就有（可以兼任的）服事，不用多跑一趟
 *   consecutive 前後一週有同一項服事
 * [ignore] 是換出去的格子（互換時對方原本那一格不算）。
 */
export function checkSlot(rosters, name, slot, ignore = new Set()) {
  let ok = true;
  let present = false;
  let consecutive = false;
  for (const r of rosters) {
    const diff = dayDiff(slot.dateKey, r.dateKey);
    if (Math.abs(diff) > 7) continue;
    for (const duty of r.duties) {
      if (!hasPerson(duty, name)) continue;
      if (ignore.has(`${r.id}|${duty.role}`)) continue;
      if (diff === 0) {
        if (r.id === slot.rosterId && duty.role === slot.role) ok = false;
        else if (rolesCanShare(duty.role, slot.role)) present = true;
        else ok = false;
      } else if (duty.role === slot.role) {
        consecutive = true;
      }
    }
  }
  return { ok, present, consecutive };
}

/** [name] 接下來可以拿出來互換的同一項服事（申請人要接得下來） */
export function swapSlotsFor(rosters, name, mySlot, requesterNames, todayKey, lastKey) {
  const slots = [];
  for (const r of rosters) {
    if (r.dateKey <= todayKey || r.dateKey > lastKey || r.dateKey === mySlot.dateKey) continue;
    for (const duty of r.duties) {
      if (duty.role !== mySlot.role || duty.locked || !hasPerson(duty, name)) continue;
      const theirs = { rosterId: r.id, dateKey: r.dateKey, serviceName: r.serviceName, role: duty.role };
      // 申請人接對方那天：自己這一格會換出去，不算
      const me = requesterNames.map((n) => checkSlot(rosters, n, theirs, new Set([slotKey(mySlot)])));
      if (me.some((c) => !c.ok || c.consecutive)) continue;
      // 對方接申請人這天：他自己那一格會換出去，不算
      const them = checkSlot(rosters, name, mySlot, new Set([slotKey(theirs)]));
      if (!them.ok || them.consecutive) continue;
      slots.push({ ...theirs, person: duty.people.find((p) => normalizeName(p) === normalizeName(name)).trim() });
    }
  }
  return slots.sort((a, b) => a.dateKey.localeCompare(b.dateKey)).slice(0, 4);
}

/**
 * 推薦人選，最適合的在前面。
 * mode = 'sub'（代班）或 'swap'（互換，只列出有可以互換那一天的人）。
 */
export function recommend({ rosters, pools, slot, requesterNames, exclude = [], mode, todayKey, lastKey }) {
  const year = slot.dateKey.slice(0, 4);
  const stats = personStats(rosters, year);
  const skip = new Set([...requesterNames, ...exclude].map(normalizeName));
  let pool = pools.roles[slot.role];
  if (!pool || !pool.length) {
    // 還沒整理同工名單的項目：今年做過這一項的人
    pool = [...stats.entries()]
      .filter(([, s]) => s.roles[slot.role])
      .map(([n]) => {
        for (const r of rosters) for (const d of r.duties) for (const p of d.people) if (normalizeName(p) === n) return p.trim();
        return n;
      });
  }
  const out = [];
  for (const name of pool) {
    const n = normalizeName(name);
    if (skip.has(n) || !isRealPerson(name)) continue;
    const ratio = pools.ratios[slot.role]?.[n] ?? 1;
    if (ratio <= 0) continue;
    const s = stats.get(n);
    const entry = { name, days: s ? s.days.size : 0, roleCount: s ? s.roles[slot.role] || 0 : 0, ratio };
    if (mode === 'swap') {
      entry.slots = swapSlotsFor(rosters, name, slot, requesterNames, todayKey, lastKey);
      if (!entry.slots.length) continue;
      entry.present = checkSlot(rosters, name, slot, new Set([slotKey(entry.slots[0])])).present;
    } else {
      const c = checkSlot(rosters, name, slot);
      if (!c.ok || c.consecutive) continue;
      entry.present = c.present;
    }
    out.push(entry);
  }
  out.sort(
    (a, b) =>
      (a.days + 1) / a.ratio - (b.days + 1) / b.ratio ||
      Number(b.present) - Number(a.present) ||
      a.roleCount - b.roleCount ||
      a.name.localeCompare(b.name),
  );
  return out.slice(0, MAX_CANDIDATES);
}

/** 自己輸入的名字：找出服事表或名單上的寫法 */
function knownSpelling(name, rosters, pools) {
  const n = normalizeName(name);
  for (const list of Object.values(pools.roles)) for (const p of list) if (normalizeName(p) === n) return p;
  for (const r of rosters) for (const d of r.duties) for (const p of d.people) if (normalizeName(p) === n) return p.trim();
  return null;
}

// ── LINE 訊息 ──

const postback = (label, data, displayText = label) => ({
  type: 'action',
  action: { type: 'postback', label: label.slice(0, 20), data, displayText: displayText.slice(0, 300) },
});
const CANCEL = postback('取消', 'sw:cancel', '取消');

function textMsg(text, quick = []) {
  const m = { type: 'text', text: text.slice(0, 4900) };
  if (quick.length) m.quickReply = { items: quick.slice(0, 13) };
  return m;
}

async function lineSend(env, endpoint, body, fetchImpl) {
  const res = await fetchImpl(`https://api.line.me/v2/bot/message/${endpoint}`, {
    method: 'POST',
    headers: { authorization: `Bearer ${env.LINE_CHANNEL_ACCESS_TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!res.ok) console.error(`LINE ${endpoint} failed`, res.status, (await res.text()).slice(0, 300));
  return res;
}
const replyMessages = (env, replyToken, messages, fetchImpl = fetch) =>
  lineSend(env, 'reply', { replyToken, messages }, fetchImpl);
const pushMessages = (env, to, messages, fetchImpl = fetch) => lineSend(env, 'push', { to, messages }, fetchImpl);

// ── KV ──

const flowKey = (uid) => `flow:${uid}`;
async function getFlow(kv, uid) {
  const raw = await kv.get(flowKey(uid));
  return raw ? JSON.parse(raw) : null;
}
const saveFlow = (kv, uid, flow) => kv.put(flowKey(uid), JSON.stringify(flow), { expirationTtl: FLOW_TTL });
const clearFlow = (kv, uid) => kv.delete(flowKey(uid));

async function getRequest(kv, id) {
  const raw = await kv.get(`swapreq:${id}`);
  return raw ? JSON.parse(raw) : null;
}
async function saveRequest(kv, req) {
  req.updatedAt = new Date().toISOString();
  const done = !['asking', 'pending'].includes(req.status);
  await kv.put(`swapreq:${req.id}`, JSON.stringify(req), done ? { expirationTtl: REQUEST_TTL } : undefined);
}
export async function listRequests(kv) {
  const out = [];
  let cursor;
  do {
    const page = await kv.list({ prefix: 'swapreq:', cursor });
    for (const k of page.keys) {
      const raw = await kv.get(k.name);
      if (raw) out.push(JSON.parse(raw));
    }
    cursor = page.list_complete ? undefined : page.cursor;
  } while (cursor);
  return out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}

const STATUS_ZH = {
  asking: '等對方回覆',
  pending: '等管理者核准',
  approved: '已核准',
  rejected: '未核准',
  declined: '對方婉拒',
  cancelled: '已取消',
};

/** 申請內容（給同工看的文字） */
export function describeRequest(req) {
  const lines = [];
  if (req.mode === 'swap') {
    lines.push('🔁 互換');
    lines.push(`${slotLabel(req.from)}：${req.from.person} → ${req.candidate}`);
    lines.push(`${slotLabel(req.to)}：${req.to.person} → ${req.from.person}`);
  } else {
    lines.push('🙋 代班');
    lines.push(`${slotLabel(req.from)}：${req.from.person} → ${req.candidate}`);
  }
  return lines.join('\n');
}

// ── 對話步驟 ──

async function swapContext(env, fromKey, fetchImpl) {
  const today = localParts(new Date(), tz(env)).dateKey;
  const lastKey = addDays(today, SWAP_LOOKAHEAD_DAYS);
  const start = `${(fromKey || today).slice(0, 4)}-01-01`;
  const [rosters, pools] = await Promise.all([
    fetchRosters(env, start < addDays(today, -7) ? start : addDays(today, -7), addDays(lastKey, 7), fetchImpl),
    fetchPools(env, fetchImpl),
  ]);
  return { today, lastKey, rosters, pools };
}

/** 第一步：列出自己接下來的服事 */
async function startSwap(env, uid, replyToken, fetchImpl) {
  const names = await getList(env.BINDINGS, `user:${uid}`);
  if (!names.length) return lineReply(env, replyToken, '請先綁定名字：傳「綁定 你的名字」，之後才能申請換班。', fetchImpl);
  const today = localParts(new Date(), tz(env)).dateKey;
  const rosters = await fetchRosters(env, addDays(today, 1), addDays(today, SWAP_LOOKAHEAD_DAYS), fetchImpl);
  const duties = [];
  for (const r of rosters) {
    for (const d of r.duties) {
      const person = d.people.find((p) => isRealPerson(p) && names.some((n) => normalizeName(n) === normalizeName(p)));
      if (person) duties.push({ rosterId: r.id, dateKey: r.dateKey, serviceName: r.serviceName, role: d.role, person: person.trim(), locked: d.locked });
    }
  }
  if (!duties.length) return lineReply(env, replyToken, `${names.join('／')}：接下來 16 週沒有排到服事，不需要換班 🙂`, fetchImpl);
  const shown = duties.slice(0, 12);
  await saveFlow(env.BINDINGS, uid, { step: 'pick', duties: shown });
  const lines = ['🔁 換班／代班', '要換哪一個服事？請按下方按鈕：', ''];
  shown.forEach((d, i) => lines.push(`${i + 1}. ${slotLabel(d)}${d.locked ? ' 🔒' : ''}`));
  if (duties.length > shown.length) lines.push('', '（只列出最近 12 項）');
  return replyMessages(env, replyToken, [
    textMsg(lines.join('\n'), [...shown.map((d, i) => postback(`${shortDate(d.dateKey)} ${d.role}`, `sw:pick:${i}`, `${i + 1}. ${slotLabel(d)}`)), CANCEL]),
  ], fetchImpl);
}

function modeMessage(slot) {
  return textMsg(
    [
      `📅 ${slotLabel(slot)}`,
      '',
      '要怎麼換？',
      '・代班：找人接手這一天',
      '・互換：對方接手這一天，你接他另一天的同一項服事',
    ].join('\n'),
    [postback('代班', 'sw:mode:sub'), postback('互換', 'sw:mode:swap'), CANCEL],
  );
}

/** 推薦名單訊息（也用在對方婉拒後重新推薦） */
async function candidatesMessage(env, flow, ctx, intro) {
  const requesterNames = flow.requesterNames;
  const list = recommend({ rosters: ctx.rosters, pools: ctx.pools, slot: flow.from, requesterNames, exclude: flow.exclude || [], mode: flow.mode, todayKey: ctx.today, lastKey: ctx.lastKey });
  flow.step = 'cand';
  flow.candidates = list;
  const lines = [intro || `📅 ${slotLabel(flow.from)}`, ''];
  if (!list.length) {
    lines.push(flow.mode === 'swap' ? '名單裡目前沒有可以互換的人選（對方要有接下來的同一項服事，而且兩邊都接得下來）。' : '名單裡目前沒有合適的人選。');
    lines.push('', '可以直接輸入名字，或按「取消」。');
    return textMsg(lines.join('\n'), [CANCEL]);
  }
  lines.push(flow.mode === 'swap' ? '推薦互換人選：' : '推薦代班人選：');
  for (const [i, c] of list.entries()) {
    const bound = (await getList(env.BINDINGS, `name:${normalizeName(c.name)}`)).length > 0;
    const tags = [`今年 ${c.days} 天`];
    if (c.present) tags.push('當天已在教會');
    if (c.ratio < 1) tags.push(`比例 ${Math.round(c.ratio * 100)}%`);
    if (!bound) tags.push('未綁 LINE');
    lines.push(`${i + 1}. ${c.name}｜${tags.join('・')}`);
    if (c.slots) lines.push(`　可換：${c.slots.map((s) => shortDate(s.dateKey)).join('、')}`);
  }
  lines.push('', '依今年服事天數排序，已排除當天有其他服事、前後一週有同一項服事的人。');
  lines.push('按下方人選，或直接輸入名字。');
  return textMsg(lines.join('\n'), [...list.map((c, i) => postback(`${i + 1}. ${c.name}`, `sw:cand:${i}`, `${i + 1}. ${c.name}`)), CANCEL]);
}

function slotMessage(flow) {
  const c = flow.candidate;
  const lines = [`${c.name} 可以拿來互換的日子：`, ''];
  c.slots.forEach((s, i) => lines.push(`${i + 1}. ${slotLabel(s)}`));
  lines.push('', '你要接哪一天？');
  return textMsg(lines.join('\n'), [...c.slots.map((s, i) => postback(shortDate(s.dateKey), `sw:slot:${i}`, `接 ${slotLabel(s)}`)), CANCEL]);
}

async function confirmMessage(env, flow) {
  const draft = draftRequest(flow);
  const uids = await getList(env.BINDINGS, `name:${normalizeName(flow.candidate.name)}`);
  flow.step = 'confirm';
  const lines = ['📝 申請內容', '', describeRequest(draft), ''];
  const quick = [postback('已講好，送出', 'sw:send:private', '已經跟對方講好了，送出申請')];
  if (uids.length) {
    lines.push(`如果已經私下跟 ${flow.candidate.name} 講好，按「已講好，送出」。`, `還沒講的話，可以按「請小幫手問他」，小幫手會私訊他按同意或婉拒。`);
    quick.push(postback('請小幫手問他', 'sw:send:ask', `請小幫手問 ${flow.candidate.name}`));
  } else {
    lines.push(`${flow.candidate.name} 還沒綁定 LINE，請先私下跟他確認，講好後按「已講好，送出」。`);
  }
  quick.push(CANCEL);
  return textMsg(lines.join('\n'), quick);
}

function draftRequest(flow) {
  return {
    mode: flow.mode,
    from: flow.from,
    to: flow.mode === 'swap' ? flow.slot : null,
    candidate: flow.candidate.name,
  };
}

function newId() {
  return `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/** 送出前再確認服事表沒變：申請人還在那一格、互換時對方也還在他那一格 */
async function stillValid(env, draft, fetchImpl) {
  const a = await fetchRoster(env, draft.from.rosterId, fetchImpl);
  if (!a?.duties.some((d) => d.role === draft.from.role && hasPerson(d, draft.from.person))) return false;
  if (draft.mode === 'swap') {
    const b = await fetchRoster(env, draft.to.rosterId, fetchImpl);
    if (!b?.duties.some((d) => d.role === draft.to.role && hasPerson(d, draft.to.person))) return false;
  }
  return true;
}

async function submitRequest(env, uid, flow, how, replyToken, fetchImpl) {
  const draft = draftRequest(flow);
  const open = (await listRequests(env.BINDINGS)).find(
    (r) => ['asking', 'pending'].includes(r.status) && slotKey(r.from) === slotKey(draft.from) && normalizeName(r.from.person) === normalizeName(draft.from.person),
  );
  if (open) {
    await clearFlow(env.BINDINGS, uid);
    return lineReply(env, replyToken, `這個服事已經有一筆申請在處理中（${STATUS_ZH[open.status]}）。\n傳「申請進度」可以查看或取消。`, fetchImpl);
  }
  if (!(await stillValid(env, draft, fetchImpl))) {
    await clearFlow(env.BINDINGS, uid);
    return lineReply(env, replyToken, '服事表剛剛有變動，這筆申請不能送出。請再傳一次「換班」重新選。', fetchImpl);
  }
  const candidateUids = await getList(env.BINDINGS, `name:${normalizeName(draft.candidate)}`);
  const now = new Date().toISOString();
  const req = {
    id: newId(),
    ...draft,
    status: how === 'ask' && candidateUids.length ? 'asking' : 'pending',
    confirmedBy: how === 'ask' && candidateUids.length ? 'line' : 'private',
    requesterNames: flow.requesterNames,
    requesterUid: uid,
    candidateUids,
    declined: flow.exclude || [],
    createdAt: now,
  };
  await saveRequest(env.BINDINGS, req);
  await clearFlow(env.BINDINGS, uid);
  if (req.status === 'asking') {
    await pushMessages(env, candidateUids[0], [askMessage(req)], fetchImpl);
    for (const other of candidateUids.slice(1)) await pushMessages(env, other, [askMessage(req)], fetchImpl);
    return lineReply(env, replyToken, `📨 已私訊 ${req.candidate}，他按同意後會自動送給管理者核准，有結果會通知你。`, fetchImpl);
  }
  return replyMessages(env, replyToken, [
    textMsg(`✅ 已送出申請，等管理者在 App 核准後會通知你。\n\n${describeRequest(req)}`, [postback('申請進度', 'sw:status', '申請進度')]),
  ], fetchImpl);
}

function askMessage(req) {
  const who = req.from.person;
  const body =
    req.mode === 'swap'
      ? `${who} 想跟你互換：\n你接 ${shortDate(req.from.dateKey)} ${req.from.role}\n他接 ${shortDate(req.to.dateKey)} ${req.to.role}`
      : `${who} 想請你代班：\n${longDate(req.from.dateKey)} ${req.from.serviceName} ${req.from.role}`;
  return {
    type: 'template',
    altText: `${who} 請你${req.mode === 'swap' ? '互換' : '代班'}服事`,
    template: {
      type: 'confirm',
      text: `🙏 ${body}\n\n可以嗎？`.slice(0, 240),
      actions: [
        { type: 'postback', label: '同意', data: `sw:ans:${req.id}:yes`, displayText: '同意' },
        { type: 'postback', label: '婉拒', data: `sw:ans:${req.id}:no`, displayText: '婉拒' },
      ],
    },
  };
}

async function answerRequest(env, uid, id, yes, replyToken, fetchImpl) {
  const req = await getRequest(env.BINDINGS, id);
  if (!req || !req.candidateUids.includes(uid)) return lineReply(env, replyToken, '找不到這筆申請。', fetchImpl);
  if (req.status !== 'asking') return lineReply(env, replyToken, `這筆申請已經${STATUS_ZH[req.status] || '處理過了'}，不用再回覆。`, fetchImpl);
  if (yes) {
    req.status = 'pending';
    await saveRequest(env.BINDINGS, req);
    await lineReply(env, replyToken, '🙏 謝謝你！已送給管理者核准，核准後會再通知你。', fetchImpl);
    return pushMessages(env, req.requesterUid, [textMsg(`✅ ${req.candidate} 同意了！已送給管理者核准。\n\n${describeRequest(req)}`)], fetchImpl);
  }
  req.status = 'declined';
  await saveRequest(env.BINDINGS, req);
  await lineReply(env, replyToken, `好的，已經告訴 ${req.from.person}，謝謝你。`, fetchImpl);
  // 把推薦名單（去掉婉拒的人）再傳給申請人
  const flow = {
    requesterNames: req.requesterNames,
    from: req.from,
    mode: req.mode,
    exclude: [...(req.declined || []), req.candidate],
  };
  const ctx = await swapContext(env, req.from.dateKey, fetchImpl);
  const msg = await candidatesMessage(env, flow, ctx, `😊 ${req.candidate} 這次不方便。\n📅 ${slotLabel(req.from)}`);
  await saveFlow(env.BINDINGS, req.requesterUid, flow);
  return pushMessages(env, req.requesterUid, [msg], fetchImpl);
}

async function statusMessage(env, uid) {
  const mine = (await listRequests(env.BINDINGS)).filter((r) => r.requesterUid === uid || r.candidateUids?.includes(uid)).slice(0, 8);
  if (!mine.length) return textMsg('目前沒有換班申請。傳「換班」可以申請。');
  const lines = ['📋 換班申請進度', ''];
  const quick = [];
  for (const r of mine) {
    lines.push(`【${STATUS_ZH[r.status] || r.status}】`, describeRequest(r));
    if (r.note) lines.push(`備註：${r.note}`);
    lines.push('');
    if (r.requesterUid === uid && ['asking', 'pending'].includes(r.status)) {
      quick.push(postback(`取消 ${shortDate(r.from.dateKey)} ${r.from.role}`, `sw:withdraw:${r.id}`, `取消 ${slotLabel(r.from)} 的申請`));
    }
  }
  return textMsg(lines.join('\n').trim(), quick);
}

async function withdrawRequest(env, uid, id, replyToken, fetchImpl) {
  const req = await getRequest(env.BINDINGS, id);
  if (!req || req.requesterUid !== uid) return lineReply(env, replyToken, '找不到這筆申請。', fetchImpl);
  if (!['asking', 'pending'].includes(req.status)) return lineReply(env, replyToken, `這筆申請已經${STATUS_ZH[req.status]}，不能取消。`, fetchImpl);
  req.status = 'cancelled';
  await saveRequest(env.BINDINGS, req);
  return lineReply(env, replyToken, `已取消：\n${describeRequest(req)}`, fetchImpl);
}

/** 換班相關的按鈕（postback） */
async function handleSwapPostback(env, uid, data, replyToken, fetchImpl) {
  const [, action, arg, arg2] = data.split(':');
  if (action === 'start') return startSwap(env, uid, replyToken, fetchImpl);
  if (action === 'status') return replyMessages(env, replyToken, [await statusMessage(env, uid)], fetchImpl);
  if (action === 'ans') return answerRequest(env, uid, arg, arg2 === 'yes', replyToken, fetchImpl);
  if (action === 'withdraw') return withdrawRequest(env, uid, arg, replyToken, fetchImpl);
  if (action === 'cancel') {
    await clearFlow(env.BINDINGS, uid);
    return lineReply(env, replyToken, '已取消。', fetchImpl);
  }

  const flow = await getFlow(env.BINDINGS, uid);
  const expired = () => lineReply(env, replyToken, '這個步驟已經過期了，請再傳一次「換班」。', fetchImpl);
  if (!flow) return expired();

  if (action === 'pick' && flow.step === 'pick') {
    const slot = flow.duties[Number(arg)];
    if (!slot) return expired();
    flow.from = slot;
    flow.requesterNames = await getList(env.BINDINGS, `user:${uid}`);
    flow.step = 'mode';
    delete flow.duties;
    await saveFlow(env.BINDINGS, uid, flow);
    return replyMessages(env, replyToken, [modeMessage(slot)], fetchImpl);
  }
  if (action === 'mode' && flow.step === 'mode') {
    flow.mode = arg === 'swap' ? 'swap' : 'sub';
    const ctx = await swapContext(env, flow.from.dateKey, fetchImpl);
    const msg = await candidatesMessage(env, flow, ctx);
    await saveFlow(env.BINDINGS, uid, flow);
    return replyMessages(env, replyToken, [msg], fetchImpl);
  }
  if (action === 'cand' && flow.step === 'cand') {
    const c = flow.candidates[Number(arg)];
    if (!c) return expired();
    return chooseCandidate(env, uid, flow, c, replyToken, fetchImpl);
  }
  if (action === 'slot' && flow.step === 'slot') {
    const s = flow.candidate.slots[Number(arg)];
    if (!s) return expired();
    flow.slot = s;
    const msg = await confirmMessage(env, flow);
    await saveFlow(env.BINDINGS, uid, flow);
    return replyMessages(env, replyToken, [msg], fetchImpl);
  }
  if (action === 'send' && flow.step === 'confirm') {
    return submitRequest(env, uid, flow, arg, replyToken, fetchImpl);
  }
  return expired();
}

async function chooseCandidate(env, uid, flow, candidate, replyToken, fetchImpl) {
  flow.candidate = candidate;
  if (flow.mode === 'swap') {
    if (candidate.slots.length === 1) {
      flow.slot = candidate.slots[0];
    } else {
      flow.step = 'slot';
      await saveFlow(env.BINDINGS, uid, flow);
      return replyMessages(env, replyToken, [slotMessage(flow)], fetchImpl);
    }
  }
  const msg = await confirmMessage(env, flow);
  await saveFlow(env.BINDINGS, uid, flow);
  return replyMessages(env, replyToken, [msg], fetchImpl);
}

/** 推薦名單那一步直接打名字 */
async function typedCandidate(env, uid, flow, text, replyToken, fetchImpl) {
  const ctx = await swapContext(env, flow.from.dateKey, fetchImpl);
  const name = knownSpelling(text, ctx.rosters, ctx.pools);
  if (!name) return replyMessages(env, replyToken, [textMsg(`服事表和同工名單上沒有「${text}」，請確認寫法再輸入一次。`, [CANCEL])], fetchImpl);
  if (flow.requesterNames.some((n) => normalizeName(n) === normalizeName(name))) {
    return replyMessages(env, replyToken, [textMsg('不能選自己喔，請輸入別人的名字。', [CANCEL])], fetchImpl);
  }
  const candidate = { name, days: personStats(ctx.rosters, flow.from.dateKey.slice(0, 4)).get(normalizeName(name))?.days.size || 0 };
  const warn = [];
  if (flow.mode === 'swap') {
    candidate.slots = swapSlotsFor(ctx.rosters, name, flow.from, flow.requesterNames, ctx.today, ctx.lastKey);
    if (!candidate.slots.length) {
      return replyMessages(env, replyToken, [textMsg(`${name} 接下來沒有可以跟你互換的${flow.from.role}（或其中一方那天有別的服事）。\n請輸入別的名字，或按「取消」。`, [CANCEL])], fetchImpl);
    }
  } else {
    const c = checkSlot(ctx.rosters, name, flow.from);
    if (!c.ok) warn.push(`⚠️ ${name} 那天已經有不能兼任的服事。`);
    if (c.consecutive) warn.push(`⚠️ ${name} 前後一週也有${flow.from.role}。`);
  }
  if (warn.length) {
    // 還是可以送，管理者核准時會再看
    await lineSend(env, 'reply', { replyToken, messages: [textMsg(warn.join('\n')), await confirmMessageWith(env, uid, flow, candidate)] }, fetchImpl);
    return;
  }
  return chooseCandidate(env, uid, flow, candidate, replyToken, fetchImpl);
}

async function confirmMessageWith(env, uid, flow, candidate) {
  flow.candidate = candidate;
  const msg = await confirmMessage(env, flow);
  await saveFlow(env.BINDINGS, uid, flow);
  return msg;
}

// ── App 管理者 API ──

function corsHeaders(request) {
  const origin = request.headers.get('origin') || '';
  let ok = false;
  try {
    const host = new URL(origin).hostname;
    ok = host === 'ipcf-church-staff.pages.dev' || host.endsWith('.ipcf-church-staff.pages.dev') || host === 'localhost' || host === '127.0.0.1';
  } catch (_) {}
  return ok
    ? {
        'access-control-allow-origin': origin,
        'access-control-allow-methods': 'GET, POST, OPTIONS',
        'access-control-allow-headers': 'authorization, content-type',
        'access-control-max-age': '86400',
        vary: 'origin',
      }
    : {};
}

function apiJson(request, data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...corsHeaders(request) },
  });
}

/** App 傳來的 Firebase 登入憑證：用它讀自己的 users/{uid}，角色要是 admin */
export async function verifyAppAdmin(request, env, fetchImpl = fetch) {
  const auth = request.headers.get('authorization') || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) return null;
  let payload;
  try {
    const part = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    payload = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(part + '='.repeat((4 - (part.length % 4)) % 4)), (c) => c.charCodeAt(0))));
  } catch (_) {
    return null;
  }
  const uid = payload.user_id || payload.sub;
  if (!uid || payload.aud !== env.FIREBASE_PROJECT_ID) return null;
  // Firestore 會驗證這個 token；過期或偽造的讀不到
  const res = await fetchImpl(`${firestoreBase(env)}/users/${encodeURIComponent(uid)}`, { headers: { authorization: `Bearer ${token}` } });
  if (!res.ok) return null;
  const f = (await res.json()).fields || {};
  if (fsValue(f.role) !== 'admin') return null;
  return { uid, name: fsValue(f.name) || fsValue(f.displayName) || fsValue(f.email) || '管理者' };
}

/** 給 App 的申請資料：不含 LINE 使用者 ID */
function publicRequest(r) {
  const { requesterUid, candidateUids, ...rest } = r;
  return { ...rest, candidateBound: (candidateUids || []).length > 0 };
}

async function handleSwapApi(request, env, url, fetchImpl = fetch) {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(request) });
  const admin = await verifyAppAdmin(request, env, fetchImpl);
  if (!admin) return apiJson(request, { error: '只有管理者可以處理換班申請，請重新登入後再試' }, 401);

  if (request.method === 'GET' && url.pathname === '/api/swaps') {
    const all = await listRequests(env.BINDINGS);
    return apiJson(request, { requests: all.map(publicRequest) });
  }

  const m = url.pathname.match(/^\/api\/swaps\/([a-z0-9]+)$/);
  if (request.method === 'POST' && m) {
    const req = await getRequest(env.BINDINGS, m[1]);
    if (!req) return apiJson(request, { error: '找不到這筆申請' }, 404);
    if (req.status !== 'pending') return apiJson(request, { error: `這筆申請${STATUS_ZH[req.status] || '已經處理過'}，不能再核准或退回` }, 409);
    const body = await request.json().catch(() => ({}));
    const approve = body.decision === 'approve';
    if (!approve && body.decision !== 'reject') return apiJson(request, { error: 'decision 要是 approve 或 reject' }, 400);
    if (approve) {
      // App 先改服事表，這裡確認改好了才算核准
      const a = await fetchRoster(env, req.from.rosterId, fetchImpl);
      const okA = a?.duties.some((d) => d.role === req.from.role && hasPerson(d, req.candidate));
      let okB = true;
      if (req.mode === 'swap') {
        const b = await fetchRoster(env, req.to.rosterId, fetchImpl);
        okB = !!b?.duties.some((d) => d.role === req.to.role && hasPerson(d, req.from.person));
      }
      if (!okA || !okB) return apiJson(request, { error: '服事表還沒改好，請重新整理後再按一次核准' }, 409);
    }
    req.status = approve ? 'approved' : 'rejected';
    req.decidedBy = admin.name;
    req.decidedAt = new Date().toISOString();
    if (typeof body.note === 'string' && body.note.trim()) req.note = body.note.trim().slice(0, 200);
    await saveRequest(env.BINDINGS, req);

    const text = approve
      ? `✅ 換班已核准，服事表已更新：\n\n${describeRequest(req)}\n\n謝謝你們的擺上！`
      : `❌ 換班申請沒有核准：\n\n${describeRequest(req)}${req.note ? `\n\n原因：${req.note}` : ''}\n\n原本的服事不變，有問題請跟管理者聯絡。`;
    const targets = new Set([req.requesterUid, ...(req.candidateUids || [])]);
    let notified = 0;
    for (const to of targets) if (to && (await pushMessages(env, to, [textMsg(text)], fetchImpl)).ok) notified++;
    return apiJson(request, { request: publicRequest(req), notified });
  }
  return apiJson(request, { error: 'Not found' }, 404);
}

// ───────────────────────── 其他 ─────────────────────────

function isAdmin(request, env) {
  // 可用 Authorization: Bearer <ADMIN_KEY>，或在瀏覽器網址加 ?key=<ADMIN_KEY>
  const auth = request.headers.get('authorization') || '';
  const key = new URL(request.url).searchParams.get('key') || '';
  const keys = [env.ADMIN_KEY, env.SETUP_KEY].filter(Boolean);
  return keys.some((k) => auth === `Bearer ${k}` || key === k);
}

function json(data) {
  return new Response(JSON.stringify(data, null, 2), { headers: { 'content-type': 'application/json; charset=utf-8' } });
}
