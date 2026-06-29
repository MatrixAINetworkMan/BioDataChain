# =============================================================================
# MyChain L2 — dev 环境（B 阶段：anvil + op-deployer v0.6.0 + CGT v2）
#
# 用法：先 cp .env.example .env 并按需修改，然后 make help 看命令
# =============================================================================

SHELL := bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

ENV_FILE := .env
FB_ENV_FILE := .env.flashblocks
ifneq (,$(wildcard $(ENV_FILE)))
include $(ENV_FILE)
# v7 Flashblocks：如果 .env.flashblocks 存在，叠加 include。
# 这会让 $(SPAM_RPC_URL_INTERNAL) 等变量在 v7 模式下自动指向 bundle-proxy。
# v6 用户（chain-test）.env.flashblocks 不存在 → 跳过 → 行为完全不变。
ifneq (,$(wildcard $(FB_ENV_FILE)))
include $(FB_ENV_FILE)
endif
export
# ANVIL_GENESIS_TIMESTAMP 会被 scripts/01-l1-up.sh 在 make 运行过程中改写。
# 若 make 启动时该值为空（dev-clean 之后），include 会把空串 export 出去，
# 后续 docker compose 调用即使用 --env-file .env，也会被父进程的空环境变量
# 反向覆盖，导致 anvil 拿到空 --timestamp 直接崩溃 → 死循环。
# 用 unexport 让 docker compose 只认 --env-file 里的值，根治这个问题。
unexport ANVIL_GENESIS_TIMESTAMP
endif

WORKDIR := ./workdir
SHARED  := $(WORKDIR)/shared

L1_ADDRS := $(WORKDIR)/shared/l1-addresses.env
COMPOSE := docker compose --env-file $(ENV_FILE) $(if $(wildcard $(L1_ADDRS)),--env-file $(L1_ADDRS),)

# -----------------------------------------------------------------------------
# L2 RPC 端点（容器内 docker network 访问）
#
# 默认所有用途都指向 op-geth。引入 Flashblocks（op-rbuilder + rollup-boost）后，
# 在 .env 里覆盖：
#   L2_RPC_URL_INTERNAL=http://op-geth:8545          # 通用：链 metadata/deploy/seed
#   SPAM_RPC_URL_INTERNAL=http://op-rbuilder:8545    # spam send 路径（真正出块的 EL）
#   DIAG_RPC_URL_INTERNAL=http://op-rbuilder:8545    # chain-tps / mempool 监控
# -----------------------------------------------------------------------------
L2_RPC_URL_INTERNAL   ?= http://op-geth:8545
SPAM_RPC_URL_INTERNAL ?= $(L2_RPC_URL_INTERNAL)
DIAG_RPC_URL_INTERNAL ?= $(SPAM_RPC_URL_INTERNAL)

# =============================================================================
# 帮助
# =============================================================================
.PHONY: help
help: ## 显示所有命令
	@echo ""
	@echo "MyChain L2 — dev 环境命令清单"
	@echo "================================"
	@# 注意：MAKEFILE_LIST 含 .env（include 进来的），所以这里固定取 Makefile 一个文件
	@# 不然 GNU grep 多文件输出会前缀 "Makefile:"，awk 切出来 target name 变成 "Makefile"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "推荐第一次跑：make dev-up"
	@echo ""

# =============================================================================
# 一键启动 / 销毁
# =============================================================================
.PHONY: dev-up
dev-up: check-env render-intent l1-up deploy-l1 deploy-genesis init-geth l2-up status info ## 一键拉起全套 dev 环境（推荐，不含浏览器）

.PHONY: dev-up-with-explorer
dev-up-with-explorer: dev-up blockscout-up ## 一键拉起 + 启动 Blockscout 浏览器

.PHONY: dev-down
dev-down: ## 停止主链（不动 blockscout）
	$(COMPOSE) --profile deploy --profile proposer down

.PHONY: dev-down-all
dev-down-all: blockscout-down dev-down ## 停止主链 + blockscout（保留 volume）

.PHONY: dev-clean
dev-clean: ## 销毁主链所有服务 + volume + workdir（包含 v7 Flashblocks，不动 blockscout，不可恢复）
	# 用 FB_COMPOSE 一次性带上 docker-compose.flashblocks.yml override，这样 down -v
	# 才能一起清 rbuilder-data / flashblocks-rpc 等 v7 volume。
	# 重 deploy 时 chainId / genesis hash 一变，op-rbuilder 拿老 db 启动会报
	# "genesis hash in storage does not match chainspec" 进 crash 循环。
	$(FB_COMPOSE) --profile deploy --profile proposer --profile flashblocks-rpc down -v --remove-orphans
	# 兜底：手动 rm v7 volume，防 docker compose 某些版本不主动清 named volume
	-docker volume rm dev_rbuilder-data 2>/dev/null
	rm -rf $(WORKDIR)
	@if [ -f .env ]; then \
	  if grep -qE '^ANVIL_GENESIS_TIMESTAMP=' .env; then \
	    sed -i.bak 's/^ANVIL_GENESIS_TIMESTAMP=.*/ANVIL_GENESIS_TIMESTAMP=/' .env && rm -f .env.bak; \
	    echo "==> 已重置 .env 里 ANVIL_GENESIS_TIMESTAMP=（下次 l1-up 会写当前时间）"; \
	  fi; \
	fi
	@echo "✅ 已清理 dev 主链环境"
	@echo "   注：blockscout DB 没动，但下次 make blockscout-up 会自动检测到链指纹变了并 wipe 重新索引"
	@echo "   想立刻清也可以：make blockscout-clean"

.PHONY: dev-clean-all
dev-clean-all: blockscout-clean dev-clean ## 销毁主链 + blockscout（彻底归零，不可恢复）

.PHONY: dev-restart
dev-restart: dev-clean dev-up ## 销毁 + 重新部署

# =============================================================================
# 单步（出问题时分步排查用）
# =============================================================================
.PHONY: check-env
check-env: ## 验证 .env 必填项 + 工具齐全
	@bash scripts/00-check-env.sh

.PHONY: render-intent
render-intent: ## 把 intent.toml.example envsubst 成 workdir/intent.toml
	@bash scripts/00-render-intent.sh

.PHONY: l1-up
l1-up: ## 启动 anvil（首次启动时把当前时间写进 .env，让 chain 时钟从今天开始）
	@bash scripts/01-l1-up.sh

.PHONY: deploy-l1
deploy-l1: ## op-deployer apply 部署 L1 合约（CGT v2 全套）
	@bash scripts/01-deploy-l1.sh

.PHONY: deploy-genesis
deploy-genesis: ## op-deployer 生成 L2 genesis & rollup config
	@bash scripts/02-deploy-genesis.sh

.PHONY: init-geth
init-geth: ## 用 patched genesis 初始化 op-geth datadir 并对齐 rollup.json
	@bash scripts/03-init-geth.sh

.PHONY: l2-up
l2-up: ## 启动 op-geth + op-node + op-batcher（dev 阶段不起 proposer）
	$(COMPOSE) up -d op-geth op-node op-batcher

