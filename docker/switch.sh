#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 快捷切换
# 合成配置 → 内核热加载（reload）；仅节点变化时优先走节点提供者热更新
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

gw_reload_config() {
  _body=$(GW_CFG_PATH="$GW_MIHOMO_HOME/config.yaml" yq -n -o=json -I0 '{"path": strenv(GW_CFG_PATH)}')
  if gw_api PUT '/configs?force=true' "$_body" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

gw_provider_update() {
  gw_api PUT '/providers/proxies/active' >/dev/null 2>&1
}

cmd_switch() { # $1=订阅名|baseline
  _target="${1:-}"
  [ -n "$_target" ] || { gw_warn "缺少订阅名"; return 2; }

  _mode=''
  if [ "$_target" = "baseline" ]; then
    _mode=baseline
  else
    gw_valid_name "$_target" || { gw_warn "订阅名不合法：$_target"; return 2; }
    [ -f "$GW_PROFILES_DIR/$_target.yaml" ] || { gw_warn "订阅不存在或尚未拉取：$_target"; return 3; }
    _mode=$(gw_profile_type "$_target") || { gw_warn "无法识别订阅类型：$_target"; return 4; }
  fi

  gw_lock

  _old_sha=$(gw_state_get config.sha256)

  # 1) 维护节点提供者文件
  if [ "$_mode" = "baseline" ]; then
    sh "$GW_APP_DIR/config.sh" provider-clear || { gw_unlock; return 5; }
  elif [ "$_mode" = "proxies" ]; then
    sh "$GW_APP_DIR/config.sh" provider-write "$_target" || { gw_unlock; return 5; }
  fi

  # 2) 合成内核配置（完整订阅用订阅自身，其余用骨架模板）
  if [ "$_mode" = "profile" ]; then
    sh "$GW_APP_DIR/config.sh" compose profile "$_target" || { gw_unlock; return 6; }
  else
    sh "$GW_APP_DIR/config.sh" compose baseline || { gw_unlock; return 6; }
  fi
  _new_sha=$(gw_state_get config.sha256)

  # 3) 热生效
  if [ "$_new_sha" != "$_old_sha" ]; then
    if gw_kernel_alive; then
      if gw_reload_config; then
        gw_log "配置已热加载（$_target）"
      else
        gw_warn "配置热加载失败，配置已写入磁盘，重启容器后生效"
      fi
    else
      gw_log "内核尚未运行，配置已写入，启动后自动生效"
    fi
  else
    if gw_kernel_alive; then
      if gw_provider_update; then
        gw_log "节点已热更新（$_target）"
      elif gw_reload_config; then
        gw_log "配置已热加载（$_target）"
      else
        gw_warn "节点热更新失败，配置已写入磁盘，重启容器后生效"
      fi
    fi
  fi

  # 4) 记录活跃订阅
  if [ "$_mode" = "baseline" ]; then
    gw_state_set active ''
    gw_log "已切换到空载基线（不使用上游订阅）"
  else
    gw_state_set active "$_target"
    gw_log "已切换到订阅：$_target"
  fi

  gw_unlock
  return 0
}

case "${1:-}" in
  '')
    echo "用法: switch.sh <订阅名|baseline>" >&2
    exit 2
    ;;
  switch|apply)
    shift
    cmd_switch "${1:-}"
    ;;
  baseline)
    cmd_switch baseline
    ;;
  *)
    # 兼容直接传订阅名：switch.sh <订阅名>
    cmd_switch "$1"
    ;;
esac
