#!/usr/bin/env bash
set -euo pipefail

: "${PLAYWRIGHT_BROWSERS_PATH:=/home/app/.cache/ms-playwright}"

# 运行期 Python 包统一安装清单（Base 构建期在 final stage 执行，随镜像分发）。
#
# 与 base/go/preload-go-modules.sh 同理：清单收敛为独立文件 + 独立镜像层，
# 仅改清单只失效本层，不会拖累 builder 的 Playwright Chromium 下载、scrapling
# 浏览器安装、CodeGraph 等重层。运行期结果与原先 builder 内联安装一致：
# 单次 pip 解析，装入系统 site-packages（/usr/local/lib/python3*/dist-packages）。
# builder 内不再安装运行期包（仅有一次性 venv 供浏览器层跑 scrapling 安装器），
# 保证 final stage 对全部包做单次统一解析。
#
# 维护约定：
# - 保持排序（sort -f 顺序），便于 diff 和复用 Docker 缓存；
# - 不要手工添加"以后可能用到"的包——每个条目都应有真实出处，否则只会白白增大镜像；
# - 改动推送后由 build-base.yml 重建 Base 层，并级联重建桌面层与动态层。
xargs -r python3 -m pip install --no-cache-dir --break-system-packages <<'PACKAGES'
arjun
asyncpg
asyncssh
bloodhound
"chardet>=5.2.0,<6"
charset-normalizer
click
defusedxml
docker
fastapi
frida-tools
httpx
httpx-sse
impacket
jsonschema
mcp
numpy
openai
openai-agents
openpyxl
pdf2image
pdfplumber
Pillow
pydantic
pydantic-settings
PyJWT
PyMuPDF
pypdf
python-docx
python-dotenv
python-multipart
python-pptx
PyYAML
reportlab
requests
"scrapling[all]>=0.4.2"
SQLAlchemy
sqlmodel
sse-starlette
tiktoken
tqdm
uro
"uvicorn[standard]"
websockets
PACKAGES

# 把 Python playwright 期望的 chromium 修订版对齐到已下载的浏览器缓存。
# 浏览器由 Node 侧 Playwright 在 builder 下载，Python 侧只建符号链接补齐自身
# 期望的修订版目录名，不重复下载。对齐放在 final stage（而非 builder）：
# final 的 Python 包版本由本层决定，可与缓存的 builder 构建期版本解耦。
python_pw_revision="$(python3 -m playwright install --dry-run chromium 2>&1 \
    | grep -oPm1 'chromium v\K[0-9]+')"
node_revision="$(ls -d "${PLAYWRIGHT_BROWSERS_PATH}"/chromium-* 2>/dev/null \
    | grep -oP 'chromium-\K[0-9]+' | sort -rn | head -n 1)"

if [ -z "${python_pw_revision}" ]; then
    echo "WARN: cannot detect Python playwright chromium revision, skip alignment" >&2
elif [ -z "${node_revision}" ]; then
    echo "WARN: no chromium-* found under ${PLAYWRIGHT_BROWSERS_PATH}, skip alignment" >&2
elif [ "${python_pw_revision}" = "${node_revision}" ]; then
    echo "Python playwright revision matches cache (${node_revision}), no symlink needed"
else
    echo "Symlinking chromium-${python_pw_revision} -> chromium-${node_revision} for Python playwright"
    ln -sfn "${PLAYWRIGHT_BROWSERS_PATH}/chromium-${node_revision}" \
        "${PLAYWRIGHT_BROWSERS_PATH}/chromium-${python_pw_revision}"
    if [ -d "${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${node_revision}" ]; then
        ln -sfn "${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${node_revision}" \
            "${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-${python_pw_revision}"
    fi
fi
