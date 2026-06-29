#!/usr/bin/env bash
# 把 intent.toml.example envsubst 成 workdir/intent.toml
set -euo pipefail

cd "$(dirname "$0")/.."

set -a
source .env
# v7 Flashblocks 模式：覆盖 chainId / 镜像版本等
# deploy 阶段必须读这个，不读则 intent.toml 仍按 v6 老 chainId 渲染，
# 跟 runtime 容器 env 不一致 → genesis chainId 跟容器 --networkid 矛盾。
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

mkdir -p workdir/shared

# 兼容 NATIVE_TOKEN_NAME 里包含双引号的写法（toml 字符串需要双引号包裹）
# .env 里写法："Matrix AI Network"  → 出来已经带引号
export NATIVE_TOKEN_NAME

envsubst < intent.toml.example > workdir/intent.toml

echo "✅ 已生成 workdir/intent.toml"
echo ""
echo "----- workdir/intent.toml -----"
cat workdir/intent.toml
echo "-------------------------------"
