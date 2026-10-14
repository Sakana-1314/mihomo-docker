#!/bin/sh
# =============================================================================
# 米哈游 API 加速网关 · 透明代理网络规则
#
#   tproxy：TCP + UDP 全量透明（推荐，保留客户端源地址）
#   redir ：TCP 透明（REDIRECT），UDP 不代理（仅 DNS 可劫持）
#   off   ：不做透明代理，仅提供常规端口服务
#
# IPv4 完整支持；IPv6 支持 block（默认，阻断转发避免绕过）/ proxy / pass
# =============================================================================
GW_APP_DIR="${GW_APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=lib.sh
. "$GW_APP_DIR/lib.sh"
gw_load_env

MARK=0x1
TABLE=100
CH_TPROXY=GW_TPROXY
CH_REDIR=GW_REDIR
CH_DNS=GW_DNS
CH_V6BLOCK=GW_V6BLOCK

# 固定放行项：保证网关自身、链路层与本机通信永不被劫持
FIXED_V4="0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 224.0.0.0/4 240.0.0.0/4 255.255.255.255/32"
FIXED_V6="::/128 ::1/128 fe80::/10 ff00::/8"

IPT4=iptables
IPT6=ip6tables

select_tools() {
  if [ "${FW_BACKEND:-legacy}" = "legacy" ] && gw_have iptables-legacy; then
    IPT4=iptables-legacy
  else
    IPT4=iptables
  fi
  if [ "${FW_BACKEND:-legacy}" = "legacy" ] && gw_have ip6tables-legacy; then
    IPT6=ip6tables-legacy
  else
    IPT6=ip6tables
  fi
  gw_have "$IPT4" || gw_die "缺少 iptables（$IPT4）"
  gw_have "$IPT6" || gw_warn "缺少 ip6tables（$IPT6），IPv6 规则将跳过"
}

iface_list() { printf '%s' "${GATEWAY_IF:-}" | tr ',' ' '; }

gw_if_ipv4() { # $1=接口 → 首个全局 IPv4（无则空）
  ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

gw_if_ipv6() {
  ip -6 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

sysctl_try() {
  if ! sysctl -w "$1=$2" >/dev/null 2>&1; then
    gw_warn "无法设置内核参数 $1=$2（/proc/sys 只读？建议在 compose 的 sysctls 中声明）"
    return 1
  fi
  return 0
}

fw_table_of() {
  case "$1" in
    "$CH_TPROXY")  printf 'mangle' ;;
    "$CH_V6BLOCK") printf 'filter' ;;
    *)             printf 'nat' ;;
  esac
}

fw_hook_of() {
  case "$1" in
    "$CH_V6BLOCK") printf 'FORWARD' ;;
    *)             printf 'PREROUTING' ;;
  esac
}

fw_rule_add() { # $1=ipt 命令 $2=表 $3=链，其余为规则
  _ipt="$1"; _t="$2"; _c="$3"
  shift 3
  "$_ipt" -w 5 -t "$_t" -A "$_c" "$@" || gw_warn "$_ipt 规则添加失败：-t $_t -A $_c $*"
}

fw_chain_init() { # 建链（先尝试清空旧链，再新建）
  _ipt="$1"; _t="$2"; _c="$3"
  "$_ipt" -w 5 -t "$_t" -F "$_c" >/dev/null 2>&1
  "$_ipt" -w 5 -t "$_t" -N "$_c" >/dev/null 2>&1
  "$_ipt" -w 5 -t "$_t" -F "$_c" >/dev/null 2>&1
}

