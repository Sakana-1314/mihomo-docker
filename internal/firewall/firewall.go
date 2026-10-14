// Package firewall 负责透明代理所需的网络规则（iptables + 策略路由）。
// 规则生成与执行分离，便于在不具备网络权限的环境下对规则本身做单元测试。
package firewall

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/Sakana-1314/mihomo-docker/internal/out"
)

const (
	mark       = "0x1"
	table      = "100"
	chTProxy   = "GW_TPROXY"
	chRedir    = "GW_REDIR"
	chDNS      = "GW_DNS"
	chV6Block  = "GW_V6BLOCK"
	iptWaitSec = "5"
)

// 固定放行项：保证网关自身、链路层与本机通信不被劫持。
var fixedV4 = []string{"0.0.0.0/8", "127.0.0.0/8", "169.254.0.0/16", "224.0.0.0/4", "240.0.0.0/4", "255.255.255.255/32"}
var fixedV6 = []string{"::/128", "::1/128", "fe80::/10", "ff00::/8"}

// Config 是透明代理规则的输入参数。
type Config struct {
	Mode        string // tproxy|redir|off
	IPv6Mode    string // block|proxy|pass
	Backend     string // legacy|nft
	Ifaces      []string
	BypassCIDRs []string
	DNSHijack   bool
	TProxyPort  int
	RedirPort   int
	DNSPort     int
}

// Rule 是一条待下发的规则（表 + 链 + 匹配/动作参数）。
type Rule struct {
	Table string
	Chain string
	Args  []string
}

// Manager 管理透明代理规则的建立与清理。
type Manager struct {
	cfg    Config
	ipt4   string
	ipt6   string
	ifaces []string
	gwIP4  map[string]string
	gwIP6  map[string]string
}

// New 构造规则管理器。
func New(cfg Config) *Manager { return &Manager{cfg: cfg} }

// ResolvedIfaces 返回实际生效的接口列表（Setup 之后可用）。
func (m *Manager) ResolvedIfaces() []string { return m.ifaces }

// ---------------------------------------------------------------- 外部命令

func run(bin string, args ...string) error {
	cmd := exec.Command(bin, args...)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %s：%v（%s）", bin, strings.Join(args, " "), err, strings.TrimSpace(string(output)))
	}
	return nil
}

func capture(bin string, args ...string) (string, error) {
	output, err := exec.Command(bin, args...).Output()
	if err != nil {
		return "", err
	}
	return string(output), nil
}

