#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 公共函数库（仅 source 使用，不直接执行）
# 兼容 busybox ash / POSIX sh，勿使用 bash 专有语法
# =============================================================================

# ---- 目录 ----
# shellcheck disable=SC2034  # 以下常量供 source 本文件的其它脚本使用
GW_DATA_DIR="${GW_DATA_DIR:-/data}"
GW_MIHOMO_HOME="$GW_DATA_DIR/mihomo"
GW_CONFIG_DIR="$GW_DATA_DIR/config"
GW_STATE_DIR="$GW_DATA_DIR/state"
GW_SUBS_STATE_DIR="$GW_STATE_DIR/subs"
GW_LOG_DIR="$GW_DATA_DIR/log"
GW_PROFILES_DIR="$GW_MIHOMO_HOME/profiles"
GW_PROVIDERS_DIR="$GW_MIHOMO_HOME/providers"
GW_APP_DIR="${GW_APP_DIR:-/app/docker}"
GW_SHARE_DIR="${GW_SHARE_DIR:-/usr/share/gw}"
GW_WWW_DIR="${GW_WWW_DIR:-/www}"

# 补齐标准可执行目录（保留调用方 PATH 的既有优先级，便于测试注入自定义程序）
PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
for _gw_dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
  case ":$PATH:" in
    *":$_gw_dir:"*) ;;
    *) PATH="$PATH:$_gw_dir" ;;
  esac
done
export PATH

