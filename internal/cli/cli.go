// Package cli 实现 gw 命令行：以面板接口为后端的轻量客户端。
package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/Sakana-1314/mihomo-docker/internal/gateway"
)

const usage = `米哈游 API 加速网关 · 命令行

  gw status                    运行状态与流量统计
  gw subs                      订阅列表
  gw switch <名称|baseline>    快捷切换订阅
  gw update [名称|all]         立即更新订阅（默认 all）
  gw add <名称> <URL> [auto|proxies|profile]
  gw del <名称>
  gw nodes                     策略组与当前节点
  gw select <策略组> <节点>    切换策略组内节点
  gw firewall [reload|status]  透明代理规则
  gw restart                   重新应用当前配置
  gw health                    健康检查（供容器 HEALTHCHECK 使用）
  gw version                   版本信息
`

type client struct {
	base  string
	token string
	http  *http.Client
}

func dataDir() string {
	if v := os.Getenv("GW_DATA_DIR"); v != "" {
		return v
	}
	return "/data"
}

func newClient() *client {
	port := os.Getenv("PANEL_PORT")
	if port == "" {
		port = "8080"
	}
	token := os.Getenv("SECRET")
	if token == "" {
		if body, err := os.ReadFile(filepath.Join(dataDir(), "state", "secret")); err == nil {
			token = strings.TrimSpace(string(body))
		}
	}
	return &client{
		base:  "http://127.0.0.1:" + port,
		token: token,
		http:  &http.Client{Timeout: 180 * time.Second},
	}
}

func (c *client) request(method, path, body string) ([]byte, error) {
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, c.base+path, reader)
	if err != nil {
		return nil, err
	}
	if c.token != "" {
		req.Header.Set("X-Panel-Token", c.token)
	}
	if body != "" {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded;charset=UTF-8")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("无法连接网关（面板端口 %s 未监听？）：%w", c.base[strings.LastIndex(c.base, ":")+1:], err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 4<<20))
	if resp.StatusCode >= 400 {
		return data, fmt.Errorf("HTTP %d：%s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	return data, nil
}

func form(values map[string]string) string {
	q := url.Values{}
	for k, v := range values {
		q.Set(k, v)
	}
	return q.Encode()
}

// Run 执行命令行；返回进程退出码。
func Run(version string, args ...string) int {
	if len(args) == 0 {
		fmt.Print(usage)
		return 2
	}
	c := newClient()
	switch args[0] {
	case "status":
		body, err := c.request(http.MethodGet, "/api/status/text", "")
		if err != nil {
			return fail(err)
		}
		fmt.Print(string(body))
		return 0

	case "subs":
		body, err := c.request(http.MethodGet, "/api/subs", "")
		if err != nil {
			return fail(err)
		}
		var view gateway.SubsView
		if err := json.Unmarshal(body, &view); err != nil {
			return fail(err)
		}
		fmt.Print(renderSubs(view))
		return 0

	case "switch":
		if len(args) < 2 {
			return fail(fmt.Errorf("用法：gw switch <名称|baseline>"))
		}
		name := args[1]
		if name == "baseline" {
			name = ""
		}
		return action(c, "/api/subs/switch", form(map[string]string{"name": name}))

	case "update":
		target := "all"
		if len(args) > 1 {
			target = args[1]
		}
		return action(c, "/api/subs/update", form(map[string]string{"name": target}))

	case "add":
		if len(args) < 3 {
			return fail(fmt.Errorf("用法：gw add <名称> <URL> [auto|proxies|profile]"))
		}
		typ := "auto"
		if len(args) > 3 {
			typ = args[3]
		}
		return action(c, "/api/subs", form(map[string]string{"name": args[1], "url": args[2], "type": typ}))

	case "del":
		if len(args) < 2 {
			return fail(fmt.Errorf("用法：gw del <名称>"))
		}
		return action(c, "/api/subs/"+url.PathEscape(args[1]), "")

	case "nodes":
		body, err := c.request(http.MethodGet, "/api/nodes", "")
		if err != nil {
			return fail(err)
		}
		var payload struct {
			Groups []struct {
				Name  string   `json:"name"`
				Type  string   `json:"type"`
				Now   string   `json:"now"`
				Nodes []string `json:"nodes"`
			} `json:"groups"`
		}
		if err := json.Unmarshal(body, &payload); err != nil {
			return fail(err)
		}
		if len(payload.Groups) == 0 {
			fmt.Println("（配置中未包含策略组）")
			return 0
		}
		for _, g := range payload.Groups {
			fmt.Printf("%s（%s）当前：%s\n", g.Name, g.Type, g.Now)
			for _, n := range g.Nodes {
				mark := "  "
				if n == g.Now {
					mark = "→ "
				}
				fmt.Printf("  %s%s\n", mark, n)
			}
		}
		return 0

	case "select":
		if len(args) < 3 {
			return fail(fmt.Errorf("用法：gw select <策略组> <节点>"))
		}
		return action(c, "/api/nodes/select", form(map[string]string{"group": args[1], "node": args[2]}))

	case "firewall":
		sub := "reload"
		if len(args) > 1 {
			sub = args[1]
		}
		if sub == "status" {
			return runStatus(c)
		}
		return action(c, "/api/firewall/reload", "")

	case "restart":
		return action(c, "/api/kernel/restart", "")

	case "health":
		if _, err := c.request(http.MethodGet, "/api/health", ""); err != nil {
			return 1
		}
		return 0

	case "version":
		fmt.Printf("米哈游 API 加速网关 · 版本 %s\n", version)
		return 0

	case "help", "-h", "--help":
		fmt.Print(usage)
		return 0

	default:
		fmt.Print(usage)
		return 2
	}
}

func runStatus(c *client) int {
	body, err := c.request(http.MethodGet, "/api/status", "")
	if err != nil {
		return fail(err)
	}
	var st gateway.Status
	if err := json.Unmarshal(body, &st); err != nil {
		return fail(err)
	}
	fmt.Printf("透明代理规则：%s（模式 %s，接口 %s）\n", st.Transparent.State, st.Transparent.Mode, st.Transparent.Interface)
	return 0
}

func action(c *client, path, body string) int {
	method := http.MethodPost
	if body == "" && strings.HasPrefix(path, "/api/subs/") {
		method = http.MethodDelete
	}
	data, err := c.request(method, path, body)
	var payload struct {
		OK     bool   `json:"ok"`
		Output string `json:"output"`
		Error  string `json:"error"`
		State  string `json:"state"`
	}
	if len(data) > 0 {
		_ = json.Unmarshal(data, &payload)
	}
	if payload.Output != "" {
		fmt.Println(payload.Output)
	}
	if payload.State != "" {
		fmt.Printf("透明代理规则：%s\n", payload.State)
	}
	if err != nil {
		return fail(err)
	}
	return 0
}

func renderSubs(view gateway.SubsView) string {
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
		nodes := "-"
		if it.Nodes > 0 {
			nodes = strconv.Itoa(it.Nodes)
		}
		fmt.Fprintf(&b, "%-18s %-8s %-6s %-22s %s%s\n", it.Name, it.Type, nodes, it.UpdatedAt, status, mark)
	}
	if view.Total == 0 {
		b.WriteString("（订阅清单为空）\n")
	}
	return b.String()
}

func fail(err error) int {
	fmt.Fprintf(os.Stderr, "%v\n", err)
	return 1
}
