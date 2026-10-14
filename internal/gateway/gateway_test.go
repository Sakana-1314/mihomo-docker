package gateway

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/Sakana-1314/mihomo-docker/internal/settings"
)

const testProfileFull = `proxies:
  - {name: n1, type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: p}
proxy-groups:
  - name: G1
    type: select
    proxies: [n1, DIRECT]
rules:
  - MATCH,G1
`

const testProfileNodes = `proxies:
  - {name: n1, type: ss, server: 127.0.0.1, port: 1, cipher: aes-128-gcm, password: p}
  - {name: n2, type: ss, server: 127.0.0.1, port: 2, cipher: aes-128-gcm, password: p}
`

func newTestGateway(t *testing.T) *Gateway {
	t.Helper()
	dir := t.TempDir()
	s, err := settings.Load(dir)
	if err != nil {
		t.Fatalf("settings.Load：%v", err)
	}
	g := New(s, Assets{
		Template:      []byte("proxy-groups:\n  - {name: G, type: select, proxies: [DIRECT]}\nrules:\n  - MATCH,G\n"),
		Overlay:       []byte("mode: rule\nlog-level: info\n"),
		Subscriptions: []byte("subscriptions: []\n"),
	})
	if err := g.ensureUserConfig(); err != nil {
		t.Fatalf("ensureUserConfig：%v", err)
	}
	return g
}

func TestDeepMergeSemantics(t *testing.T) {
	base := map[string]any{"a": 1, "nested": map[string]any{"x": 1, "y": 2}, "rules": []any{"r1", "r2"}}
	over := map[string]any{"nested": map[string]any{"y": 9, "z": 3}, "rules": []any{"only"}}
	got := deepMerge(base, over)

	if got["a"] != 1 {
		t.Fatalf("标量应保留：%v", got["a"])
	}
	nested, _ := got["nested"].(map[string]any)
	if nested["x"] != 1 || nested["y"] != 9 || nested["z"] != 3 {
		t.Fatalf("对象应递归合并：%v", nested)
	}
	rules, _ := got["rules"].([]any)
	if len(rules) != 1 || rules[0] != "only" {
		t.Fatalf("数组应整体替换：%v", rules)
	}
}

func TestComposeInjectsRuntime(t *testing.T) {
	g := newTestGateway(t)
	body, err := g.composeBaseline()
	if err != nil {
		t.Fatalf("composeBaseline：%v", err)
	}
	doc, err := decodeMap(body)
	if err != nil {
		t.Fatalf("解析合成结果：%v", err)
	}
	if doc["tproxy-port"] != g.s.TProxyPort {
		t.Fatalf("应注入 tproxy 端口：%v", doc["tproxy-port"])
	}
	if doc["redir-port"] != g.s.RedirPort || doc["mixed-port"] != g.s.MixedPort {
		t.Fatalf("应注入端口：%v / %v", doc["redir-port"], doc["mixed-port"])
	}
	if doc["secret"] != g.s.Secret {
		t.Fatalf("应注入密钥：%v", doc["secret"])
	}
	cors, _ := doc["external-controller-cors"].(map[string]any)
	if cors == nil || cors["allow-private-network"] != true {
		t.Fatalf("应注入 CORS 配置：%v", doc["external-controller-cors"])
	}
	dns, _ := doc["dns"].(map[string]any)
	if dns["listen"] == nil {
		t.Fatalf("应注入 DNS 监听：%v", doc["dns"])
	}
	if doc["log-level"] != "info" {
		t.Fatalf("未显式设置 LOG_LEVEL 时应由覆盖层决定日志级别：%v", doc["log-level"])
	}
}

func TestComposeProfileKeepsSubscriptionRules(t *testing.T) {
	g := newTestGateway(t)
	if err := os.WriteFile(g.profilePath("full"), []byte(testProfileFull), 0o644); err != nil {
		t.Fatal(err)
	}
	body, err := g.composeProfile("full")
	if err != nil {
		t.Fatalf("composeProfile：%v", err)
	}
	doc, _ := decodeMap(body)
	if doc["proxy-groups"] == nil || doc["rules"] == nil {
		t.Fatalf("完整订阅的策略组与规则应保留")
	}
	if doc["tproxy-port"] != g.s.TProxyPort {
		t.Fatalf("完整订阅同样应注入运行期参数")
	}
}

func TestProfileTypeDetection(t *testing.T) {
	g := newTestGateway(t)
	if err := os.WriteFile(g.profilePath("full"), []byte(testProfileFull), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(g.profilePath("nodes"), []byte(testProfileNodes), 0o644); err != nil {
		t.Fatal(err)
	}
	if typ, _ := g.profileType("full"); typ != "profile" {
		t.Fatalf("应识别为完整订阅，实际 %s", typ)
	}
	if typ, _ := g.profileType("nodes"); typ != "proxies" {
		t.Fatalf("应识别为仅节点订阅，实际 %s", typ)
	}
	if _, err := g.profileType("missing"); err == nil {
		t.Fatalf("不存在的订阅应报错")
	}
}

func TestProviderWriteAndClear(t *testing.T) {
	g := newTestGateway(t)
	if err := os.WriteFile(g.profilePath("nodes"), []byte(testProfileNodes), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := g.writeProvider("nodes"); err != nil {
		t.Fatalf("writeProvider：%v", err)
	}
	provider := filepath.Join(g.s.Providers, "active.yaml")
	body, err := os.ReadFile(provider)
	if err != nil {
		t.Fatal(err)
	}
	doc, _ := decodeMap(body)
	proxies, _ := doc["proxies"].([]any)
	if len(proxies) != 2 {
		t.Fatalf("节点提供者应含 2 个节点：%v", doc)
	}
	if err := g.clearProvider(); err != nil {
		t.Fatalf("clearProvider：%v", err)
	}
	body, _ = os.ReadFile(provider)
	doc, _ = decodeMap(body)
	proxies, _ = doc["proxies"].([]any)
	if len(proxies) != 0 {
		t.Fatalf("清空后不应含节点：%v", doc)
	}
}

func TestSubsViewAndStates(t *testing.T) {
	g := newTestGateway(t)
	if err := g.AddSub("s1", "http://127.0.0.1:1/s.yaml", "auto"); err == nil {
		t.Fatalf("不可达地址应返回错误")
	}
	// 拉取失败也应记录状态，便于面板展示
	view := g.Subs()
	if view.Total != 1 {
		t.Fatalf("订阅数量应为 1：%+v", view)
	}
	if view.Items[0].Status != "error" {
		t.Fatalf("失败订阅应标记为 error：%+v", view.Items[0])
	}
	if !ValidSubName("ok-1.a_b") || ValidSubName("bad name") || ValidSubName("../x") {
		t.Fatalf("订阅名校验不正确")
	}
	if err := g.DelSub("s1"); err != nil {
		t.Fatalf("DelSub：%v", err)
	}
	if g.Subs().Total != 0 {
		t.Fatalf("删除后应为空")
	}
}

func TestRuntimeLogLevelInjection(t *testing.T) {
	g := newTestGateway(t)
	g.s.LogLevel = "debug"
	g.s.LogLevelInject = true
	body, err := g.composeBaseline()
	if err != nil {
		t.Fatal(err)
	}
	doc, _ := decodeMap(body)
	if doc["log-level"] != "debug" {
		t.Fatalf("显式设置时应注入日志级别：%v", doc["log-level"])
	}
}
