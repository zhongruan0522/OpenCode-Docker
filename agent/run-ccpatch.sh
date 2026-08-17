#!/usr/bin/env bash
#
# 遍历并执行 agent/ccpatch/ 下的所有 Claude Code 补丁脚本。
#
# 兼容性设计：
#   - 未来往 ccpatch/ 新增 .sh 脚本，无需修改本文件或 Dockerfile，glob 自动拾取；
#   - 单个脚本失败只打印告警，继续执行后续脚本，最终退出码恒为 0（不阻断镜像构建）；
#   - 不依赖脚本的可执行位，统一用 bash 显式调用；
#   - 补丁目录可用 CCPATCH_DIR 环境变量覆盖（便于本地测试）。
#
# 注意：本文件放在 agent/（父目录）而非 agent/ccpatch/ 内，
# 避免被 ccpatch/*.sh 的 glob 自匹配导致重复执行自身。

set -u

CCPATCH_DIR="${CCPATCH_DIR:-/opt/ccpatch}"

if [[ ! -d "${CCPATCH_DIR}" ]]; then
    echo "[ccpatch] 目录不存在，跳过: ${CCPATCH_DIR}" >&2
    exit 0
fi

shopt -s nullglob
scripts=( "${CCPATCH_DIR}"/*.sh )
shopt -u nullglob

if [[ ${#scripts[@]} -eq 0 ]]; then
    echo "[ccpatch] 未找到任何 *.sh 补丁脚本: ${CCPATCH_DIR}"
    exit 0
fi

total=0
failed=0

for script in "${scripts[@]}"; do
    total=$((total + 1))
    echo ""
    echo "==> [ccpatch] 执行: $(basename "${script}")"
    if bash "${script}"; then
        echo "==> [ccpatch] 成功: $(basename "${script}")"
    else
        rc=$?
        failed=$((failed + 1))
        echo "==> [ccpatch] 警告: $(basename "${script}") 失败 (exit ${rc})，跳过继续" >&2
    fi
done

echo ""
echo "[ccpatch] 完成: $((total - failed))/${total} 成功, ${failed} 失败（失败不阻断构建）"
exit 0