fw_jump_add() { # $1=ipt 命令 $2=表 $3=hook $4=链 [$5=接口]
  _ipt="$1"; _t="$2"; _h="$3"; _c="$4"; _if="${5:-}"
  if [ -n "$_if" ]; then
    "$_ipt" -w 5 -t "$_t" -C "$_h" -i "$_if" -j "$_c" >/dev/null 2>&1 && return 0
    "$_ipt" -w 5 -t "$_t" -I "$_h" 1 -i "$_if" -j "$_c" >/dev/null 2>&1 || gw_warn "链挂载失败：$_t/$_h -i $_if -j $_c"
  else
    "$_ipt" -w 5 -t "$_t" -C "$_h" -j "$_c" >/dev/null 2>&1 && return 0
    "$_ipt" -w 5 -t "$_t" -I "$_h" 1 -j "$_c" >/dev/null 2>&1 || gw_warn "链挂载失败：$_t/$_h -j $_c"
  fi
}

fw_bypass_list() { # 输出全部放行网段（固定项 + 用户项）
  printf '%s %s\n' "$1" "$(printf '%s' "${BYPASS_CIDRS:-}" | tr ',' ' ')"
}

# ---------------------------------------------------------------- 清理
fw_cleanup_one() { # $1=ipt 命令
  _ipt="$1"
  for _ch in $CH_TPROXY $CH_REDIR $CH_DNS $CH_V6BLOCK; do
    _t=$(fw_table_of "$_ch")
    _h=$(fw_hook_of "$_ch")
    while "$_ipt" -w 5 -t "$_t" -C "$_h" -j "$_ch" >/dev/null 2>&1; do
      "$_ipt" -w 5 -t "$_t" -D "$_h" -j "$_ch" >/dev/null 2>&1
    done
    for _if in $(iface_list); do
      while "$_ipt" -w 5 -t "$_t" -C "$_h" -i "$_if" -j "$_ch" >/dev/null 2>&1; do
        "$_ipt" -w 5 -t "$_t" -D "$_h" -i "$_if" -j "$_ch" >/dev/null 2>&1
      done
    done
    "$_ipt" -w 5 -t "$_t" -F "$_ch" >/dev/null 2>&1
    "$_ipt" -w 5 -t "$_t" -X "$_ch" >/dev/null 2>&1
  done
  return 0
}

ip_rule_del() { # $1=地址族 4|6
  _i=0
  while ip -"$1" rule show 2>/dev/null | grep -q "fwmark $MARK lookup $TABLE"; do
    _i=$((_i + 1))
    [ "$_i" -le 20 ] || break
    ip -"$1" rule del fwmark "$MARK" table "$TABLE" >/dev/null 2>&1 || break
  done
  ip -"$1" route flush table "$TABLE" >/dev/null 2>&1
}

cmd_cleanup() {
  select_tools
  fw_cleanup_one "$IPT4"
  [ -n "$IPT6" ] && gw_have "$IPT6" && fw_cleanup_one "$IPT6"
  ip_rule_del 4
  gw_have ip && ip_rule_del 6
  return 0
}

# ---------------------------------------------------------------- 策略路由
ip_rule_ensure() { # $1=地址族
  if ! ip -"$1" rule show 2>/dev/null | grep -q "fwmark $MARK lookup $TABLE"; then
    ip -"$1" rule add fwmark "$MARK" table "$TABLE" || gw_warn "策略路由规则添加失败（$MARK → $TABLE，IPv$1）"
  fi
}

