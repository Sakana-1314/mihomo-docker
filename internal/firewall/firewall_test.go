package firewall

import (
	"strings"
	"testing"
)

func tproxyManager() *Manager {
	m := New(Config{
		Mode:        "tproxy",
		IPv6Mode:    "block",
		BypassCIDRs: []string{"10.0.0.0/8", "192.168.0.0/16"},
		DNSHijack:   true,
		TProxyPort:  7893,
		RedirPort:   7892,
		DNSPort:     53,
		Ifaces:      []string{"eth0"},
	})
	m.ifaces = []string{"eth0"}
	return m
}

func join(r Rule) string { return r.Table + " " + r.Chain + " " + strings.Join(r.Args, " ") }

func contains(rules []Rule, needle string) bool {
	for _, r := range rules {
		if strings.Contains(join(r), needle) {
			return true
		}
	}
	return false
}

func indexOf(rules []Rule, needle string) int {
	for i, r := range rules {
		if strings.Contains(join(r), needle) {
			return i
		}
	}
	return -1
}

func TestV4TProxyRules(t *testing.T) {
	m := tproxyManager()
	rules := m.V4Rules(map[string]string{"eth0": "192.168.1.250"})

	for _, want := range []string{
		"-d 192.168.1.250/32 -j RETURN",
		"-d 10.0.0.0/8 -j RETURN",
		"-d 127.0.0.0/8 -j RETURN",
		"-p tcp -j TPROXY --on-port 7893 --tproxy-mark 0x1/0x1",
		"-p udp -j TPROXY --on-port 7893 --tproxy-mark 0x1/0x1",
		"nat GW_DNS -i eth0 -p udp --dport 53 -j REDIRECT --to-ports 53",
	} {
		if !contains(rules, want) {
			t.Fatalf("缺少规则：%s\n实际：%v", want, rules)
		}
	}

	// DNS 需在 TPROXY 之前放行，否则会被透传端口抢先接管
	dnsReturn := indexOf(rules, "mangle GW_TPROXY -i eth0 -p udp --dport 53 -j RETURN")
	tproxyRule := indexOf(rules, "-j TPROXY --on-port 7893")
	if dnsReturn < 0 || tproxyRule < 0 || dnsReturn > tproxyRule {
		t.Fatalf("DNS 放行规则应位于 TPROXY 之前：dns=%d tproxy=%d", dnsReturn, tproxyRule)
	}
}

func TestV4RedirRules(t *testing.T) {
	m := tproxyManager()
	m.cfg.Mode = "redir"
	rules := m.V4Rules(map[string]string{"eth0": "192.168.1.250"})

	if !contains(rules, "nat GW_REDIR -i eth0 -p tcp -j REDIRECT --to-ports 7892") {
		t.Fatalf("redir 模式应下发 REDIRECT：%v", rules)
	}
	if contains(rules, "TPROXY") {
		t.Fatalf("redir 模式不应下发 TPROXY：%v", rules)
	}
}

func TestV6BlockRules(t *testing.T) {
	m := tproxyManager()
	rules := m.V6Rules(map[string]string{"eth0": "fd00::1"})
	if len(rules) != 1 || rules[0].Chain != chV6Block || rules[0].Table != "filter" {
		t.Fatalf("block 模式应仅阻断转发：%v", rules)
	}
	if !contains(rules, "-j DROP") {
		t.Fatalf("应下发 DROP：%v", rules)
	}
}

func TestV6ProxyRules(t *testing.T) {
	m := tproxyManager()
	m.cfg.IPv6Mode = "proxy"
	rules := m.V6Rules(map[string]string{"eth0": "fd00::1"})
	if !contains(rules, "mangle GW_TPROXY -i eth0 -p tcp -j TPROXY --on-port 7893 --tproxy-mark 0x1/0x1") {
		t.Fatalf("proxy 模式应下发 IPv6 TPROXY：%v", rules)
	}
	if !contains(rules, "-d fe80::/10 -j RETURN") {
		t.Fatalf("应放行链路本地地址：%v", rules)
	}
}

func TestChainMapping(t *testing.T) {
	cases := map[string]string{chTProxy: "mangle", chRedir: "nat", chDNS: "nat", chV6Block: "filter"}
	for chain, table := range cases {
		if got := chainTable(chain); got != table {
			t.Fatalf("%s 应属于 %s，实际 %s", chain, table, got)
		}
	}
	if chainHook(chV6Block) != "FORWARD" || chainHook(chTProxy) != "PREROUTING" {
		t.Fatalf("链挂载点不正确")
	}
}

func TestIfaceWithoutAddressSkipped(t *testing.T) {
	m := tproxyManager()
	rules := m.V4Rules(map[string]string{})
	if contains(rules, "TPROXY") {
		t.Fatalf("接口无地址时不应下发 TPROXY：%v", rules)
	}
}
