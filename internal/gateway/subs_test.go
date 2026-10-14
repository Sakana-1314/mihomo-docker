package gateway

import (
	"os"
	"testing"
)

const seededSubs = `subscriptions:
  - name: sub-a
    url: http://gw-smoke-sub-1234/sub-node-only.yaml
    type: proxies
  - name: sub-b
    url: http://gw-smoke-sub-1234/sub-full.yaml
    type: auto
`

// TestReadSeededSubscriptions 复现冒烟测试写入 /data/config/subscriptions.yaml 的形态。
func TestReadSeededSubscriptions(t *testing.T) {
	g := newTestGateway(t)
	if err := os.WriteFile(g.subsPath(), []byte(seededSubs), 0o644); err != nil {
		t.Fatal(err)
	}
	refs := g.subRefs()
	if len(refs) != 2 {
		t.Fatalf("应解析出 2 条订阅，实际 %d（%+v）", len(refs), refs)
	}
	if refs[0].Name != "sub-a" || refs[0].Type != "proxies" || refs[0].URL == "" {
		t.Fatalf("第 1 条解析不正确：%+v", refs[0])
	}
	if refs[1].Name != "sub-b" || refs[1].Type != "auto" {
		t.Fatalf("第 2 条解析不正确：%+v", refs[1])
	}
	if e, ok := g.subEntry("sub-b"); !ok || e.URL == "" {
		t.Fatalf("subEntry 查询失败：%+v %v", e, ok)
	}
	if g.subsPath() != g.s.ConfigDir+string(os.PathSeparator)+"subscriptions.yaml" {
		t.Fatalf("订阅清单路径不正确：%s", g.subsPath())
	}
}