# ---------------------------------------------------------------- IPv4
fw_setup_v4() {
  _ipt="$IPT4"
  fw_chain_init "$_ipt" mangle "$CH_TPROXY"
  fw_chain_init "$_ipt" nat "$CH_REDIR"
  [ "${DNS_HIJACK:-1}" = "1" ] && fw_chain_init "$_ipt" nat "$CH_DNS"

  for _if in $(iface_list); do
    _gwip=$(gw_if_ipv4 "$_if")
    if [ -z "$_gwip" ]; then
      gw_warn "接口 $_if 未发现全局 IPv4 地址，跳过该接口"
      continue
    fi

    if [ "$TRANSPARENT_MODE" = "tproxy" ]; then
      fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -d "$_gwip/32" -j RETURN
      for _c in $(fw_bypass_list "$FIXED_V4"); do
        fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -d "$_c" -j RETURN
      done
      if [ "${DNS_HIJACK:-1}" = "1" ]; then
        fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p udp --dport "$DNS_PORT" -j RETURN
        fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p tcp --dport "$DNS_PORT" -j RETURN
      fi
      fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p tcp \
        -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK/$MARK"
      fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p udp \
        -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK/$MARK"
    elif [ "$TRANSPARENT_MODE" = "redir" ]; then
      fw_rule_add "$_ipt" nat "$CH_REDIR" -i "$_if" -d "$_gwip/32" -j RETURN
      for _c in $(fw_bypass_list "$FIXED_V4"); do
        fw_rule_add "$_ipt" nat "$CH_REDIR" -i "$_if" -d "$_c" -j RETURN
      done
      fw_rule_add "$_ipt" nat "$CH_REDIR" -i "$_if" -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
    fi

    if [ "${DNS_HIJACK:-1}" = "1" ]; then
      fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -d "$_gwip/32" -j RETURN
      for _c in $(fw_bypass_list "$FIXED_V4"); do
        fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -d "$_c" -j RETURN
      done
      fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -p udp --dport "$DNS_PORT" -j REDIRECT --to-ports "$DNS_PORT"
      fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -p tcp --dport "$DNS_PORT" -j REDIRECT --to-ports "$DNS_PORT"
    fi
  done

  # 挂载顺序：先挂 REDIR/TPROXY，再挂 DNS（后挂的位于 PREROUTING 链首，优先匹配 DNS）
  if [ "$TRANSPARENT_MODE" = "tproxy" ]; then
    fw_jump_add "$_ipt" mangle PREROUTING "$CH_TPROXY"
    ip_rule_ensure 4
    ip -4 route replace local default dev lo table "$TABLE" >/dev/null 2>&1 \
      || gw_warn "策略路由表 $TABLE 写入失败，TPROXY 可能无法工作"
  elif [ "$TRANSPARENT_MODE" = "redir" ]; then
    fw_jump_add "$_ipt" nat PREROUTING "$CH_REDIR"
  fi
  [ "${DNS_HIJACK:-1}" = "1" ] && fw_jump_add "$_ipt" nat PREROUTING "$CH_DNS"
  return 0
}

# ---------------------------------------------------------------- IPv6
fw_setup_v6_block() {
  _ipt="$IPT6"
  fw_chain_init "$_ipt" filter "$CH_V6BLOCK"
  fw_rule_add "$_ipt" filter "$CH_V6BLOCK" -j DROP
  for _if in $(iface_list); do
    [ -n "$(gw_if_ipv6 "$_if")" ] || continue
    fw_jump_add "$_ipt" filter FORWARD "$CH_V6BLOCK" "$_if"
  done
}

