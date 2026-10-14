package gateway

import (
	"fmt"
	"strings"

	"github.com/Sakana-1314/mihomo-docker/internal/kernel"
)

// KernelInfo 是内核在线状态与版本。
type KernelInfo struct {
	Online  bool   `json:"online"`
	Version string `json:"version"`
}

// PortsInfo 是各监听端口。
type PortsInfo struct {
	Mixed      int `json:"mixed"`
	TProxy     int `json:"tproxy"`
	Redir      int `json:"redir"`
	Controller int `json:"controller"`
	Panel      int `json:"panel"`
}

// TransparentInfo 描述透明代理运行状态。
type TransparentInfo struct {
	Mode      string    `json:"mode"`
	State     string    `json:"state"`
	Interface string    `json:"interface"`
	DNSHijack bool      `json:"dns_hijack"`
	DNSPort   int       `json:"dns_port"`
	IPv6      string    `json:"ipv6"`
	Ports     PortsInfo `json:"ports"`
}

// PanelInfo 描述面板自身的配置。
type PanelInfo struct {
	Auth          string `json:"auth"`
	Secret        string `json:"secret"`
	GeoAutoUpdate bool   `json:"geo_auto_update"`
}

// Status 是面板与命令行共用的综合状态。
type Status struct {
	KernelInfo  KernelInfo      `json:"kernel"`
	Active      string          `json:"active"`
	Transparent TransparentInfo `json:"transparent"`
	Traffic     kernel.Traffic  `json:"traffic"`
	Subs        SubsView        `json:"subs"`
	Panel       PanelInfo       `json:"panel"`
}

// Status 汇总当前运行状态（内核数据全部取自进程内实例）。
func (g *Gateway) Status() Status {
	s := g.s
	started := g.k.Started()
	status := Status{
		KernelInfo: KernelInfo{Online: started, Version: g.k.Version()},
		Active:     g.ActiveName(),
		Transparent: TransparentInfo{
			Mode:      s.Mode,
			State:     g.fw.State(),
			Interface: strings.Join(g.fw.ResolvedIfaces(), ","),
			DNSHijack: s.DNSHijack,
			DNSPort:   s.DNSPort,
			IPv6:      s.IPv6Mode,
			Ports: PortsInfo{
				Mixed:      s.MixedPort,
				TProxy:     s.TProxyPort,
				Redir:      s.RedirPort,
				Controller: s.ControllerPort,
				Panel:      s.PanelPort,
			},
		},
		Subs: g.Subs(),
		Panel: PanelInfo{
			Auth:          s.PanelAuth,
			Secret:        s.Secret,
			GeoAutoUpdate: s.GeoUpdate,
		},
	}
	if started {
		status.Traffic = g.k.Traffic()
	}
	return status
}

// StatusText 渲染命令行状态文本。
func (g *Gateway) StatusText() string {
	st := g.Status()
	var b strings.Builder
	online := "离线"
	if st.KernelInfo.Online {
		online = "在线"
	}
	active := st.Active
	if active == "" {
		active = "（空载基线）"
	}
	fmt.Fprintf(&b, "米哈游 API 加速网关 · 运行状态\n")
	fmt.Fprintf(&b, "  内核        ：%s（%s）\n", st.KernelInfo.Version, online)
	fmt.Fprintf(&b, "  活跃订阅    ：%s\n", active)
	fmt.Fprintf(&b, "  透明代理    ：%s / 接口 %s / 规则 %s\n", st.Transparent.Mode, st.Transparent.Interface, st.Transparent.State)
	fmt.Fprintf(&b, "  DNS 劫持    ：%v（端口 %d）\n", st.Transparent.DNSHijack, st.Transparent.DNSPort)
	fmt.Fprintf(&b, "  IPv6        ：%s\n", st.Transparent.IPv6)
	fmt.Fprintf(&b, "  端口        ：混合 %d / 透明 %d / 控制器 %d / 面板 %d\n",
		st.Transparent.Ports.Mixed, st.Transparent.Ports.TProxy, st.Transparent.Ports.Controller, st.Transparent.Ports.Panel)
	fmt.Fprintf(&b, "  流量        ：累计 ↓ %s / ↑ %s，当前 ↓ %s/s ↑ %s/s\n",
		HumanBytes(uint64(st.Traffic.DownTotal)), HumanBytes(uint64(st.Traffic.UpTotal)),
		HumanBytes(uint64(st.Traffic.DownSpeed)), HumanBytes(uint64(st.Traffic.UpSpeed)))
	fmt.Fprintf(&b, "  连接与内存  ：活动连接 %d，内核内存 %s\n", st.Traffic.Connections, HumanBytes(st.Traffic.Memory))
	return b.String()
}
