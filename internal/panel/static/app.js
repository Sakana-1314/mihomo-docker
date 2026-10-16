/* 米哈游 API 加速网关 · 面板脚本（同源接口，密钥仅存浏览器本地） */
'use strict';

const TOKEN_KEY = 'gw_token';
const state = {
  token: localStorage.getItem(TOKEN_KEY) || '',
  status: null,
  groups: [],
  group: '',
  statusTimer: null,
  trafficTimer: null,
};

const $ = (id) => document.getElementById(id);

/* ---------------------------------------------------------------- 工具 */
function esc(v) {
  return String(v === undefined || v === null ? '' : v).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function bytes(n) {
  let v = Number(n) || 0;
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i += 1; }
  return i === 0 ? `${v} B` : `${v.toFixed(v < 10 ? 2 : 1)} ${u[i]}`;
}

function time(iso) {
  if (!iso) return '-';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  const p = (x) => String(x).padStart(2, '0');
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

let toastTimer = null;
function toast(msg, kind) {
  const el = $('toast');
  el.textContent = msg;
  el.className = `toast ${kind || ''}`;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.add('hidden'), 4000);
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (state.token) headers['X-Panel-Token'] = state.token;
  const res = await fetch(path, Object.assign({}, options, { headers, cache: 'no-store' }));
  if (res.status === 401) { showAuth(true); throw new Error('unauthorized'); }
  return res.json().catch(() => ({}));
}

function form(obj) {
  const p = new URLSearchParams();
  Object.entries(obj).forEach(([k, v]) => p.set(k, v === undefined || v === null ? '' : v));
  return p.toString();
}

/* ---------------------------------------------------------------- 登录 */
function showAuth(show) {
  $('auth').classList.toggle('hidden', !show);
  $('app').classList.toggle('hidden', show);
}

function initAuth() {
  $('auth-form').addEventListener('submit', (e) => {
    e.preventDefault();
    const v = $('token-input').value.trim();
    if (!v) return;
    state.token = v;
    localStorage.setItem(TOKEN_KEY, v);
    $('token-error').classList.add('hidden');
    start();
  });
}

/* ---------------------------------------------------------------- 状态 */
function renderStatus(st) {
  const k = st.kernel || {};
  const t = st.transparent || {};
  const subs = st.subs || {};

  const pill = (el, ok, text) => {
    el.className = `pill ${ok ? 'ok' : 'bad'}`;
    el.textContent = text;
  };
  pill($('p-kernel'), k.online, k.online ? `内核 ${k.version}` : '内核离线');
  pill($('p-fw'), t.state === 'on', `透明代理 ${t.mode}`);
  const active = st.active || 'baseline';
  pill($('p-sub'), true, `订阅 ${active}`);

  $('t-mode').textContent = t.mode;
  $('t-ipv6').textContent = t.ipv6;
  renderTraffic(st.traffic);
  renderSubs(subs);
  renderLinks(st, t.ports || {});
}

function renderTraffic(tr) {
  if (!tr || typeof tr !== 'object') return;
  $('t-down-speed').textContent = `${bytes(tr.down_speed)}/s`;
  $('t-up-speed').textContent = `${bytes(tr.up_speed)}/s`;
  $('t-down-total').textContent = bytes(tr.down_total);
  $('t-up-total').textContent = bytes(tr.up_total);
  $('t-conns').textContent = tr.connections;
  $('t-memory').textContent = bytes(tr.memory);
}

async function refreshTraffic() {
  if (document.visibilityState !== 'visible' || !state.status) return;
  try { renderTraffic(await api('api/traffic')); } catch (e) { /* 忽略瞬时错误 */ }
}

/* ---------------------------------------------------------------- 订阅 */
function renderSubs(subs) {
  const tbody = $('subs-table').querySelector('tbody');
  const items = (subs && subs.items) || [];
  if (!items.length) {
    tbody.innerHTML = '<tr><td colspan="6" class="empty">无订阅</td></tr>';
    return;
  }
  tbody.innerHTML = items.map((it) => {
    const isActive = it.name === subs.active;
    let cls = 'state';
    let label = '正常';
    if (it.status === 'ok') { cls += ' ok'; }
    else if (it.status === 'pending' || !it.status) { cls += ' pending'; label = '未拉取'; }
    else { cls += ' bad'; label = `失败 ${esc(it.error || '')}`.trim(); }
    const op = isActive
      ? '<button class="btn tiny" disabled>使用中</button>'
      : `<button class="btn tiny" data-op="switch" data-name="${esc(it.name)}">切换</button>`;
    return `<tr class="${isActive ? 'active' : ''}">
      <td>${esc(it.name)}</td>
      <td class="mono">${esc(it.type || 'auto')}</td>
      <td class="num mono">${it.nodes || 0}</td>
      <td class="mono">${esc(time(it.updated_at))}</td>
      <td><span class="${cls}">${label}</span></td>
      <td class="right"><span class="ops">
        ${op}
        <button class="btn tiny" data-op="update" data-name="${esc(it.name)}">更新</button>
        <button class="btn tiny danger" data-op="del" data-name="${esc(it.name)}">删除</button>
      </span></td></tr>`;
  }).join('');
}

