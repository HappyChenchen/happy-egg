# Relay 部署

生产入口为 `wss://happypuppy.io/ws`。Caddy 负责 TLS 和反向代理，Node.js relay 仅暴露在 Docker 内部网络。

## 前置条件

- 一台具有公网 IPv4 的 Linux 服务器
- Docker Engine 与 Docker Compose v2
- `happypuppy.io` 的 DNS A 记录指向服务器
- 防火墙允许 TCP 80 和 443

服务器不需要安装 Node.js；relay 在 Docker 镜像内运行。

## 首次部署

将仓库放到服务器，例如 `/opt/macpet`：

```sh
cd /opt/macpet
docker compose -f deploy/compose.yaml up -d --build
```

Caddy 会根据 `deploy/Caddyfile` 为域名申请证书，并把 `/ws` 与 `/health` 转发给 relay。

检查状态：

```sh
docker compose -f deploy/compose.yaml ps
docker compose -f deploy/compose.yaml logs --tail=100 relay caddy
curl -fsS https://happypuppy.io/health
```

健康检查预期返回：

```json
{"ok":true}
```

## 更新部署

代码更新后重新构建 relay：

```sh
cd /opt/macpet
docker compose -f deploy/compose.yaml up -d --build relay
docker compose -f deploy/compose.yaml ps
curl -fsS https://happypuppy.io/health
```

如果同时修改了 Caddy 或 Compose 配置，更新整个栈：

```sh
docker compose -f deploy/compose.yaml up -d --build
```

## 本地运行 Relay

```sh
npm ci --prefix relay
make relay
```

默认监听 `0.0.0.0:8080`：

```sh
curl -fsS http://localhost:8080/health
```

客户端生产构建默认连接公网地址。本地网页联动台可通过查询参数指定本地 relay：

```text
http://localhost:4173/web/?relay=ws://localhost:8080/ws
```

## 运维说明

- Relay 不使用数据库，重启会清空在线状态和未完成的配对房间。
- 客户端会自动重新注册在线状态；已经保存的长期好友不受影响。
- `relay` 容器以非 root 用户运行，并启用只读文件系统和 Docker 健康检查。
- 证书与 Caddy 状态保存在 `caddy_data`、`caddy_config` Docker volume 中。
- 部署前可在安装 Docker 的机器运行 `make deploy-config` 验证 Compose 配置。

## 故障排查

### `/health` 无法访问

```sh
docker compose -f deploy/compose.yaml ps
docker compose -f deploy/compose.yaml logs --tail=200 relay caddy
```

确认 DNS 指向当前服务器，并确认 80/443 未被其他进程占用。

### WebSocket 无法连接

先确认 HTTPS 健康检查正常，再查看 Caddy 日志中 `/ws` 的升级请求。Relay 只接受 `/ws` 路径，其他 WebSocket 路径会被关闭。

### 容器持续重启

```sh
docker compose -f deploy/compose.yaml logs --tail=200 relay
docker compose -f deploy/compose.yaml config
docker compose -f deploy/compose.yaml ps
```

不要把 SSH 私钥、Cloudflare API Token 或其他凭据提交到仓库。