func lookPath(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

func (m *Manager) selectTools() error {
	if m.cfg.Backend == "legacy" && lookPath("iptables-legacy") {
		m.ipt4 = "iptables-legacy"
	} else {
		m.ipt4 = "iptables"
	}
	if m.cfg.Backend == "legacy" && lookPath("ip6tables-legacy") {
		m.ipt6 = "ip6tables-legacy"
	} else {
		m.ipt6 = "ip6tables"
	}
	if !lookPath(m.ipt4) {
		return fmt.Errorf("缺少 iptables（%s）", m.ipt4)
	}
	if !lookPath(m.ipt6) {
		out.Warnf("缺少 ip6tables（%s），IPv6 规则将跳过", m.ipt6)
		m.ipt6 = ""
	}
	return nil
}

func setSysctl(key, value string) error {
	path := "/proc/sys/" + strings.ReplaceAll(key, ".", "/")
	if err := os.WriteFile(path, []byte(value+"\n"), 0o644); err == nil {
		return nil
	}
	if lookPath("sysctl") {
		return run("sysctl", "-w", key+"="+value)
	}
	return fmt.Errorf("无法设置 %s=%s", key, value)
}

func (m *Manager) sysctl(key, value string) {
	if err := setSysctl(key, value); err != nil {
		out.Warnf("无法设置内核参数 %s=%s（/proc/sys 只读？建议在 compose 的 sysctls 中声明）", key, value)
	}
}

// ---------------------------------------------------------------- 接口识别

func (m *Manager) resolveIfaces() []string {
	if len(m.cfg.Ifaces) > 0 {
		return m.cfg.Ifaces
	}
	if text, err := capture("ip", "route", "show", "default"); err == nil {
		fields := strings.Fields(text)
		for i, f := range fields {
			if f == "dev" && i+1 < len(fields) {
				return []string{fields[i+1]}
			}
		}
	}
	if text, err := capture("ip", "-o", "link", "show", "up"); err == nil {
		for _, line := range strings.Split(text, "\n") {
			parts := strings.SplitN(line, ": ", 3)
			if len(parts) < 2 {
				continue
			}
			name := strings.TrimSpace(parts[1])
			if name != "" && name != "lo" {
				return []string{name}
			}
		}
	}
	return nil
}

func ifaceAddr(iface string, family string) string {
	text, err := capture("ip", "-"+family, "-o", "addr", "show", "dev", iface, "scope", "global")
	if err != nil {
		return ""
	}
	key := "inet"
	if family == "6" {
		key = "inet6"
	}
	fields := strings.Fields(text)
	for i, f := range fields {
		if f == key && i+1 < len(fields) {
			return strings.SplitN(fields[i+1], "/", 2)[0]
		}
	}
	return ""
}

// ---------------------------------------------------------------- 规则生成

func chainTable(chain string) string {
	if chain == chTProxy {
		return "mangle"
	}
	if chain == chV6Block {
		return "filter"
	}
	return "nat"
}

func chainHook(chain string) string {
	if chain == chV6Block {
		return "FORWARD"
	}
	return "PREROUTING"
}

func (m *Manager) bypassList(fixed []string) []string {
	list := append([]string{}, fixed...)
	list = append(list, m.cfg.BypassCIDRs...)
	return list
}

// V4Rules 生成 IPv4 规则（不含挂载跳转与策略路由）。
func (m *Manager) V4Rules(gwIPs map[string]string) []Rule {
	var rules []Rule
	for _, iface := range m.ifaces {
		gwIP := gwIPs[iface]
		if gwIP == "" {
			out.Warnf("接口 %s 未发现全局 IPv4 地址，跳过该接口", iface)
			continue
		}
		switch m.cfg.Mode {
		case "tproxy":
			rules = append(rules, Rule{"mangle", chTProxy, []string{"-i", iface, "-d", gwIP + "/32", "-j", "RETURN"}})
			for _, cidr := range m.bypassList(fixedV4) {
				rules = append(rules, Rule{"mangle", chTProxy, []string{"-i", iface, "-d", cidr, "-j", "RETURN"}})
			}
			if m.cfg.DNSHijack {
				rules = append(rules,
					Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "udp", "--dport", itoa(m.cfg.DNSPort), "-j", "RETURN"}},
					Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "tcp", "--dport", itoa(m.cfg.DNSPort), "-j", "RETURN"}},
				)
			}
			rules = append(rules,
				Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "tcp", "-j", "TPROXY", "--on-port", itoa(m.cfg.TProxyPort), "--tproxy-mark", mark + "/" + mark}},
				Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "udp", "-j", "TPROXY", "--on-port", itoa(m.cfg.TProxyPort), "--tproxy-mark", mark + "/" + mark}},
			)
		case "redir":
			rules = append(rules, Rule{"nat", chRedir, []string{"-i", iface, "-d", gwIP + "/32", "-j", "RETURN"}})
			for _, cidr := range m.bypassList(fixedV4) {
				rules = append(rules, Rule{"nat", chRedir, []string{"-i", iface, "-d", cidr, "-j", "RETURN"}})
			}
			rules = append(rules, Rule{"nat", chRedir, []string{"-i", iface, "-p", "tcp", "-j", "REDIRECT", "--to-ports", itoa(m.cfg.RedirPort)}})
		}
		if m.cfg.DNSHijack {
			rules = append(rules, Rule{"nat", chDNS, []string{"-i", iface, "-d", gwIP + "/32", "-j", "RETURN"}})
			for _, cidr := range m.bypassList(fixedV4) {
				rules = append(rules, Rule{"nat", chDNS, []string{"-i", iface, "-d", cidr, "-j", "RETURN"}})
			}
			rules = append(rules,
				Rule{"nat", chDNS, []string{"-i", iface, "-p", "udp", "--dport", itoa(m.cfg.DNSPort), "-j", "REDIRECT", "--to-ports", itoa(m.cfg.DNSPort)}},
				Rule{"nat", chDNS, []string{"-i", iface, "-p", "tcp", "--dport", itoa(m.cfg.DNSPort), "-j", "REDIRECT", "--to-ports", itoa(m.cfg.DNSPort)}},
			)
		}
	}
	return rules
}

