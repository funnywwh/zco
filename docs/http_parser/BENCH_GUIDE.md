# HTTP 基准测试指南（ab / wrk）

## 准备
- 确保示例已开启流式解析器（已在 `http/src/main.zig` 默认启用）
- 提升系统限制（可选）：
  - `ulimit -n 1048576`
  - `sysctl -w net.core.somaxconn=65535`

## 启停脚本
```bash
# 启动示例服务器（ReleaseFast）
./scripts/http_bench.sh start

# ab -k 压测（默认 n=200000, c=400）
./scripts/http_bench.sh ab

# wrk 压测（默认 t=12 c=400 d=30s）
./scripts/http_bench.sh wrk

# 停止示例服务器
./scripts/http_bench.sh stop
```

## 建议用例
- Keep-Alive：`ab -k -n 200000 -c 400 http://127.0.0.1:8080/`
- 高并发：`wrk -t12 -c1000 -d30s http://127.0.0.1:8080/`
- 结果保存在 `benchmarks/results/` 目录下。

## 验收阈值（参考 PLAN）
- RPS 不低于基线 -5%
- P99 不高于基线 +10%
- 错误率 < 0.1%

> 如需自定义参数：
> - `N=500000 C=800 ./scripts/http_bench.sh ab`
> - `T=16 C=800 D=60s ./scripts/http_bench.sh wrk`
