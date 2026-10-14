#!/usr/bin/env bash
# =============================================================================
# 镜像冒烟测试（需 Docker）
# 覆盖：启动与配置合成、透明规则下发、订阅自动拉取与更新、快捷切换、
#       策略组节点切换、流量统计、面板鉴权与健康检查
#   用法：IMAGE=ghcr.io/sakana-1314/mihomo-docker:dev bash tests/smoke.sh
#
# 说明：镜像内只有单一二进制（gw），HTTP 断言在宿主机侧完成（宿主机具备 curl / python3）
# =============================================================================
set -uo pipefail

IMAGE="${IMAGE:?请通过 IMAGE 指定待测镜像}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
NET="gw-smoke-net-$$"
GW_NAME="gw-smoke-gw-$$"
SUB_NAME="gw-smoke-sub-$$"
TGT_NAME="gw-smoke-tgt-$$"
SECRET="smoke-secret-$$"
PASS=0
FAIL=0

ok()  { printf '  [通过] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [失败] %s\n' "$*"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$*"; }
info() { printf '  [提示] %s\n' "$*"; }

assert_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1（未包含 [$3]）"; fi; }
assert_not_contains() { if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1（不应包含 [$3]）"; else ok "$1"; fi; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2]，实际 [$3]）"; fi; }
assert_ok_json() {
  if printf '%s' "$2" | grep -qF '"ok":true'; then ok "$1"
  else bad "$1（响应：$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-300)）"; fi
}

cleanup() {
  if [ -d "$TMP" ]; then
    docker run --rm -v "$TMP:/cleanup" --entrypoint sh "$IMAGE" \
      -c 'rm -rf /cleanup/* /cleanup/.[!.]*' >/dev/null 2>&1 || true
  fi
  docker rm -f "$GW_NAME" "$SUB_NAME" "$TGT_NAME" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TMP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

gw_exec() { docker exec "$GW_NAME" "$@"; }
cli()     { docker exec "$GW_NAME" /usr/local/bin/gw "$@"; }

PANEL=""
panel() { # $1=path → 响应体（带面板密钥）
  curl -sS -m 30 -H "X-Panel-Token: $SECRET" "$PANEL$1" 2>/dev/null || true
}
panel_post() { # $1=path $2=body
  curl -sS -m 120 -H "X-Panel-Token: $SECRET" -X POST --data "$1" "$PANEL$2" 2>/dev/null || true
}
jfield() { # $1=json $2=python 表达式（d 为解析后的对象）
  printf '%s' "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print($2)" 2>/dev/null || true
}

# ---------------------------------------------------------------- 准备
step "准备网络与测试服务"
docker network create "$NET" >/dev/null
mkdir -p "$TMP/fixtures" "$TMP/data/config"
cp "$ROOT/tests/fixtures/sub-node-only.yaml" "$ROOT/tests/fixtures/sub-full.yaml" "$TMP/fixtures/"
docker run -d --name "$SUB_NAME" --network "$NET" \
  -v "$TMP/fixtures:/usr/share/nginx/html:ro" nginx:alpine >/dev/null
docker run -d --name "$TGT_NAME" --network "$NET" nginx:alpine >/dev/null
TARGET_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TGT_NAME")
echo "  目标服务地址：$TARGET_IP"

cat > "$TMP/data/config/subscriptions.yaml" <<EOF
subscriptions:
  - name: sub-a
    url: http://$SUB_NAME/sub-node-only.yaml
    type: proxies
  - name: sub-b
    url: http://$SUB_NAME/sub-full.yaml
    type: auto
EOF

step "启动网关容器"
docker run -d --name "$GW_NAME" --network "$NET" --privileged \
  --sysctl net.ipv4.ip_forward=1 \
  -e TRANSPARENT_MODE=tproxy \
  -e SECRET="$SECRET" \
  -e SUB_UPDATE_INTERVAL=120 \
  -e STATS_LOG_INTERVAL=0 \
  -e TZ=Asia/Shanghai \
  -v "$TMP/data:/data" "$IMAGE" >/dev/null
GW_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$GW_NAME")
PANEL="http://$GW_IP:8080"
echo "  网关地址：$GW_IP"

step "等待内核与面板就绪"
ready=false
for _ in $(seq 1 90); do
  if curl -fsS -m 5 "$PANEL/api/health" >/dev/null 2>&1; then ready=true; break; fi
  sleep 2
done
if [ "$ready" = true ]; then ok "内核就绪"; else bad "内核未在预期时间内就绪"; fi
if [ "$ready" != true ]; then
  printf '  容器日志末段：\n'
  docker logs "$GW_NAME" 2>&1 | tail -30 || true
fi

# ---------------------------------------------------------------- 启动与透明规则
step "启动日志、透明规则与鉴权"
LOGS=$(docker logs "$GW_NAME" 2>&1 || true)
assert_contains "启动日志符合项目口径" "$LOGS" "米哈游 API 加速网关"
assert_contains "日志输出面板访问密钥" "$LOGS" "管理面板访问密钥"

RULES=$(gw_exec sh -c 'iptables-legacy -t mangle -S 2>/dev/null || iptables -t mangle -S 2>/dev/null' || true)
assert_contains "TPROXY 链已下发" "$RULES" "GW_TPROXY"
assert_contains "TPROXY 目标端口正确" "$RULES" "--on-port 7893"
assert_contains "策略路由已下发" "$(gw_exec ip rule show 2>/dev/null || true)" "fwmark 0x1 lookup 100"

code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$PANEL/" || true)
assert_eq "面板首页可访问" "200" "$code"
code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$PANEL/app.js" || true)
assert_eq "面板脚本可访问" "200" "$code"
code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$PANEL/api/status" || true)
assert_eq "未携带密钥返回 401" "401" "$code"

# ---------------------------------------------------------------- 订阅自动拉取
step "订阅自动拉取与激活"
STATUS=$(panel /api/status)
assert_eq "默认激活第一个可用订阅" "sub-a" "$(jfield "$STATUS" "d['active']")"
assert_eq "两个订阅均已拉取成功" "2" "$(jfield "$STATUS" "len([i for i in d['subs']['items'] if i['status']=='ok'])")"
assert_contains "启动日志记录订阅拉取" "$LOGS" "订阅已更新"
assert_contains "仅节点订阅写入节点提供者" "$(gw_exec cat /data/mihomo/providers/active.yaml 2>/dev/null || true)" "smoke-a-1"
assert_contains "命令行可读订阅列表" "$(cli subs || true)" "sub-a"

# ---------------------------------------------------------------- 订阅自动更新
step "订阅内容变更后更新（快捷更新 + 热生效）"
cp "$ROOT/tests/fixtures/sub-node-only-updated.yaml" "$TMP/fixtures/sub-node-only.yaml"
UPD=$(panel_post 'name=sub-a' /api/subs/update)
assert_ok_json "更新接口执行成功" "$UPD"

live=false
for _ in $(seq 1 15); do
  if panel /api/nodes | grep -qF "smoke-a-marker"; then live=true; break; fi
  sleep 2
done
if [ "$live" = true ]; then ok "内核侧节点已热更新（无需重启容器）"; else bad "内核侧未出现新节点"; fi
assert_contains "节点提供者文件已更新" "$(gw_exec cat /data/mihomo/providers/active.yaml 2>/dev/null || true)" "smoke-a-marker"

# ---------------------------------------------------------------- 快捷切换
step "快捷切换（仅节点订阅 ↔ 完整订阅）"
SW=$(panel_post 'name=sub-b' /api/subs/switch)
assert_ok_json "切换接口执行成功" "$SW"
assert_eq "活跃订阅已变更" "sub-b" "$(jfield "$(panel /api/status)" "d['active']")"
assert_contains "完整订阅配置已合成" "$(gw_exec cat /data/mihomo/config.yaml 2>/dev/null || true)" "SMOKE-PROFILE-GROUP"

live=false
for _ in $(seq 1 15); do
  if panel /api/nodes | grep -qF "SMOKE-PROFILE-GROUP"; then live=true; break; fi
  sleep 2
done
if [ "$live" = true ]; then ok "内核侧已加载完整订阅的策略组"; else bad "内核侧未见完整订阅策略组"; fi

panel_post 'name=sub-a' /api/subs/switch >/dev/null 2>&1 || true
assert_eq "切回仅节点订阅" "sub-a" "$(jfield "$(panel /api/status)" "d['active']")"
assert_contains "切回后恢复模板规则" "$(gw_exec cat /data/mihomo/config.yaml 2>/dev/null || true)" "GEOIP,CN,DIRECT"

# ---------------------------------------------------------------- 策略组与节点
step "策略组与节点接口"
NODES_JSON=$(panel /api/nodes)
assert_contains "策略组接口返回数据" "$NODES_JSON" '"groups"'
assert_contains "策略组接口返回当前选中节点" "$NODES_JSON" '"now"'
SEL=$(curl -sS -m 30 -H "X-Panel-Token: $SECRET" -X POST \
  --data-urlencode 'group=加速节点' --data 'node=smoke-a-marker' "$PANEL/api/nodes/select" 2>/dev/null || true)
assert_ok_json "节点切换接口可用" "$SEL"
assert_contains "命令行可读策略组" "$(cli nodes || true)" "加速节点"

# ---------------------------------------------------------------- 订阅增删
step "面板订阅增删"
ADD=$(panel_post "name=sub-c&url=http%3A%2F%2F$SUB_NAME%2Fsub-node-only.yaml&type=proxies" /api/subs)
assert_ok_json "面板新增订阅" "$ADD"
DEL=$(curl -sS -m 60 -H "X-Panel-Token: $SECRET" -X DELETE "$PANEL/api/subs/sub-c" 2>/dev/null || true)
assert_ok_json "面板删除订阅" "$DEL"
assert_eq "删除后剩余订阅数" "2" "$(jfield "$(panel /api/subs)" "d['total']")"

# ---------------------------------------------------------------- 流量统计
step "流量统计（内核自带统计的直接呈现）"
BEFORE=$(jfield "$(panel /api/traffic)" "d['down_total']")
[ -n "$BEFORE" ] || BEFORE=0
CODE=$(gw_exec sh -c "http_proxy=http://127.0.0.1:7890 wget -q -O /dev/null -T 20 http://$TARGET_IP/ && echo 200 || echo failed" || true)
assert_eq "经内核混合端口访问目标服务" "200" "$CODE"
sleep 2
AFTER=$(jfield "$(panel /api/traffic)" "d['down_total']")
[ -n "$AFTER" ] || AFTER=0
if [ "${AFTER:-0}" -gt "${BEFORE:-0}" ]; then ok "代理流量计入内核统计（$BEFORE → $AFTER）"; else bad "流量计数未增长（$BEFORE → $AFTER）"; fi

TRAFFIC=$(panel /api/traffic)
assert_contains "流量接口返回累计下行" "$TRAFFIC" '"down_total"'
assert_contains "流量接口返回实时速率" "$TRAFFIC" '"down_speed"'
assert_contains "流量接口返回活动连接" "$TRAFFIC" '"connections"'
assert_contains "流量接口返回内存占用" "$TRAFFIC" '"memory"'
assert_contains "命令行状态输出流量统计" "$(cli status || true)" "累计"

# ---------------------------------------------------------------- 健康检查
step "健康检查"
HEALTH=unknown
for _ in $(seq 1 20); do
  HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$GW_NAME" 2>/dev/null || printf 'unknown')
  [ "$HEALTH" = "healthy" ] && break
  sleep 5
done
assert_eq "容器健康状态" "healthy" "$HEALTH"

# ---------------------------------------------------------------- 汇总
printf '\n=========================================\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '冒烟测试未通过，容器日志末段：\n'
  docker logs "$GW_NAME" 2>&1 | tail -30 || true
  exit 1
fi
printf '冒烟测试通过\n'
