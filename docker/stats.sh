#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 流量统计
# 数据来源为内核自带接口（/connections、/memory），仅做采样、速率换算与展示
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

gw_human_bytes() { # $1=字节数
  awk -v b="${1:-0}" 'BEGIN {
    split("B KB MB GB TB PB", u, " ")
    i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) { printf "%d %s", b, u[i] } else { printf "%.2f %s", b, u[i] }
  }'
}

gw_state_num() { # $1=名称 → 数值（缺失或非法则 0）
  _v=$(gw_state_get "$1" 2>/dev/null)
  gw_is_num "$_v" || _v=0
  printf '%s' "$_v"
}

cmd_sample() {
  _ts=$(date +%s)
  _conn=$(gw_api GET /connections 2>/dev/null || true)

  _up=0; _down=0; _conns=0
  if [ -n "$_conn" ]; then
    _up=$(printf '%s' "$_conn" | yq -p=json -r '.uploadTotal // 0' - 2>/dev/null || printf '0')
    _down=$(printf '%s' "$_conn" | yq -p=json -r '.downloadTotal // 0' - 2>/dev/null || printf '0')
    _conns=$(printf '%s' "$_conn" | yq -p=json -r '(.connections // []) | length' - 2>/dev/null || printf '0')
  fi
  gw_is_num "$_up" || _up=0
  gw_is_num "$_down" || _down=0
  gw_is_num "$_conns" || _conns=0

  _mem=0
  _mem_raw=$(gw_api GET /memory 2>/dev/null || true)
  if [ -n "$_mem_raw" ]; then
    _mem=$(printf '%s' "$_mem_raw" | yq -p=json -r 'if type == "object" then (.inuse // 0) else . end' - 2>/dev/null || printf '0')
    gw_is_num "$_mem" || _mem=0
  fi

  _prev_ts=$(gw_state_num stats.ts)
  _prev_up=$(gw_state_num stats.up)
  _prev_down=$(gw_state_num stats.down)

  _dt=$((_ts - _prev_ts))
  if [ "$_dt" -le 0 ]; then _dt=1; fi

  _up_speed=$(((_up - _prev_up) / _dt))
  _down_speed=$(((_down - _prev_down) / _dt))
  [ "$_up_speed" -ge 0 ] || _up_speed=0
  [ "$_down_speed" -ge 0 ] || _down_speed=0

  gw_state_set stats.ts "$_ts"
  gw_state_set stats.up "$_up"
  gw_state_set stats.down "$_down"

  printf '{"ts":%s,"up_total":%s,"down_total":%s,"up_speed":%s,"down_speed":%s,"connections":%s,"memory":%s}\n' \
    "$_ts" "$_up" "$_down" "$_up_speed" "$_down_speed" "$_conns" "$_mem" \
    > "$GW_STATE_DIR/traffic.json"
}

cmd_traffic_json() {
  if [ ! -f "$GW_STATE_DIR/traffic.json" ]; then
    cmd_sample
  fi
  cat "$GW_STATE_DIR/traffic.json"
}

cmd_log() {
  [ -f "$GW_STATE_DIR/traffic.json" ] || cmd_sample
  _t=$(cat "$GW_STATE_DIR/traffic.json")
  _up=$(printf '%s' "$_t" | yq -p=json -r '.up_total' - 2>/dev/null || printf '0')
  _down=$(printf '%s' "$_t" | yq -p=json -r '.down_total' - 2>/dev/null || printf '0')
  _us=$(printf '%s' "$_t" | yq -p=json -r '.up_speed' - 2>/dev/null || printf '0')
  _ds=$(printf '%s' "$_t" | yq -p=json -r '.down_speed' - 2>/dev/null || printf '0')
  _cn=$(printf '%s' "$_t" | yq -p=json -r '.connections' - 2>/dev/null || printf '0')
  _mem=$(printf '%s' "$_t" | yq -p=json -r '.memory' - 2>/dev/null || printf '0')
  gw_log "流量统计 | 累计 ↓ $(gw_human_bytes "$_down") / ↑ $(gw_human_bytes "$_up") | 当前 ↓ $(gw_human_bytes "$_ds")/s ↑ $(gw_human_bytes "$_us")/s | 活动连接 $_cn | 内核内存 $(gw_human_bytes "$_mem")"
}

