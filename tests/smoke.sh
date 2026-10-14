#!/usr/bin/env bash
# =============================================================================
# 镜像冒烟测试（需 Docker）
# 覆盖：启动与配置合成、透明规则下发、订阅自动拉取与更新、快捷切换、
#       流量统计、面板接口与鉴权、健康检查
#   用法：IMAGE=ghcr.io/sakana-1314/mihomo-docker:latest bash tests/smoke.sh
#
# 注：不使用 set -e —— 断言失败需要继续执行并累计，最终按失败数返回
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

assert_contains() { # 描述 内容 子串
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1（未包含 [$3]）"; fi
}

assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1（不应包含 [$3]）"; else ok "$1"; fi
}

assert_eq() { # 描述 期望 实际
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2]，实际 [$3]）"; fi
}

assert_ok_json() { # 描述 响应（失败时输出响应片段，便于排查）
  if printf '%s' "$2" | grep -qF '"ok":true'; then
    ok "$1"
  else
    bad "$1（响应：$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-400)）"
  fi
}

cleanup() {
  # 挂载目录内的文件由容器内 root 写入，需借助容器身份清理
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
gw_in()   { docker exec -i "$GW_NAME" "$@"; }          # 支持标准输入
api()     { gw_exec curl -fsS -H "Authorization: Bearer $SECRET" "http://127.0.0.1:9090$1"; }
panel()   { gw_exec curl -fsS -H "X-Panel-Token: $SECRET" "http://127.0.0.1:8080$1"; }
panel_post() { gw_exec curl -sS -m 90 -X POST -H "X-Panel-Token: $SECRET" --data "$1" "http://127.0.0.1:8080/cgi-bin/subs.sh" 2>&1 || true; }
jq_in()   { gw_in yq -p=json -r "$1" - 2>/dev/null; }  # 借用容器内 yq 解析 JSON
http_code() { gw_exec curl -sS -m 10 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || printf 'failed'; }
kernel_ready() { gw_exec curl -fsS -m 5 -H "Authorization: Bearer $SECRET" http://127.0.0.1:9090/version >/dev/null 2>&1; }

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

step "等待内核与面板就绪"
ready=false
for _ in $(seq 1 90); do
  if kernel_ready; then ready=true; break; fi
  sleep 2
done
if [ "$ready" = true ]; then ok "内核就绪"; else
  bad "内核未在预期时间内就绪"
fi

panel_state=failed
for _ in $(seq 1 10); do
  panel_state=$(http_code "http://127.0.0.1:8080/")
  [ "$panel_state" = "200" ] && break
  sleep 3
done
assert_eq "面板就绪（httpd 可用）" "200" "$panel_state"

if [ "$ready" != true ] || [ "$panel_state" != "200" ]; then
  printf '  容器日志末段：\n'
  docker logs "$GW_NAME" 2>&1 | tail -30 || true
fi

# ---------------------------------------------------------------- 启动与透明规则
step "启动日志、透明规则与鉴权"
LOGS=$(docker logs "$GW_NAME" 2>&1 || true)
assert_contains "启动日志符合项目口径" "$LOGS" "米哈游 API 加速网关"
assert_contains "日志输出面板访问密钥" "$LOGS" "管理面板访问密钥"

assert_eq "透明代理规则生效" "on" "$(gw_exec sh /app/docker/firewall.sh status 2>/dev/null || printf 'off')"
RULES=$(gw_exec sh -c 'iptables-legacy -t mangle -S 2>/dev/null || iptables -t mangle -S 2>/dev/null' || true)
assert_contains "TPROXY 链已下发" "$RULES" "GW_TPROXY"
assert_contains "TPROXY 目标端口正确" "$RULES" "--on-port 7893"
IPRULE=$(gw_exec ip rule show 2>/dev/null || true)
assert_contains "策略路由已下发" "$IPRULE" "fwmark 0x1 lookup 100"

assert_eq "面板脚本可访问" "200" "$(http_code 'http://127.0.0.1:8080/app.js')"
NOAUTH=$(gw_exec curl -sS -i "http://127.0.0.1:8080/cgi-bin/status.sh" 2>/dev/null || true)
assert_not_contains "未携带密钥时不返回内核数据" "$NOAUTH" '"kernel"'
info "未授权响应首行：$(printf '%s' "$NOAUTH" | head -n1)"

# ---------------------------------------------------------------- 订阅自动拉取
step "订阅自动拉取与激活"
STATUS=$(panel /cgi-bin/status.sh || true)
assert_contains "订阅清单含 sub-a" "$STATUS" '"name":"sub-a"'
assert_contains "订阅清单含 sub-b" "$STATUS" '"name":"sub-b"'
assert_eq "两个订阅均已拉取成功" "2" "$(printf '%s' "$STATUS" | jq_in '[.subs.items[] | select(.status == "ok")] | length')"
assert_eq "默认激活第一个可用订阅" "sub-a" "$(printf '%s' "$STATUS" | jq_in '.active')"
assert_contains "启动日志记录订阅拉取" "$LOGS" "订阅已更新"

PROV=$(gw_exec cat /data/mihomo/providers/active.yaml 2>/dev/null || true)
assert_contains "仅节点订阅写入节点提供者" "$PROV" "smoke-a-1"

# ---------------------------------------------------------------- 订阅自动更新
step "订阅内容变更后更新（快捷更新 + 热生效）"
cp "$ROOT/tests/fixtures/sub-node-only-updated.yaml" "$TMP/fixtures/sub-node-only.yaml"
UPD=$(panel_post 'action=update&name=sub-a')
assert_ok_json "更新接口执行成功" "$UPD"

live=false
for _ in $(seq 1 10); do
  if api /proxies 2>/dev/null | grep -qF "smoke-a-marker"; then live=true; break; fi
  sleep 2
done
if [ "$live" = true ]; then ok "内核侧节点已热更新（无需重启）"; else bad "内核侧未出现新节点"; fi
assert_contains "节点提供者文件已更新" "$(gw_exec cat /data/mihomo/providers/active.yaml 2>/dev/null || true)" "smoke-a-marker"

# ---------------------------------------------------------------- 快捷切换
step "快捷切换（仅节点订阅 ↔ 完整订阅）"
SW=$(panel_post 'action=switch&name=sub-b')
assert_ok_json "切换接口执行成功" "$SW"
assert_eq "活跃订阅已变更" "sub-b" "$(panel /cgi-bin/status.sh 2>/dev/null | jq_in '.active')"
assert_contains "完整订阅配置已合成" "$(gw_exec cat /data/mihomo/config.yaml 2>/dev/null || true)" "SMOKE-PROFILE-GROUP"

live=false
for _ in $(seq 1 10); do
  if api /proxies 2>/dev/null | grep -qF "SMOKE-PROFILE-GROUP"; then live=true; break; fi
  sleep 2
done
if [ "$live" = true ]; then ok "内核侧已加载完整订阅的策略组"; else bad "内核侧未见完整订阅策略组"; fi

panel_post 'action=switch&name=sub-a' >/dev/null 2>&1 || true
assert_eq "切回仅节点订阅" "sub-a" "$(panel /cgi-bin/status.sh 2>/dev/null | jq_in '.active')"
assert_contains "切回后恢复模板规则" "$(gw_exec cat /data/mihomo/config.yaml 2>/dev/null || true)" "GEOIP,CN,DIRECT"

# ---------------------------------------------------------------- 订阅增删
step "面板订阅增删"
ADD=$(panel_post "action=add&name=sub-c&url=http%3A%2F%2F$SUB_NAME%2Fsub-node-only.yaml&type=proxies")
assert_ok_json "面板新增订阅" "$ADD"
DEL=$(panel_post 'action=del&name=sub-c')
assert_ok_json "面板删除订阅" "$DEL"
assert_eq "删除后剩余订阅数" "2" "$(panel /cgi-bin/subs.sh 2>/dev/null | jq_in '.total')"

# ---------------------------------------------------------------- 策略组接口
step "策略组与节点接口"
GROUPS_JSON=$(panel /cgi-bin/nodes.sh || true)
assert_contains "策略组接口返回数据" "$GROUPS_JSON" '"groups"'
assert_contains "策略组接口返回当前选中节点" "$GROUPS_JSON" '"now"'

DEC=$(gw_exec sh -c '. /www/cgi-bin/_lib.sh; cgi_urldecode "%E5%8A%A0%E9%80%9F%E8%8A%82%E7%82%B9+demo"' 2>/dev/null || true)
assert_eq "容器内 URL 解码（UTF-8 + 加号）" "加速节点 demo" "$DEC"

NODE_SEL=$(gw_exec curl -sS -m 30 -X POST -H "X-Panel-Token: $SECRET" \
  --data "action=select&group=%E5%8A%A0%E9%80%9F%E8%8A%82%E7%82%B9&node=smoke-a-marker" \
  "http://127.0.0.1:8080/cgi-bin/nodes.sh" 2>&1 || true)
assert_ok_json "节点切换接口可用" "$NODE_SEL"

# ---------------------------------------------------------------- 流量统计
step "流量统计（内核自带接口的呈现）"
BEFORE=$(api /connections 2>/dev/null | jq_in '.downloadTotal' || true)
[ -n "$BEFORE" ] || BEFORE=0
CODE=$(gw_exec curl -sS -m 20 -o /dev/null -w '%{http_code}' -x "http://127.0.0.1:7890" "http://$TARGET_IP/" 2>/dev/null || printf 'failed')
assert_eq "经内核混合端口访问目标服务" "200" "$CODE"
AFTER=$(api /connections 2>/dev/null | jq_in '.downloadTotal' || true)
[ -n "$AFTER" ] || AFTER=0
if [ "$AFTER" -gt "$BEFORE" ]; then ok "代理流量计入内核统计（$BEFORE → $AFTER）"; else bad "流量计数未增长（$BEFORE → $AFTER）"; fi

TRAFFIC=$(panel /cgi-bin/traffic.sh || true)
assert_contains "流量接口返回累计下行" "$TRAFFIC" '"down_total"'
assert_contains "流量接口返回实时速率" "$TRAFFIC" '"down_speed"'
assert_contains "流量接口返回活动连接" "$TRAFFIC" '"connections"'
assert_contains "流量接口返回内存占用" "$TRAFFIC" '"memory"'
GW_CLI=$(gw_exec sh /app/docker/gw status 2>/dev/null || true)
assert_contains "命令行状态输出流量统计" "$GW_CLI" "累计"

# ---------------------------------------------------------------- 内置 DNS
step "内置 DNS（提示项）"
if gw_exec nslookup example.com 127.0.0.1 2>/dev/null | grep -q "Address"; then
  ok "内置 DNS 可解析域名"
else
  info "内置 DNS 解析未通过（可能受 CI 网络限制影响，不视为失败）"
fi

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
