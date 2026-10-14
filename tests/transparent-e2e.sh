#!/usr/bin/env bash
# =============================================================================
# 透明代理链路测试（需 Docker + 特权容器）
# 在网关容器内创建客户端网络命名空间，经 veth 对导入真实转发流量：
#   客户端 → 网关（TPROXY 捕获）→ 内核代理 → 目标服务
# 断言依据：TPROXY 规则报文计数 + 内核流量计数 + 目标服务访问日志
#   用法：IMAGE=ghcr.io/sakana-1314/mihomo-docker:dev bash tests/transparent-e2e.sh
# =============================================================================
set -uo pipefail

IMAGE="${IMAGE:?请通过 IMAGE 指定待测镜像}"
TMP="$(mktemp -d)"
NET="gw-e2e-net-$$"
GW_NAME="gw-e2e-gw-$$"
TGT_NAME="gw-e2e-tgt-$$"
SECRET="e2e-secret-$$"
CLIENT_NS=gwclient
VETH_GW=veth-gw0
VETH_CL=gw-cl0
CLIENT_IP=10.99.99.2
GW_SIDE_IP=10.99.99.1
MARKER="/e2e-$RANDOM$RANDOM"
PASS=0
FAIL=0

ok()  { printf '  [通过] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [失败] %s\n' "$*"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$*"; }
info() { printf '  [提示] %s\n' "$*"; }
assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1（未包含 [$3]）"; fi; }

cleanup() {
  if [ -d "$TMP" ]; then
    docker run --rm -v "$TMP:/cleanup" --entrypoint sh "$IMAGE" \
      -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  fi
  docker rm -f "$GW_NAME" "$TGT_NAME" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

gw_exec() { docker exec "$GW_NAME" "$@"; }
ns_exec() { gw_exec ip netns exec "$CLIENT_NS" "$@"; }
PANEL=""
panel() { curl -sS -m 20 -H "X-Panel-Token: $SECRET" "$PANEL$1" 2>/dev/null || true; }
jfield() { printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>/dev/null || true; }

# ---------------------------------------------------------------- 准备
step "准备网络与目标服务"
docker network create "$NET" >/dev/null
docker run -d --name "$TGT_NAME" --network "$NET" nginx:alpine >/dev/null
TARGET_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TGT_NAME")
echo "  目标服务地址：$TARGET_IP"

step "启动网关容器（透明代理 + 特权）"
# BYPASS_CIDRS 去掉 172.16.0.0/12，使容器网段（目标服务所在网段）也纳入透明代理
docker run -d --name "$GW_NAME" --network "$NET" --privileged \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.rp_filter=0 \
  -e TRANSPARENT_MODE=tproxy \
  -e GATEWAY_IF="eth0,$VETH_GW" \
  -e BYPASS_CIDRS="10.0.0.0/8,192.168.0.0/16,100.64.0.0/10" \
  -e SECRET="$SECRET" \
  -e STATS_LOG_INTERVAL=0 \
  -v "$TMP/data:/data" "$IMAGE" >/dev/null
GW_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GW_NAME")
PANEL="http://$GW_IP:8080"

ready=false
for _ in $(seq 1 90); do
  if curl -fsS -m 5 "$PANEL/api/health" >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
if [ "$ready" = true ]; then ok "网关就绪"; else
  bad "网关未就绪"
  docker logs "$GW_NAME" 2>&1 | tail -40 || true
fi

# ---------------------------------------------------------------- 客户端命名空间
step "创建客户端网络命名空间（$CLIENT_IP → 网关 $GW_SIDE_IP）"
gw_exec ip netns add "$CLIENT_NS"
gw_exec ip link add "$VETH_GW" type veth peer name "$VETH_CL"
gw_exec ip link set "$VETH_CL" netns "$CLIENT_NS"
gw_exec ip addr add "$GW_SIDE_IP/24" dev "$VETH_GW"
gw_exec ip link set "$VETH_GW" up
ns_exec ip link set lo up
ns_exec ip addr add "$CLIENT_IP/24" dev "$VETH_CL"
ns_exec ip link set "$VETH_CL" up
ns_exec ip route add default via "$GW_SIDE_IP"

# 新接口需要重新下发透明规则（规则按接口逐一下发，可重复执行）
curl -sS -m 120 -H "X-Panel-Token: $SECRET" -X POST "$PANEL/api/firewall/reload" >/dev/null 2>&1 || true
VETH_RULES=$(gw_exec sh -c 'iptables-legacy -t mangle -S 2>/dev/null || iptables -t mangle -S 2>/dev/null' || true)
assert_contains "新接口已纳入透明规则" "$VETH_RULES" "$VETH_GW"

if ns_exec ping -c 1 -W 3 "$GW_SIDE_IP" >/dev/null 2>&1; then
  ok "客户端可直达网关"
else
  bad "客户端无法直达网关"
fi

# ---------------------------------------------------------------- 透明转发
step "透明转发验证（客户端 → 网关 → 内核 → 目标服务）"
BEFORE=$(jfield "$(panel /api/traffic)" "d['down_total']")
[ -n "$BEFORE" ] || BEFORE=0
sleep 1
OUT=$(ns_exec wget -q -O /dev/null -T 20 "http://$TARGET_IP$MARKER" 2>&1 && printf 'ok' || printf 'failed')
sleep 2
AFTER=$(jfield "$(panel /api/traffic)" "d['down_total']")
[ -n "$AFTER" ] || AFTER=0

if [ "$OUT" = "ok" ]; then ok "客户端请求经网关完成"; else bad "客户端请求未完成（透明链路不通）：$OUT"; fi

if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then
  ok "透明流量计入内核统计（$BEFORE → $AFTER）"
else
  bad "内核流量计数未增长（$BEFORE → $AFTER），流量可能未经过内核"
fi

assert_contains "目标服务收到请求" "$(docker logs "$TGT_NAME" 2>&1 || true)" "$MARKER"

PKTS=$(gw_exec sh -c 'iptables-legacy -t mangle -L GW_TPROXY -v -n 2>/dev/null || iptables -t mangle -L GW_TPROXY -v -n 2>/dev/null' 2>/dev/null | awk '/TPROXY/ {sum += $1} END {print sum + 0}' || printf '0')
[ -n "${PKTS:-}" ] || PKTS=0
if [ "${PKTS:-0}" -gt 0 ]; then
  ok "TPROXY 规则命中报文（$PKTS 个）"
else
  bad "TPROXY 规则未命中任何报文"
fi

# ---------------------------------------------------------------- 状态一致性
step "运行状态一致性"
STATUS=$(panel /api/status)
assert_contains "面板显示透明代理已生效" "$STATUS" '"state":"on"'
assert_contains "命令行显示透明规则" "$(docker exec "$GW_NAME" /usr/local/bin/gw firewall status 2>/dev/null || true)" "透明代理规则"

# ---------------------------------------------------------------- DNS 劫持
step "DNS 劫持（提示项）"
if ns_exec nslookup example.com 8.8.8.8 2>/dev/null | grep -q "Address"; then
  ok "外部 DNS 请求被劫持至内核并成功应答"
else
  info "DNS 劫持验证未通过（可能受 CI 出口网络限制影响，不视为失败）"
fi

# ---------------------------------------------------------------- 汇总
printf '\n=========================================\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '透明链路测试未通过，容器日志末段：\n'
  docker logs "$GW_NAME" 2>&1 | tail -30 || true
  exit 1
fi
printf '透明链路测试通过\n'
