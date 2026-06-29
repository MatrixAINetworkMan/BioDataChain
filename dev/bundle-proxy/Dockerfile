# =============================================================================
# bundle-proxy — JSON-RPC adapter for op-rbuilder eth_sendBundle
#
# 角色（Phase 2 Flashblocks 接入层）：
#   dApp eth_sendRawTransaction → bundle-proxy → op-rbuilder eth_sendBundle
#
# 设计要点：
#   - alpine + node:20，~150MB 镜像
#   - 不 root：以 node 用户跑（防容器逃逸）
#   - npm ci 走 lock 文件（reproducible build）
#   - HEALTHCHECK 覆盖容器自愈
# =============================================================================

FROM node:20-alpine AS deps

WORKDIR /app

COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi


FROM node:20-alpine AS runtime

# tini：PID 1 信号转发，docker stop 时让 fastify 正常 close（不至于 SIGKILL 丢请求）
RUN apk add --no-cache tini wget

WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# Node 用户（uid 1000，alpine node 镜像内置）
USER node

EXPOSE 9560 9561

# /healthz 走 fastify ready hook，500ms 内必返
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:9560/healthz || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]
