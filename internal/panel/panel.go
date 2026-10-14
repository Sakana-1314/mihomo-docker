// Package panel 提供内置管理面板：同源静态页面 + JSON 接口（全部数据来自进程内内核）。
package panel

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/Sakana-1314/mihomo-docker/internal/gateway"
	"github.com/Sakana-1314/mihomo-docker/internal/out"
	"github.com/Sakana-1314/mihomo-docker/internal/settings"
)

//go:embed static
var staticFS embed.FS

// Panel 是管理面板的 HTTP 服务。
type Panel struct {
	gw  *gateway.Gateway
	s   *settings.Settings
	mux *http.ServeMux
}

// New 构造面板服务。
func New(gw *gateway.Gateway, s *settings.Settings) *Panel {
	p := &Panel{gw: gw, s: s, mux: http.NewServeMux()}
	p.routes()
	return p
}

// Handler 返回可直接挂载的处理器。
func (p *Panel) Handler() http.Handler { return p.mux }

// ListenAndServe 启动面板服务（阻塞）。
func (p *Panel) ListenAndServe() error {
	addr := fmt.Sprintf("0.0.0.0:%d", p.s.PanelPort)
	srv := &http.Server{
		Addr:              addr,
		Handler:           p.mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	out.Logf("管理面板已启动：%s | 完整面板：%s | 混合端口：%d", addr,
		fmt.Sprintf(":%d/ui/", p.s.ControllerPort), p.s.MixedPort)
	return srv.ListenAndServe()
}

func (p *Panel) routes() {
	sub, err := fs.Sub(staticFS, "static")
	if err == nil {
		p.mux.Handle("/", http.FileServer(http.FS(sub)))
	}

	p.mux.HandleFunc("/api/health", p.handleHealth)
	p.mux.HandleFunc("/api/status", p.auth(p.handleStatus))
	p.mux.HandleFunc("/api/status/text", p.auth(p.handleStatusText))
	p.mux.HandleFunc("/api/traffic", p.auth(p.handleTraffic))
	p.mux.HandleFunc("/api/subs", p.auth(p.handleSubs))
	p.mux.HandleFunc("/api/subs/", p.auth(p.handleSubItem))
	p.mux.HandleFunc("/api/subs/update", p.auth(p.handleSubsUpdate))
	p.mux.HandleFunc("/api/subs/switch", p.auth(p.handleSubsSwitch))
	p.mux.HandleFunc("/api/nodes", p.auth(p.handleNodes))
	p.mux.HandleFunc("/api/nodes/select", p.auth(p.handleNodesSelect))
	p.mux.HandleFunc("/api/kernel/restart", p.auth(p.handleKernelRestart))
	p.mux.HandleFunc("/api/firewall/reload", p.auth(p.handleFirewallReload))
}

// ---------------------------------------------------------------- 鉴权

func (p *Panel) auth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if p.s.PanelAuth == "token" && p.s.Secret != "" {
			token := r.Header.Get("X-Panel-Token")
			if token == "" {
				token = r.URL.Query().Get("token")
			}
			if token != p.s.Secret {
				writeJSONStatus(w, http.StatusUnauthorized, map[string]any{"ok": false, "error": "访问密钥不正确"})
				return
			}
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(v)
}

func writeJSONStatus(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// parseForm 兼容 JSON 与表单两种请求体，并回退到查询参数。
func parseForm(r *http.Request) map[string]string {
	fields := map[string]string{}
	if r.Method == http.MethodPost || r.Method == http.MethodPut || r.Method == http.MethodDelete {
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		trimmed := strings.TrimSpace(string(raw))
		if strings.HasPrefix(trimmed, "{") {
			var m map[string]any
			if json.Unmarshal(raw, &m) == nil {
				for k, v := range m {
					fields[k] = fmt.Sprint(v)
				}
			}
		} else if trimmed != "" {
			if values, err := url.ParseQuery(trimmed); err == nil {
				for k, vs := range values {
					if len(vs) > 0 {
						fields[k] = vs[0]
					}
				}
			}
		}
	}
	for k, vs := range r.URL.Query() {
		if _, ok := fields[k]; !ok && len(vs) > 0 {
			fields[k] = vs[0]
		}
	}
	return fields
}

// ---------------------------------------------------------------- 接口

func (p *Panel) handleHealth(w http.ResponseWriter, _ *http.Request) {
	if !p.gw.Kernel().Started() {
		writeJSONStatus(w, http.StatusServiceUnavailable, map[string]any{"ok": false})
		return
	}
	writeJSON(w, map[string]any{"ok": true})
}

func (p *Panel) handleStatus(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, p.gw.Status())
}

func (p *Panel) handleStatusText(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = w.Write([]byte(p.gw.StatusText()))
}

func (p *Panel) handleTraffic(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, p.gw.Kernel().Traffic())
}

func (p *Panel) handleSubs(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, p.gw.Subs())
	case http.MethodPost:
		fields := parseForm(r)
		err := p.gw.AddSub(fields["name"], fields["url"], fields["type"])
		writeJSON(w, map[string]any{"ok": err == nil, "output": errText(err), "subs": p.gw.Subs()})
	default:
		writeJSONStatus(w, http.StatusMethodNotAllowed, map[string]any{"ok": false, "error": "仅支持 GET / POST"})
	}
}

func (p *Panel) handleSubItem(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/api/subs/")
	name, _ = url.PathUnescape(name)
	err := p.gw.DelSub(name)
	writeJSON(w, map[string]any{"ok": err == nil, "output": errText(err), "subs": p.gw.Subs()})
}

func (p *Panel) handleSubsUpdate(w http.ResponseWriter, r *http.Request) {
	fields := parseForm(r)
	target := fields["name"]
	if target == "" {
		target = "all"
	}
	output, err := p.gw.UpdateSubs(target)
	writeJSON(w, map[string]any{"ok": err == nil, "output": outputText(output, err), "subs": p.gw.Subs()})
}

func (p *Panel) handleSubsSwitch(w http.ResponseWriter, r *http.Request) {
	fields := parseForm(r)
	name := fields["name"]
	err := p.gw.Switch(name)
	writeJSON(w, map[string]any{"ok": err == nil, "output": errText(err), "subs": p.gw.Subs()})
}

func (p *Panel) handleNodes(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, map[string]any{"ok": true, "groups": p.gw.Groups()})
}

func (p *Panel) handleNodesSelect(w http.ResponseWriter, r *http.Request) {
	fields := parseForm(r)
	err := p.gw.SelectNode(fields["group"], fields["node"])
	if err != nil {
		writeJSONStatus(w, http.StatusBadGateway, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, map[string]any{"ok": true, "output": "已切换节点"})
}

func (p *Panel) handleKernelRestart(w http.ResponseWriter, r *http.Request) {
	err := p.gw.Restart()
	writeJSON(w, map[string]any{"ok": err == nil, "output": errText(err)})
}

func (p *Panel) handleFirewallReload(w http.ResponseWriter, r *http.Request) {
	p.gw.SetupFirewall()
	writeJSON(w, map[string]any{"ok": true, "output": "透明代理规则已重新下发", "state": p.gw.FirewallState()})
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func outputText(output string, err error) string {
	if err != nil {
		if output == "" {
			return err.Error()
		}
		return output + "\n" + err.Error()
	}
	return output
}
