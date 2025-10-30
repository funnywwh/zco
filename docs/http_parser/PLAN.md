# HTTP 流式解析器重新实现计划（零内存积累）

## 目标
参考 wasm-http-parser 与 picohttpparser，在 Zig 中实现高性能、事件驱动、零拷贝的 HTTP/1.x 流式解析器：边解析边消费，不将完整消息保留在内存中；解决分片/粘包与 ab -k 卡死问题；具备良好的可扩展性与可维护性。

## 核心特性
- 真流式解析：输入按块增量解析，Body 通过事件逐段输出
- 零拷贝头部：仅在头部阶段使用固定缓冲区做切片引用
- 完整协议：HTTP/1.0、HTTP/1.1、Content-Length 与 chunked 编码
- 粘包/分片健壮：精准消息边界检测，处理任意分片与多请求粘连
- ab -k 兼容：严格 Content-Length 与消费边界，杜绝卡死
- 低内存：典型每连接≈8KB（HeaderBuffer 4KB + ReadBuffer 4KB）

## 实现步骤与关键文件
1) 核心解析器 `http/src/parser.zig`
   - 状态机：`START → REQUEST_LINE_* → HEADER_* → HEADERS_COMPLETE → BODY_IDENTITY/BODY_CHUNKED_* → MESSAGE_COMPLETE`
   - 事件：`on_method/on_path/on_header/on_headers_complete/on_body_chunk/on_message_complete`
   - 提供 `bytesNeeded()` 与精确 `consumed` 反馈
2) 仅头部缓冲区 `http/src/header_buffer.zig`
   - 固定 4KB，用于头部阶段的零拷贝切片
3) 流式封装
   - `http/src/streaming_request.zig`：事件落地；Body 策略：accumulate/write_file/callback
   - `http/src/streaming_response.zig`（可选）：分块响应
4) Server 集成 `http/src/server.zig`
   - 新旧解析器可切换；处理 keep-alive、超时、粘包剩余
5) 响应 Content-Length 校验 `http/src/response.zig`
   - 自动写入精确长度并完整发送
6) Cookie 与特殊头部 `http/src/cookie.zig`
   - 请求 `Cookie` 与响应 `Set-Cookie` 解析；核心仅产出原始值
7) 适配与独立性
   - `ParserConfig`、`ParserEvents`；`http/src/adapters/` 到 Request/Response 的转换

## 状态机正确性保证
- 严格状态转换表 + Debug 断言
- 不变量检查：长度/计数/模式一致
- 穷举可达性、非法转换、边界用例
- 模糊测试：随机字节不崩溃，状态合法

## 单元测试计划（覆盖重点）
- 基础解析、头部、Cookie、Body-CL、Body-chunked、粘包/分片
- 错误与容错、响应解析（若实现）、状态机保障、模糊

## 异常处理策略
- 语法错误→400；头部冲突/非法→400/431/413；Body 异常→400
- 超时→408 关闭；并发/连接超限→503；IO 错误→关闭
- 粘包隔离、错误阈值熔断、致命错误复位

## 文档与注释规范
- 公共 API 中文文档注释（///），复杂逻辑中文行内注释
- 代码变更同步更新注释/文档/测试矩阵/迁移指南；PR Checklist 强校验
- 文档目录：统一在 `docs/http_parser/`
  - `STREAMING_PARSER.md`、`COOKIE_GUIDE.md`、`TEST_MATRIX.md`、`TROUBLESHOOTING.md`、`CHANGELOG.md`、`PLAN.md`
- 禁止提交中间产物：*.tmp/*.log/*.out/原始大体量压测数据/生成的二进制等

## 架构独立性与扩展性
- 解析核心无运行时依赖；输入切片→事件；零拷贝切片由调用方提供
- 语法在核心，语义/策略在适配层
- 可配置：头数量/行长/白名单/严格模式/缓冲大小
- 可插拔：`ParserEvents` 回调集合；允许扩展统计/日志/限速
- 多协议演进：`ParserType=.request|.response`，为更高协议适配留口

## 分支与发布策略
- 基于 `feature/http-jwt-framework` 切出 `feature/http-streaming-parser`
- 小步提交，功能开关保护，默认旧解析器；模块化 PR（parser → header_buffer → streaming_request → server → cookie → 测试/基准）
- CI：构建+测试+`ab -k/wrk` 基准；回滚：一键关闭开关

## 性能评估方案
- 指标：RPS、P50/P90/P99/P99.9、错误率、CPU/上下文切换/RSS、syscalls/网络字节
- 场景：旧 vs 新；keep-alive on/off；Hello/JSON/静态/上传/chunked；并发 c∈{1,10,100,1000}；缓冲 4/8/16KB、Header 2/4/8KB；SIMD on/off
- 工具：wrk/ab/vegeta、perf、valgrind（massif/callgrind）
- 阈值：RPS -5% 失败、P99 +10% 失败、错误率 >0.1% 失败
- 专项：ab -k 连续 5 轮 c=1000 0 卡死；100MB 上传 RSS<10MB/10 分钟无泄漏；随机分片零解析错

## 成功标准
- ab -k 无卡死；Length 错误率 < 0.01%
- 大文件上传内存 < 10MB；支持任意分片与粘包
- P99 < 50ms、RPS > 100k
- 完整 chunked 流式解析与严格边界消费
