# OpenCode Docker

基于OpenCode、CodeServer打包的一个自用完整的开发环境

## 镜像变体

| Tag | 说明 |
|---|---|
| `vX.Y.Z`（无后缀） | slim 版（NoDesktop-Base）：不含远程桌面，体积更小，`FROM :base` |
| `vX.Y.Z-desktop` | 完整版（Desktop-Base）：XFCE4/xrdp 远程桌面（端口 3390），`FROM :desktop` |

docker-compose 默认使用 `-desktop` 完整版；不需要远程桌面时，把镜像 tag 换成同版本的无后缀 slim 版即可（桌面相关配置自动跳过）。
