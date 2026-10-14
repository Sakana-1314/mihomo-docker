// Package settings 解析环境变量与目录布局（容器运行期的全部可配置项）。
package settings

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Settings 是网关运行期配置，全部来自环境变量（默认值与原脚本实现保持一致）。
type Settings struct {
	DataDir   string
	ConfigDir string
	StateDir  string
	HomeDir   string // 内核工作目录（-d）
	Profiles  string
	Providers string
	StateSubs string

	AssetsDir string // 镜像内置资源（geo 数据、metacubexd 面板）
	LogDir    string

	Mode      string // tproxy|redir|off
	IPv6Mode  string // block|proxy|pass
	FWBackend string // legacy|nft
	Ifaces    []string
	LogLevel  string

	MixedPort      int
	RedirPort      int
	TProxyPort     int
	DNSPort        int
	ControllerPort int
	PanelPort      int

	DNSHijack   bool
	BypassCIDRs []string

	Secret       string
	PanelAuth    string // token|none
	GeoUpdate    bool
	GeoInterval  int // 小时
	GeoAssetsDir string

	SubInterval   int // 秒
	SubOnBoot     bool
	SubTimeout    int // 秒
	SubViaProxy   bool
	SubUserAgent  string
	ActiveProfile string

	StatsLogInterval int // 秒
	LogLevelInject   bool
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func envBool(key string, def bool) bool {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def
	}
	switch strings.ToLower(v) {
	case "1", "true", "yes", "on":
		return true
	default:
		return false
	}
}

func envInt(key string, def, min, max int) (int, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, fmt.Errorf("%s 必须是数字：%s", key, v)
	}
	if n < min || n > max {
		return 0, fmt.Errorf("%s 超出范围 %d-%d：%d", key, min, max, n)
	}
	return n, nil
}

func envEnum(key, def string, allowed ...string) (string, error) {
	v := strings.ToLower(env(key, def))
	for _, a := range allowed {
		if v == a {
			return v, nil
		}
	}
	return "", fmt.Errorf("%s 仅支持 %s", key, strings.Join(allowed, " / "))
}

func resolveSecret(stateDir string) (string, error) {
	if v := os.Getenv("SECRET"); v != "" {
		return v, nil
	}
	path := filepath.Join(stateDir, "secret")
	if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
		return strings.TrimSpace(string(b)), nil
	}
	const chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	for i := range buf {
		buf[i] = chars[int(buf[i])%len(chars)]
	}
	s := string(buf)
	if err := os.WriteFile(path, []byte(s), 0o600); err != nil {
		return "", err
	}
	return s, nil
}

// Load 读取环境变量并完成校验，同时确保目录存在。
func Load(dataDir string) (*Settings, error) {
	s := &Settings{DataDir: dataDir}
	s.ConfigDir = filepath.Join(dataDir, "config")
	s.StateDir = filepath.Join(dataDir, "state")
	s.HomeDir = filepath.Join(dataDir, "mihomo")
	s.Profiles = filepath.Join(s.HomeDir, "profiles")
	s.Providers = filepath.Join(s.HomeDir, "providers")
	s.StateSubs = filepath.Join(s.StateDir, "subs")
	s.LogDir = filepath.Join(dataDir, "log")
	s.AssetsDir = env("GW_ASSETS_DIR", "/usr/share/gw")
	s.GeoAssetsDir = filepath.Join(s.AssetsDir, "geo")

	for _, dir := range []string{s.ConfigDir, s.StateDir, s.HomeDir, s.Profiles, s.Providers, s.StateSubs, s.LogDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}

	var err error
	if s.Mode, err = envEnum("TRANSPARENT_MODE", "tproxy", "tproxy", "redir", "off"); err != nil {
		return nil, err
	}
	if s.IPv6Mode, err = envEnum("IPV6_MODE", "block", "block", "proxy", "pass"); err != nil {
		return nil, err
	}
	if s.FWBackend, err = envEnum("FW_BACKEND", "legacy", "legacy", "nft"); err != nil {
		return nil, err
	}
	if s.PanelAuth, err = envEnum("PANEL_AUTH", "token", "token", "none"); err != nil {
		return nil, err
	}
	if s.LogLevel, err = envEnum("LOG_LEVEL", "info", "debug", "info", "warning", "error", "silent"); err != nil {
		return nil, err
	}
	s.LogLevelInject = os.Getenv("LOG_LEVEL") != ""

	if s.MixedPort, err = envInt("MIXED_PORT", 7890, 1, 65535); err != nil {
		return nil, err
	}
	if s.RedirPort, err = envInt("REDIR_PORT", 7892, 1, 65535); err != nil {
		return nil, err
	}
	if s.TProxyPort, err = envInt("TPROXY_PORT", 7893, 1, 65535); err != nil {
		return nil, err
	}
	if s.DNSPort, err = envInt("DNS_PORT", 53, 1, 65535); err != nil {
		return nil, err
	}
	if s.ControllerPort, err = envInt("CONTROLLER_PORT", 9090, 1, 65535); err != nil {
		return nil, err
	}
	if s.PanelPort, err = envInt("PANEL_PORT", 8080, 1, 65535); err != nil {
		return nil, err
	}

	s.DNSHijack = envBool("DNS_HIJACK", true)
	s.GeoUpdate = envBool("GEO_UPDATE", true)
	s.SubOnBoot = envBool("SUB_UPDATE_ON_BOOT", false)
	s.SubViaProxy = envBool("SUB_VIA_PROXY", true)

	if s.GeoInterval, err = envInt("GEO_UPDATE_INTERVAL", 24, 0, 8760); err != nil {
		return nil, err
	}
	if s.SubInterval, err = envInt("SUB_UPDATE_INTERVAL", 21600, 0, 31536000); err != nil {
		return nil, err
	}
	if s.SubTimeout, err = envInt("SUB_TIMEOUT", 30, 5, 600); err != nil {
		return nil, err
	}
	if s.StatsLogInterval, err = envInt("STATS_LOG_INTERVAL", 1800, 0, 31536000); err != nil {
		return nil, err
	}

	s.SubUserAgent = env("SUB_USER_AGENT", "clash.meta")
	s.ActiveProfile = os.Getenv("ACTIVE_PROFILE")
	s.Ifaces = splitList(env("GATEWAY_IF", ""))
	s.BypassCIDRs = splitList(env("BYPASS_CIDRS", "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10"))

	if s.Secret, err = resolveSecret(s.StateDir); err != nil {
		return nil, err
	}
	return s, nil
}

func splitList(v string) []string {
	var out []string
	for _, part := range strings.Split(v, ",") {
		if p := strings.TrimSpace(part); p != "" {
			out = append(out, p)
		}
	}
	return out
}
