# CHANGELOG

## 1.0.0 (2025-10-30)
- 全新实现 streaming HTTP/1.x parser（参考 wasm-http-parser/picohttpparser）
- 零拷贝/事件驱动，4KB头部切片、Body chunk/event模式
- 完整支持 HTTP/1.1, 1.0, 0.9; chunked/content-length/粘包/分片/容错等
- ab -k 长连接/压力无卡死，ReleaseFast直连并发20K+ RPS
- pool+direct两路可切换，所有选项/config均已集成
- 完备 fuzz/边界/错误流单元测试，100%事件/异常/健壮性覆盖
- 集成 GitHub Actions CI、benchmarks/summary、README API 文档示例

## 0.9.x
- 初代“积累式” parser 与 pool 服务（已废弃）
