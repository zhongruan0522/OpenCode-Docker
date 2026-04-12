# OpenCode Docker

OpenCode 的 Docker 镜像，包含常用开发工具，并内置同容器运行的 code-server。

现在容器里会同时启动这两个服务：

OpenCode Web：默认宿主机 `4096`

code-server：默认宿主机 `127.0.0.1:18080`，适合交给 1Panel / Nginx 反向代理后再挂域名

## 官方文档

code-server 官方部署与安全指南：<https://coder.com/docs/code-server/latest/guide>

code-server 官方安装文档：<https://coder.com/docs/code-server/latest/install>

code-server FAQ（包含密码、哈希密码、端口配置）：<https://coder.com/docs/code-server/latest/FAQ>

## 环境变量

除了原有的 OpenCode 环境变量，还需要额外配置 code-server 的认证。

推荐优先使用 `CODE_SERVER_HASHED_PASSWORD`，这样宿主机不需要保存明文密码。如果只是临时测试，也可以直接设置 `CODE_SERVER_PASSWORD`。

示例：

```env
OPENCODE_SERVER_USERNAME=your-name
OPENCODE_SERVER_PASSWORD=your-opencode-password

CODE_SERVER_PORT=18080
# 二选一，推荐使用哈希密码
CODE_SERVER_PASSWORD=
CODE_SERVER_HASHED_PASSWORD=
```

## 生成 code-server 哈希密码

官方 FAQ 推荐使用 Argon2。你可以在本机直接运行：

```bash
echo -n '你的密码' | npx argon2-cli -e
```

如果你是把哈希**直接写进 docker-compose.yml**，官方要求把每个 `$` 写成 `$$`。但如果你是放进 `.env` 文件里，通常保持原样即可。

## 部署建议

当前 compose 默认把 code-server 绑定到 `127.0.0.1:${CODE_SERVER_PORT:-18080}`，这样不会直接暴露到公网，更适合配合 1Panel 套域名和 HTTPS。

比较稳的做法是：

给 OpenCode 和 code-server 分别配两个子域名，然后在 1Panel 里反向代理到对应的本地端口。

比如：

`open.your-domain.com -> 127.0.0.1:4096`

`code.your-domain.com -> 127.0.0.1:18080`

这样浏览器访问 code-server 时会走你自己的域名和证书，webview、扩展登录、PWA 这些体验也会更完整。

## 启动

```bash
docker compose up -d
```

启动后：

OpenCode 访问你映射的 `4096` 端口或对应域名。

code-server 访问你映射的 `18080` 端口，或者更推荐直接走反向代理后的域名。