# v7 模式专用：拆分 l2-up 成两步，中间插 flashblocks-up，
# 否则 op-node 启动时连 rollup-boost:8081 还没起来 → "Waiting" 死循环。
.PHONY: _l2-geth-only
_l2-geth-only:
	$(COMPOSE) up -d op-geth
	@echo "→ 等 op-geth 进入 healthy..."
	@bash -c 'for i in $$(seq 1 60); do \
	  st=$$(docker inspect -f "{{.State.Health.Status}}" mychain-op-geth 2>/dev/null); \
	  [ "$$st" = "healthy" ] && { echo "✅ op-geth healthy"; exit 0; }; \
	  sleep 1; \
	done; echo "❌ op-geth 60s 内未 healthy"; docker logs --tail 30 mychain-op-geth; exit 1'

.PHONY: _l2-node-up
# 必须用 FB_COMPOSE（含 .env.flashblocks）才能让 op-node 拿到
# OP_NODE_L2_ENGINE_URL=http://rollup-boost:8081，否则 fallback 到 op-geth:8551
# → op-rbuilder 永远收不到 FCU、latest_block 卡 0。
_l2-node-up:
	$(FB_COMPOSE) up -d --force-recreate op-node op-batcher

.PHONY: proposer-up
proposer-up: ## 启动 op-proposer（仅 Sepolia/mainnet 阶段需要，要 fault-proof game factory 已部署）
	$(COMPOSE) --profile proposer up -d op-proposer

# =============================================================================
# Blockscout 完整版（独立 stack，dev/blockscout/）
# =============================================================================
BS_COMPOSE := docker compose -f blockscout/docker-compose.yml --env-file $(ENV_FILE)

.PHONY: blockscout-up
blockscout-up: ## 启动 Blockscout 完整版（8 容器，含 stats 微服务，~2.5GB RAM，首次 1-2 分钟）
	@bash scripts/blockscout-up.sh

.PHONY: blockscout-down
blockscout-down: ## 停 Blockscout（保留 DB，下次起来不用重新索引）
	@bash scripts/blockscout-down.sh

.PHONY: blockscout-favicon
blockscout-favicon: ## 重新生成 favicon 套件（改了 icon.svg 后跑；blockscout-up 自动跑无须手动）
	@bash scripts/blockscout-make-favicon.sh --force

.PHONY: blockscout-clean
blockscout-clean: ## 删 Blockscout 容器 + DB + Redis volume（彻底归零）
	@bash scripts/blockscout-down.sh --clean

.PHONY: blockscout-pin
blockscout-pin: ## 把当前 Blockscout 镜像按 sha256 digest 写进 .env（防 :latest 自动升级错配）；SHOW=1 只打印不写
	@bash scripts/blockscout-pin.sh

.PHONY: blockscout-status
blockscout-status: ## Blockscout 8 容器状态
	$(BS_COMPOSE) ps

.PHONY: blockscout-logs
blockscout-logs: ## tail Blockscout backend / frontend 日志
	$(BS_COMPOSE) logs -f --tail=100 backend frontend

.PHONY: blockscout-logs-%
blockscout-logs-%: ## tail 指定 Blockscout 服务，如 make blockscout-logs-backend
	$(BS_COMPOSE) logs -f --tail=200 $*

# =============================================================================
# Flashblocks v7 (chain-test2) — op-rbuilder + rollup-boost + bundle-proxy
# （flashblocks-rpc 在 v7.0 因独立 image 已废弃放到 optional profile，默认不起）
#
# 设计：用 docker-compose.flashblocks.yml 作为 override 叠在主 docker-compose.yml
# 之上，新增 3 个容器，不破坏 v6 行为。详见 docs/PHASE2_INTEGRATION.md。
#
# 必须先有 .env.flashblocks（dev/.env.flashblocks），里面会覆盖 L2_CHAIN_ID（v7=175700）、
# OP_NODE_L2_ENGINE_URL（让 op-node 走 rollup-boost:8081）等。
#
# 推荐流程（fresh chain-test2 机器）：
#   1. cp .env.example .env && 按需改 PUBLIC_HOST 等
#   2. .env.flashblocks 已在 repo 里，按需调 image tag / 端口
#   3. make dev-up-flashblocks               # 一键 v6 + 3 v7 容器
#   4. make blockscout-up                    # 起浏览器（v7.0 indexer 指 op-geth 稳）
#   5. make flashblocks-status               # 看容器
# =============================================================================
FB_ENV_FILES := --env-file $(ENV_FILE) $(if $(wildcard .env.flashblocks),--env-file .env.flashblocks,)

