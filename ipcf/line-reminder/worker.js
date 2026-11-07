// IPCF 同工 LINE 服事提醒
//
// 單一檔案的 Cloudflare Worker，可直接貼進 Cloudflare 後台的程式編輯器。
//
// 功能：
//   1. LINE webhook：同工對官方帳號傳「綁定 名字」，把 LINE 帳號和服事表上的名字對起來。
//      也支援「解除綁定」、「我的服事」、「說明」。回覆訊息不計入 LINE 免費額度。
//   2. 排程（Cron）：每週三、週六晚上 8 點（教會時區）讀 Firestore 服事表，
//      只私訊接下來 4 天內有服事的人。
//   3. 管理用網址（加 ?key=ADMIN_KEY）：/admin/preview 預覽會發給誰（不發送）、/admin/run 立即發送、
//      /admin/richmenu 建立下方圖文選單（我的服事／本週服事表／使用說明／開啟同工 App）。
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
  return rows
    .filter((r) => r.document)
    .map((r) => {
      const f = r.document.fields || {};
      return {
        dateKey: fsValue(f.dateKey),
        serviceName: fsValue(f.serviceName) || '主日崇拜',
        duties: (fsValue(f.duties) || []).map((d) => ({ role: canonicalRole(d?.role), people: d?.people || [] })),
      };
    });
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
const ROLE_ORDER = ['台語講員', '華語講員', '司會報告', '敬拜讚美', '音控', '奉獻點算', '聖餐長老', '兒童主日', '幼兒主日', '愛餐整理'];

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
  '・解除綁定：停止提醒',
  '・說明：再看一次這段說明',
  '',
  '如果無法服事，請盡早告知同工協調。',
].join('\n');

// 下方圖文選單用的圖片（2500×843），放在 GitHub 上讓 Worker 抓。
const RICH_MENU_IMAGE =
  'https://raw.githubusercontent.com/austin7712/church-staff-pwa/dev/ipcf/line-reminder/richmenu.png';

/** 建立下方的圖文選單並設成預設（舊的預設選單會一併刪掉）。 */
async function setupRichMenu(env, imageUrl, fetchImpl = fetch) {
  const auth = { authorization: `Bearer ${env.LINE_CHANNEL_ACCESS_TOKEN}` };
  const site = env.SITE_URL || 'https://ipcf-church-staff.pages.dev';
  const W = 2500;
  const H = 843;
  const cell = W / 4;
  const actions = [
    { type: 'message', label: '我的服事', text: '我的服事' },
    { type: 'message', label: '本週服事表', text: '本週服事表' },
    { type: 'message', label: '使用說明', text: '說明' },
    { type: 'uri', label: '開啟同工 App', uri: `${site}/?openExternalBrowser=1` },
  ];
  const menu = {
    size: { width: W, height: H },
    selected: true,
    name: 'IPCF 服事小幫手',
    chatBarText: '服事選單',
    areas: actions.map((action, i) => ({
      bounds: { x: Math.round(i * cell), y: 0, width: Math.round(cell), height: H },
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
  if (event.type !== 'message' || event.message?.type !== 'text') return;

  const text = event.message.text.trim();
  const today = localParts(new Date(), tz(env)).dateKey;

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
