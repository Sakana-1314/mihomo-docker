package gateway

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"

	"github.com/Sakana-1314/mihomo-docker/internal/out"
)

const subMaxBytes = 16 << 20

var subNamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,64}$`)

// SubEntry 是订阅清单（subscriptions.yaml）中的一条记录。
type SubEntry struct {
	Name string `yaml:"name" json:"name"`
	URL  string `yaml:"url" json:"url"`
	Type string `yaml:"type" json:"type"`
}

// SubState 是订阅最近一次拉取的状态。
type SubState struct {
	Name      string `json:"name"`
	URL       string `json:"url"`
	Type      string `json:"type"`
	Status    string `json:"status"`
	Nodes     int    `json:"nodes"`
	SHA256    string `json:"sha256"`
	UpdatedAt string `json:"updated_at"`
	Error     string `json:"error"`
}

// SubsView 是面板所需的订阅视图。
type SubsView struct {
	Active string     `json:"active"`
	Total  int        `json:"total"`
	Items  []SubState `json:"items"`
}

type subsDoc struct {
	Subscriptions []SubEntry `yaml:"subscriptions"`
}

func (g *Gateway) subsPath() string {
	return filepath.Join(g.s.ConfigDir, "subscriptions.yaml")
}

func (g *Gateway) profilePath(name string) string {
	return filepath.Join(g.s.Profiles, name+".yaml")
}

func (g *Gateway) stateSubPath(name string) string {
	return filepath.Join(g.s.StateSubs, name+".json")
}

// ValidSubName 校验订阅名（同时用作文件名）。
func ValidSubName(name string) bool { return subNamePattern.MatchString(name) }

func (g *Gateway) readSubs() (subsDoc, error) {
	var doc subsDoc
	body, err := os.ReadFile(g.subsPath())
	if err != nil {
		return doc, err
	}
	if err := yaml.Unmarshal(body, &doc); err != nil {
		return doc, err
	}
	return doc, nil
}

func (g *Gateway) writeSubs(doc subsDoc) error {
	sort.Slice(doc.Subscriptions, func(i, j int) bool { return doc.Subscriptions[i].Name < doc.Subscriptions[j].Name })
	body, err := yaml.Marshal(doc)
	if err != nil {
		return err
	}
	return writeFileAtomic(g.subsPath(), body)
}

// subRefs 返回订阅清单（保持文件顺序）。
func (g *Gateway) subRefs() []SubEntry {
	doc, err := g.readSubs()
	if err != nil {
		return nil
	}
	return doc.Subscriptions
}

func (g *Gateway) subEntry(name string) (SubEntry, bool) {
	for _, e := range g.subRefs() {
		if e.Name == name {
			return e, true
		}
	}
	return SubEntry{}, false
}

// profileType 判定订阅形态：profile（含策略组与规则）/ proxies（仅节点）。
func (g *Gateway) profileType(name string) (string, error) {
	body, err := os.ReadFile(g.profilePath(name))
	if err != nil {
		return "", fmt.Errorf("订阅不存在或尚未拉取：%s", name)
	}
	if e, ok := g.subEntry(name); ok {
		switch e.Type {
		case "proxies", "profile":
			return e.Type, nil
		}
	}
	doc, err := decodeMap(body)
	if err != nil {
		return "", fmt.Errorf("订阅解析失败：%w", err)
	}
	if doc["proxy-groups"] != nil && doc["rules"] != nil {
		return "profile", nil
	}
	return "proxies", nil
}

func profileNodeCount(body []byte) int {
	doc, err := decodeMap(body)
	if err != nil {
		return 0
	}
	proxies, _ := doc["proxies"].([]any)
	return len(proxies)
}

func readState(path string) (SubState, bool) {
	var st SubState
	body, err := os.ReadFile(path)
	if err != nil {
		return st, false
	}
	if err := json.Unmarshal(body, &st); err != nil {
		return st, false
	}
	return st, true
}

func (g *Gateway) writeSubState(st SubState) {
	g.stateMu.Lock()
	defer g.stateMu.Unlock()
	body, err := json.Marshal(st)
	if err != nil {
		return
	}
	if err := writeFileAtomic(g.stateSubPath(st.Name), body); err != nil {
		out.Warnf("订阅状态写入失败：%s（%v）", st.Name, err)
	}
}

// Subs 汇总订阅视图（清单为准，缺失状态用占位）。
func (g *Gateway) Subs() SubsView {
	view := SubsView{Active: g.ActiveName(), Items: []SubState{}}
	for _, e := range g.subRefs() {
		st, ok := readState(g.stateSubPath(e.Name))
		if !ok {
			st = SubState{Name: e.Name, URL: e.URL, Type: e.Type, Status: "pending"}
		}
		if st.Name == "" {
			st.Name = e.Name
		}
		view.Items = append(view.Items, st)
	}
	view.Total = len(view.Items)
	return view
}

// SubsTable 返回命令行表格文本。
func (g *Gateway) SubsTable() string {
	view := g.Subs()
	var b strings.Builder
	fmt.Fprintf(&b, "%-18s %-8s %-6s %-22s %s\n", "名称", "类型", "节点", "上次更新", "状态")
	for _, it := range view.Items {
		status := it.Status
		switch it.Status {
		case "ok":
			status = "正常"
		case "pending", "":
			status = "尚未拉取"
		default:
			status = "失败（" + it.Error + "）"
		}
		mark := ""
		if it.Name == view.Active {
			mark = "  ← 当前"
		}
		nodes := fmt.Sprintf("%d", it.Nodes)
		if it.Nodes == 0 {
			nodes = "-"
		}
		fmt.Fprintf(&b, "%-18s %-8s %-6s %-22s %s%s\n", it.Name, it.Type, nodes, it.UpdatedAt, status, mark)
	}
	if view.Total == 0 {
		b.WriteString("（订阅清单为空）\n")
	}
	return b.String()
}

func isPrivateHost(host string) bool {
	if host == "" {
		return false
	}
	if !strings.Contains(host, ".") && !strings.Contains(host, ":") {
		return true // 单标签主机名（容器/内网服务名）
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified()
}

func httpClient(timeout int, proxy string) *http.Client {
	tr := &http.Transport{}
	if proxy != "" {
		if u, err := neturl.Parse(proxy); err == nil {
			tr.Proxy = http.ProxyURL(u)
		}
	}
	return &http.Client{Timeout: time.Duration(timeout) * time.Second, Transport: tr}
}

func (g *Gateway) fetchURL(client *http.Client, rawURL string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", g.s.SubUserAgent)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, subMaxBytes))
}

// download 下载订阅：公网目标优先走内核链路，内网/单标签主机优先直连，双向回退。
func (g *Gateway) download(rawURL string) ([]byte, error) {
	u, err := neturl.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("订阅地址无效：%w", err)
	}
	preferDirect := isPrivateHost(u.Hostname())
	viaProxy := g.s.SubViaProxy && g.k.Started()
	direct := httpClient(g.s.SubTimeout, "")
	proxied := httpClient(g.s.SubTimeout, fmt.Sprintf("http://127.0.0.1:%d", g.s.MixedPort))

	if !preferDirect && viaProxy {
		if body, err := g.fetchURL(proxied, rawURL); err == nil {
			return body, nil
		}
		out.Warnf("经内核链路下载失败，回退直连：%s", rawURL)
	}
	body, err := g.fetchURL(direct, rawURL)
	if err == nil {
		return body, nil
	}
	if preferDirect && viaProxy {
		out.Logf("直连下载失败，改经内核链路重试：%s", rawURL)
		if body, err2 := g.fetchURL(proxied, rawURL); err2 == nil {
			return body, nil
		}
	}
	return nil, err
}

// FetchSub 拉取单个订阅并落盘、更新状态。
func (g *Gateway) FetchSub(name string) error {
	entry, ok := g.subEntry(name)
	if !ok {
		return fmt.Errorf("订阅不存在：%s", name)
	}
	if entry.URL == "" {
		st := g.baseState(name)
		st.Status, st.Error = "error", "未配置订阅地址"
		g.writeSubState(st)
		return fmt.Errorf("订阅 %s 未配置地址", name)
	}

	body, err := g.download(entry.URL)
	if err != nil {
		st := g.baseState(name)
		st.Status, st.Error = "error", "下载失败"
		g.writeSubState(st)
		return fmt.Errorf("订阅 %s 下载失败：%w", name, err)
	}

	doc, perr := decodeMap(body)
	if perr != nil || (doc["proxies"] == nil && doc["proxy-providers"] == nil && doc["rules"] == nil) {
		st := g.baseState(name)
		st.Status, st.Error = "error", "订阅内容无效"
		g.writeSubState(st)
		return fmt.Errorf("订阅 %s 内容无效（需返回 YAML 配置）", name)
	}

	if err := writeFileAtomic(g.profilePath(name), body); err != nil {
		return err
	}
	sum := sha256.Sum256(body)
	st := g.baseState(name)
	st.Status = "ok"
	st.Nodes = profileNodeCount(body)
	st.SHA256 = hex.EncodeToString(sum[:])
	st.UpdatedAt = time.Now().UTC().Format(time.RFC3339)
	st.Type = g.declaredOrDetectedType(name)
	g.writeSubState(st)
	out.Logf("订阅已更新：%s（节点 %d 个）", name, st.Nodes)
	return nil
}

func (g *Gateway) declaredOrDetectedType(name string) string {
	if typ, err := g.profileType(name); err == nil {
		return typ
	}
	if e, ok := g.subEntry(name); ok && e.Type != "" {
		return e.Type
	}
	return "auto"
}

// baseState 生成状态骨架（保留既有节点数，便于失败时仍可展示）。
func (g *Gateway) baseState(name string) SubState {
	entry, _ := g.subEntry(name)
	st := SubState{Name: name, URL: entry.URL, Type: entry.Type}
	if prev, ok := readState(g.stateSubPath(name)); ok {
		st.Nodes = prev.Nodes
	}
	if st.Type == "" {
		st.Type = "auto"
	}
	return st
}

// UpdateSubs 更新订阅（target 为空或 all 表示全部）。
func (g *Gateway) UpdateSubs(target string) (string, error) {
	var targets []string
	if target == "" || target == "all" {
		for _, e := range g.subRefs() {
			targets = append(targets, e.Name)
		}
	} else {
		targets = []string{target}
	}
	if len(targets) == 0 {
		return "订阅清单为空，跳过更新", nil
	}

	var lines []string
	failed := false
	for _, name := range targets {
		if err := g.FetchSub(name); err != nil {
			out.Warnf("%v", err)
			lines = append(lines, "· "+err.Error())
			failed = true
			continue
		}
		lines = append(lines, fmt.Sprintf("· %s 已更新", name))
		if g.ActiveName() == name {
			if err := g.Switch(name); err != nil {
				out.Warnf("订阅 %s 已更新，但生效失败：%v", name, err)
				lines = append(lines, fmt.Sprintf("· %s 生效失败：%v", name, err))
				failed = true
			}
		}
	}
	if failed {
		return strings.Join(lines, "\n"), fmt.Errorf("存在失败项")
	}
	return strings.Join(lines, "\n"), nil
}

// AddSub 新增订阅并立即拉取。
func (g *Gateway) AddSub(name, rawURL, typ string) error {
	if !ValidSubName(name) {
		return fmt.Errorf("订阅名仅允许字母数字与 . _ -：%s", name)
	}
	if rawURL == "" {
		return fmt.Errorf("缺少订阅地址")
	}
	switch typ {
	case "", "auto", "proxies", "profile":
	default:
		return fmt.Errorf("type 仅支持 auto / proxies / profile：%s", typ)
	}
	if typ == "" {
		typ = "auto"
	}
	doc, _ := g.readSubs()
	for _, e := range doc.Subscriptions {
		if e.Name == name {
			return fmt.Errorf("订阅已存在：%s", name)
		}
	}
	doc.Subscriptions = append(doc.Subscriptions, SubEntry{Name: name, URL: rawURL, Type: typ})
	if err := g.writeSubs(doc); err != nil {
		return fmt.Errorf("写入订阅清单失败：%w", err)
	}
	out.Logf("已添加订阅：%s", name)
	return g.FetchSub(name)
}

// DelSub 删除订阅；若删除的是当前订阅，则自动切到下一个可用订阅。
func (g *Gateway) DelSub(name string) error {
	doc, err := g.readSubs()
	if err != nil {
		return err
	}
	found := false
	kept := make([]SubEntry, 0, len(doc.Subscriptions))
	for _, e := range doc.Subscriptions {
		if e.Name == name {
			found = true
			continue
		}
		kept = append(kept, e)
	}
	if !found {
		return fmt.Errorf("订阅不存在：%s", name)
	}
	doc.Subscriptions = kept
	if err := g.writeSubs(doc); err != nil {
		return fmt.Errorf("更新订阅清单失败：%w", err)
	}
	_ = os.Remove(g.profilePath(name))
	_ = os.Remove(g.stateSubPath(name))
	out.Logf("已删除订阅：%s", name)

	if g.ActiveName() != name {
		return nil
	}
	for _, e := range kept {
		if _, err := os.Stat(g.profilePath(e.Name)); err == nil {
			out.Logf("自动切换到订阅：%s", e.Name)
			return g.Switch(e.Name)
		}
	}
	return g.Switch("baseline")
}
