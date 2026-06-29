#!/usr/bin/env bash
# =============================================================================
# 一次性初始化：
#   1) 写 password.txt
#   2) 没有 validator keystore → 生成新的
#   3) 把 validator 地址写回 .env
#   4) 计算 Clique extraData（vanity 32B + signer 20B + sig 65B）
#   5) 渲染 genesis.json
#   6) 若 docker volume 还没初始化 → geth init 写入 genesis
#
# 幂等性：
#   - keystore 已存在 → 跳过生成，复用现有 validator
#   - genesis.json 会重新渲染（同 keystore 下结果一致）
#   - chaindata 已存在 → 跳过 geth init（保护已有数据，避免误删链）
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

: "${L1_CHAIN_ID:?L1_CHAIN_ID 未设置}"
: "${L1_BLOCK_TIME:?L1_BLOCK_TIME 未设置}"
: "${L1_GAS_LIMIT:?L1_GAS_LIMIT 未设置}"
: "${GETH_IMAGE:?GETH_IMAGE 未设置}"
: "${VALIDATOR_PASSWORD:?VALIDATOR_PASSWORD 未设置}"

mkdir -p keystore secrets workdir

# -----------------------------------------------------------------------------
# 1) 写 password.txt（chmod 600）
# -----------------------------------------------------------------------------
echo -n "${VALIDATOR_PASSWORD}" > secrets/password.txt
chmod 600 secrets/password.txt

# -----------------------------------------------------------------------------
# 2) 生成或复用 validator keystore
# -----------------------------------------------------------------------------
KEYSTORE_FILE="$(ls keystore/UTC--* 2>/dev/null | head -n1 || true)"

if [[ -z "$KEYSTORE_FILE" ]]; then
  echo "==> 没找到 validator keystore，生成新的（geth account new）..."
  docker run --rm \
    -v "$(pwd)/keystore:/keystore" \
    -v "$(pwd)/secrets:/secrets:ro" \
    "${GETH_IMAGE}" \
    account new --keystore /keystore --password /secrets/password.txt

  KEYSTORE_FILE="$(ls keystore/UTC--* | head -n1)"
  if [[ -z "$KEYSTORE_FILE" ]]; then
    echo "❌ keystore 生成失败" >&2
    exit 1
  fi
fi

# 修正 keystore 文件 owner（docker run 创建时是 root，host 端可能没权限读）
if [[ "$(stat -c '%u' "$KEYSTORE_FILE" 2>/dev/null || stat -f '%u' "$KEYSTORE_FILE")" == "0" ]]; then
  if command -v sudo >/dev/null; then
    sudo chown -R "$(id -u):$(id -g)" keystore || true
  fi
fi

VALIDATOR_ADDR_NO0X="$(jq -r '.address' "$KEYSTORE_FILE")"
VALIDATOR_ADDR="0x${VALIDATOR_ADDR_NO0X}"

echo "==> Validator 地址 : ${VALIDATOR_ADDR}"
echo "==> Keystore 文件 : ${KEYSTORE_FILE}"

# -----------------------------------------------------------------------------
# 3) 把 VALIDATOR_ADDRESS 写回 .env
# -----------------------------------------------------------------------------
if grep -qE '^VALIDATOR_ADDRESS=' .env; then
  sed -i.bak "s|^VALIDATOR_ADDRESS=.*|VALIDATOR_ADDRESS=${VALIDATOR_ADDR}|" .env
else
  echo "VALIDATOR_ADDRESS=${VALIDATOR_ADDR}" >> .env
fi
rm -f .env.bak

# -----------------------------------------------------------------------------
# 4) Clique extraData
#    格式：0x + vanity(32 bytes / 64 hex) + signer(20 bytes / 40 hex) + sig(65 bytes / 130 hex)
# -----------------------------------------------------------------------------
VANITY="$(printf '%064d' 0)"
SIG="$(printf '%0130d' 0)"
EXTRA_DATA="0x${VANITY}${VALIDATOR_ADDR_NO0X}${SIG}"

