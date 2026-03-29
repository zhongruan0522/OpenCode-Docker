# OpenCode Docker

OpenCode 的 Docker 镜像，包含常用开发工具。

已内置 Playwright MCP（浏览器自动化）及 Chromium，并默认以 headless + no-sandbox 方式运行，适配大多数容器环境。

同时补齐了几类高频 Skills 的运行时依赖，避免“技能已加载但环境跑不动”：

- Office / 文档类：LibreOffice、Pandoc、Poppler、Noto CJK 字体
- Python 数据类：pandas、openpyxl、markitdown、Pillow
- 生成类：docx、pptxgenjs
- 抓取类：Scrapling 及其浏览器依赖
- 开发辅助：ripgrep、GitHub CLI、Bun、Go

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

## 关于 Skills 的建议

这个镜像更适合走“保留技能、补齐环境”的思路，而不是一开始就大量删减 Skills。

原因很简单：Skills 本身大多只是提示词和参考资料，真正容易出问题的是底层运行时缺依赖。把环境补齐之后，像 `docx`、`pptx`、`xlsx`、`webapp-testing`、`scrapling-official` 这些重型 Skills 才会真正变成开箱即用。
