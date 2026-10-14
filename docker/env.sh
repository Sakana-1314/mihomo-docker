#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 环境解析
# 生成 /data/state/gw.env（所有脚本与 CGI 复用）与 /data/state/runtime.yaml
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"

gw_env_put() { # $1=键 $2=值（单引号安全写入临时文件）
  _v=$(printf '%s' "$2" | sed "s/'/'\\\\''/g")
  printf "%s='%s'\n" "$1" "$_v" >> "$GW_STATE_DIR/gw.env.tmp"
}

gw_resolve_if() {
  if [ -n "${GATEWAY_IF:-}" ]; then printf '%s' "$GATEWAY_IF"; return; fi
  _if=$(ip route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
  if [ -z "$_if" ]; then
    _if=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 != "lo" && $2 != "" { print $2; exit }')
  fi
  printf '%s' "$_if"
}

gw_resolve_secret() {
  if [ -n "${SECRET:-}" ]; then printf '%s' "$SECRET"; return; fi
  if [ -f "$GW_STATE_DIR/secret" ]; then
    cat "$GW_STATE_DIR/secret"
    return
  fi
  _s=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
  printf '%s' "$_s" > "$GW_STATE_DIR/secret"
  chmod 600 "$GW_STATE_DIR/secret"
  printf '%s' "$_s"
}

gw_port_or_default() { # $1=值 $2=默认 $3=名称
  _v="${1:-}"
  [ -n "$_v" ] || _v="$2"
  gw_is_num "$_v" || gw_die "$3 必须是数字端口：$1"
  if [ "$_v" -lt 1 ] || [ "$_v" -gt 65535 ]; then
    gw_die "$3 端口超出范围：$_v"
  fi
  printf '%s' "$_v"
}

cmd_resolve() {
  mkdir -p "$GW_STATE_DIR" "$GW_SUBS_STATE_DIR" "$GW_LOG_DIR"
  rm -f "$GW_STATE_DIR/gw.env.tmp"

  # ---- 透明代理模式 ----
  TRANSPARENT_MODE=$(printf '%s' "${TRANSPARENT_MODE:-tproxy}" | tr '[:upper:]' '[:lower:]')
  case "$TRANSPARENT_MODE" in
    tproxy|redir|off) ;;
    *) gw_die "TRANSPARENT_MODE 仅支持 tproxy / redir / off，当前：$TRANSPARENT_MODE" ;;
  esac

  IPV6_MODE=$(printf '%s' "${IPV6_MODE:-block}" | tr '[:upper:]' '[:lower:]')
  case "$IPV6_MODE" in
    block|proxy|pass) ;;
    *) gw_die "IPV6_MODE 仅支持 block / proxy / pass，当前：$IPV6_MODE" ;;
  esac

  FW_BACKEND=$(printf '%s' "${FW_BACKEND:-legacy}" | tr '[:upper:]' '[:lower:]')
  case "$FW_BACKEND" in
    legacy|nft) ;;
    *) gw_die "FW_BACKEND 仅支持 legacy / nft，当前：$FW_BACKEND" ;;
  esac

  # 日志级别：仅在显式设置 LOG_LEVEL 时注入（否则以覆盖层/订阅中的值为准）
  if [ -n "${LOG_LEVEL:-}" ]; then LOG_LEVEL_INJECT=1; else LOG_LEVEL_INJECT=0; fi
  LOG_LEVEL=$(printf '%s' "${LOG_LEVEL:-info}" | tr '[:upper:]' '[:lower:]')
  case "$LOG_LEVEL" in
    debug|info|warning|error|silent) ;;
    *) gw_die "LOG_LEVEL 仅支持 debug / info / warning / error / silent，当前：$LOG_LEVEL" ;;
  esac

  GATEWAY_IF=$(gw_resolve_if)
  [ -n "$GATEWAY_IF" ] || gw_warn "未能自动识别网关接口，透明代理规则可能无法生效（可通过 GATEWAY_IF 显式指定）"

  MIXED_PORT=$(gw_port_or_default "${MIXED_PORT:-}" 7890 MIXED_PORT)
  REDIR_PORT=$(gw_port_or_default "${REDIR_PORT:-}" 7892 REDIR_PORT)
  TPROXY_PORT=$(gw_port_or_default "${TPROXY_PORT:-}" 7893 TPROXY_PORT)
  DNS_PORT=$(gw_port_or_default "${DNS_PORT:-}" 53 DNS_PORT)
  CONTROLLER_PORT=$(gw_port_or_default "${CONTROLLER_PORT:-}" 9090 CONTROLLER_PORT)
  PANEL_PORT=$(gw_port_or_default "${PANEL_PORT:-}" 8080 PANEL_PORT)

  DNS_HIJACK=$(gw_bool "${DNS_HIJACK:-1}")
  GEO_UPDATE=$(gw_bool "${GEO_UPDATE:-1}")
  SUB_UPDATE_ON_BOOT=$(gw_bool "${SUB_UPDATE_ON_BOOT:-0}")
  SUB_VIA_PROXY=$(gw_bool "${SUB_VIA_PROXY:-1}")

  PANEL_AUTH=$(printf '%s' "${PANEL_AUTH:-token}" | tr '[:upper:]' '[:lower:]')
  case "$PANEL_AUTH" in token|none) ;; *) gw_die "PANEL_AUTH 仅支持 token / none，当前：$PANEL_AUTH" ;; esac

  SECRET=$(gw_resolve_secret)

  # ---- 数值型参数（0 视为关闭）----
  GEO_UPDATE_INTERVAL="${GEO_UPDATE_INTERVAL:-24}"
  SUB_UPDATE_INTERVAL="${SUB_UPDATE_INTERVAL:-21600}"
  SUB_TIMEOUT="${SUB_TIMEOUT:-30}"
  STATS_LOG_INTERVAL="${STATS_LOG_INTERVAL:-1800}"
  for _pair in "GEO_UPDATE_INTERVAL:$GEO_UPDATE_INTERVAL" "SUB_UPDATE_INTERVAL:$SUB_UPDATE_INTERVAL" \
               "SUB_TIMEOUT:$SUB_TIMEOUT" "STATS_LOG_INTERVAL:$STATS_LOG_INTERVAL"; do
    _k=${_pair%%:*}; _v=${_pair#*:}
    gw_is_num "$_v" || gw_die "$_k 必须是数字，当前：$_v"
  done
  [ "$SUB_TIMEOUT" -ge 5 ] || gw_die "SUB_TIMEOUT 至少为 5 秒"

  SUB_USER_AGENT="${SUB_USER_AGENT:-clash.meta}"
  ACTIVE_PROFILE="${ACTIVE_PROFILE:-}"
  BYPASS_CIDRS="${BYPASS_CIDRS:-10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10}"
  TZ="${TZ:-Asia/Shanghai}"

  # ---- 写入 gw.env ----
  gw_env_put GATEWAY_IF "$GATEWAY_IF"
  gw_env_put TRANSPARENT_MODE "$TRANSPARENT_MODE"
  gw_env_put IPV6_MODE "$IPV6_MODE"
  gw_env_put FW_BACKEND "$FW_BACKEND"
  gw_env_put LOG_LEVEL "$LOG_LEVEL"
  gw_env_put LOG_LEVEL_INJECT "$LOG_LEVEL_INJECT"
  gw_env_put MIXED_PORT "$MIXED_PORT"
  gw_env_put REDIR_PORT "$REDIR_PORT"
  gw_env_put TPROXY_PORT "$TPROXY_PORT"
  gw_env_put DNS_PORT "$DNS_PORT"
  gw_env_put CONTROLLER_PORT "$CONTROLLER_PORT"
  gw_env_put PANEL_PORT "$PANEL_PORT"
  gw_env_put DNS_HIJACK "$DNS_HIJACK"
  gw_env_put GEO_UPDATE "$GEO_UPDATE"
  gw_env_put GEO_UPDATE_INTERVAL "$GEO_UPDATE_INTERVAL"
  gw_env_put SUB_UPDATE_INTERVAL "$SUB_UPDATE_INTERVAL"
  gw_env_put SUB_UPDATE_ON_BOOT "$SUB_UPDATE_ON_BOOT"
  gw_env_put SUB_TIMEOUT "$SUB_TIMEOUT"
  gw_env_put SUB_VIA_PROXY "$SUB_VIA_PROXY"
  gw_env_put SUB_USER_AGENT "$SUB_USER_AGENT"
  gw_env_put STATS_LOG_INTERVAL "$STATS_LOG_INTERVAL"
  gw_env_put ACTIVE_PROFILE "$ACTIVE_PROFILE"
  gw_env_put BYPASS_CIDRS "$BYPASS_CIDRS"
  gw_env_put PANEL_AUTH "$PANEL_AUTH"
  gw_env_put SECRET "$SECRET"
  gw_env_put TZ "$TZ"
  mv "$GW_STATE_DIR/gw.env.tmp" "$GW_STATE_DIR/gw.env"
  chmod 600 "$GW_STATE_DIR/gw.env"

  # ---- 生成运行时注入项 ----
  gw_load_env
  sh "$GW_APP_DIR/config.sh" runtime-write
}

cmd_show() {
  gw_load_env
  cat "$GW_STATE_DIR/gw.env"
}

case "${1:-}" in
  resolve) cmd_resolve ;;
  show)    cmd_show ;;
  *)       echo "用法: env.sh resolve|show" >&2; exit 2 ;;
esac
