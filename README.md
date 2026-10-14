# mihomo-docker · 米哈游 API 加速网关

面向米哈游 API 的容器化网络加速网关：基于 [mihomo](https://github.com/MetaCubeX/mihomo) 内核（Meta 分支），
在局域网中以 **macvlan 透明网关**方式部署，为接入设备提供统一的上游加速链路、订阅自动更新与可视化流量统计。

- 镜像：`ghcr.io/sakana-1314/mihomo-docker:latest`（多架构：`linux/amd64`、`linux/arm64`）
- 内核版本固定在 `Dockerfile` 的 `ARG MIHOMO_VERSION`，随镜像一起升级
- 管理面板：`http://<网关IP>:8080/`；完整面板（MetaCubeXD）：`http://<网关IP>:9090/ui/`

## 功能特性

| 能力 | 说明 |
| --- | --- |
| 透明网关 | `tproxy`（TCP+UDP 全量，保留客户端源地址）/ `redir`（仅 TCP）/ `off` 三种模式；含 DNS 劫持与 IPv6 策略 |
| 订阅自动更新 | 按 `SUB_UPDATE_INTERVAL` 定时拉取全部订阅；下载优先走内核链路，失败自动回退直连；订阅异常时保留旧配置 |
| 快捷切换 | 面板一键切换 / 命令行 `gw switch`；仅节点订阅走节点提供者热更新，完整订阅走配置热加载，均无需重启容器 |
| 流量统计 | 直接呈现内核自带统计（`/connections`、`/memory`）：累计上下行、实时速率、活动连接数、内存占用；面板 2 秒刷新，并可定时输出摘要日志 |
| 配置合成 | 骨架模板 + 用户覆盖层 + 运行时注入项三层深度合并；切换订阅前先用内核做配置校验，校验不通过不落盘 |
| 管理面板 | 内置浅色面板：运行概览、流量统计、订阅管理（增删改查/切换/更新）、策略组与本组节点切换、密钥与面板入口 |
| 进程守护 | 内核异常退出自动拉起；连续启动失败则退出容器交由重启策略接管 |

## 快速开始（macvlan 透明网关）

```bash
# 1) 宿主机创建 macvlan 网络（按实际网段与网卡调整；容器 IP 不要落在路由器 DHCP 池内）
docker network create -d macvlan \
  --subnet=192.168.1.0/24 --gateway=192.168.1.1 \
  -o parent=eth0 -o macvlan_mode=bridge mihomo_gw

# 2) 启动网关（示例 compose 中容器地址为 192.168.1.250）
mkdir -p data
docker compose -f examples/docker-compose.macvlan.yml up -d

# 3) 将设备的「默认网关 + DNS」指向 192.168.1.250（或在路由器 DHCP 中下发）
#    随后访问管理面板：
#      http://192.168.1.250:8080/
#    访问密钥默认为自动生成，可在容器日志中查看：docker logs mihomo-docker | grep 密钥
```

在面板「上游订阅」中新增订阅即可开始加速；也可以先编辑 `data/config/subscriptions.yaml` 后执行
`docker exec mihomo-docker gw update all`。

## 管理面板与命令行

面板功能：运行概览（内核状态/透明模式/接口/DNS/IPv6）、流量统计、订阅管理、策略组与节点切换、密钥展示。

命令行（容器内 `gw`）：

```bash
docker exec mihomo-docker gw status              # 运行状态与流量统计
docker exec mihomo-docker gw subs                # 订阅列表（类型/节点数/更新时间/状态）
docker exec mihomo-docker gw switch <订阅名>     # 快捷切换（baseline 表示回到空载基线）
docker exec mihomo-docker gw update all          # 立即更新全部订阅
docker exec mihomo-docker gw add <名称> <URL> [auto|proxies|profile]
docker exec mihomo-docker gw del <名称>
docker exec mihomo-docker gw firewall setup      # 重新下发透明代理规则
docker exec mihomo-docker gw restart             # 重启内核（守护进程自动拉起）
docker exec mihomo-docker gw env                 # 查看当前生效的环境变量
```

## 上游订阅

订阅清单位于 `/data/config/subscriptions.yaml`（首次启动自动生成），支持两种形态：

| type | 行为 | 切换/更新方式 |
| --- | --- | --- |
| `proxies` | 仅取订阅中的节点，并入 `active` 节点提供者，与骨架模板的策略组配合工作 | 节点提供者热更新（不重载配置） |
| `profile` | 订阅自带策略组与分流规则，作为完整配置使用 | 配置热加载 |
| `auto`（默认） | 含 `proxy-groups` + `rules` 视为 `profile`，否则按 `proxies` 处理 | 同上 |

- 拉取使用 `SUB_USER_AGENT`（默认 `clash.meta`）请求头，订阅服务需返回 YAML 配置。
- 自动更新只替换「拉取成功且校验通过」的订阅；失败时保留旧文件并在面板/`gw subs` 中标记失败原因。
- 需要完全自定义分流时，编辑 `/data/config/overlay.yaml`（优先级高于订阅内容）。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `TZ` | `Asia/Shanghai` | 时区 |
| `TRANSPARENT_MODE` | `tproxy` | 透明代理模式：`tproxy` / `redir` / `off` |
| `GATEWAY_IF` | 自动识别 | 接管流量的接口，可用逗号指定多个（如 `eth0,eth1`） |
| `BYPASS_CIDRS` | `10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10` | 额外放行网段（这些目标地址不走透明代理） |
| `DNS_HIJACK` | `1` | 是否把外部 53 端口 DNS 请求劫持到内置 DNS |
| `IPV6_MODE` | `block` | IPv6 策略：`block` / `proxy` / `pass` |
| `SECRET` | 自动生成 | 管理面板与内核 API 访问密钥（同时写入 `/data/state/secret`） |
| `PANEL_AUTH` | `token` | 面板鉴权：`token` / `none` |
| `PANEL_PORT` | `8080` | 管理面板端口 |
| `MIXED_PORT` | `7890` | 混合端口（HTTP/SOCKS5） |
| `REDIR_PORT` | `7892` | REDIRECT 透明端口 |
| `TPROXY_PORT` | `7893` | TPROXY 透明端口 |
| `DNS_PORT` | `53` | 内置 DNS 监听端口 |
| `CONTROLLER_PORT` | `9090` | 内核 API / 完整面板端口 |
| `LOG_LEVEL` | 未设置 | 显式设置时强制注入日志级别（`debug`/`info`/`warning`/`error`/`silent`） |
| `SUB_UPDATE_INTERVAL` | `21600` | 订阅自动更新间隔（秒，`0` 关闭） |
| `SUB_UPDATE_ON_BOOT` | `0` | 启动时是否立即更新全部订阅 |
| `SUB_VIA_PROXY` | `1` | 订阅下载优先经内核链路，失败自动回退直连 |
| `SUB_TIMEOUT` | `30` | 单次订阅下载超时（秒） |
| `SUB_USER_AGENT` | `clash.meta` | 订阅请求 User-Agent |
| `STATS_LOG_INTERVAL` | `1800` | 流量摘要日志间隔（秒，`0` 关闭） |
| `GEO_UPDATE` | `1` | 是否启用地理数据自动更新（内核内置机制） |
| `FW_BACKEND` | `legacy` | iptables 后端：`legacy` / `nft` |
| `ACTIVE_PROFILE` | 空 | 首次启动时指定要激活的订阅名 |

## 数据目录

```
/data
├── config/                 # 用户可编辑（首次启动自动生成，升级不覆盖）
│   ├── subscriptions.yaml  #   订阅清单
│   └── overlay.yaml        #   覆盖层（优先级高于模板与订阅）
├── mihomo/                 # 内核工作目录（-d）
│   ├── config.yaml         #   合成后的运行配置（自动生成）
│   ├── profiles/           #   订阅原文（按名称保存，便于排查）
│   ├── providers/active.yaml  #  当前活跃的节点提供者
│   ├── ui/                 #   MetaCubeXD 完整面板
│   └── geoip.metadb 等     #   地理数据
├── state/                  # 状态：密钥、活跃订阅、订阅状态、流量采样、日志快照
└── log/
```

## 常见问题

**宿主机访问不了面板？** Linux 下 macvlan 容器与宿主机默认无法互通（macvlan 设计限制），请从局域网其它设备访问；
或为宿主机再建一个 macvlan 子接口后访问。`examples/docker-compose.bridge.yml` 提供网桥模式用于先验证功能。

**无线网卡能用吗？** 多数无线网卡不支持 macvlan，请使用有线网卡（`-o parent=eth0` 按实际网卡名调整）。

**透明代理没生效？** 检查容器是否具备 `NET_ADMIN`，`net.ipv4.ip_forward=1` 与 `rp_filter=0` 是否设置成功
（compose 中已声明 `sysctls`）；`docker exec mihomo-docker gw status` 会显示透明规则状态。

**只做普通加速容器（不接管转发）？** 设置 `TRANSPARENT_MODE=off`，按需映射端口（见 `examples/docker-compose.bridge.yml`）。

**IPv6 会被绕过吗？** 默认 `IPV6_MODE=block`，阻断网关转发方向的 IPv6 流量以避免绕过透明代理；
需要 IPv6 也走代理时设置 `IPV6_MODE=proxy`（尽力而为）。

**订阅拉取失败？** 面板与 `gw subs` 会给出失败原因；常见原因是订阅服务不支持 YAML 输出、
或网络不可达。内核启动后的下载会优先经内核链路，可改善部分订阅域名的可达性。

**如何升级内核？** 升级镜像即可：`docker compose pull && docker compose up -d`。用户配置与订阅数据都在 `/data`，不会被覆盖。

## 构建与开发

```bash
# 本地构建（需 Docker）
docker build -t local/mihomo-docker:dev .

# 无 Docker 的离线逻辑测试（需 yq、bash）
bash tests/offline.sh

# 镜像冒烟测试与透明链路测试（需 Docker）
IMAGE=local/mihomo-docker:dev bash tests/smoke.sh
IMAGE=local/mihomo-docker:dev bash tests/transparent-e2e.sh
```

仓库结构：`Dockerfile`（多阶段构建）、`docker/`（容器入口与运行时脚本）、`config/`（配置模板）、
`www/`（内置面板与 CGI 接口）、`tests/`（离线逻辑/冒烟/透明链路测试）、`examples/`（部署示例）、
`.github/workflows/`（CI：静态检查 → 镜像构建 → 验证 → 推送 ghcr.io）。

CI 门禁（PR 必须全绿）：
1. **静态检查**：shellcheck、YAML 校验、面板脚本语法、离线逻辑测试
2. **镜像构建**：多阶段构建出镜像（PR 阶段仅本地加载，不推送）
3. **验证**：面板/订阅/切换/流量冒烟测试 + netns 真实转发链路测试
4. **推送**：验证通过后才推送多架构镜像到 `ghcr.io/sakana-1314/mihomo-docker`

## 致谢与许可

- [mihomo](https://github.com/MetaCubeX/mihomo)（内核，Meta 分支）
- [MetaCubeXD](https://github.com/MetaCubeX/metacubexd)（完整面板）
- [yq](https://github.com/mikefarah/yq)、[meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)（地理数据）

本仓库以 MIT 许可发布（见 `LICENSE`）；镜像内捆绑的上游组件遵循其各自许可，上游许可原文保留在镜像的
`/usr/share/licenses/mihomo/LICENSE`。
