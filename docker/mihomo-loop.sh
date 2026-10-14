#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 内核守护
# 内核异常退出自动重启；快速连续失败达阈值则退出（由容器退出策略接管）
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

_fails=0
while :; do
  gw_log "启动内核：mihomo -d $GW_MIHOMO_HOME"
  _start=$(date +%s)

  mihomo -d "$GW_MIHOMO_HOME" &
  _pid=$!
  gw_state_set kernel.pid "$_pid"
  if wait "$_pid"; then
    _code=0
  else
    _code=$?
  fi

  _now=$(date +%s)
  if [ $((_now - _start)) -lt 60 ]; then
    _fails=$((_fails + 1))
  else
    _fails=0
  fi

  if [ "$_fails" -ge 5 ]; then
    gw_warn "内核连续 ${_fails} 次启动失败，放弃重启。请检查日志与配置：$GW_MIHOMO_HOME/config.yaml"
    exit 1
  fi

  gw_warn "内核已退出（code=$_code），3 秒后重启"
  sleep 3
done
