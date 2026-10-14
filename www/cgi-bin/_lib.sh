#!/bin/sh
# =============================================================================
# 面板 CGI 公共函数（仅供其它 CGI 脚本 source，不直接访问）
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-/app/docker}"
# shellcheck source=/dev/null
. "$GW_APP_DIR/lib.sh"
gw_load_env

cgi_header() { # $1=Content-Type [$2=Status]
  printf 'Content-Type: %s\r\n' "${1:-application/json; charset=utf-8}"
  if [ -n "${2:-}" ]; then printf 'Status: %s\r\n' "$2"; fi
  printf 'Cache-Control: no-store\r\n\r\n'
}

cgi_fail() { # $1=Status $2=消息
  cgi_header 'application/json; charset=utf-8' "$1"
  GW_MSG="$2" yq -n -o=json -I0 '{"ok": false, "error": strenv(GW_MSG)}'
  exit 0
}

cgi_ok() { # $1=JSON 文本（原样输出）
  cgi_header 'application/json; charset=utf-8'
  printf '%s\n' "$1"
  exit 0
}

cgi_urldecode() {
  printf '%b' "$(printf '%s' "$1" | sed -e 's/+/ /g' -e 's/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')"
}

cgi_urlencode() {
  _s="$1"; _out=''
  while [ -n "$_s" ]; do
    _c=$(printf '%s' "$_s" | cut -c1)
    _s=$(printf '%s' "$_s" | cut -c2-)
    case "$_c" in
      [A-Za-z0-9._~-]) _out="$_out$_c" ;;
      *) _out="$_out$(printf '%s' "$_c" | od -An -tx1 -v | tr -d ' \n' | sed 's/../%&/g')" ;;
    esac
  done
  printf '%s' "$_out"
}

cgi_qs_get() { # $1=键 → 查询串中的值（URL 解码）
  _v=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1)
  cgi_urldecode "$_v"
}

cgi_body() {
  if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    _len="${CONTENT_LENGTH:-0}"
    gw_is_num "$_len" || _len=0
    if [ "$_len" -gt 0 ] && [ "$_len" -le 65536 ]; then
      head -c "$_len"
    fi
  fi
}

cgi_body_get() { # $1=键 → 表单体中的值（URL 解码）
  _v=$(cgi_body | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1)
  cgi_urldecode "$_v"
}

cgi_method() { printf '%s' "${REQUEST_METHOD:-GET}"; }

cgi_require_auth() {
  [ "${PANEL_AUTH:-token}" = "none" ] && return 0
  _expect="${SECRET:-}"
  [ -n "$_expect" ] || return 0
  _given="${HTTP_X_PANEL_TOKEN:-}"
  [ -n "$_given" ] || _given=$(cgi_qs_get token)
  [ "$_given" = "$_expect" ] && return 0
  cgi_fail "401 Unauthorized" "访问密钥不正确"
}

cgi_run() { # 其余参数为命令：执行并输出 {ok, output}
  _out=$("$@" 2>&1)
  _rc=$?
  GW_OUT="$_out" GW_RC="$_rc" \
    yq -n -o=json -I0 '{"ok": (strenv(GW_RC) == "0"), "output": strenv(GW_OUT)}'
}

cgi_run_then_subs() { # 执行命令并附带最新订阅清单
  _out=$("$@" 2>&1)
  _rc=$?
  _subs=$(sh "$GW_APP_DIR/subs.sh" json 2>/dev/null || printf '{"active":"","total":0,"items":[]}')
  GW_OUT="$_out" GW_RC="$_rc" GW_SUBS="$_subs" \
    yq -n -o=json -I0 '{"ok": (strenv(GW_RC) == "0"), "output": strenv(GW_OUT), "subs": (strenv(GW_SUBS) | from_json)}'
}
