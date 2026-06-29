#!/usr/bin/env bash
# op-deployer：生成 L2 genesis.json + rollup.json
set -euo pipefail

cd "$(dirname "$0")/.."

set -a
source .env
# v7 Flashblocks 模式：覆盖 L2_CHAIN_ID / L2_CHAIN_ID_HEX，确保 op-deployer
# 生成的 genesis.json/rollup.json 跟 runtime 容器 env 一致（都用 175700）。
# 没这行的话 op-geth 启动 --networkid=175700（来自 docker env）但 genesis
# chainId=42170（来自这里渲染）→ bundle-proxy 报 chainId mismatch、dApp tx 被拒。
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

# 注意：不要跑 `apply --deployment-target genesis`，那会让 op-deployer 生成一个
# 自己虚构的 L1 dev genesis，rollup.json 里的 L1 hash 就跟 anvil 真实 genesis 对不上。
# apply 阶段（已在 01-deploy-l1.sh 里跑过）已经把 anvil 的 startBlock 写进 state.json，
# inspect 直接读这个就能拿到正确的 rollup.json。

# --no-deps：理由同 01-deploy-l1.sh（external-L1 模式 anvil 被 profile 关闭）。
echo "==> 步骤 1/2：inspect genesis 提取 L2 genesis.json..."
docker compose --env-file .env --profile deploy run --rm --no-deps op-deployer \
  inspect genesis \
  --workdir /workdir \
  "$L2_CHAIN_ID_HEX" \
  > workdir/shared/genesis.json

echo "==> 步骤 2/2：inspect rollup 提取 rollup.json..."
docker compose --env-file .env --profile deploy run --rm --no-deps op-deployer \
  inspect rollup \
  --workdir /workdir \
  "$L2_CHAIN_ID_HEX" \
  > workdir/shared/rollup.json

if [[ ! -s workdir/shared/genesis.json || ! -s workdir/shared/rollup.json ]]; then
  echo "❌ inspect 输出为空" >&2
  ls -la workdir/shared/ >&2
  exit 1
fi

if [[ ! -f workdir/shared/jwt.txt ]]; then
  openssl rand -hex 32 > workdir/shared/jwt.txt
fi

# ---------------------------------------------------------------------------
# 覆盖 rollup.json 的 block_time（op-deployer v0.6.0 默认生成 2s，未在 intent
# 暴露开关）。op-node / op-batcher / op-geth 都从 rollup.json 读这个数。
# ---------------------------------------------------------------------------
ROLLUP_BT_DEFAULT=$(jq -r '.block_time' workdir/shared/rollup.json)
if [[ "${L2_BLOCK_TIME}" != "${ROLLUP_BT_DEFAULT}" ]]; then
  echo "==> 覆盖 rollup.json block_time: ${ROLLUP_BT_DEFAULT}s -> ${L2_BLOCK_TIME}s ..."
  TMP_ROLLUP=$(mktemp)
  jq --argjson bt "${L2_BLOCK_TIME}" '.block_time = $bt' \
    workdir/shared/rollup.json > "$TMP_ROLLUP"
  mv "$TMP_ROLLUP" workdir/shared/rollup.json
fi

# ---------------------------------------------------------------------------
# DEV-ONLY：往 genesis.json alloc 注入 dev 账户余额
#
# CGT v2 设计上所有原生币锁在 NAL（NativeAssetLiquidity）里，op-deployer 不会
# 给任何 EOA 预存余额（fundDevAccounts 在 CGT v2 链下被无视）。这导致 deployer
# 自己也没 gas，无法调 LiquidityController 释放流动性 —— 死循环。
#
# dev workaround：直接 patch genesis.json，给 5 个 dev 角色账户各塞 10000 MAN。
# 这会改变 L2 genesis hash，所以紧接着 init-geth 之后还要 patch rollup.json。
# 上 Sepolia/mainnet 时不要这么做：那时通过 OptimismPortal/桥接获取流动性。
# ---------------------------------------------------------------------------
DEV_BAL_HEX="0x21e19e0c9bab2400000"  # 10000 * 10^18 = 0x21e19e0c9bab2400000

