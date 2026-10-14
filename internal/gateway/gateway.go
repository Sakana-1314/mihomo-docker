// Package gateway 负责编排：内核生命周期、配置合成与切换、订阅管理、透明代理、面板与定时任务。
package gateway

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/Sakana-1314/mihomo-docker/internal/firewall"
	"github.com/Sakana-1314/mihomo-docker/internal/kernel"
	"github.com/Sakana-1314/mihomo-docker/internal/out"
	"github.com/Sakana-1314/mihomo-docker/internal/settings"
)

// Gateway 是守护进程的全部状态与能力。
type Gateway struct {
	s      *settings.Settings
	k      *kernel.Kernel
	fw     *firewall.Manager
	assets Assets

	opMu    sync.Mutex // 配置合成 / 生效 / 切换
	stateMu sync.Mutex // 状态文件写入
}

// New 构造网关实例。
func New(s *settings.Settings, assets Assets) *Gateway {
	return &Gateway{
		s:      s,
		assets: assets,
		k: kernel.New(
			s.HomeDir,
			filepath.Join(s.HomeDir, "ui"),
			fmt.Sprintf("0.0.0.0:%d", s.ControllerPort),
			s.Secret,
			s.GeoUpdate,
		),
		fw: firewall.New(firewall.Config{
			Mode:        s.Mode,
			IPv6Mode:    s.IPv6Mode,
			Backend:     s.FWBackend,
			Ifaces:      s.Ifaces,
			BypassCIDRs: s.BypassCIDRs,
			DNSHijack:   s.DNSHijack,
			TProxyPort:  s.TProxyPort,
			RedirPort:   s.RedirPort,
			DNSPort:     s.DNSPort,
		}),
	}
}

// Kernel 暴露内核句柄（供面板读取策略组与统计）。
func (g *Gateway) Kernel() *kernel.Kernel { return g.k }

// Settings 暴露运行期配置。
func (g *Gateway) Settings() *settings.Settings { return g.s }

// Boot 完成启动：播种配置、部署资源、初始化内核、引导订阅、合成初始配置、下发透明规则。
func (g *Gateway) Boot() error {
	out.Logf("米哈游 API 加速网关 启动中（mihomo-docker）")
	g.k.SetLogLevel(g.s.LogLevel)

	if err := g.ensureUserConfig(); err != nil {
		return err
	}
	g.deployAssets()

	if err := g.k.Boot(); err != nil {
		return err
	}

	if err := g.bootstrap(); err != nil {
		out.Warnf("订阅引导存在失败项：%v", err)
	}

	active := g.ActiveName()
	if active != "" {
		if _, err := os.Stat(g.profilePath(active)); err == nil {
			if err := g.Switch(active); err != nil {
				out.Warnf("应用订阅 %s 失败：%v", active, err)
				if err := g.applyBaseline(); err != nil {
					return err
				}
			}
		} else {
			if err := g.applyBaseline(); err != nil {
				return err
			}
		}
	} else if err := g.applyBaseline(); err != nil {
		return err
	}

	out.Logf("接口=%s 透明模式=%s DNS劫持=%v IPv6=%s 日志级别=%s",
		strings.Join(g.s.Ifaces, ","), g.s.Mode, g.s.DNSHijack, g.s.IPv6Mode, g.s.LogLevel)
	if g.s.PanelAuth == "token" {
		out.Logf("管理面板访问密钥（同时用于内核 API）：%s", g.s.Secret)
	}
	return nil
}

// SetupFirewall 下发透明代理规则；失败只告警（仍可作为普通端口服务使用）。
func (g *Gateway) SetupFirewall() {
	if err := g.fw.Setup(); err != nil {
		out.Warnf("透明代理规则应用失败：%v", err)
		return
	}
	if g.s.Mode == "off" {
		return
	}
	out.Logf("透明代理规则已应用：模式=%s 接口=%s DNS劫持=%v IPv6=%s 后备=%s",
		g.s.Mode, strings.Join(g.fw.ResolvedIfaces(), ","), g.s.DNSHijack, g.s.IPv6Mode, g.s.FWBackend)
}

// StartScheduler 启动后台定时任务（订阅更新与流量摘要）。
func (g *Gateway) StartScheduler() {
	if g.s.SubInterval > 0 {
		go func() {
			t := time.NewTicker(time.Duration(g.s.SubInterval) * time.Second)
			defer t.Stop()
			for range t.C {
				out.Logf("开始定时更新全部订阅")
				if _, err := g.UpdateSubs("all"); err != nil {
					out.Warnf("定时订阅更新存在失败项：%v", err)
				}
			}
		}()
	}
	if g.s.StatsLogInterval > 0 {
		go func() {
			t := time.NewTicker(time.Duration(g.s.StatsLogInterval) * time.Second)
			defer t.Stop()
			for range t.C {
				g.LogTraffic()
			}
		}()
	}
	out.Logf("定时任务已启动：订阅更新间隔 %ds，流量摘要间隔 %ds", g.s.SubInterval, g.s.StatsLogInterval)
}

// LogTraffic 输出一次流量摘要（数据来自内核自带统计）。
func (g *Gateway) LogTraffic() {
	t := g.k.Traffic()
	out.Logf("流量统计 | 累计 ↓ %s / ↑ %s | 当前 ↓ %s/s ↑ %s/s | 活动连接 %d | 内核内存 %s",
		HumanBytes(uint64(t.DownTotal)), HumanBytes(uint64(t.UpTotal)),
		HumanBytes(uint64(t.DownSpeed)), HumanBytes(uint64(t.UpSpeed)),
		t.Connections, HumanBytes(t.Memory))
}

