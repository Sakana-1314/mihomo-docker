// 米哈游 API 加速网关：以内核库形式调用 mihomo，编译为单个二进制。
//
// 用法（同一二进制）：
//
//	gw            启动网关守护进程（容器 ENTRYPOINT）
//	gw <子命令>   命令行客户端（status / subs / switch / update / nodes / …）
package main

import (
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/Sakana-1314/mihomo-docker/internal/cli"
	"github.com/Sakana-1314/mihomo-docker/internal/gateway"
	"github.com/Sakana-1314/mihomo-docker/internal/out"
	"github.com/Sakana-1314/mihomo-docker/internal/panel"
	"github.com/Sakana-1314/mihomo-docker/internal/settings"
)

// 由构建注入：-X main.version=... -X github.com/metacubex/mihomo/constant.Version=...
var version = "dev"

func main() {
	args := os.Args[1:]
	if isCLI(args) {
		os.Exit(cli.Run(version, args...))
	}
	if err := runDaemon(); err != nil {
		out.Errf("启动失败：%v", err)
		os.Exit(1)
	}
}

// isCLI 判断当前调用是命令行还是守护进程：
// 无参数即守护进程（容器 ENTRYPOINT），带参数一律按命令行处理（未知子命令给出用法）。
func isCLI(args []string) bool {
	if len(args) == 0 {
		return false
	}
	return args[0] != "daemon"
}

func dataDir() string {
	if v := os.Getenv("GW_DATA_DIR"); v != "" {
		return v
	}
	return "/data"
}

func runDaemon() error {
	s, err := settings.Load(dataDir())
	if err != nil {
		return err
	}

	gw := gateway.New(s, gateway.DefaultAssets())

	// 先起面板：内核初始化（含地理数据加载）可能耗时，期间面板照常可访问并显示内核离线
	p := panel.New(gw, s)
	go func() {
		if err := p.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			out.Errf("管理面板退出：%v", err)
		}
	}()
	out.Logf("管理面板：http://<网关IP>:%d/  |  完整面板：http://<网关IP>:%d/ui/  |  混合端口：%d",
		s.PanelPort, s.ControllerPort, s.MixedPort)

	go func() {
		if err := gw.Boot(); err != nil {
			out.Errf("网关初始化失败：%v", err)
		}
	}()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
	out.Logf("收到退出信号，正在停止服务…")
	gw.Shutdown()
	return nil
}