# ---- 日志 ----
gw_log()  { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
gw_warn() { printf '%s [警告] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
gw_die()  { gw_warn "$*"; exit 1; }
gw_have() { command -v "$1" >/dev/null 2>&1; }

# ---- 环境与状态 ----
gw_load_env() {
  if [ -f "$GW_STATE_DIR/gw.env" ]; then
    # shellcheck disable=SC1091
    . "$GW_STATE_DIR/gw.env"
  fi
  return 0
}

gw_state_get() { # $1=名称（无则输出空）
  if [ -f "$GW_STATE_DIR/$1" ]; then cat "$GW_STATE_DIR/$1"; fi
}

gw_state_set() { # $1=名称 $2=内容
  printf '%s' "$2" > "$GW_STATE_DIR/$1"
}

# ---- 内核 API ----
gw_api() { # $1=method $2=path $3=body(可选)
  _m="$1"; _p="$2"; _b="${3:-}"
  if [ -n "$_b" ]; then
    curl -fsS --max-time "${GW_API_TIMEOUT:-20}" -X "$_m" \
      -H "Authorization: Bearer ${SECRET:-}" -H 'Content-Type: application/json' \
      --data-binary "$_b" "http://127.0.0.1:${CONTROLLER_PORT:-9090}${_p}"
  else
    curl -fsS --max-time "${GW_API_TIMEOUT:-20}" -X "$_m" \
      -H "Authorization: Bearer ${SECRET:-}" "http://127.0.0.1:${CONTROLLER_PORT:-9090}${_p}"
  fi
}

gw_kernel_alive() { gw_api GET /version >/dev/null 2>&1; }

# ---- 操作锁（避免并发写配置/状态）----
gw_lock() {
  _i=0
  while ! mkdir "$GW_STATE_DIR/.lock" 2>/dev/null; do
    _i=$((_i + 1))
    if [ "$_i" -gt 30 ]; then
      gw_warn "等待操作锁超时，强制继续"
      rm -rf "$GW_STATE_DIR/.lock"
      break
    fi
    sleep 1
  done
}

gw_unlock() { rm -rf "$GW_STATE_DIR/.lock"; }

# ---- JSON 输出（统一由 yq 生成，避免手工转义出错）----
gw_json() { yq -n -o=json "$@"; }

# ---- 订阅元数据（清单读取与类型识别，供多个脚本共用）----
gw_subs_file() { printf '%s' "$GW_CONFIG_DIR/subscriptions.yaml"; }

gw_subs_names() {
  yq -r '.subscriptions[]? | .name // ""' "$(gw_subs_file)" 2>/dev/null
}

gw_subs_type() { # $1=名称 → auto|proxies|profile（缺省 auto）
  _t=$(GW_SUB_NAME="$1" yq -r '.subscriptions[]? | select(.name == strenv(GW_SUB_NAME)) | .type // "auto"' "$(gw_subs_file)" 2>/dev/null | head -n1)
  [ -n "$_t" ] || _t=auto
  printf '%s' "$_t"
}

gw_subs_url() { # $1=名称 → url
  GW_SUB_NAME="$1" yq -r '.subscriptions[]? | select(.name == strenv(GW_SUB_NAME)) | .url // ""' "$(gw_subs_file)" 2>/dev/null | head -n1
}

gw_subs_exists() {
  GW_SUB_NAME="$1" yq -e '.subscriptions[]? | select(.name == strenv(GW_SUB_NAME))' "$(gw_subs_file)" >/dev/null 2>&1
}

gw_valid_name() { # 订阅名安全校验（同时用作文件名）
  case "${1:-}" in
    ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

gw_profile_type() { # $1=名称 → proxies|profile
  _f="$GW_PROFILES_DIR/$1.yaml"
  [ -f "$_f" ] || return 1
  _t=$(gw_subs_type "$1")
  case "$_t" in
    proxies|profile) printf '%s' "$_t"; return 0 ;;
  esac
  if yq -e 'has("proxy-groups") and has("rules")' "$_f" >/dev/null 2>&1; then
    printf 'profile'
  else
    printf 'proxies'
  fi
}

gw_profile_nodes() { # $1=名称 → 节点数量
  yq -r '(.proxies // []) | length' "$GW_PROFILES_DIR/$1.yaml" 2>/dev/null | head -n1 || printf '0'
}

# ---- 下载（公网目标优先经内核链路，内网/单标签主机优先直连；双向回退）----
gw_download() { # $1=url $2=目标文件
  _url="$1"; _out="$2"
  _ua="${SUB_USER_AGENT:-clash.meta}"
  _timeout="${SUB_TIMEOUT:-30}"
  _host=$(printf '%s' "$_url" | sed -e 's|^[A-Za-z][A-Za-z0-9+.-]*://||' -e 's|^[^/]*@||' -e 's|[:/?].*$||')

  # 单标签主机名（容器/内网服务名）与私有地址优先直连：
  # 这类目标在分流规则中可能被判定为代理流量，直连更符合预期
  _prefer_direct=0
  case "$_host" in
    ''|*.*) ;;
    *) _prefer_direct=1 ;;
  esac
  case "$_host" in
    10.*|127.*|192.168.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) _prefer_direct=1 ;;
  esac

  _via_proxy=0
  if [ "${SUB_VIA_PROXY:-1}" = "1" ] && gw_kernel_alive; then _via_proxy=1; fi

  if [ "$_prefer_direct" = "0" ] && [ "$_via_proxy" = "1" ]; then
    if curl -fsSL --max-time "$_timeout" -A "$_ua" \
        -x "http://127.0.0.1:${MIXED_PORT:-7890}" "$_url" -o "$_out" 2>/dev/null; then
      return 0
    fi
    gw_warn "经内核链路下载失败，回退直连：$_url"
  fi

  if curl -fsSL --max-time "$_timeout" --retry 2 --retry-delay 1 -A "$_ua" "$_url" -o "$_out"; then
    return 0
  fi

  if [ "$_prefer_direct" = "1" ] && [ "$_via_proxy" = "1" ]; then
    gw_log "直连下载失败，改经内核链路重试：$_url"
    curl -fsSL --max-time "$_timeout" -A "$_ua" \
      -x "http://127.0.0.1:${MIXED_PORT:-7890}" "$_url" -o "$_out"
    return $?
  fi
  return 1
}

# ---- 数值校验 ----
gw_is_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

gw_bool() { # 1/true/yes/on → 1；其余 → 0
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) printf '1' ;;
    *) printf '0' ;;
  esac
}
