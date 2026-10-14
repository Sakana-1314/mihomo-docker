#!/bin/sh
# 面板接口：综合运行状态（GET）
_cgi_dir=$(dirname "$0" 2>/dev/null || printf '/www/cgi-bin')
# shellcheck source=_lib.sh
. "$_cgi_dir/_lib.sh"

cgi_require_auth

case "$(cgi_method)" in
  GET) cgi_ok "$(sh "$GW_APP_DIR/stats.sh" status-json)" ;;
  *)   cgi_fail "405 Method Not Allowed" "仅支持 GET" ;;
esac
