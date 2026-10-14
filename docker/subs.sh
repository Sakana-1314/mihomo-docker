#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 订阅管理
# 拉取 / 更新 / 增删 / 列表 / 面板 JSON（定时自动更新由 scheduler.sh 触发）
# 订阅元数据读取函数（gw_subs_* / gw_profile_*）位于 lib.sh
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

sub_state_write() { # $1=名称 $2=状态 $3=节点数 $4=sha256 $5=错误信息
  _err=$(printf '%s' "${5:-}" | tr -d '\n\r' | cut -c1-300)
  if GW_SN="$1" GW_SS="$2" GW_SNODES="${3:-0}" GW_SSHA="${4:-}" GW_SERR="$_err" \
     GW_SURL="$(gw_subs_url "$1")" GW_STYPE="$(gw_profile_type "$1" 2>/dev/null || printf 'unknown')" \
     GW_STS="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
     yq -n -o=json -I0 '
      .name = strenv(GW_SN) |
      .url = strenv(GW_SURL) |
      .type = strenv(GW_STYPE) |
      .status = strenv(GW_SS) |
      .nodes = (strenv(GW_SNODES) | tonumber) |
      .sha256 = strenv(GW_SSHA) |
      .updated_at = strenv(GW_STS) |
      .error = strenv(GW_SERR)
    ' > "$GW_SUBS_STATE_DIR/$1.json.new" 2>/dev/null; then
    mv "$GW_SUBS_STATE_DIR/$1.json.new" "$GW_SUBS_STATE_DIR/$1.json"
  else
    rm -f "$GW_SUBS_STATE_DIR/$1.json.new"
    gw_warn "订阅状态写入失败：$1"
  fi
}

cmd_fetch() { # $1=名称 [url]
  _name="$1"
  gw_valid_name "$_name" || { gw_warn "订阅名不合法（仅允许字母数字与 . _ -）：$_name"; return 2; }
  _url="${2:-$(gw_subs_url "$_name")}"
  if [ -z "$_url" ]; then
    gw_warn "订阅 $_name 未配置 URL"
    sub_state_write "$_name" error 0 "" "未配置 URL"
    return 3
  fi

  mkdir -p "$GW_PROFILES_DIR" "$GW_SUBS_STATE_DIR"
  _tmp="$GW_PROFILES_DIR/.$_name.yaml.new"
  rm -f "$_tmp"

  if ! gw_download "$_url" "$_tmp"; then
    gw_warn "订阅 $_name 下载失败：$_url"
    rm -f "$_tmp"
    sub_state_write "$_name" error "$(gw_profile_nodes "$_name" 2>/dev/null || printf '0')" "" "下载失败"
    return 4
  fi

  if [ ! -s "$_tmp" ] || ! yq -e 'has("proxies") or has("proxy-providers") or has("rules")' "$_tmp" >/dev/null 2>&1; then
    gw_warn "订阅 $_name 内容无效（需以 clash.meta UA 返回 YAML 配置）"
    rm -f "$_tmp"
    sub_state_write "$_name" error 0 "" "订阅内容无效"
    return 5
  fi

  mv "$_tmp" "$GW_PROFILES_DIR/$_name.yaml"
  _nodes=$(gw_profile_nodes "$_name")
  _sha=$(sha256sum "$GW_PROFILES_DIR/$_name.yaml" | awk '{print $1}')
  sub_state_write "$_name" ok "$_nodes" "$_sha" ""
  gw_log "订阅已更新：$_name（节点 $_nodes 个）"
  return 0
}

cmd_update() { # $1=all|名称
  _target="${1:-all}"
  if [ "$_target" = "all" ]; then
    _list=$(gw_subs_names)
    if [ -z "$_list" ]; then
      gw_log "订阅清单为空，跳过更新"
      return 0
    fi
  else
    _list="$_target"
  fi

  _rc=0
  for _n in $_list; do
    if cmd_fetch "$_n"; then
      _active=$(gw_state_get active)
      if [ "$_active" = "$_n" ]; then
        if ! sh "$GW_APP_DIR/switch.sh" "$_n"; then
          gw_warn "订阅 $_n 已更新，但热生效失败"
          _rc=1
        fi
      fi
    else
      _rc=1
    fi
  done
  return $_rc
}

cmd_add() { # $1=名称 $2=url [type]
  _name="${1:-}"; _url="${2:-}"; _type="${3:-auto}"
  gw_valid_name "$_name" || gw_die "订阅名仅允许字母数字与 . _ - ：$_name"
  [ -n "$_url" ] || gw_die "缺少订阅地址"
  case "$_type" in auto|proxies|profile) ;; *) gw_die "type 仅支持 auto / proxies / profile：$_type" ;; esac
  sh "$GW_APP_DIR/config.sh" ensure-user-config
  if gw_subs_exists "$_name"; then
    gw_die "订阅已存在：$_name（如需替换请先删除）"
  fi
  GW_SUB_NAME="$_name" GW_SUB_URL="$_url" GW_SUB_TYPE="$_type" \
    yq -i '.subscriptions = ((.subscriptions // []) + [{"name": strenv(GW_SUB_NAME), "url": strenv(GW_SUB_URL), "type": strenv(GW_SUB_TYPE)}])' "$(gw_subs_file)" \
    || gw_die "写入订阅清单失败"
  gw_log "已添加订阅：$_name"
  cmd_fetch "$_name"
}

