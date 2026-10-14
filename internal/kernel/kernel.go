// Package kernel 以内核库的形式在进程内启动与管理 mihomo（无子进程、无外部配置工具）。
package kernel

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"sync"

	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

// Kernel 封装内核生命周期与状态读取。
type Kernel struct {
	mu          sync.Mutex
	homeDir     string
	uiDir       string
	controller  string
	secret      string
	geoAuto     bool
	geoRegister bool
	started     bool
}

// New 构造内核句柄；homeDir 为内核工作目录（-d），uiDir 为完整面板目录。
func New(homeDir, uiDir, controllerAddr, secret string, geoAuto bool) *Kernel {
	return &Kernel{homeDir: homeDir, uiDir: uiDir, controller: controllerAddr, secret: secret, geoAuto: geoAuto}
}

func levelOf(name string) log.LogLevel {
	switch name {
	case "debug":
		return log.DEBUG
	case "warning":
		return log.WARNING
	case "error":
		return log.ERROR
	case "silent":
		return log.SILENT
	default:
		return log.INFO
	}
}

// SetLogLevel 设置内核日志级别。
func (k *Kernel) SetLogLevel(level string) {
	log.SetLevel(levelOf(level))
}

// Boot 完成内核初始化（设置工作目录与日志级别），只应调用一次。
func (k *Kernel) Boot() error {
	constant.SetHomeDir(k.homeDir)
	// 配置路径必须是绝对路径：否则内核的默认配置会落到进程当前目录
	constant.SetConfig(filepath.Join(k.homeDir, constant.Path.Config()))
	if err := config.Init(k.homeDir); err != nil {
		return fmt.Errorf("初始化内核工作目录失败：%w", err)
	}
	return nil
}

// Validate 解析配置字节（等价于 mihomo -t），不生效、不监听端口。
func (k *Kernel) Validate(cfg []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	_, err := executor.ParseWithBytes(cfg)
	return err
}

// Apply 解析并生效配置（首次启动与热加载共用；配置字节在内存中直达内核）。
func (k *Kernel) Apply(cfg []byte) error {
	k.mu.Lock()
	defer k.mu.Unlock()

	options := []hub.Option{
		hub.WithExternalController(k.controller),
		hub.WithSecret(k.secret),
	}
	if k.uiDir != "" {
		options = append(options, hub.WithExternalUI(k.uiDir))
	}
	if err := hub.Parse(cfg, options...); err != nil {
		return err
	}
	if k.geoAuto && !k.geoRegister {
		updater.RegisterGeoUpdater()
		k.geoRegister = true
	}
	k.started = true
	return nil
}

// Started 报告内核是否已成功启动。
func (k *Kernel) Started() bool {
	k.mu.Lock()
	defer k.mu.Unlock()
	return k.started
}

// Stop 关闭内核（停止监听与后台任务）。
func (k *Kernel) Stop() {
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.started {
		return
	}
	executor.Shutdown()
	k.started = false
}

// Version 返回内核版本号。
func (k *Kernel) Version() string { return constant.Version }

// Traffic 是内核自带统计的只读快照。
type Traffic struct {
	UpTotal     int64  `json:"up_total"`
	DownTotal   int64  `json:"down_total"`
	UpSpeed     int64  `json:"up_speed"`
	DownSpeed   int64  `json:"down_speed"`
	Connections int    `json:"connections"`
	Memory      uint64 `json:"memory"`
}

// Traffic 读取累计流量、实时速率、活动连接数与内存占用。
func (k *Kernel) Traffic() Traffic {
	upTotal, downTotal := statistic.DefaultManager.Total()
	upSpeed, downSpeed := statistic.DefaultManager.Now()
	conns := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		conns++
		return true
	})
	return Traffic{
		UpTotal:     upTotal,
		DownTotal:   downTotal,
		UpSpeed:     upSpeed,
		DownSpeed:   downSpeed,
		Connections: conns,
		Memory:      statistic.DefaultManager.Memory(),
	}
}

// Node 是策略组中的一个节点。
type Node struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// Group 是策略组及其节点列表。
type Group struct {
	Name  string   `json:"name"`
	Type  string   `json:"type"`
	Now   string   `json:"now"`
	Nodes []string `json:"nodes"`
}

// Groups 返回内核当前的全部策略组（等价于内核 API 的 /proxies 视图）。
func (k *Kernel) Groups() []Group {
	proxies := tunnel.Proxies()
	groups := make([]Group, 0, len(proxies))
	for name, p := range proxies {
		if name == "GLOBAL" || p == nil || p.Adapter() == nil {
			continue
		}
		raw, err := json.Marshal(p)
		if err != nil {
			continue
		}
		var view struct {
			Type string   `json:"type"`
			Now  string   `json:"now"`
			All  []string `json:"all"`
		}
		if err := json.Unmarshal(raw, &view); err != nil || view.All == nil {
			continue
		}
		groups = append(groups, Group{Name: name, Type: view.Type, Now: view.Now, Nodes: view.All})
	}
	sort.Slice(groups, func(i, j int) bool { return groups[i].Name < groups[j].Name })
	return groups
}

// Select 切换策略组内节点。
func (k *Kernel) Select(group, node string) error {
	p, ok := tunnel.Proxies()[group]
	if !ok || p == nil || p.Adapter() == nil {
		return fmt.Errorf("策略组不存在：%s", group)
	}
	selector, ok := p.Adapter().(outboundgroup.SelectAble)
	if !ok {
		return fmt.Errorf("不是可切换的策略组：%s", group)
	}
	if err := selector.Set(node); err != nil {
		return fmt.Errorf("切换失败：%w", err)
	}
	return nil
}
