# CONTRIBUTING

## PR 提交流程
- 请确保每次提交：
  - 新增/变更代码均有充分单元测试
  - 文档/API 注释及时维护，主接口应为中文注释
  - 性能优化相关PR需附 wrk/ab 或相关基准简表
- Run: `zig build test && zig test src/parser_test.zig && zig test src/parser_chunked_test.zig && zig test src/parser_fuzz_test.zig`
- CI 失败或 code style/lints 未通过将自动拒绝合并

## 开发规范
- 类型/结构体/事件使用 PascalCase，变量/字段 snake_case
- 4空格缩进，不允许制表符
- 含关键业务/边界事件请写中英行内注释
- 错误路径统一使用 Zig error体系, error.*

## 性能分析&提交
- 性能重大变更需补 bench日志摘要/特定 wrk/ab 场景复现
- 主务阅读 [docs/http_parser/PLAN.md]、BENCH_GUIDE、README
