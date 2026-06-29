# MAN L2 — Dev 测试网接入指南

> 这是一条 **基于 OP Stack v6.0.0 + CGT v2** 的开发测试链，
> 原生 gas 资产是自定义代币 **MAN**。
> 任何 EVM 钱包 / 合约工具 / 脚本都可以直接接入，体验跟主网完全一致。

> ⚠️ 仅用于内部联调测试，**链可能随时被清空重建**；
> 不要在这里部署任何真实价值的资产或长期数据。

> 📅 **最近一次重建**：2026-04-24（链上状态已全部清空、合约地址不变、网络参数不变）。
> 钱包里如果发交易一直 pending、或余额对不上，请到钱包 Settings → Advanced → **Clear activity tab data** 重置 nonce 即可。
>
> 历史变更：原生币符号 `MYC → MAN`、链名 `MyChain → MAN`、Blockscout 浏览器换上了 MAN logo。
> 之前加过 `MyChain Dev` 的同学请**先删除旧网络**再按 §2 重新添加为 `MAN Dev`。

---

## 1. 网络参数

### L2（业务链，平时只接这个就行）

| 项 | 值 |
|---|---|
| **Network Name** | `MAN Dev` |
| **RPC URL (HTTP)** | `http://13.158.71.128:9545` |
| **WebSocket URL** | `ws://13.158.71.128:9546` |
| **Chain ID** | `42170` |
| **Currency Symbol** | `MAN` |
| **Block Explorer URL** | `https://demo.example.com` |
| **出块时间** | 3 秒 |

### L1（开发用 anvil 假以太坊，调试时偶尔会用）

| 项 | 值 |
|---|---|
| **RPC URL** | `http://13.158.71.128:8545` |
| **Chain ID** | `901` |
| **Currency** | ETH（不是真 ETH，仅 dev 占位）|

### op-node sequencer（仅排查 rollup 状态用，业务无关）

| 项 | 值 |
|---|---|
| **RPC URL** | `http://13.158.71.128:9547` |

---

## 2. MetaMask / Rabby / OKX Wallet 添加网络

打开钱包 → 设置 → **Networks → Add a network manually**，按下表填：

```
Network Name:   MAN Dev
RPC URL:        http://13.158.71.128:9545
Chain ID:       42170
Currency:       MAN
Explorer URL:   https://demo.example.com
```

保存后切到该网络即可看到 MAN 余额。

> 如果之前加过这条网络但 Currency 还显示 `MYC`，先删除旧网络再用上表重新添加。

---

## 3. 测试用 EOA（带 10000 MAN 的预设账户）

下面这些账户是 **anvil 默认助记词** 的前几位，
创世时每个地址预存了 **10000 MAN**，
**所有人共用、纯 dev、绝对不要在任何真实网络（包括 Sepolia）使用**。

> 强烈建议大家**各挑一个先用，并且只用一个**，避免互相覆盖 nonce / 把对方 gas 用光。

| 用途建议 | 地址 | 私钥 |
|---|---|---|
| **🅐 推荐自用钱包 #1** | `0x<DEV_WALLET_1_ADDRESS>` | `0x<DEV_WALLET_1_PRIVATE_KEY>` |
| **🅑 推荐自用钱包 #2** | `0x<DEV_WALLET_2_ADDRESS>` | `0x<DEV_WALLET_2_PRIVATE_KEY>` |
| ⚠️ 系统 Deployer（勿动）| `0x<DEPLOYER_ADDRESS>` | `0x<DEPLOYER_PRIVATE_KEY>` |
| ⚠️ 系统 Batcher（勿动）| `0x<BATCHER_ADDRESS>` | `0x<BATCHER_PRIVATE_KEY>` |
| ⚠️ 系统 Proposer（勿动）| `0x<PROPOSER_ADDRESS>` | `0x<PROPOSER_PRIVATE_KEY>` |

> 上述地址/私钥仅为占位符。实际 dev 环境的密钥请由运维通过
> `scripts/01-generate-wallets.sh` 生成并私下分发给团队成员，**不要入仓**。

**用法**：把"自用钱包 #1 / #2"的私钥导入 MetaMask（Account → Import → Private Key），
切到 `MAN Dev` 网络，应该就能看到 `10000 MAN`。

> 如果余额是 0，可能是钱包还没连上、或者链被重建过。
> 找我（运维）跑一次 `make fund TO=<你的地址> AMOUNT=100` 即可补给。

---

## 4. 区块浏览器（Blockscout 完整版）

| 项 | 值 |
|---|---|
| 浏览器入口 | https://demo.example.com |
| 健康自检 | https://demo.example.com/api/v2/blocks?limit=1 |