// V6Rules 生成 IPv6 规则（block 模式仅阻断转发；proxy 模式与 IPv4 类似）。
func (m *Manager) V6Rules(gwIPs map[string]string) []Rule {
	var rules []Rule
	switch m.cfg.IPv6Mode {
	case "block":
		rules = append(rules, Rule{"filter", chV6Block, []string{"-j", "DROP"}})
	case "proxy":
		for _, iface := range m.ifaces {
			gwIP := gwIPs[iface]
			if gwIP == "" {
				out.Warnf("接口 %s 未发现全局 IPv6 地址，跳过 IPv6 透明代理", iface)
				continue
			}
			rules = append(rules, Rule{"mangle", chTProxy, []string{"-i", iface, "-d", gwIP + "/128", "-j", "RETURN"}})
			for _, cidr := range m.bypassList(fixedV6) {
				rules = append(rules, Rule{"mangle", chTProxy, []string{"-i", iface, "-d", cidr, "-j", "RETURN"}})
			}
			if m.cfg.DNSHijack {
				rules = append(rules,
					Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "udp", "--dport", itoa(m.cfg.DNSPort), "-j", "RETURN"}},
					Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "tcp", "--dport", itoa(m.cfg.DNSPort), "-j", "RETURN"}},
				)
			}
			rules = append(rules,
				Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "tcp", "-j", "TPROXY", "--on-port", itoa(m.cfg.TProxyPort), "--tproxy-mark", mark + "/" + mark}},
				Rule{"mangle", chTProxy, []string{"-i", iface, "-p", "udp", "-j", "TPROXY", "--on-port", itoa(m.cfg.TProxyPort), "--tproxy-mark", mark + "/" + mark}},
			)
			if m.cfg.DNSHijack {
				for _, cidr := range m.bypassList(fixedV6) {
					rules = append(rules, Rule{"nat", chDNS, []string{"-i", iface, "-d", cidr, "-j", "RETURN"}})
				}
				rules = append(rules,
					Rule{"nat", chDNS, []string{"-i", iface, "-p", "udp", "--dport", itoa(m.cfg.DNSPort), "-j", "REDIRECT", "--to-ports", itoa(m.cfg.DNSPort)}},
					Rule{"nat", chDNS, []string{"-i", iface, "-p", "tcp", "--dport", itoa(m.cfg.DNSPort), "-j", "REDIRECT", "--to-ports", itoa(m.cfg.DNSPort)}},
				)
			}
		}
	}
	return rules
}

func itoa(v int) string { return fmt.Sprintf("%d", v) }

// ---------------------------------------------------------------- 规则下发

func (m *Manager) chainInit(bin, tableName, chain string) {
	_ = run(bin, "-w", iptWaitSec, "-t", tableName, "-F", chain)
	_ = run(bin, "-w", iptWaitSec, "-t", tableName, "-N", chain)
	_ = run(bin, "-w", iptWaitSec, "-t", tableName, "-F", chain)
}

func (m *Manager) applyRules(bin string, rules []Rule) {
	for _, r := range rules {
		args := append([]string{"-w", iptWaitSec, "-t", r.Table, "-A", r.Chain}, r.Args...)
		if err := run(bin, args...); err != nil {
			out.Warnf("规则下发失败：%v", err)
		}
	}
}