cmd_del() { # $1=名称
  _name="${1:-}"
  gw_subs_exists "$_name" || gw_die "订阅不存在：$_name"
  GW_SUB_NAME="$_name" \
    yq -i '.subscriptions = [.subscriptions[]? | select(.name != strenv(GW_SUB_NAME))]' "$(gw_subs_file)" \
    || gw_die "更新订阅清单失败"
  rm -f "$GW_PROFILES_DIR/$_name.yaml" "$GW_SUBS_STATE_DIR/$_name.json"
  gw_log "已删除订阅：$_name"
  if [ "$(gw_state_get active)" = "$_name" ]; then
    _next=$(gw_subs_names | head -n1)
    if [ -n "$_next" ]; then
      sh "$GW_APP_DIR/switch.sh" "$_next" || gw_warn "自动切换到 $_next 失败"
    else
      sh "$GW_APP_DIR/switch.sh" baseline || gw_warn "自动切换到空载基线失败"
    fi
  fi
}

cmd_list() {
  _active=$(gw_state_get active)
  printf '%-18s %-8s %-6s %-22s %s\n' 名称 类型 节点 上次更新 状态
  for _n in $(gw_subs_names); do
    _st="$GW_SUBS_STATE_DIR/$_n.json"
    if [ -f "$_st" ]; then
      _type=$(yq -r '.type // "?"' "$_st" 2>/dev/null)
      _nodes=$(yq -r '.nodes // 0' "$_st" 2>/dev/null)
      _upd=$(yq -r '.updated_at // "-"' "$_st" 2>/dev/null)
      _status=$(yq -r '.status // "?"' "$_st" 2>/dev/null)
      _err=$(yq -r '.error // ""' "$_st" 2>/dev/null)
      [ "$_status" = "ok" ] || _status="$_status（$_err）"
    else
      _type=$(gw_subs_type "$_n"); _nodes=0; _upd='-'; _status='尚未拉取'
    fi
    _mark=''
    [ "$_n" = "$_active" ] && _mark='  ← 当前'
    printf '%-18s %-8s %-6s %-22s %s%s\n' "$_n" "$_type" "$_nodes" "$_upd" "$_status" "$_mark"
  done
}

cmd_json() { # 面板用：订阅清单 JSON（保证 each 元素都是合法对象）
  _active=$(gw_state_get active)
  _items=''
  _total=0
  for _n in $(gw_subs_names); do
    _total=$((_total + 1))
    _obj=''
    _st="$GW_SUBS_STATE_DIR/$_n.json"
    if [ -f "$_st" ]; then
      _obj=$(yq -o=json -I0 '.' "$_st" 2>/dev/null || true)
    fi
    case "$_obj" in
      '{'*) ;;
      *) _obj=$(GW_SN="$_n" GW_SURL="$(gw_subs_url "$_n")" GW_STYPE="$(gw_subs_type "$_n")" \
           yq -n -o=json -I0 '{"name": strenv(GW_SN), "url": strenv(GW_SURL), "type": strenv(GW_STYPE), "status": "pending", "nodes": 0, "sha256": "", "updated_at": "", "error": ""}' 2>/dev/null || printf '{}') ;;
    esac
    _items="$_items$_obj,"
  done
  _items=${_items%,}
  _active_json=$(GW_V="$_active" yq -n -o=json -I0 'strenv(GW_V)' 2>/dev/null || printf '""')
  GW_ITEMS="[$_items]" GW_ACTIVE="$_active_json" GW_TOTAL="$_total" \
    yq -n -o=json -I0 '{"active": (strenv(GW_ACTIVE) | from_json), "total": (strenv(GW_TOTAL) | tonumber), "items": (strenv(GW_ITEMS) | from_json)}'
}

cmd_bootstrap() { # 启动引导：补齐缺失订阅；无活跃订阅时激活第一个可用订阅
  _has=0
  for _n in $(gw_subs_names); do
    _has=1
    if [ ! -f "$GW_PROFILES_DIR/$_n.yaml" ]; then
      gw_log "首次拉取订阅：$_n"
      cmd_fetch "$_n" || true
    fi
  done
  [ "$_has" = "1" ] || return 0

  _active=$(gw_state_get active)
  if [ -z "$_active" ] || [ ! -f "$GW_PROFILES_DIR/$_active.yaml" ]; then
    for _n in $(gw_subs_names); do
      if [ -f "$GW_PROFILES_DIR/$_n.yaml" ]; then
        sh "$GW_APP_DIR/switch.sh" "$_n" || true
        break
      fi
    done
  fi

  if [ "${SUB_UPDATE_ON_BOOT:-0}" = "1" ]; then
    cmd_update all || true
  fi
}

case "${1:-}" in
  list)      cmd_list ;;
  json)      cmd_json ;;
  fetch)     shift; cmd_fetch "$@" ;;
  update)    shift; cmd_update "$@" ;;
  add)       shift; cmd_add "$@" ;;
  del)       shift; cmd_del "$@" ;;
  bootstrap) cmd_bootstrap ;;
  type)      shift; gw_profile_type "$@" ;;
  names)     gw_subs_names ;;
  *) echo "用法: subs.sh list|json|fetch|update|add|del|bootstrap|type|names" >&2; exit 2 ;;
esac
