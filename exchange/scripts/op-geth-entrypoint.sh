#!/bin/sh
# op-geth 入口包装：首次启动自动 geth init，之后幂等直接 exec geth
# 这样交易所只需 docker compose up -d 一个命令，无需单独的 init 步骤
set -e

DATADIR=/data/geth
SCHEME="${OP_GETH_STATE_SCHEME:-path}"

if [ ! -d "${DATADIR}/geth/chaindata" ]; then
  echo "==> 首次启动：初始化 op-geth (state.scheme=${SCHEME}) ..."
  geth init --datadir="${DATADIR}" --state.scheme="${SCHEME}" /shared/genesis.json
  echo "==> 初始化完成"
else
  echo "==> op-geth 数据目录已存在，跳过 init"
fi

# "$@" 是 compose 里 command 传入的 geth 运行参数
exec geth "$@"
