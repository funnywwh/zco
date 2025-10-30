# Zig Streaming HTTP Parser

[![CI](https://github.com/你的组织/你的仓库/actions/workflows/ci.yml/badge.svg)](https://github.com/你的组织/你的仓库/actions)

---

## 主要文档索引
- [项目规范与计划](docs/http_parser/PLAN.md)
- [性能压测与评测指南](docs/http_parser/BENCH_GUIDE.md)
- [升级兼容/迁移指南](docs/http_parser/UPGRADE_GUIDE.md)
- [变更日志](CHANGELOG.md)
- [贡献指南](CONTRIBUTING.md)
- [文档导航/FAQ](docs/http_parser/README.md)
- [Fuzz 测试入口](src/parser_fuzz_test.zig)

## 特性&用法及其它…
（保留原典型代码、使用、性能说明、详细参见 docs/）

## 测试与验证
- 执行所有核心/边界/fuzz测试：
  ```
  zig build test
  zig test src/parser_test.zig
  zig test src/parser_chunked_test.zig
  zig test src/cookie_test.zig
  zig test src/parser_fuzz_test.zig
  ```
- CI均自动集成，见[.github/workflows/ci.yml](.github/workflows/ci.yml)

## 性能与基准
- ReleaseFast + direct模式 RPS 20k+（2核本机 wrk/ab）
- pool模式 RPS ~1K，推荐用直连协程高并发
相关脚本见 [benchmarks/scripts/http_bench.sh](benchmarks/scripts/http_bench.sh)

## 文档与扩展阅读
- [docs/http_parser/PLAN.md](docs/http_parser/PLAN.md)
- [docs/http_parser/BENCH_GUIDE.md](docs/http_parser/BENCH_GUIDE.md)
- [docs/http_parser/STREAMING_PARSER.md]（可补充）

## License
MIT