- **常驻服务**，平时直接打开就能用。
- 链刚重建时，**前 1–2 分钟**后端还在初始化，搜索可能为空，刷新即可。
- 浏览器只跟 `https://demo.example.com` 一个域名打交道；服务器上的 nginx 把 `/api`、`/socket`、`/sitemap.xml`、`/auth/*` 反代到 backend，其他路径反代到 frontend，所以**公司网络只要放 443 即可**，不再需要 `:4000`/`:4001`。
- 备用直连入口（绕过 nginx 调试用，不一定对外开）：`http://13.158.71.128:4000` / `:4001`。

---

## 5. 5 分钟 Smoke Test

### 5.1 钱包侧

1. 钱包导入上面 #1 的私钥
2. 切到 `MAN Dev`，确认余额 ≈ `10000 MAN`
3. 发一笔小额转账给自己另一个地址（比如 `1 MAN`）
4. 浏览器 `https://demo.example.com` 搜索发起地址，能看到刚才那笔交易

### 5.2 命令行侧（任何装了 `cast` 的机器）

```bash
# 看链 ID
cast chain-id --rpc-url http://13.158.71.128:9545
# 应输出：42170

# 看最新区块号（应持续增长，约 3s 一块）
cast block-number --rpc-url http://13.158.71.128:9545

# 看自己余额（单位 wei）——换成你自己的 dev 地址
cast balance 0x<YOUR_DEV_ADDRESS> \
  --rpc-url http://13.158.71.128:9545

# 转 1 MAN ——换成你自己的 dev 私钥
cast send --private-key 0x<YOUR_DEV_PRIVATE_KEY> \
  0x000000000000000000000000000000000000dEaD --value 1ether \
  --rpc-url http://13.158.71.128:9545
```

> 没装 `cast`？一行装：
> `curl -L https://foundry.paradigm.xyz | bash && foundryup`

### 5.3 部署一个简单合约（可选）

任何 Hardhat / Foundry / Remix 工程，把 RPC 改成 `http://13.158.71.128:9545`、
chain ID 改成 `42170`、私钥用上面 #1，部署即可。
Gas 计价完全用 MAN，无需任何特殊改动（CGT v2 对应用层透明）。

---

## 6. 关于 CGT v2（背景知识）

这条链跑的是 **Custom Gas Token v2** —— Optimism 在 v6.0.0 引入的新方案：
原生 gas 资产不是 ETH 而是 MAN，但所有应用层接口（`msg.value` / `block.basefee` /
`tx.gasprice` / ERC20 / DeFi 协议等）跟以太坊主网**完全一致**，无需任何代码适配。

后续会做的事：
- 在 BSC 上部署 MAN ERC-20
- 通过 LayerZero 桥把 MAN 从 BSC 桥到本链作为原生 gas
- 反向把 L2 的 MAN 桥回 BSC

dev 阶段不需要关心桥，**直接当一条普通 EVM 链用**就好。

---

## 7. 常见问题

**Q：钱包里余额还是显示 `MYC` 或者数字不对？网络名还叫 `MyChain Dev`？**
A：链刚重建过，原生币符号和链名都变了。先删掉旧的 `MyChain Dev` 网络，按本文 §2 重新加为 `MAN Dev`；再到钱包 Settings → Advanced → **Clear activity tab data** 清掉缓存。

**Q：钱包提示 "could not detect network" 或 "RPC error"？**
A：先 `curl http://13.158.71.128:9545` 确认能连。不通的话八成是公司网络拦了端口 9545（或 9546），换网或挂代理。浏览器打不开 `https://demo.example.com` 同理，多半是 443 被拦或 DNS 出问题。

**Q：发交易一直 pending？**
A：可能 nonce 撞了（同一个私钥多人在用）。在钱包里 reset account（Settings → Advanced → Clear activity tab data）再重发。

**Q：浏览器打开是空的 / 搜不到块？**
A：链刚重建后 Blockscout 后端要扫几分钟，刷新等 1–2 分钟。还不行 ping 我。

**Q：可以提 PR / 部署到这条链吗？**
A：可以随便折腾，链可能不定期重建。**生产前所有合约必须在 Sepolia 阶段重新过一遍审计 + 验证。**

**Q：链挂了 / 出不了块？**
A：直接 ping 我，不用自己排查。

---

## 8. 链当前健康状态（2026-04-24 重建后验收快照）

✅ CGT v2 全部 10 项验收通过：

1. 原生币 symbol/name = `MAN`
2. `L1Block.isCustomGasToken() = true`
3. `NativeAssetLiquidity` 创世余额 = 2,000,000,000 MAN
4. `LiquidityController` predeploy 已部署（4120 字节）
5. Deployer 创世余额 = 10,000 MAN
6. 原生币转账测试通过
7. Gas 全部以 MAN 计价
8. 零余额账户被正确拒绝 
9. `op-batcher` 在向 L1 提交 batch
10. `op-node` safe/unsafe head 正常推进

---

## 9. 联系

- 链运维：@<你的飞书 / 微信>
- 链上问题、补 MAN、要私钥、加白名单 IP，统统找我
