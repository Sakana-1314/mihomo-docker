/* =============================================================================
 * 米哈游 API 加速网关 · 管理面板脚本
 * 全部请求经同源 CGI 代理到内核 API，密钥仅保存在浏览器本地
 * ============================================================================= */
'use strict';

const TOKEN_KEY = 'gw_token';

const state = {
  token: localStorage.getItem(TOKEN_KEY) || '',
  status: null,
  groups: [],
  group: '',
  secretVisible: false,
  trafficTimer: null,
  statusTimer: null,
};

const $ = (id) => document.getElementById(id);

/* ---------------------------------------------------------------- 工具 */
function esc(value) {
  return String(value === undefined || value === null ? '' : value).replace(/[&<>"']/g, (c) => (
    { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]
  ));
}

function fmtBytes(bytes) {
  let n = Number(bytes) || 0;
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i += 1; }
  return i === 0 ? `${n} ${units[i]}` : `${n.toFixed(2)} ${units[i]}`;
}

function fmtTime(iso) {
  if (!iso) return '-';
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString('zh-CN', { hour12: false });
}

function toast(message, ok) {
  const old = document.querySelector('.toast');
  if (old) old.remove();
  const el = document.createElement('div');
  el.className = `toast ${ok ? 'ok' : 'bad'}`;
  el.textContent = message;
  document.body.appendChild(el);
  setTimeout(() => el.remove(), 4200);
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (state.token) headers['X-Panel-Token'] = state.token;
  const res = await fetch(path, Object.assign({}, options, { headers, cache: 'no-store' }));
  if (res.status === 401) {
    showAuth(true);
    throw new Error('unauthorized');
  }
  const data = await res.json().catch(() => ({}));
  return data;
}

function post(body) {
  return api('cgi-bin/subs.sh', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
    body,
  });
}

/* ---------------------------------------------------------------- 鉴权 */
function showAuth(show) {
  $('auth-card').classList.toggle('hidden', !show);
  $('main').classList.toggle('hidden', show);
}

function initAuth() {
  $('token-save').addEventListener('click', () => {
    const value = $('token-input').value.trim();
    if (!value) return;
    state.token = value;
    localStorage.setItem(TOKEN_KEY, value);
    $('token-error').classList.add('hidden');
    start();
  });
  $('token-input').addEventListener('keydown', (e) => {
    if (e.key === 'Enter') $('token-save').click();
  });
}

/* ---------------------------------------------------------------- 概览 */
function kv(label, value, cls) {
  return `<div class="kv"><span>${esc(label)}</span><span class="val ${cls || ''}">${value}</span></div>`;
}

function renderOverview(st) {
  const t = st.transparent || {};
  const p = t.ports || {};
  const k = st.kernel || {};
  const ipv6Map = { block: '阻断转发（推荐）', proxy: '透明代理', pass: '直通' };
  const rows = [
    kv('内核状态', k.online ? `在线 · ${esc(k.version)}` : '离线', k.online ? 'ok' : 'bad'),
    kv('活跃订阅', st.active ? esc(st.active) : '空载基线'),
    kv('透明代理', `${t.state === 'on' ? '已生效' : '未生效'} · ${esc(t.mode || '-')}（${esc(t.interface || '-')}）`,
      t.state === 'on' ? 'ok' : 'bad'),
    kv('DNS 劫持', t.dns_hijack ? `开启 · 端口 ${esc(t.dns_port)}` : '关闭'),
    kv('IPv6 策略', esc(ipv6Map[t.ipv6] || t.ipv6 || '-')),
    kv('监听端口', `混合 ${p.mixed} · 透明 ${t.mode === 'redir' ? p.redir : p.tproxy} · 控制 ${p.controller} · 面板 ${p.panel}`),
  ];
  $('overview').innerHTML = rows.join('');
  $('kernel-badge').textContent = k.online ? `内核：${k.version}` : '内核：离线';
  $('kernel-badge').className = `badge ${k.online ? 'ok' : 'bad'}`;
  $('fw-badge').textContent = `透明代理：${t.state === 'on' ? '已生效' : '未生效'}`;
  $('fw-badge').className = `badge ${t.state === 'on' ? 'ok' : 'bad'}`;
  $('brand-sub').textContent = `mihomo-docker · ${st.active ? `当前订阅 ${st.active}` : '空载基线'}`;
  renderLinks(st, p);
}

