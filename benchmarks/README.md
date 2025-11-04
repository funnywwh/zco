# 性能测试基准

这个目录包含了 ZCO 与 Go 协程库的性能对比测试。

## 目录结构

```
benchmarks/
├── README.md              # 本文件
├── quick_test.sh          # 快速性能测试脚本
├── run_benchmark.sh       # 完整性能测试脚本
├── go_server/             # Go HTTP 服务器
│   ├── main.go
│   └── go.mod
├── zig_server/            # ZCO HTTP 服务器
│   ├── main.zig
│   ├── build.zig
│   └── build.zig.zon
└── results/               # 测试结果目录
```

## 快速开始

### 运行快速测试

```bash
cd benchmarks
./quick_test.sh
```

这将运行一个简化的性能测试，对比 ZCO 和 Go 服务器在 10,000 请求、100 并发连接下的性能。

### 运行完整测试

```bash
cd benchmarks
./run_benchmark.sh
```

这将运行多个测试用例，包括：
- 1,000 请求，10 并发
- 10,000 请求，100 并发
- 50,000 请求，500 并发
- 100,000 请求，1,000 并发

## 测试环境要求

- **Zig**: 0.14.0+
- **Go**: 1.21+
- **ApacheBench (ab)**: 用于 HTTP 性能测试
- **curl**: 用于服务器健康检查

### 安装依赖

#### Ubuntu/Debian
```bash
sudo apt update
sudo apt install zig golang-go apache2-utils curl
```

#### CentOS/RHEL
```bash
sudo yum install zig golang apache2-utils curl
```

## 测试服务器说明

### ZCO 服务器 (zig_server/)

- **端口**: 8080
- **特性**: 基于 ZCO 协程库的高性能 HTTP 服务器
- **调度**: 强制时间片抢占调度
- **栈大小**: 16KB (Release 模式)

### Go 服务器 (go_server/)

- **端口**: 8081
- **特性**: 基于 Go 标准库的 HTTP 服务器
- **调度**: Go 运行时调度器
- **GOMAXPROCS**: 1 (模拟单线程协程调度)

## 性能指标

测试将测量以下关键指标：

- **RPS (Requests Per Second)**: 每秒处理的请求数
- **平均响应时间**: 每个请求的平均处理时间
- **失败请求数**: 处理失败的请求数量
- **并发处理能力**: 在高并发下的稳定性

## 结果分析

### 预期性能特征

**ZCO 优势**:
- 更低的协程创建开销
- 更快的上下文切换
- 强制抢占调度，防止饿死
- 更小的运行时开销

**Go 优势**:
- 成熟的生态系统
- 自动垃圾回收
- 更丰富的标准库
- 更好的调试工具

### 典型结果示例

```
ZCO Results:
  RPS: 15,000
  Avg Time: 6.67 ms
  Failed: 0

Go Results:
  RPS: 12,000
  Avg Time: 8.33 ms
  Failed: 0
```

## 自定义测试

### 修改测试参数

编辑 `quick_test.sh` 或 `run_benchmark.sh` 中的测试参数：

```bash
# 修改请求数和并发数
test_server "ZCO" 8080 50000 500
```

### 添加新的测试用例

在 `run_benchmark.sh` 中的 `TEST_CASES` 数组添加新的测试用例：

```bash
TEST_CASES=(
    "1000:10"      # 1000 requests, 10 concurrent
    "10000:100"    # 10000 requests, 100 concurrent
    "50000:500"    # 50000 requests, 500 concurrent
    "100000:1000"  # 100000 requests, 1000 concurrent
    "200000:2000"  # 200000 requests, 2000 concurrent (新增)
)
```

## 故障排除

### 常见问题

1. **端口被占用**
   ```bash
   # 检查端口使用情况
   netstat -tlnp | grep :808
   
   # 杀死占用端口的进程
   sudo kill -9 <PID>
   ```

2. **服务器启动失败**
   - 检查依赖是否正确安装
   - 确保端口没有被占用
   - 查看服务器日志输出

3. **测试结果异常**
   - 确保系统资源充足
   - 检查网络连接
   - 验证服务器响应正常

### 调试模式

启用详细日志输出：

```bash
# 设置环境变量
export ZCO_DEBUG=1
export GO_DEBUG=1

# 运行测试
./quick_test.sh
```

## 贡献

欢迎提交性能测试的改进建议：

1. 添加新的测试用例
2. 优化测试脚本
3. 改进结果分析
4. 添加更多性能指标

## 许可证

本测试代码遵循与主项目相同的 MIT 许可证。


