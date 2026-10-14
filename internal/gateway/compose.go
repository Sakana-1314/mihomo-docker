package gateway

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"go.yaml.in/yaml/v3"

	"github.com/Sakana-1314/mihomo-docker/internal/out"
)

// Assets 是编译进二进制的配置骨架（模板 / 覆盖层 / 订阅清单）。
type Assets struct {
	Template      []byte
	Overlay       []byte
	Subscriptions []byte
}

// normalize 把 YAML 解码结果统一为 map[string]any / []any / 标量。
func normalize(v any) any {
	switch t := v.(type) {
	case map[string]any:
		for k, val := range t {
			t[k] = normalize(val)
		}
		return t
	case map[any]any:
		m := make(map[string]any, len(t))
		for k, val := range t {
			m[fmt.Sprint(k)] = normalize(val)
		}
		return m
	case []any:
		for i, val := range t {
			t[i] = normalize(val)
		}
		return t
	default:
		return v
	}
}

func decodeMap(b []byte) (map[string]any, error) {
	var raw any
	if err := yaml.Unmarshal(b, &raw); err != nil {
		return nil, err
	}
	if m, ok := normalize(raw).(map[string]any); ok {
		return m, nil
	}
	return map[string]any{}, nil
}

// deepMerge 深度合并：对象递归合并，数组与标量整体替换（后者覆盖前者）。
func deepMerge(dst, src map[string]any) map[string]any {
	if dst == nil {
		dst = map[string]any{}
	}
	for k, v := range src {
		if sm, ok := v.(map[string]any); ok {
			if dm, ok := dst[k].(map[string]any); ok {
				dst[k] = deepMerge(dm, sm)
				continue
			}
			dst[k] = deepMerge(nil, sm)
			continue
		}
		dst[k] = v
	}
	return dst
}

func encodeYAML(doc map[string]any) ([]byte, error) {
	var buf bytes.Buffer
	enc := yaml.NewEncoder(&buf)
	enc.SetIndent(2)
	if err := enc.Encode(doc); err != nil {
		return nil, err
	}
	if err := enc.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ensureUserConfig 播种用户可编辑文件（仅缺失时），并保证节点提供者文件存在。
func (g *Gateway) ensureUserConfig() error {
	overlay := filepath.Join(g.s.ConfigDir, "overlay.yaml")
	if _, err := os.Stat(overlay); os.IsNotExist(err) {
		if err := os.WriteFile(overlay, g.assets.Overlay, 0o644); err != nil {
			return err
		}
		out.Logf("已生成默认覆盖层：%s", overlay)
	}
	subs := filepath.Join(g.s.ConfigDir, "subscriptions.yaml")
	if _, err := os.Stat(subs); os.IsNotExist(err) {
		if err := os.WriteFile(subs, g.assets.Subscriptions, 0o644); err != nil {
			return err
		}
		out.Logf("已生成订阅清单：%s", subs)
	}
	provider := filepath.Join(g.s.Providers, "active.yaml")
	if _, err := os.Stat(provider); os.IsNotExist(err) {
		if err := os.WriteFile(provider, []byte("proxies: []\n"), 0o644); err != nil {
			return err
		}
	}
	return nil
}

// runtimeDoc 生成运行期注入项（端口、控制器、密钥等，优先级最高）。
func (g *Gateway) runtimeDoc() map[string]any {
	s := g.s
	doc := map[string]any{
		"mixed-port":          s.MixedPort,
		"redir-port":          s.RedirPort,
		"tproxy-port":         s.TProxyPort,
		"allow-lan":           true,
		"bind-address":        "*",
		"external-controller": fmt.Sprintf("0.0.0.0:%d", s.ControllerPort),
		"external-ui":         "ui",
		"external-controller-cors": map[string]any{
			"allow-origins":         []any{"*"},
			"allow-private-network": true,
		},
		"geo-auto-update":     s.GeoUpdate,
		"geo-update-interval": s.GeoInterval,
		"secret":              s.Secret,
		"dns":                 map[string]any{"listen": fmt.Sprintf("0.0.0.0:%d", s.DNSPort)},
	}
	if s.LogLevelInject {
		doc["log-level"] = s.LogLevel
	}
	return doc
}

// compose 合并「基础配置 + 用户覆盖层 + 运行期注入项」。
func (g *Gateway) compose(base []byte) ([]byte, error) {
	baseDoc, err := decodeMap(base)
	if err != nil {
		return nil, fmt.Errorf("基础配置解析失败：%w", err)
	}

	overlayBytes, err := os.ReadFile(filepath.Join(g.s.ConfigDir, "overlay.yaml"))
	if err != nil {
		overlayBytes = g.assets.Overlay
	}
	overlayDoc, err := decodeMap(overlayBytes)
	if err != nil {
		return nil, fmt.Errorf("覆盖层解析失败：%w", err)
	}

	merged := deepMerge(deepMerge(baseDoc, overlayDoc), g.runtimeDoc())
	return encodeYAML(merged)
}

// composeBaseline 使用内置骨架模板合成（仅节点订阅与空载场景）。
func (g *Gateway) composeBaseline() ([]byte, error) {
	return g.compose(g.assets.Template)
}

// composeProfile 使用完整订阅合成（保留订阅自带策略组与规则）。
func (g *Gateway) composeProfile(name string) ([]byte, error) {
	body, err := os.ReadFile(g.profilePath(name))
	if err != nil {
		return nil, fmt.Errorf("订阅文件不存在：%s", name)
	}
	return g.compose(body)
}

// writeProvider 把「仅节点」订阅的节点写入节点提供者文件。
func (g *Gateway) writeProvider(name string) error {
	body, err := os.ReadFile(g.profilePath(name))
	if err != nil {
		return fmt.Errorf("订阅文件不存在：%s", name)
	}
	doc, err := decodeMap(body)
	if err != nil {
		return fmt.Errorf("订阅解析失败：%w", err)
	}
	proxies, _ := doc["proxies"].([]any)
	if proxies == nil {
		proxies = []any{}
	}
	out, err := encodeYAML(map[string]any{"proxies": proxies})
	if err != nil {
		return err
	}
	return writeFileAtomic(filepath.Join(g.s.Providers, "active.yaml"), out)
}

// clearProvider 清空节点提供者（空载基线）。
func (g *Gateway) clearProvider() error {
	return writeFileAtomic(filepath.Join(g.s.Providers, "active.yaml"), []byte("proxies: []\n"))
}

// applyConfig 校验并生效配置，同时落盘供排查（校验失败不落盘、不生效）。
func (g *Gateway) applyConfig(cfg []byte) error {
	if err := g.k.Validate(cfg); err != nil {
		return fmt.Errorf("配置校验失败：%w", err)
	}
	if err := g.k.Apply(cfg); err != nil {
		return fmt.Errorf("配置生效失败：%w", err)
	}
	return writeFileAtomic(filepath.Join(g.s.HomeDir, "config.yaml"), cfg)
}

// writeFileAtomic 先写临时文件再改名，避免半截文件被内核读到。
func writeFileAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