function renderLinks(st, ports) {
  const host = location.hostname;
  const panelUrl = location.origin + location.pathname;
  const dashUrl = `http://${host}:${ports.controller}/ui/`;
  const apiUrl = `http://${host}:${ports.controller}`;
  $('panel-link').textContent = panelUrl;
  $('panel-link').href = panelUrl;
  $('dash-link').textContent = dashUrl;
  $('dash-link').href = dashUrl;
  $('api-addr').textContent = apiUrl;
  const secret = (st.panel && st.panel.secret) || '';
  $('secret-text').textContent = secret ? (state.secretVisible ? secret : '••••••••••••') : '（未启用）';
}

/* ---------------------------------------------------------------- 流量 */
function renderTraffic(t) {
  if (!t || typeof t !== 'object') return;
  $('t-down-total').textContent = fmtBytes(t.down_total);
  $('t-up-total').textContent = fmtBytes(t.up_total);
  $('t-down-speed').textContent = `${fmtBytes(t.down_speed)}/s`;
  $('t-up-speed').textContent = `${fmtBytes(t.up_speed)}/s`;
  $('t-conns').textContent = t.connections;
  $('t-memory').textContent = fmtBytes(t.memory);
  $('traffic-updated').textContent = t.ts ? `更新于 ${new Date(t.ts * 1000).toLocaleTimeString('zh-CN', { hour12: false })}` : '-';
}

async function refreshTraffic() {
  if (document.visibilityState !== 'visible' || !state.status) return;
  try {
    const t = await api('cgi-bin/traffic.sh');
    renderTraffic(t);
  } catch (e) { /* 忽略瞬时错误 */ }
}

/* ---------------------------------------------------------------- 订阅 */
function renderSubs(subs) {
  const tbody = $('subs-table').querySelector('tbody');
  const items = (subs && subs.items) || [];
  if (!items.length) {
    tbody.innerHTML = '<tr><td colspan="6" class="hint">尚未配置订阅：可在下方新增，或编辑 /data/config/subscriptions.yaml</td></tr>';
    return;
  }
  tbody.innerHTML = items.map((it) => {
    const active = it.name === subs.active;
    const status = it.status === 'ok'
      ? '<span class="status-ok">正常</span>'
      : (it.status === 'pending'
        ? '<span class="status-warn">尚未拉取</span>'
        : `<span class="status-bad">失败：${esc(it.error || '未知')}</span>`);
    const switchBtn = active
      ? '<button class="tiny" disabled>当前</button>'
      : `<button class="tiny" data-op="switch" data-name="${esc(it.name)}">切换</button>`;
    return `<tr class="${active ? 'active' : ''}">
      <td>${esc(it.name)}<span class="hint">${active ? ' · 当前' : ''}</span></td>
      <td>${esc(it.type || 'auto')}</td>
      <td>${esc(it.nodes)}</td>
      <td>${esc(fmtTime(it.updated_at))}</td>
      <td>${status}</td>
      <td class="right"><div class="ops">
        ${switchBtn}
        <button class="tiny" data-op="update" data-name="${esc(it.name)}">更新</button>
        <button class="tiny danger" data-op="del" data-name="${esc(it.name)}">删除</button>
      </div></td></tr>`;
  }).join('');
}

async function subsAction(body, label) {
  $('subs-message').textContent = `${label}…`;
  try {
    const data = await post(body);
    const ok = data.ok;
    $('subs-message').textContent = data.output || (ok ? '完成' : (data.error || '失败'));
    if (!ok) toast((data.output || data.error || '操作失败'), false);
    else toast(`${label}完成`, true);
    if (data.subs) renderSubs(data.subs);
    await refreshStatus();
  } catch (e) {
    $('subs-message').textContent = '请求失败';
  }
}

function initSubs() {
  $('subs-refresh').addEventListener('click', () => refreshStatus(true));
  $('subs-update-all').addEventListener('click', () => subsAction('action=update&name=all', '更新全部订阅'));
  $('add-submit').addEventListener('click', () => {
    const name = $('add-name').value.trim();
    const url = $('add-url').value.trim();
    const type = $('add-type').value;
    if (!name || !url) { toast('请填写名称与订阅地址', false); return; }
    subsAction(`action=add&name=${encodeURIComponent(name)}&url=${encodeURIComponent(url)}&type=${encodeURIComponent(type)}`, '添加订阅');
  });
  $('subs-table').addEventListener('click', (e) => {
    const btn = e.target.closest('button[data-op]');
    if (!btn) return;
    const name = btn.getAttribute('data-name');
    const op = btn.getAttribute('data-op');
    if (op === 'switch') subsAction(`action=switch&name=${encodeURIComponent(name)}`, `切换到 ${name}`);
    if (op === 'update') subsAction(`action=update&name=${encodeURIComponent(name)}`, `更新 ${name}`);
    if (op === 'del' && window.confirm(`确认删除订阅 ${name}？`)) {
      subsAction(`action=del&name=${encodeURIComponent(name)}`, `删除 ${name}`);
    }
  });
}