// Restart 重新合成并生效当前配置（等价于重启内核，无需重启进程）。
func (g *Gateway) Restart() error {
	g.opMu.Lock()
	defer g.opMu.Unlock()
	return g.switchLocked(g.ActiveName())
}

// Groups 返回策略组（来自内核）。
func (g *Gateway) Groups() []kernel.Group { return g.k.Groups() }

// SelectNode 切换策略组内的节点。
func (g *Gateway) SelectNode(group, node string) error { return g.k.Select(group, node) }

// Shutdown 停止内核并清理透明代理规则。
func (g *Gateway) Shutdown() {
	g.k.Stop()
	g.fw.Cleanup()
}

// FirewallState 返回透明代理规则状态（on|off）。
func (g *Gateway) FirewallState() string { return g.fw.State() }

// ActiveName 读取当前活跃订阅名（空表示空载基线）。
func (g *Gateway) ActiveName() string {
	body, err := os.ReadFile(filepath.Join(g.s.StateDir, "active"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(body))
}

func (g *Gateway) writeActive(name string) {
	g.stateMu.Lock()
	defer g.stateMu.Unlock()
	if err := writeFileAtomic(filepath.Join(g.s.StateDir, "active"), []byte(name)); err != nil {
		out.Warnf("活跃订阅状态写入失败：%v", err)
	}
}

// Switch 切换到指定订阅（name 为空或 baseline 表示空载基线）。
func (g *Gateway) Switch(name string) error {
	g.opMu.Lock()
	defer g.opMu.Unlock()
	return g.switchLocked(name)
}

func (g *Gateway) switchLocked(name string) error {
	if name == "" || name == "baseline" {
		if err := g.clearProvider(); err != nil {
			return err
		}
		cfg, err := g.composeBaseline()
		if err != nil {
			return err
		}
		if err := g.applyConfig(cfg); err != nil {
			return err
		}
		g.writeActive("")
		out.Logf("已切换到空载基线（不使用上游订阅）")
		return nil
	}

	if !ValidSubName(name) {
		return fmt.Errorf("订阅名不合法：%s", name)
	}
	typ, err := g.profileType(name)
	if err != nil {
		return err
	}
	var cfg []byte
	if typ == "profile" {
		cfg, err = g.composeProfile(name)
	} else {
		if err := g.writeProvider(name); err != nil {
			return err
		}
		cfg, err = g.composeBaseline()
	}
	if err != nil {
		return err
	}
	if err := g.applyConfig(cfg); err != nil {
		return err
	}
	g.writeActive(name)
	out.Logf("已切换到订阅：%s", name)
	return nil
}

func (g *Gateway) applyBaseline() error {
	cfg, err := g.composeBaseline()
	if err != nil {
		return err
	}
	return g.applyConfig(cfg)
}

// bootstrap 首次启动时补齐缺失的订阅，并在没有活跃订阅时激活第一个可用订阅。
func (g *Gateway) bootstrap() error {
	refs := g.subRefs()
	if len(refs) == 0 {
		return nil
	}
	var firstErr error
	for _, e := range refs {
		if _, err := os.Stat(g.profilePath(e.Name)); err != nil {
			out.Logf("首次拉取订阅：%s", e.Name)
			if err := g.FetchSub(e.Name); err != nil && firstErr == nil {
				firstErr = err
			}
		}
	}
	active := g.ActiveName()
	if _, err := os.Stat(g.profilePath(active)); active == "" || err != nil {
		for _, e := range refs {
			if _, err := os.Stat(g.profilePath(e.Name)); err == nil {
				g.writeActive(e.Name)
				break
			}
		}
	}
	if g.s.SubOnBoot {
		if _, err := g.UpdateSubs("all"); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

// deployAssets 把镜像内置资源（完整面板、地理数据）铺到内核工作目录。
func (g *Gateway) deployAssets() {
	uiSrc := filepath.Join(g.s.AssetsDir, "ui")
	uiDst := filepath.Join(g.s.HomeDir, "ui")
	if st, err := os.Stat(uiSrc); err == nil && st.IsDir() {
		if _, err := os.Stat(filepath.Join(uiDst, "index.html")); err != nil {
			if err := copyDir(uiSrc, uiDst); err != nil {
				out.Warnf("完整面板部署失败：%v", err)
			} else {
				out.Logf("已部署完整面板：%s", uiDst)
			}
		}
	}
	for _, f := range []string{"geoip.metadb", "geosite.dat", "geoip.dat"} {
		src := filepath.Join(g.s.GeoAssetsDir, f)
		dst := filepath.Join(g.s.HomeDir, f)
		if _, err := os.Stat(src); err != nil {
			continue
		}
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		if body, err := os.ReadFile(src); err == nil {
			_ = os.WriteFile(dst, body, 0o644)
		}
	}
}

func copyDir(src, dst string) error {
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		from := filepath.Join(src, e.Name())
		to := filepath.Join(dst, e.Name())
		if e.IsDir() {
			if err := copyDir(from, to); err != nil {
				return err
			}
			continue
		}
		body, err := os.ReadFile(from)
		if err != nil {
			return err
		}
		if err := os.WriteFile(to, body, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// HumanBytes 把字节数格式化为易读文本。
func HumanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	units := []string{"KB", "MB", "GB", "TB", "PB"}
	value := float64(n)
	idx := -1
	for value >= unit && idx < len(units)-1 {
		value /= unit
		idx++
	}
	return fmt.Sprintf("%.2f %s", value, units[idx])
}
