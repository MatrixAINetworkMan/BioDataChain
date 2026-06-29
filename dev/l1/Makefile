.DEFAULT_GOAL := help
SHELL := /usr/bin/env bash

# .env 文件存在才 include；不存在时 help / clean 仍可运行
ifneq (,$(wildcard .env))
include .env
export
endif

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help: ## 显示所有命令
	@printf "MyChain L1 (geth Clique PoA, single validator)\n\n"
	@printf "常用流程：\n"
	@printf "  1) cp .env.example .env && vim .env  # 改 PUBLIC_HOST、VALIDATOR_PASSWORD\n"
	@printf "  2) make init                          # 一次性生成 validator + genesis\n"
	@printf "  3) make up                            # 启动\n"
	@printf "  4) make status                        # 看出块号\n\n"
	@printf "命令：\n"
	@awk 'BEGIN {FS = ":.*?## "}; /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# =============================================================================
# Preflight
# =============================================================================
.PHONY: check-env
check-env:
	@test -f .env || (echo "❌ .env 不存在。请先：cp .env.example .env"; exit 1)
	@command -v docker >/dev/null || (echo "❌ 需要 docker"; exit 1)
	@command -v jq >/dev/null || (echo "❌ 需要 jq（apt install jq / brew install jq）"; exit 1)
	@command -v envsubst >/dev/null || (echo "❌ 需要 envsubst（apt install gettext-base）"; exit 1)

# =============================================================================
# Main targets
# =============================================================================
.PHONY: init
init: check-env ## [一次性] 生成 validator keystore + 渲染 genesis + geth init datadir
	@bash scripts/01-init.sh

.PHONY: up
up: check-env ## 启动 L1
	@bash scripts/02-up.sh

.PHONY: down
down: ## 停止 L1（不删数据）
	@docker compose --env-file .env down

.PHONY: restart
restart: down up ## 重启 L1

.PHONY: status
status: ## 看 L1 当前状态（block#、validator、余额等）
	@bash scripts/03-status.sh

.PHONY: logs
logs: ## 跟实时日志
	@docker compose --env-file .env logs -f --tail=100 geth-l1

.PHONY: ps
ps: ## docker ps
	@docker compose --env-file .env ps

.PHONY: fund
fund: ## 用 validator 转账到指定地址：make fund TO=0xabc... [AMOUNT=1000]
	@test -n "$(TO)" || (echo "Usage: make fund TO=0x... [AMOUNT=1000]"; exit 1)
	@bash scripts/04-fund.sh "$(TO)" "$(AMOUNT)"

.PHONY: console
console: ## 进入 geth 交互式 console（attach 到运行中的节点）
	@docker exec -it mychain-l1-geth geth attach /data/geth.ipc

# =============================================================================
# Blockscout (L1 区块浏览器)
# =============================================================================
.PHONY: blockscout-up
blockscout-up: check-env ## 启动 L1 Blockscout（7 个 service）
	@bash scripts/blockscout-up.sh

.PHONY: blockscout-down
blockscout-down: ## 停止 Blockscout（不删数据）
	@bash scripts/blockscout-down.sh

.PHONY: blockscout-restart
blockscout-restart: blockscout-down blockscout-up ## 重启 Blockscout

.PHONY: blockscout-logs
blockscout-logs: ## 跟 Blockscout 所有容器日志
	@cd blockscout && docker compose --env-file ../.env logs -f --tail=50

.PHONY: blockscout-ps
blockscout-ps: ## docker ps（Blockscout 容器）
	@# 用裸 docker ps 不走 docker compose 的 ${VAR:-default} substitution，
	@# 避开 `docker compose ps` 在某些版本里报 "invalid hostPort" 的 quirk
	@docker ps -a --filter name=mychain-l1-bs --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

.PHONY: blockscout-clean
blockscout-clean: ## ⚠️ 删除 Blockscout 索引数据（L1 链数据不受影响）
	@bash scripts/blockscout-clean.sh

# =============================================================================
# Danger zone
# =============================================================================
.PHONY: clean
clean: ## ⚠️ 删除链所有数据（docker volume + keystore），不可恢复
	@bash scripts/99-clean.sh
