#!/bin/sh
# 面板接口：策略组与节点
#   GET                 策略组列表（含当前选中节点）
#   POST action=select  切换节点（group, node）
_cgi_dir=$(dirname "$0" 2>/dev/null || printf '/www/cgi-bin')
# shellcheck source=_lib.sh
. "$_cgi_dir/_lib.sh"

cgi_init
cgi_require_auth

if [ "$(cgi_method)" = "GET" ]; then
  _proxies=$(gw_api GET /proxies 2>/dev/null || true)
  if [ -z "$_proxies" ]; then
    cgi_ok '{"ok":false,"error":"内核未就绪","groups":[]}'
  fi
  _groups=$(printf '%s' "$_proxies" | yq -p=json -o=json -I0 '
    {
      "ok": true,
      "groups": (.proxies | to_entries
        | map(select(.value.all != null and .key != "GLOBAL")
        | {"name": .key, "type": (.value.type // ""), "now": (.value.now // ""), "nodes": (.value.all // [])}))
    }' - 2>/dev/null) || _groups=''
  [ -n "$_groups" ] || _groups='{"ok":false,"error":"策略组解析失败","groups":[]}'
  cgi_ok "$_groups"
fi

action=$(cgi_field action)
if [ "$action" != "select" ]; then
  cgi_fail "400 Bad Request" "未知操作：$action"
fi

group=$(cgi_field group)
node=$(cgi_field node)
[ -n "$group" ] || cgi_fail "400 Bad Request" "缺少策略组名"
[ -n "$node" ] || cgi_fail "400 Bad Request" "缺少节点名"

_enc_group=$(cgi_urlencode "$group")
_body=$(GW_NODE="$node" yq -n -o=json -I0 '{"name": strenv(GW_NODE)}')
if gw_api PUT "/proxies/$_enc_group" "$_body" >/dev/null 2>&1; then
  cgi_ok '{"ok": true, "output": "已切换节点"}'
fi
cgi_fail "502 Bad Gateway" "切换失败（策略组或节点不存在）"
