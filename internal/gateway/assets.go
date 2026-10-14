package gateway

import _ "embed"

// 内置配置骨架：编译进二进制，首次启动时播种到 /data/config，无需外部文件。
//
//go:embed assets/config/template.yaml
var templateYAML []byte

//go:embed assets/config/overlay.yaml
var overlayYAML []byte

//go:embed assets/config/subscriptions.yaml
var subscriptionsYAML []byte

// DefaultAssets 返回内置配置骨架。
func DefaultAssets() Assets {
	return Assets{
		Template:      templateYAML,
		Overlay:       overlayYAML,
		Subscriptions: subscriptionsYAML,
	}
}
