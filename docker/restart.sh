#!/bin/sh
# 米哈游 API 加速网关 · 重启内核（由 mihomo-loop.sh 守护自动拉起）
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

_pid=$(gw_state_get kernel.pid)
case "$_pid" in
  ''|*[!0-9]*)
    gw_warn "未找到内核进程号（内核可能未在运行）"
    exit 1
    ;;
esac

if kill -TERM "$_pid" 2>/dev/null; then
  gw_log "已通知内核退出，守护进程将自动重启（pid=$_pid）"
else
  gw_warn "发送信号失败（pid=$_pid）"
  exit 1
fi