# 校验长度：234 hex chars + "0x" = 236
if [[ "${#EXTRA_DATA}" -ne 236 ]]; then
  echo "❌ extraData 长度异常 (${#EXTRA_DATA})，应为 236" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 5) 渲染 genesis.json
# -----------------------------------------------------------------------------
TS="$(date +%s)"
TS_HEX="$(printf '0x%x' "$TS")"
GAS_LIMIT_HEX="$(printf '0x%x' "${L1_GAS_LIMIT}")"

export L1_CHAIN_ID L1_BLOCK_TIME
export VALIDATOR_ADDRESS_NO0X="${VALIDATOR_ADDR_NO0X}"
export EXTRA_DATA
export GENESIS_TIMESTAMP_HEX="${TS_HEX}"
export L1_GAS_LIMIT_HEX="${GAS_LIMIT_HEX}"

envsubst < genesis.json.tpl > workdir/genesis.json
echo "==> 已渲染 workdir/genesis.json（已资助 validator）"

# -----------------------------------------------------------------------------
# 5b) 可选：给 dev 钱包预存 L1 ETH
#     DEV_FUND_ADDRESSES 为逗号/空格分隔的 0x 地址列表（在 .env 配置，默认空）。
#     留空则只有 validator 有余额；填了就给每个地址塞 10000 ETH。
#     生产环境请保持为空，资金通过桥接获取。
# -----------------------------------------------------------------------------
DEV_FUND_BAL_HEX="0x21e19e0c9bab2400000"  # 10000 * 10^18
if [[ -n "${DEV_FUND_ADDRESSES:-}" ]]; then
  echo "==> [DEV-ONLY] 给 dev 钱包预存 L1 ETH（每人 10000）..."
  for addr in ${DEV_FUND_ADDRESSES//,/ }; do
    lower="${addr,,}"; lower="${lower#0x}"
    if [[ ! "$lower" =~ ^[0-9a-f]{40}$ ]]; then
      echo "❌ DEV_FUND_ADDRESSES 含非法地址：$addr" >&2
      exit 1
    fi
    TMP_GENESIS="$(mktemp)"
    jq --arg a "$lower" --arg b "$DEV_FUND_BAL_HEX" \
      '.alloc[$a] = ((.alloc[$a] // {}) + {balance: $b})' \
      workdir/genesis.json > "$TMP_GENESIS"
    mv "$TMP_GENESIS" workdir/genesis.json
    echo "     0x${lower}  ->  ${DEV_FUND_BAL_HEX}"
  done
fi

# 简单校验：jq 能解析 + extraData 长度正确
if ! jq empty workdir/genesis.json 2>/dev/null; then
  echo "❌ workdir/genesis.json 不是合法 JSON" >&2
  exit 1
fi

# -----------------------------------------------------------------------------
# 6) geth init（幂等：chaindata 已存在则跳过）
# -----------------------------------------------------------------------------
HAS_CHAINDATA="$(docker run --rm \
  -v "mychain-l1-geth-data:/data" \
  --entrypoint sh \
  "${GETH_IMAGE}" \
  -c "[ -d /data/geth/chaindata ] && echo yes || echo no")"

if [[ "$HAS_CHAINDATA" == "yes" ]]; then
  echo "==> docker volume mychain-l1-geth-data 已存在 chaindata，跳过 geth init"
  echo "   想强制重建链：先 make clean"
else
  echo "==> 执行 geth init ..."
  docker run --rm \
    -v "mychain-l1-geth-data:/data" \
    -v "$(pwd)/workdir:/workdir:ro" \
    "${GETH_IMAGE}" \
    init --datadir /data /workdir/genesis.json
fi

echo ""
echo "✅ L1 init 完成"
echo ""
echo "  Validator     : ${VALIDATOR_ADDR}"
echo "  Chain ID      : ${L1_CHAIN_ID}"
echo "  Block time    : ${L1_BLOCK_TIME}s"
echo "  Genesis time  : $(date -d @${TS} '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -r ${TS} '+%Y-%m-%d %H:%M:%S %Z')"
echo "  Genesis ts hex: ${TS_HEX}"
echo ""
echo "下一步：make up"