func (m *Manager) jumpAdd(bin, tableName, hook, chain, iface string) {
	base := []string{"-w", iptWaitSec, "-t", tableName, "-C", hook}
	if iface != "" {
		base = append(base, "-i", iface)
	}
	base = append(base, "-j", chain)
	if err := run(bin, base...); err == nil {
		return
	}
	insert := []string{"-w", iptWaitSec, "-t", tableName, "-I", hook, "1"}
	if iface != "" {
		insert = append(insert, "-i", iface)
	}
	insert = append(insert, "-j", chain)
	if err := run(bin, insert...); err != nil {
		out.Warnf("链挂载失败：%s %s/%s -j %s（%v）", bin, tableName, hook, chain, err)
	}
}

func (m *Manager) cleanupOne(bin string) {
	for _, chain := range []string{chTProxy, chRedir, chDNS, chV6Block} {
		tableName, hook := chainTable(chain), chainHook(chain)
		for i := 0; i < 20; i++ {
			args := []string{"-w", iptWaitSec, "-t", tableName, "-C", hook, "-j", chain}
			if err := run(bin, args...); err != nil {
				break
			}
			_ = run(bin, append([]string{"-w", iptWaitSec, "-t", tableName, "-D", hook}, "-j", chain)...)
		}
		for _, iface := range m.ifaces {
			for i := 0; i < 20; i++ {
				args := []string{"-w", iptWaitSec, "-t", tableName, "-C", hook, "-i", iface, "-j", chain}
				if err := run(bin, args...); err != nil {
					break
				}
				_ = run(bin, append([]string{"-w", iptWaitSec, "-t", tableName, "-D", hook}, "-i", iface, "-j", chain)...)
			}
		}
		_ = run(bin, "-w", iptWaitSec, "-t", tableName, "-F", chain)
		_ = run(bin, "-w", iptWaitSec, "-t", tableName, "-X", chain)
	}
}

func (m *Manager) clearPolicyRouting() {
	for _, family := range []string{"4", "6"} {
		for i := 0; i < 20; i++ {
			text, err := capture("ip", "-"+family, "rule", "show")
			if err != nil || !strings.Contains(text, "fwmark "+mark+" lookup "+table) {
				break
			}
			if err := run("ip", "-"+family, "rule", "del", "fwmark", mark, "table", table); err != nil {
				break
			}
		}
		_ = run("ip", "-"+family, "route", "flush", "table", table)
	}
}

func (m *Manager) ensurePolicyRouting(family string) {
	text, err := capture("ip", "-"+family, "rule", "show")
	if err != nil {
		out.Warnf("读取策略路由失败（IPv%s）：%v", family, err)
		return
	}
	if !strings.Contains(text, "fwmark "+mark+" lookup "+table) {
		if err := run("ip", "-"+family, "rule", "add", "fwmark", mark, "table", table); err != nil {
			out.Warnf("策略路由规则添加失败（IPv%s）：%v", family, err)
		}
	}
	if err := run("ip", "-"+family, "route", "replace", "local", "default", "dev", "lo", "table", table); err != nil {
		out.Warnf("策略路由表写入失败（IPv%s）：%v", family, err)
	}
}

// Cleanup 清理全部自建规则（幂等）。
func (m *Manager) Cleanup() {
	if m.ipt4 == "" {
		m.ipt4 = "iptables"
	}
	m.ifaces = m.resolveIfaces()
	if lookPath(m.ipt4) {
		m.cleanupOne(m.ipt4)
	}
	if m.ipt6 == "" {
		m.ipt6 = "ip6tables"
	}
	if lookPath(m.ipt6) {
		m.cleanupOne(m.ipt6)
	}
	m.clearPolicyRouting()
}

