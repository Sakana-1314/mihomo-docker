# AGENTS.md

mihomo-docker（米哈游 API 加速网关）。事实标准以代码与各目录内文档为准，本文件不重复实现细节与历史决策。

## 唯一约定

**禁止未经明确授权修改 AGENTS.md。** 未获得用户明确授权，任何智能体不得增删改本文件。

## 定位口径

本仓库对外定位为「基于米哈游 API 的容器化网络加速网关」，所有对外文案一律沿用该口径：

- 不引入与该定位无关的用途描述或第三方项目叙事。
- 技术术语（透明网关、上游订阅、分流、流量统计）按事实描述，不臆造功能。
- 面向用户可见的文案（面板、启动日志、镜像 DESCRIPTION）保持同一口径；`README.md` 只保留一句话。

## 目录

- `main.go` - 单一入口：无参数启动守护进程，带参数进入命令行
- `internal/kernel/` - 内核库级调用（启动 / 热加载 / 停止、统计、策略组与节点）
- `internal/gateway/` - 编排：运行期配置、配置合成、订阅管理、定时任务；`assets/config/` 为内置配置骨架
- `internal/firewall/` - 透明代理规则（iptables + 策略路由；规则生成与执行分离以便单测）
- `internal/panel/` - 管理面板（同源静态页 + JSON 接口，静态资源编译进二进制）
- `internal/cli/`、`internal/out/`、`internal/settings/` - 命令行客户端、日志输出、运行期配置
- `tests/` - 容器级测试（冒烟、透明链路）；Go 单测与被测包同目录
- `examples/` - 部署示例（macvlan 透明网关、普通网桥）
- `.github/workflows/` - CI/CD 工作流

根目录只放 `AGENTS.md`、`LICENSE`、`README.md`、`Dockerfile`、`go.mod`、`go.sum`、`main.go`、`.gitignore`、`.gitattributes`、`.dockerignore`；其余代码与文档放进所属目录内部。

## notes

`notes/` 用于存放本地资料：机密文件、测试服务器、生产服务器相关信息。

- 不得进入 git，必须在 `.gitignore` 中忽略（`notes/`）。
- 只留本地，不复用、不外传、不复制进仓库其它目录。

## 协作与提交

- 作者与提交者统一为 `Sakana <admin@yangrucheng.top>`。
- 必须走 PR：`gh pr create` → 等 `构建镜像` 工作流全绿 → `gh pr merge --squash` 并删除 head 分支；禁止本地 merge 后直推 `main`。
- 分支前缀 `feat/`、`fix/`、`refactor/`、`docs/`、`chore/`；提交信息中文，格式 `type(scope): 描述`。
- 工作流 `name` 用中文（专有名词除外）；严禁硬编码 IP、密钥与内部域名，一律 `${{ secrets.* }}` 或示例占位。

## 发布模型

- 每天 02:00 UTC 定时拉取内核 **Meta 分支**代码构建并发布；`workflow_dispatch` 手动触发与 `main` 推送同样发布，PR 只校验。
- 版本号统一为 `dev`：镜像标签 `dev` 与 `latest` 指向同一次构建；每次先删除旧的 `dev` tag 与 release 再重建（`gh release delete dev --yes --cleanup-tag`）。
- 镜像内 `/usr/share/gw/kernel-version` 记录本次构建解析到的内核版本，可用于核对发布内容。

## 验证门禁

- `lint`：`gofmt -l .`、`go vet -tags with_gvisor ./...`、`go test -tags with_gvisor ./...`、`shellcheck tests/*.sh`、`node --check internal/panel/static/app.js`。
- `image`：构建 → `tests/smoke.sh` → `tests/transparent-e2e.sh` → 通过后才推送镜像并刷新 `dev`。
- 行为变更必须补测试：优先 Go 单测（不得依赖网络、Docker 或 Linux 专属能力），必要时补容器级测试。

## 实现约束（改动前必读）

- 内核以**库**的形式在同进程内运行：启动用 `hub.Parse`，热加载用 `executor.ParseWithBytes` + `hub.ApplyConfig`，流量统计读 `tunnel/statistic`，策略组读 `tunnel.Proxies()`、切换节点用 `adapter/outboundgroup.SelectAble`。运行期不依赖子进程与外部配置工具（yq / jq / curl / httpd 均不参与）。
- 内核工作目录与配置路径必须是绝对路径（`constant.SetHomeDir` / `constant.SetConfig`），否则内核的默认配置会落到进程当前目录。
- 配置合成顺序为「骨架模板或完整订阅 → `/data/config/overlay.yaml` → 运行期注入项」；运行期注入项由环境变量生成且优先级最高；合成结果先经内核校验（`Validate`）再生效，校验失败不落盘。
- 透明代理：`tproxy` 模式依赖 `ip rule fwmark 0x1 → table 100` 与 `ip route local default dev lo table 100`；只有具备全局地址的接口才会下发规则，新增接口后重新执行 `gw firewall reload`。
- 面板与内核 API 共用同一个密钥：`X-Panel-Token` 头或 `?token=` 查询参数鉴权，`PANEL_AUTH=none` 可关闭；`/api/health` 不需要密钥（供健康检查）。
- 命令行与守护进程是同一个二进制：无参数即守护进程，带参数即命令行客户端（经面板接口访问守护进程）。
