// mock-rbuilder/index.js — 假 op-rbuilder + op-geth + flashblocks-rpc
//
// 用途：让 bundle-proxy 单元测试 / smoke 测试能在 chain-test2 没起的环境下跑。
// 三个 endpoint 都跑在同一个 fastify 上，用 routePrefix 区分：
//   POST /rbuilder           -> 模拟 op-rbuilder eth_sendBundle
//   POST /opgeth             -> 模拟 op-geth eth_sendRawTransaction / eth_blockNumber
//   POST /flashblocks        -> 模拟 flashblocks-rpc 读路径
//
// 行为模拟：
//   - eth_sendBundle:           accept 一切，返回 bundleHash（fake）
//   - eth_sendRawTransaction:   accept 一切，返回 txHash（用 viem 算）
//   - eth_blockNumber:          自增计数器，0x1 起每秒 +1
//   - eth_chainId / net_version: 175700
//   - eth_call:                 返回 0x（empty）
//   - 其他读：返回 null
//
// 故障注入（用 query string 控制）：
//   GET /control/rbuilder/down              op-rbuilder 接下来都返 503
//   GET /control/rbuilder/up                op-rbuilder 恢复
//   GET /control/rbuilder/slow?ms=2000      op-rbuilder 每个请求加 2s 延迟
//   GET /control/rbuilder/normal            清掉延迟

import Fastify from 'fastify';
import { keccak256 } from 'viem';

const PORT = parseInt(process.env.MOCK_PORT || '18545', 10);
const CHAIN_ID = parseInt(process.env.MOCK_CHAIN_ID || '175700', 10);

let blockNumber = 1;
setInterval(() => { blockNumber++; }, 1000).unref();

const failure = {
  rbuilder_down: false,
  rbuilder_slow_ms: 0,
  opgeth_down: false,
};

function rpcResp(id, result) {
  return { jsonrpc: '2.0', id, result };
}

function rpcErr(id, code, message) {
  return { jsonrpc: '2.0', id, error: { code, message } };
}

async function handleRbuilder(req, reply) {
  if (failure.rbuilder_down) {
    return reply.code(503).send('Too many connections');
  }
  if (failure.rbuilder_slow_ms > 0) {
    await new Promise((r) => setTimeout(r, failure.rbuilder_slow_ms));
  }

  const body = req.body;
  const id = body?.id ?? null;
  switch (body?.method) {
    case 'eth_sendBundle': {
      const bundle = body.params?.[0];
      if (!bundle || !Array.isArray(bundle.txs) || bundle.txs.length === 0) {
        return reply.send(rpcErr(id, -32602, 'invalid bundle'));
      }
      const fakeBundleHash = keccak256(bundle.txs[0]);
      return reply.send(rpcResp(id, { bundleHash: fakeBundleHash }));
    }
    case 'eth_chainId':
      return reply.send(rpcResp(id, '0x' + CHAIN_ID.toString(16)));
    case 'eth_blockNumber':
      return reply.send(rpcResp(id, '0x' + blockNumber.toString(16)));
    default:
      return reply.send(rpcErr(id, -32601, `mock-rbuilder: method ${body?.method} not supported`));
  }
}

async function handleOpgeth(req, reply) {
  if (failure.opgeth_down) {
    return reply.code(503).send('opgeth down');
  }
  const body = req.body;
  const id = body?.id ?? null;
  switch (body?.method) {
    case 'eth_sendRawTransaction': {
      const raw = body.params?.[0];
      if (typeof raw !== 'string') {
        return reply.send(rpcErr(id, -32602, 'invalid raw tx'));
      }
      return reply.send(rpcResp(id, keccak256(raw)));
    }
    case 'eth_chainId':
      return reply.send(rpcResp(id, '0x' + CHAIN_ID.toString(16)));
    case 'net_version':
      return reply.send(rpcResp(id, String(CHAIN_ID)));
    case 'eth_blockNumber':
      return reply.send(rpcResp(id, '0x' + blockNumber.toString(16)));
    case 'eth_getBlockByNumber':
      return reply.send(rpcResp(id, {
        number: '0x' + blockNumber.toString(16),
        hash: '0x' + 'aa'.repeat(32),
        parentHash: '0x' + 'bb'.repeat(32),
        timestamp: '0x' + Math.floor(Date.now() / 1000).toString(16),
        transactions: [],
      }));
    case 'web3_clientVersion':
      return reply.send(rpcResp(id, 'mock-rbuilder/0.1.0'));
    default:
      return reply.send(rpcErr(id, -32601, `mock-opgeth: method ${body?.method} not supported`));
  }
}

async function handleFlashblocks(req, reply) {
  const body = req.body;
  const id = body?.id ?? null;
  switch (body?.method) {
    case 'eth_getBalance':
      return reply.send(rpcResp(id, '0x56bc75e2d63100000')); // 100 ETH in wei
    case 'eth_getTransactionByHash':
    case 'eth_getTransactionReceipt':
      return reply.send(rpcResp(id, null));
    case 'eth_blockNumber':
      return reply.send(rpcResp(id, '0x' + blockNumber.toString(16)));
    case 'eth_call':
      return reply.send(rpcResp(id, '0x'));
    case 'eth_estimateGas':
      return reply.send(rpcResp(id, '0x5208')); // 21000
    case 'eth_gasPrice':
      return reply.send(rpcResp(id, '0x3b9aca00')); // 1 gwei
    case 'eth_getTransactionCount':
      return reply.send(rpcResp(id, '0x0'));
    default:
      return reply.send(rpcErr(id, -32601, `mock-flashblocks: method ${body?.method} not supported`));
  }
}

export async function startMock() {
  const app = Fastify({ logger: { level: process.env.MOCK_LOG_LEVEL || 'warn' } });

  app.post('/rbuilder', handleRbuilder);
  app.post('/opgeth', handleOpgeth);
  app.post('/flashblocks', handleFlashblocks);

  app.get('/control/rbuilder/down',   async () => { failure.rbuilder_down = true; return { ok: true }; });
  app.get('/control/rbuilder/up',     async () => { failure.rbuilder_down = false; return { ok: true }; });
  app.get('/control/rbuilder/slow',   async (req) => { failure.rbuilder_slow_ms = parseInt(req.query.ms || '0', 10); return { ok: true, ms: failure.rbuilder_slow_ms }; });
  app.get('/control/rbuilder/normal', async () => { failure.rbuilder_slow_ms = 0; return { ok: true }; });
  app.get('/control/opgeth/down',     async () => { failure.opgeth_down = true; return { ok: true }; });
  app.get('/control/opgeth/up',       async () => { failure.opgeth_down = false; return { ok: true }; });
  app.get('/healthz', async () => ({ ok: true, blockNumber }));

  await app.listen({ host: '127.0.0.1', port: PORT });
  console.log(`[mock-rbuilder] listening on http://127.0.0.1:${PORT}`);
  console.log(`  POST /rbuilder      -> simulate op-rbuilder eth_sendBundle`);
  console.log(`  POST /opgeth        -> simulate op-geth eth_sendRawTransaction`);
  console.log(`  POST /flashblocks   -> simulate flashblocks-rpc reads`);
  console.log(`  GET  /control/...   -> failure injection`);
  return app;
}

const isMain = import.meta.url === `file://${process.argv[1]}` ||
               process.argv[1]?.endsWith('/mock-rbuilder/index.js');
if (isMain) {
  startMock().catch((e) => {
    console.error(e);
    process.exit(1);
  });
}