// Setup 下发透明代理规则；返回致命错误（如缺少 iptables）时由调用方决定降级。
func (m *Manager) Setup() error {
	m.ifaces = m.resolveIfaces()

	if m.cfg.Mode == "off" {
		m.Cleanup()
		out.Logf("透明代理已关闭（TRANSPARENT_MODE=off），仅提供常规端口服务")
		return nil
	}

	if err := m.selectTools(); err != nil {
		return err
	}
	if len(m.ifaces) == 0 {
		out.Warnf("未能识别网关接口，透明代理规则可能无法生效（可通过 GATEWAY_IF 显式指定）")
	}

	m.Cleanup()

	m.sysctl("net.ipv4.ip_forward", "1")
	m.sysctl("net.ipv4.conf.all.rp_filter", "0")
	m.sysctl("net.ipv4.conf.default.rp_filter", "0")
	for _, iface := range m.ifaces {
		m.sysctl("net.ipv4.conf."+iface+".rp_filter", "0")
	}

	m.gwIP4 = map[string]string{}
	for _, iface := range m.ifaces {
		m.gwIP4[iface] = ifaceAddr(iface, "4")
	}
	m.gwIP6 = map[string]string{}
	for _, iface := range m.ifaces {
		m.gwIP6[iface] = ifaceAddr(iface, "6")
	}

	// IPv4：建链 → 规则 → 挂载 → 策略路由
	chains4 := []string{chTProxy}
	if m.cfg.Mode == "redir" {
		chains4 = append(chains4, chRedir)
	}
	if m.cfg.DNSHijack {
		chains4 = append(chains4, chDNS)
	}
	for _, chain := range chains4 {
		if chain == chRedir && m.cfg.Mode != "redir" {
			continue
		}
		m.chainInit(m.ipt4, chainTable(chain), chain)
	}
	m.applyRules(m.ipt4, m.V4Rules(m.gwIP4))
	switch m.cfg.Mode {
	case "tproxy":
		m.jumpAdd(m.ipt4, "mangle", "PREROUTING", chTProxy, "")
		m.ensurePolicyRouting("4")
	case "redir":
		m.jumpAdd(m.ipt4, "nat", "PREROUTING", chRedir, "")
	}
	if m.cfg.DNSHijack {
		m.jumpAdd(m.ipt4, "nat", "PREROUTING", chDNS, "")
	}

	// IPv6
	if m.ipt6 != "" {
		switch m.cfg.IPv6Mode {
		case "block":
			m.chainInit(m.ipt6, "filter", chV6Block)
			m.applyRules(m.ipt6, m.V6Rules(m.gwIP6))
			for _, iface := range m.ifaces {
				if m.gwIP6[iface] == "" {
					continue
				}
				m.jumpAdd(m.ipt6, "filter", "FORWARD", chV6Block, iface)
			}
			out.Logf("IPv6：阻断转发（避免绕过透明代理）")
		case "proxy":
			m.chainInit(m.ipt6, "mangle", chTProxy)
			if m.cfg.DNSHijack {
				m.chainInit(m.ipt6, "nat", chDNS)
			}
			m.applyRules(m.ipt6, m.V6Rules(m.gwIP6))
			m.jumpAdd(m.ipt6, "mangle", "PREROUTING", chTProxy, "")
			if m.cfg.DNSHijack {
				m.jumpAdd(m.ipt6, "nat", "PREROUTING", chDNS, "")
			}
			m.ensurePolicyRouting("6")
			m.sysctl("net.ipv6.conf.all.forwarding", "1")
			out.Logf("IPv6：透明代理（best-effort）")
		default:
			out.Logf("IPv6：直通（不代理、不阻断）")
		}
	}

	if data, err := os.ReadFile("/proc/sys/net/ipv4/ip_forward"); err == nil {
		if strings.TrimSpace(string(data)) != "1" {
			out.Warnf("net.ipv4.ip_forward 未开启，未被代理的转发流量可能中断；请在 compose 的 sysctls 中声明")
		}
	}
	return nil
}

// State 返回当前透明代理规则状态（on|off），供面板展示。
func (m *Manager) State() string {
	if m.cfg.Mode == "off" {
		return "off"
	}
	bin := m.ipt4
	if bin == "" {
		bin = "iptables"
	}
	if m.cfg.Backend == "legacy" && lookPath("iptables-legacy") {
		bin = "iptables-legacy"
	}
	if !lookPath(bin) {
		return "off"
	}
	var chain, tableName string
	switch m.cfg.Mode {
	case "tproxy":
		chain, tableName = chTProxy, "mangle"
	case "redir":
		chain, tableName = chRedir, "nat"
	default:
		return "off"
	}
	if err := run(bin, "-w", iptWaitSec, "-t", tableName, "-C", "PREROUTING", "-j", chain); err == nil {
		return "on"
	}
	return "off"
}
