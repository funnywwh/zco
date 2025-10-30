#!/usr/bin/env bash
set -euo pipefail

# 简单 HTTP 基准测试脚本（ab / wrk）
# 用法：
#   ./scripts/http_bench.sh start   # 启动示例服务器
#   ./scripts/http_bench.sh ab      # 运行 ab -k 压测
#   ./scripts/http_bench.sh wrk     # 运行 wrk 压测
#   ./scripts/http_bench.sh stop    # 停止示例服务器

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT_DIR/http/zig-out/bin/http"
LOG_DIR="$ROOT_DIR/benchmarks/results"
mkdir -p "$LOG_DIR"

start_server() {
  echo "[+] building and starting server..."
  (cd "$ROOT_DIR/http" && zig build -Doptimize=ReleaseFast)
  # 后台启动（若已有同端口服务，请先手动停止）
  (cd "$ROOT_DIR/http" && ./zig-out/bin/http > "$LOG_DIR/server.out" 2>&1 & echo $! > "$LOG_DIR/server.pid")
  echo "[+] server pid: $(cat "$LOG_DIR/server.pid")"
  sleep 1
}

stop_server() {
  if [[ -f "$LOG_DIR/server.pid" ]]; then
    PID=$(cat "$LOG_DIR/server.pid")
    echo "[+] stopping server pid $PID"
    kill "$PID" || true
    rm -f "$LOG_DIR/server.pid"
  fi
}

run_ab() {
  URL=${1:-http://127.0.0.1:8080/}
  N=${N:-200000}
  C=${C:-400}
  OUT="$LOG_DIR/ab_k_n${N}_c${C}.txt"
  echo "[+] ab -k -n $N -c $C $URL"
  ab -k -n "$N" -c "$C" "$URL" | tee "$OUT"
  echo "[+] result saved: $OUT"
}

run_wrk() {
  URL=${1:-http://127.0.0.1:8080/}
  T=${T:-12}
  C=${C:-400}
  D=${D:-30s}
  OUT="$LOG_DIR/wrk_t${T}_c${C}_d${D}.txt"
  echo "[+] wrk -t$T -c$C -d$D $URL"
  wrk -t"$T" -c"$C" -d"$D" "$URL" | tee "$OUT"
  echo "[+] result saved: $OUT"
}

case "${1:-}" in
  start) start_server ;;
  stop) stop_server ;;
  ab) run_ab "$2" ;;
  wrk) run_wrk "$2" ;;
  *) echo "usage: $0 {start|ab|wrk|stop}" ; exit 1 ;;
esac


