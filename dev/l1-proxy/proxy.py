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
  - 支持单 JSON 和 batch JSON 两种请求

依赖：纯标准库，无 pip 安装。
环境变量：UPSTREAM = 后端真 L1 URL。
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
import urllib.request

UPSTREAM = os.environ.get("UPSTREAM", "http://172.31.22.10:8545")


def intercept(p):
    if isinstance(p, dict) and p.get("method") == "eth_blobBaseFee":
        return {"jsonrpc": "2.0", "id": p.get("id"), "result": "0x1"}
    return None


class H(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            req = json.loads(body)
        except Exception:
            self.send_response(400)
            self.end_headers()
            return

        if isinstance(req, list):
            results = [intercept(p) for p in req]
            if all(r is not None for r in results):
                self._reply_json(200, results)
                return
        else:
            r = intercept(req)
            if r is not None:
                self._reply_json(200, r)
                return

        try:
            rr = urllib.request.Request(
                UPSTREAM,
                data=body,
                headers={"Content-Type": "application/json"},
            )
            resp = urllib.request.urlopen(rr, timeout=30)
            data = resp.read()
            self.send_response(resp.status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            err = {
                "jsonrpc": "2.0",
                "error": {"code": -32603, "message": f"proxy upstream error: {e}"},
                "id": None,
            }
            self._reply_json(502, err)

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
    HTTPServer(("0.0.0.0", 8546), H).serve_forever()
