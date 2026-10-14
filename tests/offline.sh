#!/usr/bin/env bash
# =============================================================================
# 离线逻辑测试（无需 Docker、无需内核）
# 用桩程序替换 curl / mihomo，验证：环境解析、配置合成、订阅管理、快捷切换、面板接口
#   本地运行：bash tests/offline.sh（需 yq 在 PATH 中）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
export FIXTURES_DIR="$ROOT/tests/fixtures"
PASS=0
FAIL=0
trap 'rm -rf "$TMP"' EXIT

ok()  { printf '  [通过] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '  [失败] %s\n' "$*"; FAIL=$((FAIL + 1)); }
step() { printf '\n== %s ==\n' "$*"; }

assert_eq() { # 描述 期望 实际
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$2]，实际 [$3]）"; fi
}

assert_contains() { # 描述 内容 子串
  if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1（未包含 [$3]）"; fi
}

assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then bad "$1（不应包含 [$3]）"; else ok "$1"; fi
}

assert_file_contains() { # 描述 文件 子串
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1（$2 未包含 [$3]）"; fi
}

assert_file_missing() {
  if [ -e "$2" ]; then bad "$1（文件仍存在：$2）"; else ok "$1"; fi
}

command -v yq >/dev/null 2>&1 || { echo "缺少 yq，请先安装并加入 PATH"; exit 2; }

