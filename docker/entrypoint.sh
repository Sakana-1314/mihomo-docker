#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 容器入口
# 初始化 → 配置合成 → 透明代理规则 → 内核 / 面板 / 定时任务
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-/app/docker}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"

gw_log "米哈游 API 加速网关 启动中（mihomo-docker）"

mkdir -p "$GW_CONFIG_DIR" "$GW_MIHOMO_HOME" "$GW_STATE_DIR" "$GW_SUBS_STATE_DIR" \
         "$GW_LOG_DIR" "$GW_PROFILES_DIR" "$GW_PROVIDERS_DIR"

# ---- 用户可编辑文件播种 ----
sh "$GW_APP_DIR/config.sh" ensure-user-config

# ---- 随镜像分发的资源就位（仅缺失时复制，不覆盖用户数据）----
if [ -d "$GW_SHARE_DIR/ui" ] && [ ! -f "$GW_MIHOMO_HOME/ui/index.html" ]; then
  mkdir -p "$GW_MIHOMO_HOME/ui"
  cp -a "$GW_SHARE_DIR/ui/." "$GW_MIHOMO_HOME/ui/"
  gw_log "已部署 MetaCubeXD 完整面板：$GW_MIHOMO_HOME/ui"
fi
for _f in geoip.metadb geosite.dat geoip.dat; do
  if [ -f "$GW_SHARE_DIR/geo/$_f" ] && [ ! -f "$GW_MIHOMO_HOME/$_f" ]; then
    cp "$GW_SHARE_DIR/geo/$_f" "$GW_MIHOMO_HOME/$_f"
  fi
done

# ---- 环境解析 ----
sh "$GW_APP_DIR/env.sh" resolve
gw_load_env
gw_log "接口=$GATEWAY_IF 透明模式=$TRANSPARENT_MODE DNS劫持=$DNS_HIJACK IPv6=$IPV6_MODE 日志级别=$LOG_LEVEL"
if [ "$PANEL_AUTH" = "token" ]; then
  gw_log "管理面板访问密钥（同时用于内核 API）：$SECRET"
fi

# ---- 订阅引导（首次拉取缺失订阅；必要时激活第一个可用订阅）----
sh "$GW_APP_DIR/subs.sh" bootstrap || gw_warn "订阅引导存在失败项（可在面板中重试）"
gw_load_env

# ---- 初始配置合成 ----
_active=$(gw_state_get active)
if [ -n "$_active" ] && [ -f "$GW_PROFILES_DIR/$_active.yaml" ]; then
  if ! sh "$GW_APP_DIR/switch.sh" "$_active"; then
    gw_warn "应用订阅 $_active 失败，回退空载基线"
    sh "$GW_APP_DIR/config.sh" compose baseline || gw_die "初始配置合成失败"
  fi
else
  sh "$GW_APP_DIR/config.sh" compose baseline || gw_die "初始配置合成失败"
fi

# ---- 透明代理规则 ----
sh "$GW_APP_DIR/firewall.sh" setup || gw_warn "透明代理规则应用失败（本次仅提供常规端口服务，请检查权限）"

# ---- 子进程 ----
sh "$GW_APP_DIR/mihomo-loop.sh" &
MI_PID=$!
HTTPD_PID=''
if gw_have httpd; then
  httpd -f -p "$PANEL_PORT" -h "$GW_WWW_DIR" &
  HTTPD_PID=$!
else
  gw_warn "未找到 httpd（busybox-extras），管理面板不可用；命令行 gw 不受影响"
fi
sh "$GW_APP_DIR/scheduler.sh" &
SCHED_PID=$!

gw_log "管理面板：http://<网关IP>:$PANEL_PORT/  |  完整面板：http://<网关IP>:$CONTROLLER_PORT/ui/  |  混合端口：$MIXED_PORT"

# shellcheck disable=SC2317,SC2329  # 由 trap 调用（旧版 shellcheck 报 SC2317，新版报 SC2329）
_shutdown() {
  gw_log "收到退出信号，正在停止服务…"
  for _p in "$SCHED_PID" "$HTTPD_PID" "$MI_PID"; do
    if [ -n "$_p" ]; then kill "$_p" 2>/dev/null; fi
  done
  wait 2>/dev/null
  exit 0
}
trap _shutdown TERM INT

wait "$MI_PID"
gw_warn "内核守护进程已退出，容器退出"
exit 1