/* ---------------------------------------------------------------- 节点 */
async function refreshNodes() {
  try {
    const data = await api('cgi-bin/nodes.sh');
    if (!data.ok) { $('nodes-grid').innerHTML = `<span class="hint">${esc(data.error || '内核未就绪')}</span>`; return; }
    state.groups = data.groups || [];
    if (!state.groups.length) {
      $('group-select').innerHTML = '';
      $('nodes-grid').innerHTML = '<span class="hint">暂无策略组（配置中未包含 proxy-groups）</span>';
      return;
    }
    if (!state.groups.some((g) => g.name === state.group)) state.group = state.groups[0].name;
    $('group-select').innerHTML = state.groups
      .map((g) => `<option value="${esc(g.name)}" ${g.name === state.group ? 'selected' : ''}>${esc(g.name)}（${esc(g.type)}）</option>`)
      .join('');
    renderNodes();
  } catch (e) { /* 忽略 */ }
}

function renderNodes() {
  const group = state.groups.find((g) => g.name === state.group);
  if (!group) return;
  $('group-now').textContent = `当前：${group.now || '-'} · 共 ${group.nodes.length} 个节点`;
  $('nodes-grid').innerHTML = group.nodes.map((n) => (
    `<button class="node ${n === group.now ? 'selected' : ''}" data-node="${esc(n)}" title="${esc(n)}">${esc(n)}</button>`
  )).join('');
}

async function selectNode(node) {
  const group = state.group;
  try {
    const data = await api('cgi-bin/nodes.sh', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8' },
      body: `action=select&group=${encodeURIComponent(group)}&node=${encodeURIComponent(node)}`,
    });
    if (data.ok) {
      toast(`已切换到 ${node}`, true);
      refreshNodes();
    } else {
      toast(data.error || '切换失败', false);
    }
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

/* ---------------------------------------------------------------- 密钥展示 */
function initSecret() {
  $('secret-toggle').addEventListener('click', () => {
    state.secretVisible = !state.secretVisible;
    $('secret-toggle').textContent = state.secretVisible ? '隐藏' : '显示';
    if (state.status) renderLinks(state.status, (state.status.transparent || {}).ports || {});
  });
  $('secret-copy').addEventListener('click', async () => {
    const secret = (state.status && state.status.panel && state.status.panel.secret) || '';
    if (!secret) { toast('当前未启用访问密钥', false); return; }
    try {
      await navigator.clipboard.writeText(secret);
      toast('访问密钥已复制', true);
    } catch (e) {
      toast('复制失败，请手动选择文本', false);
    }
  });
}

/* ---------------------------------------------------------------- 主流程 */
async function refreshStatus(forceSubs) {
  try {
    const st = await api('cgi-bin/status.sh');
    state.status = st;
    renderOverview(st);
    renderTraffic(st.traffic);
    if (forceSubs || st.subs) renderSubs(st.subs);
  } catch (e) { /* 401 已处理 */ }
}

function start() {
  showAuth(false);
  refreshStatus(true);
  refreshTraffic();
  refreshNodes();
  if (state.statusTimer) clearInterval(state.statusTimer);
  if (state.trafficTimer) clearInterval(state.trafficTimer);
  state.statusTimer = setInterval(() => refreshStatus(false), 6000);
  state.trafficTimer = setInterval(refreshTraffic, 2000);
}

document.addEventListener('DOMContentLoaded', () => {
  initAuth();
  initSubs();
  initNodes();
  initSecret();
  $('refresh-overview').addEventListener('click', () => refreshStatus(true));

  if (state.token) {
    start();
  } else {
    // 未持有密钥时先探测：面板未启用密钥（PANEL_AUTH=none）则直接进入
    api('cgi-bin/status.sh')
      .then((st) => {
        state.status = st;
        start();
      })
      .catch(() => showAuth(true));
  }
});
