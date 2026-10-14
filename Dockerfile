# syntax=docker/dockerfile:1

ARG MIHOMO_REF=Meta
ARG METACUBEXD_VERSION=v1.273.1
ARG ALPINE_VERSION=3.22
ARG GOLANG_VERSION=1.27

# ---------------------------------------------------------------- 编译（内核作为库，编译进同一个二进制）
FROM --platform=$BUILDPLATFORM golang:${GOLANG_VERSION}-alpine AS builder
ARG MIHOMO_REF
ARG TARGETOS TARGETARCH
ENV GOPROXY="https://proxy.golang.org|https://goproxy.cn|direct"
RUN apk add --no-cache git
WORKDIR /src

COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go get "github.com/metacubex/mihomo@${MIHOMO_REF}" \
 && go mod tidy

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    KERNEL_VERSION="$(go list -m -f '{{.Version}}' github.com/metacubex/mihomo)" \
 && echo "${KERNEL_VERSION}" > /out/kernel-version \
 && CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -tags with_gvisor -trimpath \
      -ldflags "-s -w -X main.version=${KERNEL_VERSION} -X github.com/metacubex/mihomo/constant.Version=${KERNEL_VERSION}" \
      -o /out/gw .

# ---------------------------------------------------------------- 运行时资产（完整面板与地理数据）
FROM alpine:${ALPINE_VERSION} AS assets
ARG MIHOMO_REF
ARG METACUBEXD_VERSION
RUN apk add --no-cache curl tar
RUN mkdir -p /out/ui /out/geo /out/licenses \
 && curl -fsSL "https://github.com/MetaCubeX/metacubexd/releases/download/${METACUBEXD_VERSION}/compressed-dist.tgz" \
      | tar -xz -C /out/ui \
 && curl -fsSL -o /out/geo/geoip.metadb "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb" \
 && curl -fsSL -o /out/geo/geosite.dat "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat" \
 && curl -fsSL -o /out/geo/geoip.dat "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat" \
 && curl -fsSL -o /out/licenses/mihomo-LICENSE "https://raw.githubusercontent.com/MetaCubeX/mihomo/${MIHOMO_REF}/LICENSE" \
 && [ -f /out/ui/index.html ]

# ---------------------------------------------------------------- 运行时
FROM alpine:${ALPINE_VERSION}
ARG MIHOMO_REF

LABEL org.opencontainers.image.title="mihomo-docker" \
      org.opencontainers.image.description="米哈游 API 加速网关：容器版透明网关，支持订阅自动更新、快捷切换与流量统计" \
      org.opencontainers.image.source="https://github.com/Sakana-1314/mihomo-docker" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${MIHOMO_REF}"

RUN apk add --no-cache ca-certificates tzdata iproute2 iptables iptables-legacy \
 && { command -v iptables >/dev/null 2>&1 || ln -sf "$(command -v iptables-legacy)" /usr/local/bin/iptables; } \
 && { command -v ip6tables >/dev/null 2>&1 || ln -sf "$(command -v ip6tables-legacy)" /usr/local/bin/ip6tables; } \
 && command -v iptables >/dev/null 2>&1 \
 && command -v ip6tables >/dev/null 2>&1

COPY --from=builder /out/gw /usr/local/bin/gw
COPY --from=assets /out/ui /usr/share/gw/ui
COPY --from=assets /out/geo /usr/share/gw/geo
COPY --from=assets /out/licenses /usr/share/licenses

VOLUME ["/data"]
EXPOSE 7890 7892 7893 8080 9090 53/tcp 53/udp

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/gw", "health"]

ENTRYPOINT ["/usr/local/bin/gw"]
