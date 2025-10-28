# ZCO 0.4.0 - Performance Optimization Release

## 🎯 What's New

A major performance update with significant improvements to scheduler efficiency, memory management, and HTTP processing.

### ⚡ Key Improvements

- **50% better performance** in low-concurrency scenarios (surpassing Go by 14.5%)
- **O(log n) → O(1)** scheduler efficiency improvement
- **50% memory reduction** (8KB → 4KB stack size)
- **Three-level pooling** architecture

### 📊 Performance Benchmarks

| Test | ZCO RPS | vs Go |
|------|---------|-------|
| 1000 req, 10 con | 44,308 | +14.5% |
| 10k req, 100 con | 44,944 | Competitive |
| 50k req, 500 con | 43,646 | Competitive |

### 🔧 Major Features

**Scheduler**
- ArrayList-based scheduling (O(1) insertion)
- Dynamic batch processing (16-128 coroutines/batch)
- Optimized signal handling

**Memory Management**
- Memory pool (1000 × 1KB blocks)
- Coroutine pool (500 objects)
- Connection pool (200 TCP connections)

**Network**
- TCP_NODELAY for reduced latency
- Connection reuse optimization

**HTTP**
- SIMD-accelerated string matching
- Pre-compiled responses
- 1000-entry response cache
- Zero-copy buffers

**System**
- Branch prediction hints
- CPU affinity interface
- Memory alignment optimization

### 📦 Installation

```bash
git clone https://github.com/funnywwh/zco.git
cd zco
zig build
```

### 🔄 Upgrade

No breaking changes. This is a performance-focused release maintaining full API compatibility.

### 📝 Full Changelog

See [CHANGELOG_V0.4.0.md](./CHANGELOG_V0.4.0.md) for complete details.
