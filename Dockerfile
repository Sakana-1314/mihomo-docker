# syntax=docker/dockerfile:1

# =============================================================================
# 米哈游 API 加速网关（mihomo-docker）
#   多阶段构建：内核编译 → 面板与地理数据资产 → 精简运行时
#   内核版本与资产版本以 ARG 固定，升级走独立 PR
# =============================================================================

ARG MIHOMO_VERSION=v1.19.32
ARG METACUBEXD_VERSION=v1.273.1
ARG YQ_VERSION=v4.47.1
ARG ALPINE_VERSION=3.22
ARG GOLANG_VERSION=1.26

# ---------------------------------------------------------------- 内核编译
FROM --platform=$BUILDPLATFORM golang:${GOLANG_VERSION}-alpine AS kernel
ARG MIHOMO_VERSION
ARG TARGETOS TARGETARCH
# 模块代理带兜底（| 表示任意错误即切换下一个），go.sum 校验保证完整性
ENV GOPROXY="https://proxy.golang.org|https://goproxy.cn|direct"
RUN apk add --no-cache git
WORKDIR /src
RUN git clone --depth 1 --branch "${MIHOMO_VERSION}" https://github.com/MetaCubeX/mihomo.git .

# 依赖下载独立成层：网络抖动可重试，配合模块缓存提升重复构建效率
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download || { echo "依赖下载失败，重试…"; sleep 5; go mod download; }

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -tags "with_gvisor" -trimpath \
      -ldflags "-X github.com/metacubex/mihomo/constant.Version=${MIHOMO_VERSION} -w -s -buildid=" \
      -o /out/mihomo

# ---------------------------------------------------------------- 运行时资产
FROM alpine:${ALPINE_VERSION} AS assets
ARG MIHOMO_VERSION
ARG METACUBEXD_VERSION
ARG YQ_VERSION
ARG TARGETARCH
RUN apk add --no-cache curl tar
RUN mkdir -p /out/ui /out/geo /out/bin \
 && curl -fsSL "https://github.com/MetaCubeX/metacubexd/releases/download/${METACUBEXD_VERSION}/compressed-dist.tgz" \
      | tar -xz -C /out/ui \
 && curl -fsSL -o /out/geo/geoip.metadb "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" \
 && curl -fsSL -o /out/geo/geosite.dat "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" \
 && curl -fsSL -o /out/geo/geoip.dat "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat" \
 && curl -fsSL -o /out/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
 && chmod +x /out/bin/yq \
 && curl -fsSL -o /out/mihomo-LICENSE "https://raw.githubusercontent.com/MetaCubeX/mihomo/${MIHOMO_VERSION}/LICENSE" \
 && [ -f /out/ui/index.html ]

# ---------------------------------------------------------------- 运行时
FROM alpine:${ALPINE_VERSION}
ARG MIHOMO_VERSION

LABEL org.opencontainers.image.title="mihomo-docker" \
      org.opencontainers.image.description="米哈游 API 加速网关：mihomo 内核容器版，支持透明网关（macvlan）、订阅自动更新、快捷切换与流量统计" \
      org.opencontainers.image.source="https://github.com/Sakana-1314/mihomo-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${MIHOMO_VERSION}"

# 运行依赖：curl（订阅与 API）、iproute2（策略路由）、iptables + legacy（透明代理）、yq（配置合成）
RUN apk add --no-cache ca-certificates tzdata curl iproute2 iptables iptables-legacy \
 && { command -v iptables >/dev/null 2>&1 || ln -sf "$(command -v iptables-legacy)" /usr/local/bin/iptables; } \
 && { command -v ip6tables >/dev/null 2>&1 || ln -sf "$(command -v ip6tables-legacy)" /usr/local/bin/ip6tables; } \
 && command -v iptables >/dev/null 2>&1 \
 && command -v ip6tables >/dev/null 2>&1

WORKDIR /app

COPY --from=kernel /out/mihomo /usr/local/bin/mihomo
COPY --from=assets /out/bin/yq /usr/local/bin/yq
COPY --from=assets /out/mihomo-LICENSE /usr/share/licenses/mihomo/LICENSE
COPY --from=assets /out/ui /usr/share/gw/ui
COPY --from=assets /out/geo /usr/share/gw/geo
COPY config/ /usr/share/gw/config/
COPY docker/ /app/docker/
COPY www/ /www/

RUN chmod +x /app/docker/*.sh /app/docker/gw /www/cgi-bin/*.sh /usr/local/bin/mihomo /usr/local/bin/yq \
 && ln -sf /app/docker/gw /usr/local/bin/gw \
 && mihomo -v \
 && yq --version \
 && yq eval '.' /usr/share/gw/config/template.yaml > /dev/null \
 && yq eval '.' /usr/share/gw/config/overlay.yaml > /dev/null

VOLUME ["/data"]
EXPOSE 7890 7892 7893 8080 9090 53/tcp 53/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD ["/app/docker/healthcheck.sh"]

ENTRYPOINT ["/app/docker/entrypoint.sh"]
