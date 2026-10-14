# 部署示例

## macvlan 透明网关

```bash
docker network create -d macvlan \
  --subnet=192.168.1.0/24 --gateway=192.168.1.1 \
  -o parent=eth0 -o macvlan_mode=bridge mihomo_gw

mkdir -p data
docker compose -f docker-compose.macvlan.yml up -d
```

随后把设备的「默认网关 + DNS」指向 `192.168.1.250`（或在路由器 DHCP 中下发），
管理面板位于 `http://192.168.1.250:8080/`，访问密钥见容器日志（`docker logs mihomo-docker`）。

## 普通网桥（不接管转发）

```bash
docker compose -f docker-compose.bridge.yml up -d
```

面板：`http://<宿主机IP>:8080/`；完整面板：`http://<宿主机IP>:9090/ui/`。
