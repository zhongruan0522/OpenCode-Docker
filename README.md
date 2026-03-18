# OpenCode Docker

OpenCode 的 Docker 镜像，包含常用开发工具。

已内置 Playwright MCP（浏览器自动化）及 Chromium，并默认以 headless + no-sandbox 方式运行，适配大多数容器环境。

## 一键部署

```bash
bash deploy.sh
```

脚本会引导你完成所有配置并自动启动。

## 启用浏览器 MCP（Playwright）

`deploy.sh` 会在首次运行时自动生成 `.config/opencode/opencode.json`，并启用 Playwright MCP：

- MCP server 名称：`playwright`
- 启动命令：`playwright-mcp --headless --browser chromium --no-sandbox`
- 浏览器路径：`/home/app/.cache/ms-playwright`

如果你已有自己的 OpenCode 配置文件，只需要把对应的 `mcp.playwright` 配置合并进去即可。
