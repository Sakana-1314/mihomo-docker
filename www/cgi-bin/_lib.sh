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

cgi_hex_dec() { # $1=单个十六进制字符 → 十进制（POSIX 无 base# 语法，故用查表）
  case "${1:-}" in
    0|1|2|3|4|5|6|7|8|9) printf '%s' "$1" ;;
    a|A) printf '10' ;;
    b|B) printf '11' ;;
    c|C) printf '12' ;;
    d|D) printf '13' ;;
    e|E) printf '14' ;;
    f|F) printf '15' ;;
    *) printf '' ;;
  esac
}

cgi_urldecode() { # $1=URL 编码字符串 → 解码（仅 POSIX 语法与八进制转义，兼容 dash/busybox）
  _s="$1"; _out=''
  while [ -n "$_s" ]; do
    case "$_s" in
      '%'[0-9a-fA-F][0-9a-fA-F]*)
        _hi=$(cgi_hex_dec "$(printf '%s' "$_s" | cut -c2)")
        _lo=$(cgi_hex_dec "$(printf '%s' "$_s" | cut -c3)")
        if [ -n "$_hi" ] && [ -n "$_lo" ]; then
          _s=$(printf '%s' "$_s" | cut -c4-)
          # 运行时拼装的八进制转义作为 printf 格式串（\ooo 为 POSIX 定义）
          # shellcheck disable=SC2059
          _out="$_out$(printf "\\$(printf '%03o' "$((_hi * 16 + _lo))")")"
          continue
        fi
        _out="$_out%"
        _s=$(printf '%s' "$_s" | cut -c2-)
        ;;
      '+'*)
        _out="$_out "
        _s=$(printf '%s' "$_s" | cut -c2-)
        ;;
      *)
        _out="$_out$(printf '%s' "$_s" | cut -c1)"
        _s=$(printf '%s' "$_s" | cut -c2-)
        ;;
    esac
  done
  printf '%s' "$_out"
}

cgi_qs_get() { # $1=键 → 查询串中的值（URL 解码）
  _v=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1)
  cgi_urldecode "$_v"
}

cgi_body() { printf '%s' "${CGI_BODY:-}"; }

cgi_init() { # 每个 CGI 脚本开头调用一次：请求体只从 stdin 读取一次并缓存
  CGI_BODY=''
  if [ "${REQUEST_METHOD:-GET}" = "POST" ]; then
    _len="${CONTENT_LENGTH:-0}"
    gw_is_num "$_len" || _len=0
    if [ "$_len" -gt 0 ] && [ "$_len" -le 65536 ]; then
      CGI_BODY=$(head -c "$_len")
    fi
  fi
}

cgi_field_raw() { # $1=键 → 原始值（不做 URL 解码，便于直接用于 API 路径）
  _v=$(cgi_body | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1)
  if [ -z "$_v" ]; then
    _v=$(printf '%s' "${QUERY_STRING:-}" | tr '&' '\n' | sed -n "s/^$1=//p" | head -n1)
  fi
  printf '%s' "$_v"
}

cgi_field() { # $1=键 → 表单体（或查询串）中的值（URL 解码）
  cgi_urldecode "$(cgi_field_raw "$1")"
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

cgi_run() { # 其余参数为命令：执行并输出完整响应 {ok, output}
  _out=$("$@" 2>&1)
  _rc=$?
  _json=$(GW_OUT="$_out" GW_RC="$_rc" \
    yq -n -o=json -I0 '{"ok": (strenv(GW_RC) == "0"), "output": strenv(GW_OUT)}' 2>/dev/null) || _json=''
  [ -n "$_json" ] || _json=$(GW_OUT="$_out" yq -n -o=json -I0 '{"ok": false, "output": strenv(GW_OUT)}' 2>/dev/null) || _json='{"ok":false,"error":"响应生成失败"}'
  cgi_ok "$_json"
}

cgi_run_then_subs() { # 执行命令并附带最新订阅清单（同样输出完整响应）
  _out=$("$@" 2>&1)
  _rc=$?
  _subs=$(sh "$GW_APP_DIR/subs.sh" json 2>/dev/null || true)
  case "$_subs" in
    '{'*) ;;
    *) _subs='{"active":"","total":0,"items":[]}' ;;
  esac
  _json=$(GW_OUT="$_out" GW_RC="$_rc" GW_SUBS="$_subs" \
    yq -n -o=json -I0 '{"ok": (strenv(GW_RC) == "0"), "output": strenv(GW_OUT), "subs": (strenv(GW_SUBS) | from_json)}' 2>/dev/null) || _json=''
  if [ -z "$_json" ]; then
    _json=$(GW_OUT="$_out" GW_RC="$_rc" \
      yq -n -o=json -I0 '{"ok": (strenv(GW_RC) == "0"), "output": strenv(GW_OUT)}' 2>/dev/null) || _json=''
  fi
  [ -n "$_json" ] || _json='{"ok":false,"error":"响应生成失败"}'
  cgi_ok "$_json"
}