async function subsAction(path, body, label, method) {
  try {
    const data = await api(path, {
      method: method || 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: body || '',
    });
    if (data.ok) toast(data.output || label, 'ok');
    else toast(data.output || data.error || '失败', 'bad');
    if (data.subs) renderSubs(data.subs);
    await refreshStatus();
  } catch (e) { /* 401 已处理 */ }
}

function initSubs() {
  $('subs-update-all').addEventListener('click', () => subsAction('api/subs/update', form({ name: 'all' }), '订阅已更新'));
  $('add-submit').addEventListener('click', () => {
    const name = $('add-name').value.trim();
    const url = $('add-url').value.trim();
    if (!name || !url) { toast('名称与地址必填', 'bad'); return; }
    subsAction('api/subs', form({ name, url, type: $('add-type').value }), `已添加 ${name}`).then(() => {
      $('add-name').value = '';
      $('add-url').value = '';
    });
  });
  $('subs-table').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-op]');
    if (!btn) return;
    const name = btn.getAttribute('data-name');
    const op = btn.getAttribute('data-op');
    if (op === 'switch') subsAction('api/subs/switch', form({ name }), `已切换到 ${name}`);
    if (op === 'update') subsAction('api/subs/update', form({ name }), `${name} 已更新`);
    if (op === 'del' && window.confirm(`删除订阅 ${name}？`)) {
      subsAction(`api/subs/${encodeURIComponent(name)}`, '', `已删除 ${name}`, 'DELETE');
    }
  });
}

/* ---------------------------------------------------------------- 分组 */
async function refreshNodes() {
  try {
    const data = await api('api/nodes');
    state.groups = data.groups || [];
    if (!state.groups.length) {
      $('group-select').innerHTML = '';
      $('group-now').textContent = '';
      $('nodes-grid').innerHTML = '<span class="empty">无策略组</span>';
      return;
    }
    if (!state.groups.some((g) => g.name === state.group)) state.group = state.groups[0].name;
    $('group-select').innerHTML = state.groups
      .map((g) => `<option value="${esc(g.name)}" ${g.name === state.group ? 'selected' : ''}>${esc(g.name)} · ${esc(g.type)}</option>`)
      .join('');
    renderNodes();
  } catch (e) { /* 忽略 */ }
}

function renderNodes() {
  const g = state.groups.find((x) => x.name === state.group);
  if (!g) return;
  $('group-now').textContent = `${g.now || '-'} · ${g.nodes.length}`;
  $('nodes-grid').innerHTML = g.nodes.map((n) => (
    `<button class="node ${n === g.now ? 'selected' : ''}" data-node="${esc(n)}" title="${esc(n)}">${esc(n)}</button>`
  )).join('') || '<span class="empty">无节点</span>';
}

async function selectNode(node) {
  try {
    const data = await api('api/nodes/select', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: form({ group: state.group, node }),
    });
    if (data.ok) { toast(`已切换到 ${node}`, 'ok'); refreshNodes(); }
    else toast(data.error || '切换失败', 'bad');
  } catch (e) { /* 忽略 */ }
}

function initNodes() {
  $('nodes-refresh').addEventListener('click', refreshNodes);
  $('group-select').addEventListener('change', (e) => { state.group = e.target.value; renderNodes(); });
  $('nodes-grid').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-node]');
    if (btn) selectNode(btn.getAttribute('data-node'));
  });
}

/* ---------------------------------------------------------------- 入口 */
function renderLinks(st, ports) {
  const host = location.hostname;
  const panel = `${location.origin}/`;
  const dash = `http://${host}:${ports.controller}/ui/`;
  $('panel-link').textContent = `${host}:${ports.panel}`;
  $('panel-link').href = panel;
  $('dash-link').textContent = `${host}:${ports.controller}/ui/`;
  $('dash-link').href = dash;
  $('api-addr').textContent = `${host}:${ports.controller}`;
  const secret = (st.panel && st.panel.secret) || '';
  $('secret-text').textContent = secret || '未启用';
  $('secret-text').dataset.secret = secret;
}

function initLinks() {
  $('secret-copy').addEventListener('click', async () => {
    const secret = $('secret-text').dataset.secret || '';
    if (!secret) { toast('未启用访问密钥', 'bad'); return; }
    try { await navigator.clipboard.writeText(secret); toast('密钥已复制', 'ok'); }
    catch (e) { toast('复制失败', 'bad'); }
  });
  $('btn-key').addEventListener('click', () => {
    const secret = $('secret-text').dataset.secret || '';
    toast(secret ? `访问密钥：${secret}` : '未启用访问密钥', 'ok');
  });
}

/* ---------------------------------------------------------------- 主流程 */
async function refreshStatus() {
  try {
    const st = await api('api/status');
    state.status = st;
    renderStatus(st);
  } catch (e) { /* 401 已处理 */ }
}

function start() {
  showAuth(false);
  refreshStatus();
  refreshTraffic();
  refreshNodes();
  clearInterval(state.statusTimer);
  clearInterval(state.trafficTimer);
  state.statusTimer = setInterval(refreshStatus, 5000);
  state.trafficTimer = setInterval(refreshTraffic, 2000);
}

document.addEventListener('DOMContentLoaded', () => {
  initAuth();
  initSubs();
  initNodes();
  initLinks();
  $('btn-refresh').addEventListener('click', () => { refreshStatus(); refreshNodes(); });

  if (state.token) {
    start();
  } else {
    api('api/status').then((st) => { state.status = st; start(); }).catch(() => showAuth(true));
  }
});
