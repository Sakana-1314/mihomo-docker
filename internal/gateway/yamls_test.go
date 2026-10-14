package gateway

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// TestRepositoryYAMLValid 校验仓库内全部 YAML（示例部署文件与内置模板）可正常解析。
func TestRepositoryYAMLValid(t *testing.T) {
	root := filepath.Join("..", "..")
	var files []string
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if info.IsDir() {
			if info.Name() == ".git" || info.Name() == "notes" || info.Name() == "data" {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasSuffix(path, ".yaml") || strings.HasSuffix(path, ".yml") {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("遍历仓库失败：%v", err)
	}
	if len(files) == 0 {
		t.Fatal("未找到任何 YAML 文件")
	}
	for _, f := range files {
		body, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("读取 %s：%v", f, err)
		}
		var doc any
		if err := yaml.Unmarshal(body, &doc); err != nil {
			t.Fatalf("%s 解析失败：%v", f, err)
		}
	}
	t.Logf("已校验 %d 个 YAML 文件", len(files))
}

// TestEmbeddedTemplatesParse 校验内置模板与覆盖层可被解析为可用的配置骨架。
func TestEmbeddedTemplatesParse(t *testing.T) {
	assets := DefaultAssets()
	doc, err := decodeMap(assets.Template)
	if err != nil {
		t.Fatalf("内置模板解析失败：%v", err)
	}
	if doc["proxy-groups"] == nil || doc["rules"] == nil {
		t.Fatalf("内置模板应包含策略组与规则：%v", doc)
	}
	overlay, err := decodeMap(assets.Overlay)
	if err != nil {
		t.Fatalf("内置覆盖层解析失败：%v", err)
	}
	if overlay["dns"] == nil || overlay["sniffer"] == nil {
		t.Fatalf("内置覆盖层应包含 DNS 与嗅探配置：%v", overlay)
	}
	subs, err := decodeMap(assets.Subscriptions)
	if err != nil {
		t.Fatalf("内置订阅清单解析失败：%v", err)
	}
	if _, ok := subs["subscriptions"]; !ok {
		t.Fatalf("内置订阅清单应包含 subscriptions 字段：%v", subs)
	}
}