echo "==> [DEV-ONLY] 往 genesis.json 注入 dev 账户余额（每人 10000 MAN）..."
TMP_GENESIS=$(mktemp)
jq \
  --arg dep "${DEPLOYER_ADDRESS,,}" \
  --arg seq "${SEQUENCER_ADDRESS,,}" \
  --arg bat "${BATCHER_ADDRESS,,}" \
  --arg pro "${PROPOSER_ADDRESS,,}" \
  --arg cha "${CHALLENGER_ADDRESS,,}" \
  --arg bal "$DEV_BAL_HEX" \
  '
  def addalloc(addr; balance):
    .alloc[(addr | sub("^0x"; ""))] = (
      (.alloc[(addr | sub("^0x"; ""))] // {}) + {balance: balance}
    );
  addalloc($dep; $bal)
  | addalloc($seq; $bal)
  | addalloc($bat; $bal)
  | addalloc($pro; $bal)
  | addalloc($cha; $bal)
  ' workdir/shared/genesis.json > "$TMP_GENESIS"
mv "$TMP_GENESIS" workdir/shared/genesis.json

# 显示注入结果
echo "   注入后 dev 账户余额："
for addr in "$DEPLOYER_ADDRESS" "$SEQUENCER_ADDRESS" "$BATCHER_ADDRESS" "$PROPOSER_ADDRESS" "$CHALLENGER_ADDRESS"; do
  lower="${addr,,}"; lower="${lower#0x}"
  bal=$(jq -r ".alloc.\"$lower\".balance // \"-\"" workdir/shared/genesis.json)
  echo "     $addr  ->  $bal"
done

# 生成 anvil L1 的 chain config
# op-node v1.16+ 要求自定义 L1 必须传 --rollup.l1-chain-config，
# 且实测必须用 genesis.json 嵌套格式（虽然文档说两种都行，扁平格式会报 missing JSON field "config"）
cat > workdir/shared/l1-chain-config.json <<EOF
{
  "config": {
    "chainId": ${L1_CHAIN_ID},
    "homesteadBlock": 0,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "arrowGlacierBlock": 0,
    "grayGlacierBlock": 0,
    "mergeNetsplitBlock": 0,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "pragueTime": 0,
    "terminalTotalDifficulty": 0,
    "blobSchedule": {
      "cancun": {
        "target": 3,
        "max": 6,
        "baseFeeUpdateFraction": 3338477
      },
      "prague": {
        "target": 6,
        "max": 9,
        "baseFeeUpdateFraction": 5007109
      }
    }
  }
}
EOF

chmod 644 workdir/shared/*.json workdir/shared/jwt.txt

echo ""
echo "✅ genesis.json / rollup.json / jwt.txt 已就绪："
ls -la workdir/shared/

echo ""
echo "==> 验证 genesis 中的 CGT v2 配置..."
ETH_TOKEN_ADDR=$(jq -r '.config.ethereumTokenAddress // empty' workdir/shared/genesis.json 2>/dev/null || true)
if [[ -n "$ETH_TOKEN_ADDR" ]]; then
  echo "   ethereumTokenAddress = $ETH_TOKEN_ADDR"
fi

# NativeAssetLiquidity predeploy = 0x4200000000000000000000000000000000000029（v6.0.0）
NAL_BAL=$(jq -r '.alloc."4200000000000000000000000000000000000029".balance // empty' workdir/shared/genesis.json)
if [[ -n "$NAL_BAL" && "$NAL_BAL" != "0x0" ]]; then
  echo "   ✅ NativeAssetLiquidity (0x4200..0029) 余额 = $NAL_BAL"
else
  echo "   ⚠️ NativeAssetLiquidity 余额异常 = $NAL_BAL"
fi

# LiquidityController predeploy = 0x420000000000000000000000000000000000002A（v6.0.0）
LC_CODE=$(jq -r '.alloc."420000000000000000000000000000000000002a".code // empty' workdir/shared/genesis.json)
if [[ -n "$LC_CODE" && "$LC_CODE" != "0x" ]]; then
  echo "   ✅ LiquidityController (0x4200..002A) 已部署 (code 长度: ${#LC_CODE})"
else
  echo "   ⚠️ LiquidityController 未在 genesis 出现"
fi
