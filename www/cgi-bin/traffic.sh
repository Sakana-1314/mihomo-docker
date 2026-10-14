#!/bin/sh
# 面板接口：流量统计（GET，采样后返回，前端轮询）
_cgi_dir=$(dirname "$0" 2>/dev/null || printf '/www/cgi-bin')
# shellcheck source=_lib.sh
. "$_cgi_dir/_lib.sh"

cgi_require_auth

case "$(cgi_method)" in
  GET)
    sh "$GW_APP_DIR/stats.sh" sample >/dev/null 2>&1 || true
    cgi_ok "$(sh "$GW_APP_DIR/stats.sh" traffic-json)"
    ;;
  *) cgi_fail "405 Method Not Allowed" "仅支持 GET" ;;
esac
