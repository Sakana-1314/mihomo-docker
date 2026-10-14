# AGENTS.md

mihomo-docker（米哈游 API 加速网关）。事实标准以代码与各目录内文档为准，本文件不重复实现细节与历史决策。

## 唯一约定

**禁止未经明确授权修改 AGENTS.md。** 未获得用户明确授权，任何智能体不得增删改本文件。

## 定位口径

本仓库对外定位为「基于米哈游 API 的容器化网络加速网关」，所有文档、注释、提交信息、镜像描述一律沿用该口径：

- 不引入与该定位无关的用途描述或第三方项目叙事。
- 技术术语（透明网关、上游订阅、分流、流量统计）按事实描述，不臆造功能。
- 面向用户可见的文案（README、面板、启动日志首行、镜像 DESCRIPTION）保持同一口径。

## 目录

- `Dockerfile` - 镜像构建（多阶段：内核编译 → 面板与地理数据资产 → 运行时）
- `docker/` - 容器入口与运行时脚本（POSIX sh，需兼容 busybox ash，勿用 bash 专有语法）
- `config/` - 配置模板（`template.yaml` 骨架、`overlay.yaml` 覆盖层、`subscriptions.yaml` 订阅清单）
- `www/` - 内置管理面板（静态页 + `cgi-bin/` CGI 接口）
- `tests/` - 离线逻辑测试、镜像冒烟测试、透明链路测试
- `examples/` - 部署示例（macvlan 透明网关、普通网桥）
- `.github/workflows/` - CI/CD 工作流

根目录只放 `AGENTS.md`、`LICENSE`、`README.md`、`Dockerfile`、`.gitignore`、`.gitattributes`、`.dockerignore`；其余文档与脚本放进所属目录内部。

## notes

`notes/` 用于存放本地资料：机密文件、测试服务器、生产服务器相关信息。

- 不得进入 git，必须在 `.gitignore` 中忽略（`notes/`）。
- 只留本地，不复用、不外传、不复制进仓库其它目录。

## 协作与提交

- 作者与提交者统一为 `Sakana <admin@yangrucheng.top>`。
- 必须走 PR：`gh pr create` → 等 `构建镜像` 工作流三道门禁全绿 → `gh pr merge --squash` 并删除 head 分支；禁止本地 merge 后直推 `main`（会把 PR 关成 CLOSED 而非 MERGED）。
- 分支前缀 `feat/`、`fix/`、`refactor/`、`docs/`、`chore/`；提交信息中文，格式 `type(scope): 描述`。
- 工作流 `name` 用中文（专有名词除外）；严禁硬编码 IP、密钥与内部域名，一律 `${{ secrets.* }}` 或示例占位。

## 验证门禁

- 所有改动必须通过 `构建镜像` 工作流：`静态检查`（shellcheck + YAML 校验 + 面板脚本语法 + 离线逻辑测试）→ `镜像构建` → `冒烟测试` 与 `透明链路测试`；**验证通过后才推送镜像**。
- 内核与资产版本固定在 `Dockerfile` 的 `ARG MIHOMO_VERSION` / `ARG METACUBEXD_VERSION` / `ARG YQ_VERSION`，升级走独立 PR。
- 涉及 `docker/`、`config/`、`www/` 的行为变更，必须在 `tests/` 中补充或更新断言（优先写进离线测试；需要内核或转发能力时补到 `tests/smoke.sh`、`tests/transparent-e2e.sh`）。
- 本地自检：

```bash
shellcheck -s sh docker/*.sh docker/gw www/cgi-bin/*.sh
shellcheck tests/*.sh
bash tests/check-yaml.sh
bash tests/offline.sh
```

## 实现约束（改动前必读）

- 跨脚本复用的函数（含订阅元数据读取）一律放 `docker/lib.sh`，不要跨脚本调用未定义函数；环境变量与路径常量同样集中在 `lib.sh`。
- yq 表达式：flow 映射的键必须加引号（如 `{"name": .key}`），否则本仓库固定的 yq 版本会报词法错误。
- 透明代理（`tproxy` 模式）依赖：`ip rule fwmark 0x1 → table 100`、`ip route local default dev lo table 100`、`net.ipv4.ip_forward=1`、`rp_filter=0`；只有具备全局地址的接口才会下发规则，新增接口后需重新执行 `gw firewall setup`。
- 内核配置合成顺序为「骨架模板或订阅 → `overlay.yaml` → `runtime.yaml`」，后合并者优先；数组整体替换、对象递归合并。运行时注入项（端口/密钥/控制器/UI）由环境变量生成，用户不可在 `overlay.yaml` 中覆盖。
- 切换订阅前必须先通过内核配置校验（`mihomo -t`），校验失败不得替换现行配置。
