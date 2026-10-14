#!/usr/bin/env bash
# =============================================================================
# YAML 语法校验（仓库内全部 yaml/yml）
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

command -v yq >/dev/null 2>&1 || { echo "缺少 yq，请先安装（见 .github/workflows/build-image.yml）"; exit 2; }

fail=0
while IFS= read -r f; do
  if yq ea '.' "$f" > /dev/null 2>&1; then
    echo "  [通过] $f"
  else
    echo "  [失败] $f"
    yq ea '.' "$f" > /dev/null
    fail=1
  fi
done < <(find config examples tests .github -name '*.yaml' -o -name '*.yml' | sort)

if [ "$fail" -ne 0 ]; then
  echo "YAML 校验未通过"
  exit 1
fi
echo "YAML 校验通过"
