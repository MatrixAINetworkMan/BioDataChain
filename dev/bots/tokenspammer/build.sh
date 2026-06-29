#!/usr/bin/env bash
# =============================================================================
# 用 docker 里的 foundry stable 编译 contracts/{TestERC20,BatchTransfer}.sol。
# 产物直接放在 contracts/out/ 下，tokenspammer.js 直接读，无需中间合并。
#
# host 不需要装 forge / solc / jq / node。
#
# 用法：
#   bash build.sh
# 或通过 Makefile：
#   make bot-token-build
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")"

FOUNDRY_IMG="${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:stable}"

echo "==> forge build（容器：$FOUNDRY_IMG）"
docker run --rm \
  -v "$PWD/contracts:/work" \
  -w /work \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  --entrypoint forge \
  "$FOUNDRY_IMG" build --silent

ART_ERC20="contracts/out/TestERC20.sol/TestERC20.json"
ART_BATCH="contracts/out/BatchTransfer.sol/BatchTransfer.json"
[[ -f "$ART_ERC20" ]] || { echo "❌ 编译失败，找不到 $ART_ERC20"; exit 1; }
[[ -f "$ART_BATCH" ]] || { echo "❌ 编译失败，找不到 $ART_BATCH"; exit 1; }

echo ""
echo "✅ 编译完成"
echo "   $ART_ERC20"
echo "   $ART_BATCH"