fw_setup_v6_proxy() {
  _ipt="$IPT6"
  fw_chain_init "$_ipt" mangle "$CH_TPROXY"
  [ "${DNS_HIJACK:-1}" = "1" ] && fw_chain_init "$_ipt" nat "$CH_DNS"

  for _if in $(iface_list); do
    _gwip6=$(gw_if_ipv6 "$_if")
    if [ -z "$_gwip6" ]; then
      gw_warn "接口 $_if 未发现全局 IPv6 地址，跳过 IPv6 透明代理"
      continue
    fi
    fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -d "$_gwip6/128" -j RETURN
    for _c in $(fw_bypass_list "$FIXED_V6"); do
      fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -d "$_c" -j RETURN
    done
    if [ "${DNS_HIJACK:-1}" = "1" ]; then
      fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p udp --dport "$DNS_PORT" -j RETURN
      fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p tcp --dport "$DNS_PORT" -j RETURN
    fi
    fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p tcp \
      -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK/$MARK"
    fw_rule_add "$_ipt" mangle "$CH_TPROXY" -i "$_if" -p udp \
      -j TPROXY --on-port "$TPROXY_PORT" --tproxy-mark "$MARK/$MARK"

    if [ "${DNS_HIJACK:-1}" = "1" ]; then
      fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -d "$_gwip6/128" -j RETURN
      for _c in $(fw_bypass_list "$FIXED_V6"); do
        fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -d "$_c" -j RETURN
      done
      fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -p udp --dport "$DNS_PORT" -j REDIRECT --to-ports "$DNS_PORT"
      fw_rule_add "$_ipt" nat "$CH_DNS" -i "$_if" -p tcp --dport "$DNS_PORT" -j REDIRECT --to-ports "$DNS_PORT"
    fi
  done

  fw_jump_add "$_ipt" mangle PREROUTING "$CH_TPROXY"
  [ "${DNS_HIJACK:-1}" = "1" ] && fw_jump_add "$_ipt" nat PREROUTING "$CH_DNS"
  ip_rule_ensure 6
  ip -6 route replace local default dev lo table "$TABLE" >/dev/null 2>&1 \
    || gw_warn "IPv6 策略路由写入失败"
  sysctl_try net.ipv6.conf.all.forwarding 1
}

fw_setup_v6() {
  gw_have "$IPT6" || return 0
  case "${IPV6_MODE:-block}" in
    pass)  gw_log "IPv6：直通（不代理、不阻断）" ;;
    block) fw_setup_v6_block; gw_log "IPv6：阻断转发（避免绕过透明代理）" ;;
    proxy) fw_setup_v6_proxy; gw_log "IPv6：透明代理（best-effort）" ;;
  esac
  return 0
}

# ---------------------------------------------------------------- 入口
cmd_setup() {
  select_tools

  if [ "${TRANSPARENT_MODE:-off}" = "off" ]; then
    gw_log "透明代理已关闭（TRANSPARENT_MODE=off），仅提供常规端口服务"
    cmd_cleanup
    return 0
  fi

  cmd_cleanup

  sysctl_try net.ipv4.ip_forward 1
  sysctl_try net.ipv4.conf.all.rp_filter 0
  sysctl_try net.ipv4.conf.default.rp_filter 0
  for _if in $(iface_list); do
    sysctl_try "net.ipv4.conf.$_if.rp_filter" 0
  done

  fw_setup_v4
  fw_setup_v6

  _fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || printf '?')
  if [ "$_fwd" != "1" ]; then
    gw_warn "net.ipv4.ip_forward=$_fwd，未被代理的转发流量可能中断；请在 compose 的 sysctls 中声明 net.ipv4.ip_forward=1"
  fi

  gw_log "透明代理规则已应用：模式=$TRANSPARENT_MODE 接口=$(iface_list) DNS劫持=$DNS_HIJACK IPv6=$IPV6_MODE 后备=$FW_BACKEND"
  return 0
}

cmd_status() { # 输出 on|off（供面板展示）
  select_tools
  _st=off
  if [ "${TRANSPARENT_MODE:-off}" != "off" ] && gw_have "$IPT4"; then
    case "$TRANSPARENT_MODE" in
      tproxy)
        "$IPT4" -w 5 -t mangle -C PREROUTING -j "$CH_TPROXY" >/dev/null 2>&1 && _st=on
        ;;
      redir)
        "$IPT4" -w 5 -t nat -C PREROUTING -j "$CH_REDIR" >/dev/null 2>&1 && _st=on
        ;;
    esac
  fi
  printf '%s' "$_st"
}

case "${1:-setup}" in
  setup)   cmd_setup ;;
  cleanup) cmd_cleanup && gw_log "透明代理规则已清理" ;;
  status)  cmd_status ;;
  *) echo "用法: firewall.sh setup|cleanup|status" >&2; exit 2 ;;
esac