# Bot 用：跟 FB_ENV_FILES 同套逻辑（v7 模式下 .env 里 L2_CHAIN_ID 老值会被
# .env.flashblocks 覆盖，否则 spammer 拿 42170 签 tx → 全被 v7 链拒）
BOT_ENV_FILES := $(FB_ENV_FILES)
# external-L1 模式检测：.env 里 L1_RPC_URL_INTERNAL 指向 l1-proxy 就要带上 external-l1.yml
# 否则 FB_COMPOSE 显式 -f 会覆盖 COMPOSE_FILE env var，丢失 external-l1 override，
# anvil 被默认拉起 / op-node/op-batcher depends_on anvil 等问题重现。
# anvil 模式（L1_RPC_URL_INTERNAL=http://anvil:8545）filter 不匹配 → 这一段为空 → 行为不变。
FB_EXTERNAL_L1_YML := $(if $(filter http://l1-proxy%,$(L1_RPC_URL_INTERNAL)),-f docker-compose.external-l1.yml,)
FB_COMPOSE := docker compose $(FB_ENV_FILES) $(if $(wildcard $(L1_ADDRS)),--env-file $(L1_ADDRS),) -f docker-compose.yml $(FB_EXTERNAL_L1_YML) -f docker-compose.flashblocks.yml

.PHONY: _check-fb-env
_check-fb-env:
	@test -f .env.flashblocks || { \
	  echo "❌ .env.flashblocks 不存在。它已纳入 git（不像 .env），异常缺失时 git checkout dev/.env.flashblocks 即可恢复。"; \
	  exit 1; }

.PHONY: flashblocks-build
flashblocks-build: ## [v7] 本地构建 bundle-proxy 镜像
	$(FB_COMPOSE) build bundle-proxy

.PHONY: flashblocks-up
flashblocks-up: _check-fb-env flashblocks-build ## [v7] 在 v6 主链之上叠 3 个 Flashblocks 容器（op-rbuilder + rollup-boost + bundle-proxy）
	$(FB_COMPOSE) up -d op-rbuilder rollup-boost bundle-proxy
	@echo ""
	@echo "✅ Flashblocks stack 已起："
	@echo "   op-rbuilder      host:$${OP_RBUILDER_PORT:-9550}     (eth_sendBundle, 不对外)"
	@echo "   rollup-boost     host:$${ROLLUP_BOOST_PORT:-9555}     (engine API 8081)"
	@echo "   bundle-proxy     host:$${BUNDLE_PROXY_PORT:-9560}     ← dApp 唯一入口"
	@echo "   metrics          host:$${BUNDLE_PROXY_METRICS_PORT:-9561}/metrics"
	@echo ""
	@echo "   flashblocks-rpc  (optional, v7.0 默认不起，见 docs/PHASE2_INTEGRATION.md)"
	@echo ""
	@echo "下一步：make flashblocks-smoke  /  make flashblocks-status"

.PHONY: flashblocks-down
flashblocks-down: ## [v7] 停 Flashblocks 容器（保留 v6 主链 + 数据卷）
	-$(FB_COMPOSE) --profile flashblocks-rpc stop bundle-proxy flashblocks-rpc rollup-boost op-rbuilder
	-$(FB_COMPOSE) --profile flashblocks-rpc rm -f bundle-proxy flashblocks-rpc rollup-boost op-rbuilder

.PHONY: flashblocks-clean
flashblocks-clean: ## [v7] 删 Flashblocks 容器 + rbuilder datadir volume（不影响 v6 主链）
	-$(FB_COMPOSE) --profile flashblocks-rpc stop bundle-proxy flashblocks-rpc rollup-boost op-rbuilder
	-$(FB_COMPOSE) --profile flashblocks-rpc rm -fv bundle-proxy flashblocks-rpc rollup-boost op-rbuilder
	-docker volume rm dev_rbuilder-data 2>/dev/null
	@echo "✅ Flashblocks 容器 + datadir 已清"

.PHONY: flashblocks-status
flashblocks-status: ## [v7] Flashblocks 容器状态
	$(FB_COMPOSE) --profile flashblocks-rpc ps op-rbuilder rollup-boost flashblocks-rpc bundle-proxy 2>/dev/null || $(FB_COMPOSE) ps op-rbuilder rollup-boost bundle-proxy

.PHONY: flashblocks-logs
flashblocks-logs: ## [v7] tail Flashblocks 容器日志
	$(FB_COMPOSE) logs -f --tail=100 op-rbuilder rollup-boost bundle-proxy

.PHONY: flashblocks-logs-%
flashblocks-logs-%: ## [v7] tail 指定 Flashblocks 容器，如 make flashblocks-logs-bundle-proxy
	$(FB_COMPOSE) logs -f --tail=200 $*

.PHONY: flashblocks-restart
flashblocks-restart: flashblocks-down flashblocks-up ## [v7] 重启 Flashblocks 容器（不动 v6 + 数据）

.PHONY: flashblocks-restart-proxy
flashblocks-restart-proxy: ## [v7] 仅重启 bundle-proxy（改 .env.flashblocks 后用）
	$(FB_COMPOSE) up -d --force-recreate bundle-proxy

.PHONY: flashblocks-smoke
flashblocks-smoke: ## [v7] 端到端冒烟（9 项验收：容器健康 + RPC + metrics + 链可达），~15s
	@bash scripts/flashblocks-smoke.sh

.PHONY: flashblocks-debug
flashblocks-debug: ## [v7] 一键诊断 v7 部署失败原因（smoke 全 fail 时第一步跑）
	@bash scripts/flashblocks-debug.sh

.PHONY: flashblocks-port-check
flashblocks-port-check: ## [v7] 公网端口可达性自检：本机/外部跑都行，缺端口输出清单
	@bash scripts/flashblocks-port-check.sh

.PHONY: flashblocks-port-ticket
flashblocks-port-ticket: ## [v7] 同上 + 末尾生成可直接发给运维的工单 markdown
	@bash scripts/flashblocks-port-check.sh --ticket

.PHONY: flashblocks-logs-fail
flashblocks-logs-fail: ## [v7] dump 所有 unhealthy/exited v7 容器最近 100 行日志（启动失败时跑这个）
	@for c in mychain-op-rbuilder mychain-rollup-boost mychain-bundle-proxy mychain-flashblocks-rpc; do \
	  if docker inspect "$$c" >/dev/null 2>&1; then \
	    st=$$(docker inspect -f '{{.State.Status}}/{{.State.Health.Status}}' "$$c" 2>/dev/null); \
	    if [ "$$st" != "running/healthy" ]; then \
	      echo ""; \
	      echo "============================================"; \
	      echo "▼ $$c  (status=$$st)"; \
	      echo "============================================"; \
	      docker logs --tail 100 "$$c" 2>&1 | sed 's/^/  /'; \
	    fi; \
	  fi; \
	done

.PHONY: flashblocks-recover
flashblocks-recover: _check-fb-env ## [v7] op-node 卡 Waiting/v7 半起来时一键恢复（rm op-node/batcher → 起 boost → 重起 op-node/batcher）
	@echo "→ 1/4 移除卡住的 op-node / op-batcher（保留 op-geth 不动）"
	-$(COMPOSE) rm -fs op-node op-batcher
	@echo ""
	@echo "→ 2/4 确认 op-geth healthy"
	@bash -c 'for i in $$(seq 1 30); do \
	  st=$$(docker inspect -f "{{.State.Health.Status}}" mychain-op-geth 2>/dev/null); \
	  [ "$$st" = "healthy" ] && { echo "✅ op-geth healthy"; exit 0; }; \
	  [ "$$st" = "" ] && { echo "❌ op-geth 不存在，建议 make dev-clean + make dev-up-flashblocks"; exit 1; }; \
	  sleep 1; \
	done; echo "❌ op-geth 30s 内未 healthy"; exit 1'
	@echo ""
	@echo "→ 3/4 起 op-rbuilder + rollup-boost + bundle-proxy"
	$(MAKE) flashblocks-up
	@echo ""
	$(MAKE) _wait-rollup-boost
	@echo ""
	@echo "→ 4/4 起 op-node + op-batcher（必须用 FB_COMPOSE 让 op-node 拿到 OP_NODE_L2_ENGINE_URL=rollup-boost:8081）"
	$(FB_COMPOSE) up -d --force-recreate op-node op-batcher
	@echo ""
	@echo "✅ 恢复完成。验证："
	@echo "  make flashblocks-debug"
	@echo "  make flashblocks-smoke"

.PHONY: flashblocks-host-cleanup
flashblocks-host-cleanup: ## [v7] 查 mychain 端口被谁占了（dry-run）。+CLEANUP=1 自动 stop+rm
	@bash scripts/flashblocks-host-cleanup.sh $${CLEANUP:+--auto-stop}

.PHONY: flashblocks-chaos
flashblocks-chaos: ## [v7] 故障注入（4 场景：rbuilder-down / proxy-overload / fbrpc-down / boost-down，~3 分钟）
	@bash scripts/flashblocks-chaos.sh all

.PHONY: flashblocks-chaos-%
flashblocks-chaos-%: ## [v7] 单场景故障注入：make flashblocks-chaos-rbuilder-down
	@bash scripts/flashblocks-chaos.sh $*

.PHONY: flashblocks-monitor
flashblocks-monitor: ## [v7] v7 指标采样（跟 bot-token-soak 并行跑）：make flashblocks-monitor DURATION=600
	@bash scripts/flashblocks-monitor.sh $${DURATION:-600}

.PHONY: flashblocks-info
flashblocks-info: ## [v7] 显示 v7 stack 关键端点 / chainId
	@echo "L2 chainId         : $${L2_CHAIN_ID}"
	@echo "dApp 入口（bundle-proxy）"
	@echo "  RPC URL          : http://$${PUBLIC_HOST:-127.0.0.1}:$${BUNDLE_PROXY_PORT:-9560}"
	@echo "  metrics          : http://$${PUBLIC_HOST:-127.0.0.1}:$${BUNDLE_PROXY_METRICS_PORT:-9561}/metrics"
	@echo "  health           : http://$${PUBLIC_HOST:-127.0.0.1}:$${BUNDLE_PROXY_PORT:-9560}/healthz"
	@echo "  status           : http://$${PUBLIC_HOST:-127.0.0.1}:$${BUNDLE_PROXY_PORT:-9560}/status"
	@echo "其他端点（一般不直接对外）"
	@echo "  op-rbuilder      : http://$${PUBLIC_HOST:-127.0.0.1}:$${OP_RBUILDER_PORT:-9550}"
	@echo "  rollup-boost     : http://$${PUBLIC_HOST:-127.0.0.1}:$${ROLLUP_BOOST_PORT:-9555}  (engine API)"
	@echo "  op-geth (fallback): http://$${PUBLIC_HOST:-127.0.0.1}:$${L2_RPC_PORT:-9545}"
	@echo "  flashblocks-rpc  : (optional profile, v7.0 默认不起)"

.PHONY: _wait-rollup-boost
_wait-rollup-boost:
	@echo "→ 等 rollup-boost 接受 RPC（engine API 端口 8081 / host $${ROLLUP_BOOST_PORT:-9555}）..."
	@bash -c 'PORT=$${ROLLUP_BOOST_PORT:-9555}; \
	for i in $$(seq 1 60); do \
	  if curl -fsS --max-time 2 -H "Content-Type: application/json" \
	       -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_chainId\",\"params\":[],\"id\":1}" \
	       "http://127.0.0.1:$$PORT" 2>/dev/null | grep -q result; then \
	    echo "✅ rollup-boost 接 RPC OK"; exit 0; \
	  fi; \
	  sleep 1; \
	done; \
	echo "⚠️  rollup-boost 60s 内未应答 RPC，看日志："; \
	docker logs --tail 50 mychain-rollup-boost; \
	echo "（op-node 还是会试着接，如果 rollup-boost 之后能起 op-node 会自动连上）"'

# 一键拉起完整 v7 stack（v6 基础设施 + 3 个 Flashblocks 容器）
# 关键：op-node 必须在 rollup-boost 接 RPC 之后才起，不能复用 dev-up（那个会
# 先起 op-node 连不上 rollup-boost:8081 卡 "Waiting"）。
.PHONY: dev-up-flashblocks
dev-up-flashblocks: _check-fb-env check-env render-intent l1-up deploy-l1 deploy-genesis init-geth _l2-geth-only flashblocks-up _wait-rollup-boost _l2-node-up flashblocks-info status ## [v7] 推荐入口：按正确顺序 anvil→deploy→op-geth→rollup-boost→op-node

# 老命名兼容（之前文档/runbook 用过的）
.PHONY: dev-up-flashblocks-naive
dev-up-flashblocks-naive: dev-up flashblocks-up flashblocks-info ## [v7-legacy] 老顺序（op-node 会卡 Waiting）保留排查用，不推荐

.PHONY: dev-up-flashblocks-with-explorer
dev-up-flashblocks-with-explorer: dev-up-flashblocks blockscout-up ## [v7] dev-up + Flashblocks + Blockscout（v7.0 indexer 指 op-geth 稳）

# =============================================================================
# 状态 / 日志 / 健康检查
# =============================================================================
.PHONY: status
status: ## 显示 docker 服务状态
	$(COMPOSE) ps

.PHONY: info
info: ## 显示外部访问 URL（团队同事看这个）
	@bash scripts/info.sh

.PHONY: info-customer
info-customer: ## 给跨链桥 / 第三方接入的客户友好版（含 L1/L2 合约地址 + chain 状态）
	@bash scripts/info-customer.sh

.PHONY: logs
logs: ## tail 所有 OP 服务日志
	$(COMPOSE) logs -f --tail=100 anvil op-geth op-node op-batcher

.PHONY: logs-%
logs-%: ## tail 指定服务日志，如 make logs-op-batcher
	$(COMPOSE) logs -f --tail=200 $*

.PHONY: healthcheck
healthcheck: ## 端到端健康检查
	@bash scripts/healthcheck.sh

# =============================================================================
# CGT v2 验收（关键！）
# =============================================================================
.PHONY: verify-cgt
verify-cgt: ## 跑 CGT v2 的 10 条验收用例（对应 PLAN_OPSTACK_CGTV2.md §9.1）
	@bash scripts/verify-cgt.sh

.PHONY: test-deploy
test-deploy: ## 端到端：编译 + 部署 Faucet 合约 + 调一次 drip()，验证 L2 合约能跑
	@bash scripts/test-deploy.sh

# =============================================================================
# 给团队成员发钱（dev MAN）
# =============================================================================
.PHONY: fund
fund: ## 给地址转 MAN：make fund TO=0xabc... AMOUNT=100（走 deployer EOA，额度受 deployer 余额限制）
	@if [ -z "$(TO)" ] || [ -z "$(AMOUNT)" ]; then \
	  echo "用法: make fund TO=0x... AMOUNT=100  (单位 MAN，整数)"; \
	  exit 1; \
	fi
	@bash scripts/fund.sh "$(TO)" "$(AMOUNT)"

.PHONY: mint
mint: ## 虚空造币：make mint TO=0xabc... AMOUNT=1000000（走 LC predeploy，额度只受 NAL 20 亿储备限制）
	@if [ -z "$(TO)" ] || [ -z "$(AMOUNT)" ]; then \
	  echo "用法: make mint TO=0x... AMOUNT=1000000  (单位 MAN，整数)"; \
	  echo "区别 fund vs mint:"; \
	  echo "  fund  - deployer EOA 普通转账，受 deployer 余额限制（默认 10000 MAN）"; \
	  echo "  mint  - 调 LiquidityController.mint() 从 NAL 20 亿储备虚空造币，给同事发 1 千万都没事"; \
	  exit 1; \
	fi
	@bash scripts/mint.sh "$(TO)" "$(AMOUNT)"

# =============================================================================
# 刷量机器人（dev/bots/spammer/）— 给 Blockscout 制造持续交易活动
#
# 全部跑在 docker 里，host 不需要装 node。
#   - 镜像：node:22-alpine（约 60MB）
#   - 网络：mychain-dev（用内部 RPC http://op-geth:8545，比走公网 RPC 快）
#   - 持久化：bots/spammer 整个目录 bind mount 进容器，wallets.json /
#     active.json / node_modules 都在 host 上
#   - 用 host UID 跑容器，避免 root 写出文件后 host 不好删
# =============================================================================
SPAMMER_DIR    := bots/spammer
SPAMMER_IMAGE  ?= node:22-alpine
SPAMMER_NAME   := mychain-spammer

# 共享 docker 参数（前台 / 后台都用）
DOCKER_RUN_SPAMMER := docker run --rm --init \
  --network mychain-dev \
  -v "$(CURDIR)/$(SPAMMER_DIR):/app" \
  -w /app \
  --user $(shell id -u):$(shell id -g) \
  -e HOME=/tmp \
  $(BOT_ENV_FILES) \
  -e RPC_URL=http://op-geth:8545 \
  $(SPAMMER_IMAGE)

# 前置检查：网络存在 + 依赖已装
.PHONY: _check-mychain-net
_check-mychain-net:
	@docker network inspect mychain-dev >/dev/null 2>&1 || { \
	  echo "❌ docker 网络 mychain-dev 不存在，先 make dev-up"; exit 1; }

.PHONY: _check-spammer-deps
_check-spammer-deps:
	@test -d $(SPAMMER_DIR)/node_modules/viem || { \
	  echo "❌ 依赖未装，先 make bot-spam-install"; exit 1; }

.PHONY: bot-spam-install
bot-spam-install: ## [bot] 装 npm 依赖（在 docker 里跑，约 30s）
	@test -f $(SPAMMER_DIR)/package.json || { echo "❌ $(SPAMMER_DIR)/package.json 不存在"; exit 1; }
	$(DOCKER_RUN_SPAMMER) npm install --no-audit --no-fund

.PHONY: bot-spam-init
bot-spam-init: _check-spammer-deps ## [bot] 生成 5642 钱包到 wallets.json（含私钥，已 gitignore）
	$(DOCKER_RUN_SPAMMER) node spammer.js init

.PHONY: bot-grow
bot-grow: _check-mychain-net _check-spammer-deps ## [bot] 拟真模式（前台跑，Ctrl+C 退；推荐 demo 用）
	$(DOCKER_RUN_SPAMMER) node spammer.js grow

.PHONY: bot-grow-up
bot-grow-up: _check-mychain-net _check-spammer-deps ## [bot] 后台 daemon 跑 grow（preflight 失败不会无限重启踩 mempool）
	@docker rm -f $(SPAMMER_NAME) >/dev/null 2>&1 || true
	docker run -d --init \
	  --name $(SPAMMER_NAME) \
	  --restart on-failure:0 \
	  --network mychain-dev \
	  -v "$(CURDIR)/$(SPAMMER_DIR):/app" \
	  -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  -e HOME=/tmp \
	  $(BOT_ENV_FILES) \
	  -e RPC_URL=http://op-geth:8545 \
	  $(SPAMMER_IMAGE) \
	  node spammer.js grow
	@echo "✅ spammer daemon 已起，看日志：make bot-grow-logs"
	@echo "   注：preflight 失败会立刻退出（不再无限重启）。看 grow 命令加 \`docker logs $(SPAMMER_NAME)\`"

.PHONY: bot-grow-down
bot-grow-down: ## [bot] 停 daemon spammer
	docker rm -f $(SPAMMER_NAME) >/dev/null 2>&1 || true
	@echo "✅ daemon 已停（active.json 保留，下次 grow 续跑）"

.PHONY: bot-grow-logs
bot-grow-logs: ## [bot] tail daemon spammer 日志
	docker logs -f --tail=200 $(SPAMMER_NAME)

.PHONY: bot-grow-status
bot-grow-status: ## [bot] 看 daemon 容器状态
	@docker ps -a --filter name=$(SPAMMER_NAME) --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'

.PHONY: bot-consolidate
bot-consolidate: _check-mychain-net _check-spammer-deps ## [bot] 把 sequencer/batcher/proposer/challenger 闲钱合并到 deployer（不重建链给 deployer 增余额）
	$(DOCKER_RUN_SPAMMER) node spammer.js consolidate

# bot-mint 用法：
#   make bot-mint                          # 默认 100000 MAN 给 deployer
#   make bot-mint AMOUNT=30000000          # 3000 万 MAN 给 deployer（够 5642 钱包按 200-10000 跑）
#   make bot-mint AMOUNT=10000 TO=0xabc... # 给指定地址
.PHONY: bot-mint
bot-mint: _check-mychain-net _check-spammer-deps ## [bot] 通过 LiquidityController 从 NAL 池增发 MAN（默认 100000 给 deployer）
	$(DOCKER_RUN_SPAMMER) node spammer.js mint $(AMOUNT) $(TO)

.PHONY: bot-inspect-lc
bot-inspect-lc: _check-mychain-net _check-spammer-deps ## [bot] 排查 LiquidityController 状态（owner/isAuthorizedMinter/simulate authorize+mint，看 revert reason）
	$(DOCKER_RUN_SPAMMER) node spammer.js inspect-lc

.PHONY: bot-ping-tx
bot-ping-tx: _check-mychain-net _check-spammer-deps ## [bot] 用 deployer 发 1 wei 自转，验证链是否真的在收 tx + 出块（排查 mempool 卡死）
	$(DOCKER_RUN_SPAMMER) node spammer.js ping-tx

.PHONY: bot-clear-mempool
bot-clear-mempool: _check-mychain-net _check-spammer-deps ## [bot] 用极高 fee 顶替 deployer 卡 mempool 的 pending tx（不用重启 op-geth）
	$(DOCKER_RUN_SPAMMER) node spammer.js clear-mempool

.PHONY: bot-spam-fund
bot-spam-fund: _check-mychain-net _check-spammer-deps ## [bot] 一次性从 deployer 给每个钱包打钱（暴力模式）
	$(DOCKER_RUN_SPAMMER) node spammer.js fund

.PHONY: bot-spam
bot-spam: _check-mychain-net _check-spammer-deps ## [bot] 一次性模式：每秒 3-15 笔随机互转（要求 bot-spam-fund 已跑）
	$(DOCKER_RUN_SPAMMER) node spammer.js spam

.PHONY: bot-spam-status
bot-spam-status: _check-mychain-net _check-spammer-deps ## [bot] 看链 / 钱包数 / grow 激活进度 / 抽样余额
	$(DOCKER_RUN_SPAMMER) node spammer.js status

.PHONY: bot-spam-clean
bot-spam-clean: ## [bot] 清 wallets.json + active.json + node_modules（彻底归零）
	@docker rm -f $(SPAMMER_NAME) >/dev/null 2>&1 || true
	@# 用 docker 跑 rm 而不是 host rm，免得碰到 root 创建的残留文件
	docker run --rm \
	  -v "$(CURDIR)/$(SPAMMER_DIR):/app" -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  alpine sh -c 'rm -rf wallets.json active.json node_modules package-lock.json'
	@echo "✅ 已清理 spammer 状态"

.PHONY: bot-grow-reset
bot-grow-reset: ## [bot] 只清 grow 进度（active.json），钱包保留
	@docker rm -f $(SPAMMER_NAME) >/dev/null 2>&1 || true
	docker run --rm \
	  -v "$(CURDIR)/$(SPAMMER_DIR):/app" -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  alpine rm -f active.json
	@echo "✅ 已清 grow 状态，下次 bot-grow 从 t=0 重新开始曲线"

# =============================================================================
# ERC-20 多 token 压测机器人（dev/bots/tokenspammer/）
#
# 部署 1000 个 ERC-20 + 50000 个钱包 + 1000 TPS 随机互转。
# 完整文档：dev/bots/tokenspammer/README.md
#
# 流程：build → init → mint → deploy → fund-gas → seed → spam-up
# =============================================================================
TS_DIR    := bots/tokenspammer
TS_IMAGE  ?= node:22-alpine
TS_NAME   := mychain-tokenspammer

DOCKER_RUN_TS := docker run --rm --init \
  --network mychain-dev \
  -v "$(CURDIR)/$(TS_DIR):/app" \
  -w /app \
  --user $(shell id -u):$(shell id -g) \
  -e HOME=/tmp \
  $(BOT_ENV_FILES) \
  -e RPC_URL=$(L2_RPC_URL_INTERNAL) \
  -e SPAM_RPC_URL=$(SPAM_RPC_URL_INTERNAL) \
  -e DIAG_RPC_URL=$(DIAG_RPC_URL_INTERNAL) \
  $(TS_IMAGE)

.PHONY: _check-ts-deps
_check-ts-deps:
	@test -d $(TS_DIR)/node_modules/viem || { \
	  echo "❌ tokenspammer 依赖未装，先 make bot-token-install"; exit 1; }

.PHONY: _check-ts-artifacts
_check-ts-artifacts:
	@test -f $(TS_DIR)/contracts/out/TestERC20.sol/TestERC20.json || { \
	  echo "❌ 合约未编译，先 make bot-token-build"; exit 1; }

.PHONY: bot-token-install
bot-token-install: ## [token] 装 npm 依赖（docker 里 npm install）
	@test -f $(TS_DIR)/package.json || { echo "❌ $(TS_DIR)/package.json 不存在"; exit 1; }
	$(DOCKER_RUN_TS) npm install --no-audit --no-fund

.PHONY: bot-token-build
bot-token-build: ## [token] forge 编译 TestERC20 + BatchTransfer 到 artifacts.json
	@bash $(TS_DIR)/build.sh

.PHONY: bot-token-init
bot-token-init: _check-ts-deps ## [token] 生成 50000 钱包到 wallets-50k.json
	$(DOCKER_RUN_TS) node tokenspammer.js init

# bot-token-mint 用法：
#   make bot-token-mint                # 默认 5000 MAN
#   make bot-token-mint AMOUNT=10000   # 指定 MAN 数
.PHONY: bot-token-mint
bot-token-mint: _check-mychain-net _check-ts-deps ## [token] 通过 LiquidityController mint MAN 给 deployer（默认 5000）
	$(DOCKER_RUN_TS) node tokenspammer.js mint $(AMOUNT)

.PHONY: bot-token-deploy
bot-token-deploy: _check-mychain-net _check-ts-deps _check-ts-artifacts ## [token] 部署 1 BatchTransfer + 1000 ERC-20 + approve max
	$(DOCKER_RUN_TS) node tokenspammer.js deploy

.PHONY: bot-token-fund-gas
bot-token-fund-gas: _check-mychain-net _check-ts-deps _check-ts-artifacts ## [token] 给所有 50k 钱包打 gas 费（用 BatchTransfer）
	$(DOCKER_RUN_TS) node tokenspammer.js fund-gas

.PHONY: bot-token-seed
bot-token-seed: _check-mychain-net _check-ts-deps _check-ts-artifacts ## [token] 每个 token 随机选 500 holder 分发种子
	$(DOCKER_RUN_TS) node tokenspammer.js seed

.PHONY: bot-token-spam
bot-token-spam: _check-mychain-net _check-ts-deps ## [token] 前台跑 spam（Ctrl+C 退；调试用）
	$(DOCKER_RUN_TS) node tokenspammer.js spam

.PHONY: bot-token-spam-up
bot-token-spam-up: _check-mychain-net _check-ts-deps ## [token] 后台 daemon 跑 spam（restart unless-stopped）
	@docker rm -f $(TS_NAME) >/dev/null 2>&1 || true
	docker run -d --init \
	  --name $(TS_NAME) \
	  --restart unless-stopped \
	  --network mychain-dev \
	  -v "$(CURDIR)/$(TS_DIR):/app" \
	  -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  -e HOME=/tmp \
	  $(BOT_ENV_FILES) \
	  -e RPC_URL=$(L2_RPC_URL_INTERNAL) \
	  -e SPAM_RPC_URL=$(SPAM_RPC_URL_INTERNAL) \
	  -e DIAG_RPC_URL=$(DIAG_RPC_URL_INTERNAL) \
	  $(if $(TARGET_TPS),-e TARGET_TPS=$(TARGET_TPS),) \
	  $(if $(SPAM_TICK_MS),-e SPAM_TICK_MS=$(SPAM_TICK_MS),) \
	  $(if $(MEMPOOL_BACKPRESSURE),-e MEMPOOL_BACKPRESSURE=$(MEMPOOL_BACKPRESSURE),) \
	  $(if $(MEMPOOL_HIGH_WATER),-e MEMPOOL_HIGH_WATER=$(MEMPOOL_HIGH_WATER),) \
	  $(if $(MEMPOOL_LOW_WATER),-e MEMPOOL_LOW_WATER=$(MEMPOOL_LOW_WATER),) \
	  $(if $(MAX_TICK_QUEUE),-e MAX_TICK_QUEUE=$(MAX_TICK_QUEUE),) \
	  $(TS_IMAGE) \
	  node tokenspammer.js spam
	@echo "✅ tokenspammer daemon 已起，看 TPS：make bot-token-spam-logs"
	@echo "   spam send RPC: $(SPAM_RPC_URL_INTERNAL)"
	@echo "   diag/mempool:  $(DIAG_RPC_URL_INTERNAL)"
	@if [ -n "$(TARGET_TPS)" ]; then echo "   TARGET_TPS:    $(TARGET_TPS) (shell override)"; fi
	@if [ -n "$(MEMPOOL_BACKPRESSURE)" ]; then echo "   BACKPRESSURE:  $(MEMPOOL_BACKPRESSURE) (shell override)"; fi

.PHONY: bot-token-spam-failfast
bot-token-spam-failfast: _check-mychain-net _check-ts-deps ## [token] daemon 跑 fail-fast 模式（关 backpressure，超额 tx 即时 fail）
	@docker rm -f $(TS_NAME) >/dev/null 2>&1 || true
	@echo "⚠️  fail-fast 模式：需先把 op-geth 改小 txpool："
	@echo "    OP_GETH_TXPOOL_GLOBALSLOTS=200 OP_GETH_TXPOOL_ACCOUNTSLOTS=4 \\"
	@echo "    docker compose up -d --force-recreate op-geth"
	@echo "   spammer 这边关 backpressure、固定 200 TPS"
	@sleep 1
	docker run -d --init \
	  --name $(TS_NAME) \
	  --restart unless-stopped \
	  --network mychain-dev \
	  -v "$(CURDIR)/$(TS_DIR):/app" \
	  -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  -e HOME=/tmp \
	  $(BOT_ENV_FILES) \
	  -e RPC_URL=$(L2_RPC_URL_INTERNAL) \
	  -e SPAM_RPC_URL=$(SPAM_RPC_URL_INTERNAL) \
	  -e DIAG_RPC_URL=$(DIAG_RPC_URL_INTERNAL) \
	  -e MEMPOOL_BACKPRESSURE=0 \
	  -e TARGET_TPS=200 \
	  $(TS_IMAGE) \
	  node tokenspammer.js spam
	@echo "✅ tokenspammer fail-fast daemon 已起；report 里看 fail{full=...}"

.PHONY: bot-token-spam-down
bot-token-spam-down: ## [token] 停 daemon spam
	docker rm -f $(TS_NAME) >/dev/null 2>&1 || true
	@echo "✅ tokenspammer daemon 已停"

.PHONY: bot-token-stairs
bot-token-stairs: _check-mychain-net _check-ts-deps ## [token] 阶梯压测：100→350 TPS 找真实拐点（~22 分钟）
	@echo "============================================"
	@echo "📊 阶梯压测：100/150/200/250/300/350 TPS"
	@echo "   每档 3 分钟（45s warmup + 135s 采样）"
	@echo "   每档之间：等 mempool < 30 + 冷却 30s（防残留消化失真）"
	@echo "   总耗时：约 22 分钟"
	@echo "============================================"
	@echo ""
	@echo "可用环境变量覆盖："
	@echo "  TPS_LIST=\"100 200 300\"  自定义档位"
	@echo "  DURATION=120              每档时长（秒）"
	@echo "  WARMUP=30                 warmup 时长"
	@echo "  COOL_DOWN=60              每档之间冷却时长（默认 30）"
	@echo "  DRAIN_THRESHOLD=10        排空阈值（默认 30，越严格越慢）"
	@echo ""
	@echo "💡 想要更精确单点验证 → make bot-token-soak（10 分钟单档长跑，更可信）"
	@echo ""
	@bash scripts/stress-stairs.sh

.PHONY: bot-token-soak
bot-token-soak: _check-mychain-net _check-ts-deps ## [token] 单档长跑：固定 TPS 跑 10 分钟拿稳态数据（最可信）
	@echo "============================================"
	@echo "🎯 单档长跑测试（最可信的承载验证方法）"
	@echo "============================================"
	@echo ""
	@echo "默认：TARGET_TPS=200 DURATION=600（10 分钟）"
	@echo "  60s warmup + 540s 主测试 + 末尾 120s 严格采样作为最终结论"
	@echo ""
	@echo "可用环境变量："
	@echo "  TARGET_TPS=150       目标 TPS（默认 200）"
	@echo "  DURATION=300         总时长秒数（默认 600）"
	@echo "  SAMPLE_WINDOW=60     末尾 N 秒做严格采样（默认 120）"
	@echo ""
	@TARGET_TPS=$${TARGET_TPS:-200} DURATION=$${DURATION:-600} \
	  bash scripts/stress-soak.sh

.PHONY: bot-token-spam-logs
bot-token-spam-logs: ## [token] tail daemon 日志
	docker logs -f --tail=100 $(TS_NAME)

.PHONY: bot-token-spam-status
bot-token-spam-status: ## [token] daemon 容器状态
	@docker ps -a --filter name=$(TS_NAME) --format 'table {{.Names}}\t{{.Status}}\t{{.RunningFor}}'

.PHONY: bot-token-chain-tps
bot-token-chain-tps: ## [token] 看链上最近 N=10 个块的真实 TPS（用法：make bot-token-chain-tps N=20）
	@N_BLOCKS=$${N:-10}; \
	RPC=$(DIAG_RPC_URL_INTERNAL); \
	docker run --rm --network mychain-dev --entrypoint sh -e "RPC=$$RPC" $(ANVIL_IMAGE) -c '\
	  set -e; \
	  N='"$$N_BLOCKS"'; \
	  HEAD=$$(cast block-number --rpc-url $$RPC); \
	  echo "  block      ts          Δs    tx     gas(M)  util%"; \
	  echo "  ---------- ----------  ---   ----   ------  -----"; \
	  TOTAL=0; PREV_TS=0; FIRST_TS=0; LAST_TS=0; \
	  i=$$((N-1)); \
	  while [ $$i -ge 0 ]; do \
	    H=$$((HEAD - i)); \
	    HEX=$$(printf "0x%x" $$H); \
	    BLK=$$(cast rpc eth_getBlockByNumber "$$HEX" false --rpc-url $$RPC); \
	    TX_HEX=$$(echo "$$BLK" | grep -oE "\"transactions\":\\[[^]]*\\]" | tr -d "\"\\[\\]" | tr "," "\n" | grep -c "0x" || echo 0); \
	    TS_HEX=$$(echo "$$BLK" | grep -oE "\"timestamp\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*"); \
	    TS_DEC=$$(printf "%d\n" $$TS_HEX); \
	    GAS_HEX=$$(echo "$$BLK" | grep -oE "\"gasUsed\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*"); \
	    GAS_DEC=$$(printf "%d\n" $$GAS_HEX); \
	    GAS_M=$$((GAS_DEC / 100000)); \
	    UTIL=$$((GAS_DEC * 100 / 60000000)); \
	    if [ $$PREV_TS -eq 0 ]; then DT="—"; FIRST_TS=$$TS_DEC; else DT=$$((TS_DEC - PREV_TS)); fi; \
	    printf "  %-10s %-10s  %-3s   %-4s   %d.%dM    %s%%\n" "$$H" "$$TS_DEC" "$$DT" "$$TX_HEX" "$$((GAS_M / 10))" "$$((GAS_M % 10))" "$$UTIL"; \
	    PREV_TS=$$TS_DEC; LAST_TS=$$TS_DEC; \
	    TOTAL=$$((TOTAL + TX_HEX)); \
	    i=$$((i - 1)); \
	  done; \
	  SPAN=$$((LAST_TS - FIRST_TS)); \
	  if [ $$SPAN -gt 0 ]; then \
	    echo "  -----"; \
	    echo "  $$N 块共 $$TOTAL tx，时间跨度 $${SPAN}s → 实测 TPS ≈ $$((TOTAL / SPAN))"; \
	  else \
	    echo "  $$N 块共 $$TOTAL tx（时间跨度 0 无法算 TPS）"; \
	  fi'

.PHONY: bot-token-mempool
bot-token-mempool: ## [token] 看 sequencer EL mempool 大小（pending / queued）
	@RPC=$(DIAG_RPC_URL_INTERNAL); \
	docker run --rm --network mychain-dev --entrypoint sh -e "RPC=$$RPC" $(ANVIL_IMAGE) -c '\
	  RES=$$(cast rpc txpool_status --rpc-url $$RPC); \
	  PENDING=$$(echo "$$RES" | grep -oE "\"pending\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*"); \
	  QUEUED=$$(echo "$$RES"  | grep -oE "\"queued\":\"0x[0-9a-f]*\""  | grep -oE "0x[0-9a-f]*"); \
	  echo "  RPC: $$RPC"; \
	  echo "  pending: $$(printf %d $$PENDING)"; \
	  echo "  queued : $$(printf %d $$QUEUED)"'

.PHONY: bot-token-geth-stats
bot-token-geth-stats: ## [token] op-geth CPU / 内存 / IO 一行
	@docker stats mychain-op-geth --no-stream --format \
	  'table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}'

.PHONY: bot-token-geth-metrics
bot-token-geth-metrics: ## [token] op-geth 内部 metrics（chain insert / commit / txpool 耗时）
	@docker run --rm --network mychain-dev alpine sh -c '\
	  apk add --quiet curl >/dev/null 2>&1; \
	  echo "=== chain insert（每块 commit 耗时，> 100ms = 慢）===" ; \
	  curl -s http://op-geth:6060/debug/metrics | tr "," "\n" | grep -E "\"(chain/inserts|chain/account/(reads|updates)|chain/storage/(reads|updates)|chain/(execution|validation|write|commits|crossvalidation))" || true; \
	  echo ""; \
	  echo "=== state / trie commit（path scheme flush 耗时）==="; \
	  curl -s http://op-geth:6060/debug/metrics | tr "," "\n" | grep -E "\"(state/snapshot|state/persist|trie/(commits|memcache)|chain/triedb)" || true; \
	  echo ""; \
	  echo "=== txpool（mempool 内部 timing）==="; \
	  curl -s http://op-geth:6060/debug/metrics | tr "," "\n" | grep -E "\"txpool/(pending|queued|all|locals|reorgs|invalid|underpriced|knowntxs|valid)" || true; \
	  echo ""; \
	  echo "=== miner / worker（block 构建耗时 / interrupt）==="; \
	  curl -s http://op-geth:6060/debug/metrics | tr "," "\n" | grep -E "\"miner/(commit|prepare|seal|fillTransactions|block)" || true; \
	  echo ""; \
	  echo "=== rpc handler ==="; \
	  curl -s http://op-geth:6060/debug/metrics | tr "," "\n" | grep -E "\"rpc/(requests|failure|duration)" || true'

.PHONY: bot-token-geth-logs
bot-token-geth-logs: ## [token] op-geth 最近 5 分钟出块/commit 日志（找卡顿原因）
	@echo "=== Imported new chain segment（每块 commit 时间）==="
	@docker logs --since=5m mychain-op-geth 2>&1 | grep -E "Imported (new|chain)|Sealed|Mined" | tail -30 || true
	@echo ""
	@echo "=== Commit / Persisted（path scheme flush）==="
	@docker logs --since=5m mychain-op-geth 2>&1 | grep -iE "Persisted|Committed|Flushed|trie node|state.*commit" | tail -20 || true
	@echo ""
	@echo "=== Warning / Error（卡顿先行警告）==="
	@docker logs --since=5m mychain-op-geth 2>&1 | grep -E "^(WARN|ERROR)" | tail -20 || true

.PHONY: bot-token-diag
bot-token-diag: ## [token] 一键全量诊断（spam 跑着的时候用，~10s）
	@echo "===================== 1. CPU / 内存 / IO ====================="
	@$(MAKE) bot-token-geth-stats
	@echo ""
	@echo "===================== 2. 最近 30 块详情 ====================="
	@$(MAKE) bot-token-chain-tps N=30
	@echo ""
	@echo "===================== 3. mempool ====================="
	@$(MAKE) bot-token-mempool
	@echo ""
	@echo "===================== 4. op-geth metrics ====================="
	@$(MAKE) bot-token-geth-metrics
	@echo ""
	@echo "===================== 5. op-geth logs ====================="
	@$(MAKE) bot-token-geth-logs

.PHONY: bot-token-status
bot-token-status: _check-mychain-net _check-ts-deps ## [token] 看链 / 钱包 / token / seed 进度
	$(DOCKER_RUN_TS) node tokenspammer.js status

.PHONY: bot-token-clean
bot-token-clean: ## [token] 清 wallets-50k / tokens / artifacts / node_modules（彻底归零）
	@docker rm -f $(TS_NAME) >/dev/null 2>&1 || true
	docker run --rm \
	  -v "$(CURDIR)/$(TS_DIR):/app" -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  alpine sh -c 'rm -rf wallets-50k.json tokens.json artifacts.json node_modules package-lock.json contracts/out contracts/cache'
	@echo "✅ 已清理 tokenspammer 状态（合约还在链上，但本地索引已删）"

.PHONY: bot-token-clear-mempool
bot-token-clear-mempool: ## [token] 清空 op-geth mempool（停容器 + 删 transactions.rlp + 重启，~10s）
	@echo "==> 停 spammer + op-geth ..."
	@docker rm -f $(TS_NAME) >/dev/null 2>&1 || true
	@docker stop mychain-op-geth >/dev/null 2>&1 || true
	@echo "==> 删 mempool journal（transactions.rlp）..."
	@docker run --rm -v dev_opgeth-data:/data alpine \
	  sh -c 'rm -fv /data/geth/transactions.rlp /data/geth/journal.rlp 2>/dev/null; ls /data/geth/transactions.rlp /data/geth/journal.rlp 2>/dev/null && echo "❌ 还在" || echo "✅ 已删"'
	@echo "==> 重启 op-geth ..."
	@docker start mychain-op-geth >/dev/null
	@echo "==> 等 op-geth ready ~10s ..."
	@sleep 10
	@echo "==> 验证 mempool 空了 ..."
	@RPC=$(DIAG_RPC_URL_INTERNAL); \
	docker run --rm --network mychain-dev --entrypoint sh -e "RPC=$$RPC" $(ANVIL_IMAGE) -c '\
	  RES=$$(cast rpc txpool_status --rpc-url $$RPC); \
	  PENDING=$$(echo "$$RES" | grep -oE "\"pending\":\"0x[0-9a-f]*\"" | grep -oE "0x[0-9a-f]*"); \
	  QUEUED=$$(echo "$$RES"  | grep -oE "\"queued\":\"0x[0-9a-f]*\""  | grep -oE "0x[0-9a-f]*"); \
	  echo "  pending: $$(printf %d $$PENDING)"; \
	  echo "  queued : $$(printf %d $$QUEUED)"'
	@echo "✅ mempool 已清空，可以 make bot-token-spam-up 重跑"

.PHONY: bot-token-reset-deploy
bot-token-reset-deploy: ## [token] 只清 tokens.json + 重启 op-geth 清 mempool（deploy 卡死后用，钱包保留）
	@docker rm -f $(TS_NAME) >/dev/null 2>&1 || true
	docker run --rm \
	  -v "$(CURDIR)/$(TS_DIR):/app" -w /app \
	  --user $(shell id -u):$(shell id -g) \
	  alpine rm -f tokens.json
	@echo "==> tokens.json 已删（本地 deploy 进度归零）"
	@echo "==> 重启 op-geth 清 mempool 里卡死的 queued tx ..."
	$(COMPOSE) restart op-geth
	@echo "==> 等 op-geth 起来 ~10s ..."
	@sleep 10
	@echo "✅ 重置完成。链上已部署但孤儿的合约不会自动清掉，但 deployer nonce 会从 latest 重拉，"
	@echo "   下次 make bot-token-deploy 会从 idx=0 重新部署 1000 个干净的 token。"

# =============================================================================
# 调试 / 杂项
# =============================================================================
.PHONY: cast-l1
cast-l1: ## 进入 cast shell 连 L1
	@docker run --rm -it --network mychain-dev $(ANVIL_IMAGE) cast --rpc-url $(L1_RPC_URL_INTERNAL)

.PHONY: cast-l2
cast-l2: ## 进入 cast shell 连 L2（默认 op-geth；Flashblocks 后看 L2_RPC_URL_INTERNAL）
	@docker run --rm -it --network mychain-dev $(ANVIL_IMAGE) cast --rpc-url $(L2_RPC_URL_INTERNAL)

.PHONY: shell
shell: ## 进入一个连了 mychain-dev 网络的工具容器（含 cast/curl/jq）
	@docker run --rm -it --network mychain-dev -v $(PWD)/workdir:/workdir $(ANVIL_IMAGE) sh

.PHONY: pull
pull: ## 预先拉主链所有镜像（首次部署时跑可避免超时）
	$(COMPOSE) --profile deploy --profile proposer pull

.PHONY: pull-blockscout
pull-blockscout: ## 预先拉 Blockscout 所有镜像（约 2GB 下载量）
	$(BS_COMPOSE) pull

# =============================================================================
# 长期稳定性测试（一期 SLA：链稳态 ~180 TPS，按 150 TPS 跑长跑，超载 fail-fast）
#   - stability-up：智能初始化 1000 token + 50000 钱包 + gas + seed，启动 daemon spam
#                  每步幂等：第一次 ~10-15 分钟；之后 ~10 秒重启 spam
#   - stability-down：停 spammer，保留所有数据
#   - stability-status：一屏总览（容器 / spammer 累计 / 链 TPS / mempool）
#   - stability-logs：tail spammer 实时日志
#
# 默认参数（可被 shell 环境变量覆盖）：
#   TARGET_TPS=150              一期 SLA（链稳态 ~180 的 0.83x）
#   MEMPOOL_BACKPRESSURE=0      fail-fast（链层超载即时拒绝）
# =============================================================================
.PHONY: stability-up
stability-up: _check-mychain-net _check-ts-deps ## [稳定性] 一键启动长期稳定性测试（150 TPS，fail-fast，幂等）
	@bash scripts/stability-up.sh

.PHONY: stability-down
stability-down: ## [稳定性] 停 daemon spam（保留 wallets / tokens 数据，下次秒启）
	@bash scripts/stability-down.sh

.PHONY: stability-status
stability-status: ## [稳定性] 一屏总览：容器 / spammer 累计 / 链 TPS / mempool（用法：make stability-status N_BLOCKS=30）
	@bash scripts/stability-status.sh

.PHONY: stability-logs
stability-logs: ## [稳定性] tail spammer daemon 实时日志（Ctrl+C 退）
	docker logs -f --tail=100 $(TS_NAME)
