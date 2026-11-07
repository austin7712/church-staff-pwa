// 換班／代班流程的測試：假的 KV、Firestore、LINE，從按鈕一路走到管理者核准。
// 執行：node --test ipcf/line-reminder/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleEvent, recommend, checkSlot, rolesCanShare, parsePools, addDays, localParts } from './worker.js';

const TODAY = localParts(new Date(), 'America/Los_Angeles').dateKey;
// 下一個週日開始的幾個主日
function sunday(n) {
  let d = addDays(TODAY, 1);
  while (new Date(`${d}T12:00:00Z`).getUTCDay() !== 0) d = addDays(d, 1);
  return addDays(d, 7 * n);
}

function fsVal(v) {
  if (typeof v === 'string') return { stringValue: v };
  if (typeof v === 'boolean') return { booleanValue: v };
  if (typeof v === 'number') return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(fsVal) } };
  return { mapValue: { fields: Object.fromEntries(Object.entries(v).map(([k, x]) => [k, fsVal(x)])) } };
}

function setup({ rosters, pool, users = {} }) {
  const kv = new Map();
  const KV = {
    get: async (k) => kv.get(k) ?? null,
    put: async (k, v) => void kv.set(k, v),
    delete: async (k) => void kv.delete(k),
    list: async ({ prefix }) => ({ keys: [...kv.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }),
  };
  const sent = [];
  const db = { rosters: structuredClone(rosters) };
  const doc = (r) => ({
    name: `projects/p/databases/(default)/documents/rosters/${r.id}`,
    fields: { dateKey: fsVal(r.dateKey), serviceName: fsVal(r.serviceName), duties: fsVal(r.duties) },
  });
  const fetchImpl = async (url, init = {}) => {
    const u = String(url);
    const ok = (data) => ({ ok: true, status: 200, json: async () => data, text: async () => JSON.stringify(data) });
    if (u.includes('identitytoolkit')) return ok({ idToken: 'bot', expiresIn: '3600' });
    if (u.includes('api.line.me')) {
      sent.push({ kind: u.split('/').pop(), body: JSON.parse(init.body) });
      return ok({});
    }
    if (u.endsWith(':runQuery')) {
      const q = JSON.parse(init.body).structuredQuery.where.compositeFilter.filters;
      const from = q[0].fieldFilter.value.stringValue;
      const to = q[1].fieldFilter.value.stringValue;
      return ok(db.rosters.filter((r) => r.dateKey >= from && r.dateKey <= to).sort((a, b) => a.dateKey.localeCompare(b.dateKey)).map((r) => ({ document: doc(r) })));
    }
    if (u.includes('/settings/auto_assign')) return ok({ fields: { service1: fsVal(pool) } });
    const m = u.match(/\/rosters\/([^/?]+)$/);
    if (m) {
      const r = db.rosters.find((x) => x.id === decodeURIComponent(m[1]));
      return r ? ok(doc(r)) : { ok: false, status: 404, text: async () => '' };
    }
    const um = u.match(/\/users\/([^/?]+)$/);
    if (um) {
      const user = users[decodeURIComponent(um[1])];
      const token = (init.headers?.authorization || '').slice(7);
      if (!user || token !== user.token) return { ok: false, status: 403, text: async () => '' };
      return ok({ fields: { role: fsVal(user.role), name: fsVal(user.name) } });
    }
    throw new Error(`unexpected fetch ${u}`);
  };
  const env = { BINDINGS: KV, FIREBASE_PROJECT_ID: 'proj', FIREBASE_API_KEY: 'k', BOT_EMAIL: 'b', BOT_PASSWORD: 'p', LINE_CHANNEL_ACCESS_TOKEN: 't' };
  const say = (uid, text) => handleEvent(env, { type: 'message', replyToken: 'r', source: { type: 'user', userId: uid }, message: { type: 'text', text } }, fetchImpl);
  const tap = (uid, data) => handleEvent(env, { type: 'postback', replyToken: 'r', source: { type: 'user', userId: uid }, postback: { data } }, fetchImpl);
  const last = () => sent.at(-1);
  const lastText = () => last().body.messages.map((m) => m.text || m.template?.text).join('\n');
  return { env, kv, sent, db, say, tap, last, lastText, fetchImpl };
}

const roster = (id, dateKey, duties) => ({ id, dateKey, serviceName: '主日崇拜', duties: duties.map(([role, ...people]) => ({ role, people })) });

function sampleRosters() {
  return [
    roster('a0', sunday(0), [['音控', 'Austin'], ['司會報告', 'Kevin'], ['奉獻點算', 'Grace']]),
    roster('a1', sunday(1), [['音控', 'Daniel'], ['敬拜讚美', 'Joe']]),
    roster('a2', sunday(2), [['音控', 'Henry'], ['奉獻點算', 'Austin']]),
    roster('a3', sunday(3), [['音控', 'Joe']]),
    // 今年過去的服事：Henry 服事很多天
    roster('p1', addDays(sunday(0), -14), [['音控', 'Henry'], ['招待', 'Henry']]),
    roster('p2', addDays(sunday(0), -21), [['音控', 'Victor'], ['司會報告', 'Henry']]),
  ];
}
const samplePool = { pool: { 音控: ['Austin', 'Daniel', 'Henry', 'Joe', 'Kevin', 'Victor', 'Paulina'] }, ratios: [{ role: '音控', person: 'Paulina', ratio: 0 }] };

test('兼任規則跟 app 一樣', () => {
  assert.equal(rolesCanShare('奉獻點算', '音控'), true);
  assert.equal(rolesCanShare('聖餐長老', '報告'), true);
  assert.equal(rolesCanShare('音控', '敬拜讚美'), false);
  assert.equal(rolesCanShare('音控', '音控'), false);
});

test('同工名單合併各聚會，服事比例讀得到 0 與小數', () => {
  const p = parsePools({ service1: { pool: { 收奉: ['Grace'] }, ratios: [{ role: '音控', person: 'Joe', ratio: 0.25 }] }, other: { pool: { 奉獻點算: ['grace', 'Kevin'] } }, updatedAt: 'x' });
  assert.deepEqual(p.roles['奉獻點算'], ['Grace', 'Kevin']);
  assert.equal(p.ratios['音控'].joe, 0.25);
});

test('代班推薦：排除自己、當天不能兼任、前後一週同一項、比例 0%，天數少的在前', () => {
  const rosters = sampleRosters();
  const slot = { rosterId: 'a0', dateKey: sunday(0), serviceName: '主日崇拜', role: '音控', person: 'Austin' };
  const list = recommend({ rosters, pools: parsePools({ s: samplePool }), slot, requesterNames: ['Austin'], mode: 'sub', todayKey: TODAY, lastKey: addDays(TODAY, 112) });
  const names = list.map((c) => c.name);
  assert.ok(!names.includes('Austin'));
  assert.ok(!names.includes('Kevin'), 'Kevin 當天司會報告，不能兼音控');
  assert.ok(!names.includes('Daniel'), 'Daniel 下週音控，連續');
  assert.ok(!names.includes('Paulina'), '比例 0%');
  assert.ok(names.includes('Victor'));
});

test('Henry 不算連續（兩週前），但天數多排在後面', () => {
  const rosters = sampleRosters().filter((r) => r.id !== 'a2');
  const slot = { rosterId: 'a0', dateKey: sunday(0), serviceName: '主日崇拜', role: '音控', person: 'Austin' };
  const list = recommend({ rosters, pools: parsePools({ s: samplePool }), slot, requesterNames: ['Austin'], mode: 'sub', todayKey: TODAY, lastKey: addDays(TODAY, 112) });
  const names = list.map((c) => c.name);
  assert.ok(names.includes('Henry'));
  // Victor 今年 1 天、Henry 2 天
  assert.ok(names.indexOf('Victor') < names.indexOf('Henry'));
});

test('checkSlot：互換時換出去的那一格不算連續', () => {
  const rosters = sampleRosters();
  const mine = { rosterId: 'a0', dateKey: sunday(0), role: '音控' };
  assert.equal(checkSlot(rosters, 'Daniel', mine).consecutive, true);
  assert.equal(checkSlot(rosters, 'Daniel', mine, new Set(['a1|音控'])).consecutive, false);
});

test('代班：私下講好 → 送出 → 管理者核准 → 通知雙方', async () => {
  const s = setup({ rosters: sampleRosters(), pool: samplePool, users: { admin1: { role: 'admin', name: 'Lin', token: 'h.' + btoa(JSON.stringify({ user_id: 'admin1', aud: 'proj' })) + '.s' } } });
  await s.kv.set('user:U1', JSON.stringify(['Austin']));
  await s.kv.set('name:austin', JSON.stringify(['U1']));
  await s.kv.set('name:joe', JSON.stringify(['U2']));

  await s.say('U1', '換班');
  assert.match(s.lastText(), /要換哪一個服事/);
  const items = s.last().body.messages[0].quickReply.items;
  assert.equal(items[0].action.data, 'sw:pick:0');
  assert.match(items[0].action.label, /音控/);

  await s.tap('U1', 'sw:pick:0');
  assert.match(s.lastText(), /代班/);
  await s.tap('U1', 'sw:mode:sub');
  assert.match(s.lastText(), /推薦代班人選/);
  assert.doesNotMatch(s.lastText(), /Kevin|Daniel|Paulina/);

  // 直接打名字
  await s.say('U1', 'joe');
  assert.match(s.lastText(), /申請內容/);
  assert.match(s.lastText(), /Austin → Joe/);
  await s.tap('U1', 'sw:send:private');
  assert.match(s.lastText(), /已送出申請/);

  const reqKey = [...s.kv.keys()].find((k) => k.startsWith('swapreq:'));
  const req = JSON.parse(s.kv.get(reqKey));
  assert.equal(req.status, 'pending');
  assert.equal(req.candidate, 'Joe');

  // 同一格不能重複申請
  await s.say('U1', '換班');
  await s.tap('U1', 'sw:pick:0');
  await s.tap('U1', 'sw:mode:sub');
  await s.say('U1', 'Victor');
  await s.tap('U1', 'sw:send:private');
  assert.match(s.lastText(), /已經有一筆申請在處理中/);

  // 管理者 API
  const { default: worker } = await import('./worker.js');
  const token = s.env && 'h.' + btoa(JSON.stringify({ user_id: 'admin1', aud: 'proj' })) + '.s';
  const call = (path, init = {}) => {
    const orig = globalThis.fetch;
    globalThis.fetch = s.fetchImpl;
    return worker
      .fetch(new Request(`https://w.example${path}`, { ...init, headers: { authorization: `Bearer ${token}`, origin: 'https://dev.ipcf-church-staff.pages.dev', 'content-type': 'application/json' } }), s.env, {})
      .finally(() => (globalThis.fetch = orig));
  };
  const list = await (await call('/api/swaps')).json();
  assert.equal(list.requests.length, 1);
  assert.equal(list.requests[0].requesterUid, undefined, '不外流 LINE ID');

  // 服事表還沒改就核准 → 409
  let res = await call(`/api/swaps/${req.id}`, { method: 'POST', body: JSON.stringify({ decision: 'approve' }) });
  assert.equal(res.status, 409);
  assert.equal(res.headers.get('access-control-allow-origin'), 'https://dev.ipcf-church-staff.pages.dev');

  // App 改好服事表
  s.db.rosters.find((r) => r.id === 'a0').duties[0].people = ['Joe'];
  const before = s.sent.length;
  res = await call(`/api/swaps/${req.id}`, { method: 'POST', body: JSON.stringify({ decision: 'approve' }) });
  assert.equal(res.status, 200);
  const pushed = s.sent.slice(before).filter((m) => m.kind === 'push');
  assert.deepEqual(pushed.map((m) => m.body.to).sort(), ['U1', 'U2']);
  assert.match(pushed[0].body.messages[0].text, /已核准/);

  // 非管理者
  const bad = await worker.fetch(new Request('https://w.example/api/swaps', { headers: { authorization: 'Bearer x.y.z' } }), s.env, {});
  assert.equal(bad.status, 401);
});

test('互換：請小幫手問 → 對方婉拒 → 申請人收到新的推薦名單（去掉婉拒的人）', async () => {
  const rosters = [
    roster('a0', sunday(0), [['音控', 'Austin']]),
    roster('a2', sunday(2), [['音控', 'Joe']]),
    roster('a4', sunday(4), [['音控', 'Victor']]),
  ];
  const s = setup({ rosters, pool: { pool: { 音控: ['Austin', 'Joe', 'Victor'] } } });
  await s.kv.set('user:U1', JSON.stringify(['Austin']));
  await s.kv.set('name:austin', JSON.stringify(['U1']));
  await s.kv.set('name:joe', JSON.stringify(['U2']));

  await s.say('U1', '換班');
  await s.tap('U1', 'sw:pick:0');
  await s.tap('U1', 'sw:mode:swap');
  assert.match(s.lastText(), /推薦互換人選/);
  assert.match(s.lastText(), /Joe/);
  assert.match(s.lastText(), /Victor/);
  const idx = s.last().body.messages[0].quickReply.items.findIndex((i) => /Joe/.test(i.action.label));
  await s.tap('U1', `sw:cand:${idx}`);
  assert.match(s.lastText(), /互換/);
  await s.tap('U1', 'sw:send:ask');

  const ask = s.sent.find((m) => m.kind === 'push' && m.body.to === 'U2');
  assert.ok(ask, '私訊 Joe');
  const no = ask.body.messages[0].template.actions[1].data;
  await s.tap('U2', no);
  const back = s.sent.at(-1);
  assert.equal(back.kind, 'push');
  assert.equal(back.body.to, 'U1');
  const text = back.body.messages[0].text;
  assert.match(text, /Joe 這次不方便/);
  assert.match(text, /Victor/);
  assert.doesNotMatch(text.split('推薦')[1], /Joe/);
  // 申請人可以直接從新的名單選
  const vi = back.body.messages[0].quickReply.items.findIndex((i) => /Victor/.test(i.action.label));
  await s.tap('U1', `sw:cand:${vi}`);
  assert.match(s.lastText(), /申請內容/);
});