cmd_status() {
  _online=false
  _ver='-'
  if _v=$(gw_api GET /version 2>/dev/null); then
    _online=true
    _ver=$(printf '%s' "$_v" | yq -p=json -r '.version // "unknown"' - 2>/dev/null || printf 'unknown')
  fi
  _active=$(gw_state_get active)
  [ -n "$_active" ] || _active='（空载基线）'
  _act=$(gw_state_get active)
  _nodes=-
  if [ -n "$_act" ] && [ -f "$GW_SUBS_STATE_DIR/$_act.json" ]; then
    _nodes=$(yq -r '.nodes // 0' "$GW_SUBS_STATE_DIR/$_act.json" 2>/dev/null || printf '-')
  fi
  _fw=$(sh "$GW_APP_DIR/firewall.sh" status 2>/dev/null || printf 'off')

  [ -f "$GW_STATE_DIR/traffic.json" ] || cmd_sample
  _t=$(cat "$GW_STATE_DIR/traffic.json" 2>/dev/null || printf '{}')
  _down=$(printf '%s' "$_t" | yq -p=json -r '.down_total // 0' - 2>/dev/null || printf '0')
  _up=$(printf '%s' "$_t" | yq -p=json -r '.up_total // 0' - 2>/dev/null || printf '0')
  _ds=$(printf '%s' "$_t" | yq -p=json -r '.down_speed // 0' - 2>/dev/null || printf '0')
  _us=$(printf '%s' "$_t" | yq -p=json -r '.up_speed // 0' - 2>/dev/null || printf '0')
  _cn=$(printf '%s' "$_t" | yq -p=json -r '.connections // 0' - 2>/dev/null || printf '0')
  _mem=$(printf '%s' "$_t" | yq -p=json -r '.memory // 0' - 2>/dev/null || printf '0')

  printf '米哈游 API 加速网关 · 运行状态\n'
  printf '  内核        ：%s（%s）\n' "$_ver" "$( [ "$_online" = true ] && printf '在线' || printf '离线' )"
  printf '  活跃订阅    ：%s（节点 %s）\n' "$_active" "$_nodes"
  printf '  透明代理    ：%s / 接口 %s / 规则 %s\n' "$TRANSPARENT_MODE" "$GATEWAY_IF" "$_fw"
  printf '  DNS 劫持    ：%s（端口 %s）\n' "$DNS_HIJACK" "$DNS_PORT"
  printf '  IPv6        ：%s\n' "$IPV6_MODE"
  printf '  端口        ：混合 %s / 透明 %s / 控制器 %s / 面板 %s\n' "$MIXED_PORT" "$TPROXY_PORT" "$CONTROLLER_PORT" "$PANEL_PORT"
  printf '  流量        ：累计 ↓ %s / ↑ %s，当前 ↓ %s/s ↑ %s/s\n' \
    "$(gw_human_bytes "$_down")" "$(gw_human_bytes "$_up")" "$(gw_human_bytes "$_ds")" "$(gw_human_bytes "$_us")"
  printf '  连接与内存  ：活动连接 %s，内核内存 %s\n' "$_cn" "$(gw_human_bytes "$_mem")"
}

cmd_status_json() { # 面板综合状态
  _online=false
  _ver='-'
  if _v=$(gw_api GET /version 2>/dev/null); then
    _online=true
    _ver=$(printf '%s' "$_v" | yq -p=json -r '.version // "unknown"' - 2>/dev/null || printf 'unknown')
  fi
  _fw=$(sh "$GW_APP_DIR/firewall.sh" status 2>/dev/null || printf 'off')
  _active=$(gw_state_get active)
  _subs_json=$(sh "$GW_APP_DIR/subs.sh" json 2>/dev/null || printf '{"active":"","total":0,"items":[]}')
  [ -f "$GW_STATE_DIR/traffic.json" ] || cmd_sample
  _traffic=$(cat "$GW_STATE_DIR/traffic.json" 2>/dev/null || printf '{}')

  GW_ON="$_online" GW_VER="$_ver" GW_FW="$_fw" GW_ACTIVE="$_active" \
  GW_MODE="$TRANSPARENT_MODE" GW_IF="$GATEWAY_IF" GW_DNSH="$DNS_HIJACK" GW_DNSPORT="$DNS_PORT" \
  GW_V6="$IPV6_MODE" GW_MIXED="$MIXED_PORT" GW_TPROXY="$TPROXY_PORT" GW_REDIR="$REDIR_PORT" \
  GW_CTRL="$CONTROLLER_PORT" GW_PANEL="$PANEL_PORT" GW_AUTH="${PANEL_AUTH:-token}" \
  GW_PSECRET="${SECRET:-}" \
  GW_SUBS="$_subs_json" GW_TRAFFIC="$_traffic" GW_GEOBOX="$GEO_UPDATE" \
    yq -n -o=json -I0 '
      .kernel = {"online": (strenv(GW_ON) == "true"), "version": strenv(GW_VER)} |
      .active = strenv(GW_ACTIVE) |
      .transparent = {
        "mode": strenv(GW_MODE), "state": strenv(GW_FW), "interface": strenv(GW_IF),
        "dns_hijack": (strenv(GW_DNSH) == "1"), "dns_port": (strenv(GW_DNSPORT) | tonumber),
        "ipv6": strenv(GW_V6),
        "ports": {
          "mixed": (strenv(GW_MIXED) | tonumber), "tproxy": (strenv(GW_TPROXY) | tonumber),
          "redir": (strenv(GW_REDIR) | tonumber), "controller": (strenv(GW_CTRL) | tonumber),
          "panel": (strenv(GW_PANEL) | tonumber)
        }
      } |
      .traffic = (strenv(GW_TRAFFIC) | from_json) |
      .subs = (strenv(GW_SUBS) | from_json) |
      .panel = {"auth": strenv(GW_AUTH), "secret": strenv(GW_PSECRET), "geo_auto_update": (strenv(GW_GEOBOX) == "1")}
    '
}

case "${1:-}" in
  sample)       cmd_sample ;;
  log)          cmd_log ;;
  status)       cmd_status ;;
  status-json)  cmd_status_json ;;
  traffic-json) cmd_traffic_json ;;
  human)        shift; gw_human_bytes "${1:-0}" ;;
  *) echo "用法: stats.sh sample|log|status|status-json|traffic-json|human <字节>" >&2; exit 2 ;;
esac
