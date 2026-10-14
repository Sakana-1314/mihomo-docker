#!/bin/sh
# 面板接口：订阅管理
#   GET                      订阅清单
#   POST action=add          新增（name, url, type）
#   POST action=del          删除（name）
#   POST action=update       更新（name 或 all）
#   POST action=switch       快捷切换（name 或 baseline）
_cgi_dir=$(dirname "$0" 2>/dev/null || printf '/www/cgi-bin')
# shellcheck source=_lib.sh
. "$_cgi_dir/_lib.sh"

cgi_init
cgi_require_auth

if [ "$(cgi_method)" = "GET" ]; then
  cgi_ok "$(sh "$GW_APP_DIR/subs.sh" json)"
fi

action=$(cgi_field action)
case "$action" in
  add)
    name=$(cgi_field name)
    url=$(cgi_field url)
    type=$(cgi_field type)
    [ -n "$type" ] || type=auto
    [ -n "$name" ] || cgi_fail "400 Bad Request" "缺少订阅名称"
    [ -n "$url" ] || cgi_fail "400 Bad Request" "缺少订阅地址"
    cgi_run_then_subs sh "$GW_APP_DIR/subs.sh" add "$name" "$url" "$type"
    ;;
  del)
    name=$(cgi_field name)
    [ -n "$name" ] || cgi_fail "400 Bad Request" "缺少订阅名称"
    cgi_run_then_subs sh "$GW_APP_DIR/subs.sh" del "$name"
    ;;
  update)
    name=$(cgi_field name)
    [ -n "$name" ] || name=all
    cgi_run_then_subs sh "$GW_APP_DIR/subs.sh" update "$name"
    ;;
  switch)
    name=$(cgi_field name)
    [ -n "$name" ] || cgi_fail "400 Bad Request" "缺少订阅名称"
    cgi_run_then_subs sh "$GW_APP_DIR/switch.sh" "$name"
    ;;
  *)
    cgi_fail "400 Bad Request" "未知操作：$action"
    ;;
esac
