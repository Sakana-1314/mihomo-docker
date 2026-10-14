#!/bin/sh
# 米哈游 API 加速网关 · 健康检查（内核 API 可用即视为健康）
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

gw_kernel_alive || exit 1
exit 0
