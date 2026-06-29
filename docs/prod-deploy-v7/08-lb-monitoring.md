# 机器 #8：LB / 网关 + 监控

> 角色：公网入口（nginx + TLS）+ 可观测（Prometheus / Grafana）。
> 公网只暴露这台的 80/443；后端各机端口只在内网。

---

## 1. 硬件

| 项 | 推荐 | 最低 |
|---|---|---|
| CPU | 4 vCPU | 2 vCPU |
| 内存 | 16 GB | 8 GB |
| 磁盘 | SSD 200 GB（Prometheus TSDB 按保留期）| 100 GB |

## 2. 端口 / 防火墙

| 端口 | 用途 | 范围 |
|---|---|---|
| 22 | SSH | 白名单 |
| 80/443 | 公网 HTTPS 入口（RPC + 浏览器）| `0.0.0.0/0` |
| 3000 | Grafana | 内网/白名单 |
| 9090 | Prometheus | 内网 |

## 3. nginx 反代（公网入口）

参考 `dev/l1/nginx/devl1.example.com.conf` 与历史 `dev.example.com` 配置。核心路由：

```nginx
# —— 官方 RPC：写走 bundle-proxy(#3)，读走副本(#5/#6) ——
upstream l2_write { server <主seq#3内网IP>:9560; }           # bundle-proxy（dApp 唯一写入口）
upstream l2_read  { server <副本#5内网IP>:9545;               # 只读副本，负载均衡
                    server <副本#6内网IP>:9545; keepalive 32; }

server {
  listen 443 ssl http2;
  server_name man-seed-dev.example.com;       # 官方 RPC 域名
  ssl_certificate     /etc/nginx/ssl/example.com.pem;
  ssl_certificate_key /etc/nginx/ssl/example.com.key;

  # 写路径（eth_sendRawTransaction 等）→ bundle-proxy
  location / {
    proxy_pass http://l2_write;
    proxy_set_header Host $host;
    proxy_http_version 1.1;
    # 如需读写分流，可在 openresty/网关层按 method 路由：写→l2_write，读→l2_read
  }
}

# —— 浏览器（Blockscout #7）——
server {
  listen 443 ssl http2;
  server_name scan.example.com;
  location /api    { proxy_pass http://<bs#7内网IP>:4001; }
  location /socket { proxy_pass http://<bs#7内网IP>:4001;   # WebSocket 实时刷新
                     proxy_http_version 1.1;
                     proxy_set_header Upgrade $http_upgrade;
                     proxy_set_header Connection "upgrade"; }
  location /       { proxy_pass http://<bs#7内网IP>:4000; }
}
```

```bash
sudo apt install -y nginx
# 放置证书（通配 *.example.com）到 /etc/nginx/ssl/
sudo nginx -t && sudo systemctl reload nginx
```

> dApp/钱包 RPC 用 `https://man-seed-dev.example.com`（→ bundle-proxy）。**bundle-proxy 才是 dApp 唯一写入口**，不要把公网直接指 op-geth。

## 4. 监控（Prometheus + Grafana）

抓取目标（各机内网）：

```yaml
# prometheus.yml scrape_configs 摘要
- job_name: bundle-proxy   # 入口层 QPS/限流/熔断
  static_configs: [{ targets: ['<主seq#3内网IP>:9561'] }]   # /metrics
- job_name: op-geth        # 各 op-geth：sequencer + 副本
  metrics_path: /debug/metrics/prometheus
  static_configs: [{ targets: ['<#3>:6060','<#5>:6060','<#6>:6060'] }]
- job_name: rollup-boost
  static_configs: [{ targets: ['<#3内网IP>:6062'] }]   # 按实际 metrics 端口
- job_name: node-exporter  # 各机主机指标（CPU/IO/磁盘）
  static_configs: [{ targets: ['<每台>:9100'] }]
```

```bash
# 用 docker 起 prometheus + grafana + node-exporter（各机装 node-exporter）
docker run -d --name prometheus -p 9090:9090 -v /data/prometheus.yml:/etc/prometheus/prometheus.yml prom/prometheus
docker run -d --name grafana -p 3000:3000 grafana/grafana
```

## 5. 关键告警（必配）

| 告警 | 条件 | 含义 |
|---|---|---|
| L1 出块停 | L1 Block# 5min 不增 | #1/#2 L1 异常 |
| L2 unsafe 停 | sequencer head 不增 | #3 出块异常 |
| safe 落后 | unsafe - safe 持续拉大 | batcher/DA 异常（查 l1-proxy）|
| bundle-proxy both_failed | `bundle_proxy_rpc_total{outcome="both_failed"}` 增长 | 写入口全挂 |
| 副本 lag | 副本 head 落后主 > 阈值 | #5/#6 同步异常 |
| 磁盘 | NVMe 使用率 > 80% | 扩容/清理 |
| 验证者/出块节点 down | 容器 not running | 触发故障切换流程 |

## 6. 验收

- 公网 `https://man-seed-dev.example.com` 返回 `eth_chainId=0x2ae54`、`eth_blockNumber` 递增；
- `https://scan.example.com` 浏览器正常、实时刷新；
- Grafana 看到各机 CPU/IO、链 head、bundle-proxy QPS/熔断状态。
