#!/usr/bin/env bash
# op-deployer apply：在 anvil 上部署 L1 合约（含 CGT v2）
set -euo pipefail

cd "$(dirname "$0")/.."

set -a
source .env
# v7 Flashblocks 模式：覆盖 chainId，跟 deploy-genesis / runtime 一致
[[ -f .env.flashblocks ]] && source .env.flashblocks
set +a

if [[ ! -f workdir/intent.toml ]]; then
  echo "❌ 没找到 workdir/intent.toml，先 make render-intent" >&2
  exit 1
fi

# op-deployer apply 要求 state.json 存在且有 version 字段；首次部署给一个最小骨架
if [[ ! -f workdir/state.json ]]; then
  echo '{"version":1,"create2Salt":"0x0000000000000000000000000000000000000000000000000000000000000000","appliedIntent":null,"opChainDeployments":[]}' > workdir/state.json
  echo "==> 创建初始 workdir/state.json (version=1)"
fi

echo "==> 在 L1 上部署 L1 合约（约 2-5 分钟）..."

# --no-deps：op-deployer 在 base compose 里 depends_on: anvil。
# - anvil 模式：anvil 在 `make l1-up` 时已起好，跳过依赖检查无害。
# - external-L1 模式 (docker-compose.external-l1.yml override)：anvil 被 profile
#   关闭，如果不加 --no-deps，compose 会尝试 start 一个 disabled 的 service 报错。
docker compose --env-file .env --profile deploy run --rm --no-deps op-deployer \
  apply \
  --workdir /workdir \
  --l1-rpc-url "$L1_RPC_URL_INTERNAL" \
  --private-key "${DEPLOYER_PRIVATE_KEY#0x}"

if [[ ! -f workdir/state.json ]]; then
  echo "❌ op-deployer 没有生成 workdir/state.json" >&2
  exit 1
fi

echo ""
echo "✅ L1 合约部署完成"
echo ""
echo "==> 提取关键地址到 workdir/shared/l1-addresses.env ..."
mkdir -p workdir/shared

# 从 state.json 提取核心地址（v0.6.0 schema：opChainDeployments[].XxxProxy 大驼峰）
jq -r '
  .opChainDeployments[0] as $c |
  .superchainContracts as $s |
  "L2_CHAIN_ID=\($c.id)
SYSTEM_CONFIG_PROXY=\($c.SystemConfigProxy)
OPTIMISM_PORTAL_PROXY=\($c.OptimismPortalProxy)
DISPUTE_GAME_FACTORY_PROXY=\($c.DisputeGameFactoryProxy)
ANCHOR_STATE_REGISTRY_PROXY=\($c.AnchorStateRegistryProxy)
ETH_LOCKBOX_PROXY=\($c.EthLockboxProxy)
ADDRESS_MANAGER=\($c.AddressManagerImpl)
L1_CROSS_DOMAIN_MESSENGER_PROXY=\($c.L1CrossDomainMessengerProxy)
L1_STANDARD_BRIDGE_PROXY=\($c.L1StandardBridgeProxy)
L1_ERC721_BRIDGE_PROXY=\($c.L1Erc721BridgeProxy)
OPTIMISM_MINTABLE_ERC20_FACTORY_PROXY=\($c.OptimismMintableErc20FactoryProxy)
PROXY_ADMIN=\($c.OpChainProxyAdminImpl)
DELAYED_WETH_PERMISSIONED=\($c.DelayedWethPermissionedGameProxy)
DELAYED_WETH_PERMISSIONLESS=\($c.DelayedWethPermissionlessGameProxy)
PERMISSIONED_DISPUTE_GAME_IMPL=\($c.PermissionedDisputeGameImpl)
FAULT_DISPUTE_GAME_IMPL=\($c.FaultDisputeGameImpl)
START_BLOCK=\($c.startBlock // "")"
' workdir/state.json > workdir/shared/l1-addresses.env

cat workdir/shared/l1-addresses.env

echo ""
echo "✅ 关键地址已写入 workdir/shared/l1-addresses.env"
