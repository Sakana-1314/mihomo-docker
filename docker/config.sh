#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 配置合成
# 模板骨架 / 完整订阅 + 用户覆盖层 + 运行时注入项 → /data/mihomo/config.yaml
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"

# ---- 用户可编辑文件播种（仅缺失时，绝不覆盖）----
cmd_ensure_user_config() {
  mkdir -p "$GW_CONFIG_DIR" "$GW_PROFILES_DIR" "$GW_PROVIDERS_DIR"
  if [ ! -f "$GW_CONFIG_DIR/overlay.yaml" ]; then
    cp "$GW_SHARE_DIR/config/overlay.yaml" "$GW_CONFIG_DIR/overlay.yaml"
    gw_log "已生成默认覆盖层：$GW_CONFIG_DIR/overlay.yaml"
  fi
  if [ ! -f "$GW_CONFIG_DIR/subscriptions.yaml" ]; then
    cp "$GW_SHARE_DIR/config/subscriptions.yaml" "$GW_CONFIG_DIR/subscriptions.yaml"
    gw_log "已生成订阅清单：$GW_CONFIG_DIR/subscriptions.yaml"
  fi
  # 节点提供者文件必须存在（file 类型 provider 缺文件会导致内核启动失败）
  if [ ! -f "$GW_PROVIDERS_DIR/active.yaml" ]; then
    printf 'proxies: []\n' > "$GW_PROVIDERS_DIR/active.yaml"
  fi
}

# ---- 运行时注入（环境变量 → runtime.yaml，优先级最高）----
cmd_runtime_write() {
  _rt="$GW_STATE_DIR/runtime.yaml"
  if [ "$(gw_bool "${GEO_UPDATE:-1}")" = "1" ]; then _geo=true; else _geo=false; fi
  {
    printf '# 由容器按环境变量生成，请勿手工修改（重启或被覆盖）\n'
    printf 'mixed-port: %s\n' "${MIXED_PORT:-7890}"
    printf 'redir-port: %s\n' "${REDIR_PORT:-7892}"
    printf 'tproxy-port: %s\n' "${TPROXY_PORT:-7893}"
    printf 'allow-lan: true\n'
    printf "bind-address: '*'\n"
    if [ "${LOG_LEVEL_INJECT:-0}" = "1" ]; then
      printf 'log-level: %s\n' "${LOG_LEVEL:-info}"
    fi
    printf 'external-controller: 0.0.0.0:%s\n' "${CONTROLLER_PORT:-9090}"
    printf 'external-ui: ui\n'
    printf 'external-controller-cors:\n'
    printf "  allow-origins:\n    - '*'\n"
    printf '  allow-private-network: true\n'
    printf 'geo-auto-update: %s\n' "$_geo"
    printf 'geo-update-interval: %s\n' "${GEO_UPDATE_INTERVAL:-24}"
    printf 'dns:\n'
    printf '  listen: 0.0.0.0:%s\n' "${DNS_PORT:-53}"
  } > "$_rt.new"
  GW_RT_SECRET="${SECRET:-}" yq -i '.secret = strenv(GW_RT_SECRET)' "$_rt.new" || {
    rm -f "$_rt.new"
    gw_die "runtime.yaml 生成失败"
  }
  mv "$_rt.new" "$_rt"
}

# ---- 配置校验（内核 dry-run）----
gw_config_test() { # $1=待校验文件
  _out=$(mihomo -d "$GW_MIHOMO_HOME" -f "$1" -t 2>&1)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    gw_warn "配置校验失败：$_out"
    return 1
  fi
  return 0
}

# ---- 配置合成并落盘（校验通过才替换现行配置）----
cmd_compose() { # $1=baseline|profile  $2=订阅名（profile 时必填）
  _mode="$1"; _name="${2:-}"
  case "$_mode" in
    baseline)
      _base="$GW_SHARE_DIR/config/template.yaml"
      ;;
    profile)
      _base="$GW_PROFILES_DIR/$_name.yaml"
      [ -f "$_base" ] || { gw_warn "订阅文件不存在：$_base"; return 1; }
      ;;
    *)
      gw_warn "未知合成模式：$_mode"
      return 2
      ;;
  esac

  mkdir -p "$GW_MIHOMO_HOME" "$GW_STATE_DIR" "$GW_CONFIG_DIR"
  _overlay="$GW_CONFIG_DIR/overlay.yaml"
  _runtime="$GW_STATE_DIR/runtime.yaml"
  [ -f "$_overlay" ] || _overlay="$GW_SHARE_DIR/config/overlay.yaml"
  [ -f "$_runtime" ] || { gw_warn "缺少运行时注入项，请先执行 env.sh resolve"; return 3; }

  _new="$GW_MIHOMO_HOME/config.yaml.new"
  # 深度合并：后面的文件覆盖前面的同名键（对象递归、数组整体替换）
  # shellcheck disable=SC2016  # 单引号内为 yq 表达式，不需要 shell 展开
  if ! yq ea '. as $item ireduce ({}; . * $item)' "$_base" "$_overlay" "$_runtime" > "$_new" 2>"$GW_STATE_DIR/.compose.err"; then
    gw_warn "配置合成失败：$(cat "$GW_STATE_DIR/.compose.err")"
    rm -f "$_new"
    return 4
  fi

  if ! gw_config_test "$_new"; then
    rm -f "$_new"
    return 5
  fi

  mv "$_new" "$GW_MIHOMO_HOME/config.yaml"
  sha256sum "$GW_MIHOMO_HOME/config.yaml" | awk '{print $1}' > "$GW_STATE_DIR/config.sha256"
  return 0
}

# ---- 节点提供者文件 ----
cmd_provider_write() { # $1=订阅名（仅取 .proxies）
  _f="$GW_PROFILES_DIR/$1.yaml"
  [ -f "$_f" ] || { gw_warn "订阅文件不存在：$_f"; return 1; }
  mkdir -p "$GW_PROVIDERS_DIR"
  if ! yq '{"proxies": (.proxies // [])}' "$_f" > "$GW_PROVIDERS_DIR/active.yaml.new" 2>"$GW_STATE_DIR/.provider.err"; then
    gw_warn "节点提取失败：$_f（$(cat "$GW_STATE_DIR/.provider.err" 2>/dev/null)）"
    rm -f "$GW_PROVIDERS_DIR/active.yaml.new"
    return 2
  fi
  mv "$GW_PROVIDERS_DIR/active.yaml.new" "$GW_PROVIDERS_DIR/active.yaml"
  return 0
}

cmd_provider_clear() {
  mkdir -p "$GW_PROVIDERS_DIR"
  printf 'proxies: []\n' > "$GW_PROVIDERS_DIR/active.yaml"
}

# ---- 概要（供面板与命令行展示）----
cmd_summary() {
  gw_load_env
  printf '内核配置：%s\n' "$GW_MIHOMO_HOME/config.yaml"
  printf '活跃订阅：%s\n' "$(gw_state_get active)"
  printf '覆盖层：%s\n' "$GW_CONFIG_DIR/overlay.yaml"
}

case "${1:-}" in
  ensure-user-config) cmd_ensure_user_config ;;
  runtime-write)      cmd_runtime_write ;;
  compose)            shift; cmd_compose "$@" ;;
  provider-write)     shift; cmd_provider_write "$@" ;;
  provider-clear)     cmd_provider_clear ;;
  test)               shift; gw_config_test "$@" ;;
  summary)            cmd_summary ;;
  *) echo "用法: config.sh ensure-user-config|runtime-write|compose|provider-write|provider-clear|test|summary" >&2; exit 2 ;;
esac
