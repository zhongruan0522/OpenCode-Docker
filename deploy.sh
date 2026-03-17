#!/bin/bash
set -e

IMAGE="ghcr.io/zhongruan0522/opencode-docker:latest"
COMPOSE_FILE="docker-compose.yml"
ENV_FILE=".env"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
fail()  { echo -e "\033[1;31m[FAIL]\033[0m  $*" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in docker "docker compose"; do
        if ! command -v $cmd &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        fail "缺少依赖: ${missing[*]}，请先安装 Docker。"
    fi
}

info "检查依赖..."
check_deps
ok "依赖检查通过"

if [ ! -f "$COMPOSE_FILE" ]; then
    fail "未找到 $COMPOSE_FILE，请在项目根目录运行此脚本。"
fi

LOCAL_UID=$(id -u)
LOCAL_GID=$(id -g)
info "检测到当前用户 UID=$LOCAL_UID, GID=$LOCAL_GID"

if [ -f "$ENV_FILE" ]; then
    info "检测到已有 .env 文件："
    sed 's/OPENCODE_SERVER_PASSWORD=.*/OPENCODE_SERVER_PASSWORD=***/' "$ENV_FILE"
    read -rp "是否覆盖？[y/N]: " overwrite
    if [[ "$overwrite" != [yY] ]]; then
        info "保留现有配置，直接启动..."
        docker compose up -d
        ok "启动成功！访问 http://127.0.0.1:4096"
        exit 0
    fi
fi

echo ""
read -rp "请输入服务端用户名: " username
while [ -z "$password" ]; do
    read -rsp "请输入服务端密码: " password
    echo
done

read -rp "是否自定义端口？[当前默认 4096，直接回车跳过]: " port
port=${port:-4096}

cat > "$ENV_FILE" <<EOF
OPENCODE_SERVER_USERNAME=$username
OPENCODE_SERVER_PASSWORD=$password
LOCAL_UID=$LOCAL_UID
LOCAL_GID=$LOCAL_GID
PORT=$port
EOF
chmod 600 "$ENV_FILE"
ok ".env 已生成"

mkdir -p workspace .config
ok "目录已创建"

info "拉取镜像..."
docker compose pull 2>/dev/null || docker pull "$IMAGE"
ok "镜像就绪"

info "启动容器..."
docker compose up -d
ok "启动成功！"

echo ""
echo -e "\033[1;32m========================================\033[0m"
echo -e "\033[1;32m  OpenCode 已部署完成！\033[0m"
echo -e "\033[1;32m  访问地址: http://127.0.0.1:$port\033[0m"
echo -e "\033[1;32m  用户名:   $username\033[0m"
echo -e "\033[1;32m  工作目录: $(pwd)/workspace\033[0m"
echo -e "\033[1;32m  配置目录: $(pwd)/config\033[0m"
echo -e "\033[1;32m========================================\033[0m"