# ---------------------------------------------------------------- 桩程序
mkdir -p "$TMP/bin" "$TMP/data"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# 桩 curl：http://sub.test/<file> → fixtures 目录；其它请求失败（模拟内核 API 未启动）
out=''; url=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  *sub.test/*) cp "$FIXTURES_DIR/$(basename "$url")" "$out"; exit 0 ;;
  *) exit 7 ;;
esac
STUB
cat > "$TMP/bin/mihomo" <<'STUB'
#!/usr/bin/env bash
# 桩内核：配置校验恒成功
exit 0
STUB
chmod +x "$TMP/bin/curl" "$TMP/bin/mihomo"

export PATH="$TMP/bin:$PATH"
export GW_DATA_DIR="$TMP/data"
export GW_APP_DIR="$ROOT/docker"
export GW_SHARE_DIR="$ROOT"
export GW_WWW_DIR="$ROOT/www"
export GATEWAY_IF=eth0
export SECRET=testsecret
export SUB_VIA_PROXY=1
export TZ=Asia/Shanghai

DATA="$TMP/data"
gw_cli() { sh "$ROOT/docker/gw" "$@"; }

# ---------------------------------------------------------------- 1. 环境解析
step "1. 环境解析与运行时注入"
if sh "$GW_APP_DIR/env.sh" resolve > /dev/null 2>&1; then ok "env.sh resolve 执行成功"; else bad "env.sh resolve 执行失败"; fi
assert_file_contains "gw.env 记录接口" "$DATA/state/gw.env" "GATEWAY_IF='eth0'"
assert_file_contains "gw.env 记录密钥" "$DATA/state/gw.env" "SECRET='testsecret'"
assert_file_contains "runtime.yaml 注入透明端口" "$DATA/state/runtime.yaml" "tproxy-port: 7893"
assert_file_contains "runtime.yaml 注入控制器" "$DATA/state/runtime.yaml" "external-controller: 0.0.0.0:9090"
assert_file_contains "runtime.yaml 注入密钥" "$DATA/state/runtime.yaml" "secret: testsecret"

if TRANSPARENT_MODE=bogus sh "$GW_APP_DIR/env.sh" resolve > /dev/null 2>&1; then
  bad "非法 TRANSPARENT_MODE 应被拒绝"
else
  ok "非法 TRANSPARENT_MODE 被拒绝"
fi

# ---------------------------------------------------------------- 2. 用户文件播种
step "2. 用户可编辑文件播种"
sh "$GW_APP_DIR/config.sh" ensure-user-config > /dev/null 2>&1
if [ -f "$DATA/config/overlay.yaml" ]; then ok "已生成 overlay.yaml"; else bad "缺少 overlay.yaml"; fi
if [ -f "$DATA/config/subscriptions.yaml" ]; then ok "已生成 subscriptions.yaml"; else bad "缺少 subscriptions.yaml"; fi
if [ -f "$DATA/mihomo/providers/active.yaml" ]; then ok "已生成空节点提供者"; else bad "缺少节点提供者文件"; fi

# ---------------------------------------------------------------- 3. 基线合成
step "3. 基线配置合成（模板 + 覆盖层 + 运行时）"
if sh "$GW_APP_DIR/config.sh" compose baseline > /dev/null 2>&1; then ok "compose baseline 执行成功"; else bad "compose baseline 执行失败"; fi
CFG="$DATA/mihomo/config.yaml"
assert_file_contains "合并出透明端口" "$CFG" "tproxy-port: 7893"
assert_file_contains "合并出 DNS 监听" "$CFG" "listen: 0.0.0.0:53"
assert_file_contains "合并出默认规则" "$CFG" "GEOIP,CN,DIRECT"
assert_file_contains "合并出策略组" "$CFG" "name: 加速节点"
assert_file_contains "覆盖层 log-level 生效" "$CFG" "log-level: info"

# ---------------------------------------------------------------- 4. 订阅新增
step "4. 订阅新增与拉取"
if gw_cli add sub-a "http://sub.test/sub-node-only.yaml" proxies > /dev/null 2>&1; then ok "新增仅节点订阅"; else bad "新增仅节点订阅失败"; fi
if [ -f "$DATA/mihomo/profiles/sub-a.yaml" ]; then ok "订阅文件已落盘"; else bad "订阅文件缺失"; fi
NODES=$(yq -r '.nodes' "$DATA/state/subs/sub-a.json" 2>/dev/null || echo '')
assert_eq "订阅节点数解析" "2" "$NODES"
assert_eq "订阅类型解析（proxies）" "proxies" "$(sh "$GW_APP_DIR/subs.sh" type sub-a)"

if gw_cli add sub-b "http://sub.test/sub-full.yaml" auto > /dev/null 2>&1; then ok "新增完整订阅"; else bad "新增完整订阅失败"; fi
assert_eq "订阅类型解析（auto → profile）" "profile" "$(sh "$GW_APP_DIR/subs.sh" type sub-b)"

# 重复新增应失败
if gw_cli add sub-a "http://sub.test/sub-node-only.yaml" proxies > /dev/null 2>&1; then
  bad "重复订阅名应被拒绝"
else
  ok "重复订阅名被拒绝"
fi

# ---------------------------------------------------------------- 5. 快捷切换
step "5. 快捷切换"
if sh "$GW_APP_DIR/switch.sh" sub-a > /dev/null 2>&1; then ok "切换到仅节点订阅"; else bad "切换到仅节点订阅失败"; fi
assert_eq "活跃订阅记录" "sub-a" "$(cat "$DATA/state/active")"
assert_file_contains "节点写入提供者文件" "$DATA/mihomo/providers/active.yaml" "smoke-a-1"
assert_file_contains "仅节点模式仍使用模板规则" "$CFG" "GEOIP,CN,DIRECT"

if sh "$GW_APP_DIR/switch.sh" sub-b > /dev/null 2>&1; then ok "切换到完整订阅"; else bad "切换到完整订阅失败"; fi
assert_file_contains "完整订阅的策略组生效" "$CFG" "SMOKE-PROFILE-GROUP"
assert_file_contains "完整订阅仍注入透明端口" "$CFG" "tproxy-port: 7893"
assert_not_contains "完整订阅不再包含模板规则" "$(cat "$CFG")" "GEOIP,CN,DIRECT"

if sh "$GW_APP_DIR/switch.sh" baseline > /dev/null 2>&1; then ok "切换到空载基线"; else bad "切换到空载基线失败"; fi
assert_eq "空载基线清空活跃订阅" "" "$(cat "$DATA/state/active")"
assert_file_contains "空载基线清空提供者" "$DATA/mihomo/providers/active.yaml" "proxies: []"
assert_not_contains "空载基线恢复模板规则" "$(cat "$CFG")" "SMOKE-PROFILE-GROUP"

# ---------------------------------------------------------------- 6. 覆盖层优先级
step "6. 覆盖层优先级（用户可覆盖订阅规则）"
cat > "$DATA/config/overlay.yaml" <<'EOF'
log-level: debug
rules:
  - MATCH,DIRECT
EOF
sh "$GW_APP_DIR/config.sh" compose baseline > /dev/null 2>&1
assert_file_contains "覆盖层 log-level 覆盖生效" "$CFG" "log-level: debug"
assert_file_contains "覆盖层自定义规则生效" "$CFG" "MATCH,DIRECT"
assert_not_contains "覆盖层规则整体替换" "$(cat "$CFG")" "GEOIP,CN,DIRECT"

# ---------------------------------------------------------------- 7. 订阅 JSON 与删除
step "7. 订阅 JSON 与删除"
SUBS_JSON=$(sh "$GW_APP_DIR/subs.sh" json)
assert_contains "JSON 含活跃字段" "$SUBS_JSON" '"active"'
TOTAL=$(printf '%s' "$SUBS_JSON" | yq -p=json -r '.total' -)
assert_eq "JSON 订阅总数" "2" "$TOTAL"
ITEMS=$(printf '%s' "$SUBS_JSON" | yq -p=json -r '.items | length' -)
assert_eq "JSON 订阅条目数" "2" "$ITEMS"

if gw_cli del sub-b > /dev/null 2>&1; then ok "删除订阅"; else bad "删除订阅失败"; fi
assert_file_missing "订阅文件已删除" "$DATA/mihomo/profiles/sub-b.yaml"
assert_file_missing "订阅状态已删除" "$DATA/state/subs/sub-b.json"
NAMES=$(sh "$GW_APP_DIR/subs.sh" names)
assert_eq "剩余订阅数量" "1" "$(printf '%s\n' "$NAMES" | grep -c . || true)"

# ---------------------------------------------------------------- 8. 流量统计
step "8. 流量统计（内核未运行时降级）"
if sh "$GW_APP_DIR/stats.sh" sample > /dev/null 2>&1; then ok "采样在内核离线时降级成功"; else bad "采样失败"; fi
assert_file_contains "流量状态文件生成" "$DATA/state/traffic.json" '"up_total":0'
assert_eq "字节单位换算" "1.00 MB" "$(sh "$GW_APP_DIR/stats.sh" human 1048576)"
assert_eq "字节单位换算（字节）" "512 B" "$(sh "$GW_APP_DIR/stats.sh" human 512)"

# ---------------------------------------------------------------- 9. 面板接口
step "9. 面板 CGI 接口"
STATUS_OUT=$(REQUEST_METHOD=GET QUERY_STRING="token=testsecret" sh "$ROOT/www/cgi-bin/status.sh")
assert_contains "状态接口返回 JSON 头" "$STATUS_OUT" "Content-Type: application/json"
assert_contains "状态接口含内核字段" "$STATUS_OUT" '"kernel"'
assert_contains "状态接口含流量字段" "$STATUS_OUT" '"traffic"'
assert_contains "状态接口含订阅字段" "$STATUS_OUT" '"subs"'

NOAUTH_OUT=$(REQUEST_METHOD=GET QUERY_STRING="" sh "$ROOT/www/cgi-bin/status.sh")
assert_contains "无密钥访问被拒绝" "$NOAUTH_OUT" "401 Unauthorized"

TRAFFIC_OUT=$(REQUEST_METHOD=GET QUERY_STRING="token=testsecret" sh "$ROOT/www/cgi-bin/traffic.sh")
assert_contains "流量接口返回数据" "$TRAFFIC_OUT" '"down_total"'

NODES_OUT=$(REQUEST_METHOD=GET QUERY_STRING="token=testsecret" sh "$ROOT/www/cgi-bin/nodes.sh")
assert_contains "节点接口在内核离线时降级" "$NODES_OUT" '"ok":false'

UPDATE_OUT=$(REQUEST_METHOD=POST CONTENT_LENGTH=20 QUERY_STRING="token=testsecret" \
  sh -c "printf 'action=update&name=sub-a' | sh '$ROOT/www/cgi-bin/subs.sh'")
assert_contains "订阅更新接口执行成功" "$UPDATE_OUT" '"ok":true'

# ---------------------------------------------------------------- 10. CLI
step "10. 命令行入口"
LIST_OUT=$(gw_cli subs)
assert_contains "gw subs 列出订阅" "$LIST_OUT" "sub-a"
STATUS_CLI=$(gw_cli status)
assert_contains "gw status 输出状态" "$STATUS_CLI" "透明代理"

# ---------------------------------------------------------------- 汇总
printf '\n=========================================\n'
printf '通过 %d 项，失败 %d 项\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf '离线逻辑测试未通过\n'
  exit 1
fi
printf '离线逻辑测试通过\n'
