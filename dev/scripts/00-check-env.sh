#!/usr/bin/env bash
# 检查 .env 必填项 + 工具齐全
set -euo pipefail

cd "$(dirname "$0")/.."

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

fail=0

check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    red "❌ 缺少命令：$1（请安装：$2）"
    fail=1
  else
    green "✅ $1"
  fi
}

check_env() {
  local key="$1"
  local val="${!key:-}"
  if [[ -z "$val" ]]; then
    red "❌ 环境变量未设置：$key"
    fail=1
  else
    green "✅ $key=$val"
  fi
}

echo "=== 检查工具 ==="
check_cmd docker        "https://get.docker.com"
check_cmd jq            "apt install jq"
check_cmd envsubst      "apt install gettext-base"
check_cmd curl          "apt install curl"

echo ""
echo "=== 检查 .env 文件 ==="
if [[ ! -f .env ]]; then
  red "❌ .env 不存在，请先：cp .env.example .env"
  exit 1
fi
green "✅ .env 存在"

set +u
source .env
# v7 Flashblocks：如果存在 .env.flashblocks 也加载，保持跟 deploy 脚本一致
if [[ -f .env.flashblocks ]]; then
  source .env.flashblocks
  yellow "ℹ️  也加载了 .env.flashblocks（v7 模式覆盖：chainId=$L2_CHAIN_ID）"
fi
set -u

echo ""
echo "=== 检查必填变量 ==="
for v in PUBLIC_HOST L1_CHAIN_ID L2_CHAIN_ID L2_CHAIN_ID_HEX \
         DEPLOYER_PRIVATE_KEY BATCHER_PRIVATE_KEY PROPOSER_PRIVATE_KEY \
         SEQUENCER_PRIVATE_KEY OWNER_MULTISIG \
         NATIVE_TOKEN_NAME NATIVE_TOKEN_SYMBOL NATIVE_INITIAL_LIQUIDITY \
         L1_CONTRACTS_LOCATOR L2_CONTRACTS_LOCATOR \
         OP_DEPLOYER_IMAGE OP_GETH_IMAGE OP_NODE_IMAGE OP_BATCHER_IMAGE OP_PROPOSER_IMAGE; do
  check_env "$v"
done

echo ""
echo "=== 检查 docker daemon ==="
if docker info >/dev/null 2>&1; then
  green "✅ docker 可用"
else
  red "❌ docker daemon 不可达，请检查 docker 服务和当前用户是否在 docker 组"
  fail=1
fi

echo ""
echo "=== 检查 PUBLIC_HOST 形式 ==="
if [[ "$PUBLIC_HOST" == "" ]]; then
  red "❌ PUBLIC_HOST 必须填，否则 make info 给出的访问地址不可用"
  fail=1
elif [[ "$PUBLIC_HOST" == "localhost" || "$PUBLIC_HOST" == "127.0.0.1" ]]; then
  yellow "⚠️  PUBLIC_HOST=$PUBLIC_HOST 仅本机访问；远程团队需填外网 IP / 域名"
fi

echo ""
if [[ $fail -eq 0 ]]; then
  green "==> 所有检查通过"
else
  red "==> 有 $fail 项检查未通过，先修复再继续"
  exit 1
fi
