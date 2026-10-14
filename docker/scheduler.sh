#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 定时任务
#   流量采样（60s）/ 订阅自动更新（SUB_UPDATE_INTERVAL）/ 流量日志摘要（STATS_LOG_INTERVAL）
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

_now0=$(date +%s)
_last_stats=0
_last_sub=$_now0
_last_log=$_now0

gw_log "定时任务已启动：订阅更新间隔 ${SUB_UPDATE_INTERVAL}s，流量摘要间隔 ${STATS_LOG_INTERVAL}s"

while :; do
  _now=$(date +%s)

  # 流量采样：每分钟一次（面板会自行采样，此处保证日志与页面数据连续）
  if [ $((_now - _last_stats)) -ge 60 ]; then
    sh "$GW_APP_DIR/stats.sh" sample >/dev/null 2>&1 || true
    _last_stats=$_now
  fi

  # 订阅自动更新
  if [ "${SUB_UPDATE_INTERVAL:-0}" -gt 0 ] && [ $((_now - _last_sub)) -ge "$SUB_UPDATE_INTERVAL" ]; then
    gw_log "开始定时更新全部订阅"
    sh "$GW_APP_DIR/subs.sh" update all || gw_warn "定时订阅更新存在失败项"
    _last_sub=$(date +%s)
  fi

  # 流量日志摘要
  if [ "${STATS_LOG_INTERVAL:-0}" -gt 0 ] && [ $((_now - _last_log)) -ge "$STATS_LOG_INTERVAL" ]; then
    sh "$GW_APP_DIR/stats.sh" log || true
    _last_log=$(date +%s)
  fi

  sleep 15
done
