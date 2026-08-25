#!/usr/bin/env python3
"""
L1 JSON-RPC proxy.

为什么：
  op-batcher v1.16.7 在 SimpleTxManager.suggestGasPriceCaps 里无条件调
  eth_blobBaseFee 估 blob gas price，即使指定 --data-availability-type=calldata
  也没绕开。Geth Clique（无 Cancun fork）不暴露这个 method
  → batcher 永远卡在 "Failed to create a transaction, will retry"
  → L2 出块但 batch 没人提交 → safe head 永远不动。

做了什么：
  - 监听 :8546 接收 JSON-RPC 请求
  - 拦截 method == "eth_blobBaseFee" 直接返回 {"result": "0x1"}
    (op-batcher 在 calldata 模式下不会真用这个 blob fee 数字)
  - 其他 RPC 一律透传给 UPSTREAM（默认 http://172.31.22.10:8545）
  - 支持单 JSON 和 batch JSON；batch 内逐条拦截，未命中的子集才转发上游，
    再按 id 合并回原顺序（避免混合 batch 把 eth_blobBaseFee 透传到无 Cancun 的 geth）
  - 多线程处理（op-node 与 op-batcher 并发打到本代理，避免队头阻塞）

依赖：纯标准库，无 pip 安装。
环境变量：
  UPSTREAM      后端真 L1 URL（默认 http://172.31.22.10:8545）
  MAX_BODY      请求体字节上限，默认 2MB
"""

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import urllib.request

UPSTREAM = os.environ.get("UPSTREAM", "http://172.31.22.10:8545")
MAX_BODY = int(os.environ.get("MAX_BODY", str(2 * 1024 * 1024)))


def intercept(p):
    if isinstance(p, dict) and p.get("method") == "eth_blobBaseFee":
        return {"jsonrpc": "2.0", "id": p.get("id"), "result": "0x1"}
    return None


def forward_upstream(payload):
    """把任意 payload（dict 或 list）转发给上游并返回解析后的 JSON。"""
    body = json.dumps(payload).encode()
    rr = urllib.request.Request(
        UPSTREAM,
        data=body,
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(rr, timeout=30) as resp:
        return json.loads(resp.read())


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        if length > MAX_BODY:
            self._reply_json(413, {
                "jsonrpc": "2.0",
                "error": {"code": -32600, "message": "request body too large"},
                "id": None,
            })
            return
        body = self.rfile.read(length)
        try:
            req = json.loads(body)
        except Exception:
            self._reply_json(400, {
                "jsonrpc": "2.0",
                "error": {"code": -32700, "message": "parse error"},
                "id": None,
            })
            return

        try:
            if isinstance(req, list):
                self._reply_json(200, self._handle_batch(req))
            else:
                r = intercept(req)
                self._reply_json(200, r if r is not None else forward_upstream(req))
        except Exception as e:
            self._reply_json(502, {
                "jsonrpc": "2.0",
                "error": {"code": -32603, "message": f"proxy upstream error: {e}"},
                "id": None,
            })

    def _handle_batch(self, items):
        # 先逐条本地拦截，未命中的收集起来一次性转发上游，再按 id 合并回原顺序。
        results = [None] * len(items)
        passthrough = []
        passthrough_idx = []
        for i, p in enumerate(items):
            local = intercept(p)
            if local is not None:
                results[i] = local
            else:
                passthrough.append(p)
                passthrough_idx.append(i)

        if passthrough:
            upstream_resp = forward_upstream(passthrough)
            if isinstance(upstream_resp, list):
                by_id = {}
                for r in upstream_resp:
                    if isinstance(r, dict):
                        by_id[json.dumps(r.get("id"))] = r
                for offset, idx in enumerate(passthrough_idx):
                    key = json.dumps(passthrough[offset].get("id") if isinstance(passthrough[offset], dict) else None)
                    results[idx] = by_id.pop(key, None) or (
                        upstream_resp[offset] if offset < len(upstream_resp) else None
                    )
            else:
                # 上游对 batch 回了非列表（异常），整体回退为该响应
                return upstream_resp
        return results

    def _reply_json(self, status, obj):
        out = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        return


if __name__ == "__main__":
    print(f"l1-blob-proxy: :8546 -> {UPSTREAM}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8546), H).serve_forever()
