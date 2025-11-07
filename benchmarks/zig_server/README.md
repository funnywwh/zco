# ZCO HelloWorld Server

这是一个使用 ZCO 协程库实现的简单 HTTP HelloWorld 服务器，用于 Apache Bench (ab) 性能测试。

## 功能特性

- 使用 ZCO 协程实现异步 I/O
- 支持 HTTP Keep-Alive 连接
- 返回简单的 "helloworld" 响应
- 监听 127.0.0.1:8080

## 构建

```bash
cd benchmarks/zig_server
zig build
```

构建后的可执行文件位于 `zig-out/bin/zig_server`。

## 运行

```bash
# 方式1: 使用 zig build run
zig build run

# 方式2: 直接运行可执行文件
./zig-out/bin/zig_server
```

服务器将在 `127.0.0.1:8080` 上启动。

## 使用 Apache Bench 测试

```bash
# 基本测试（1000 个请求，10 个并发）
ab -n 1000 -c 10 http://127.0.0.1:8080/

# 使用 keep-alive 测试
ab -n 10000 -c 100 -k http://127.0.0.1:8080/

# 性能测试（100000 个请求，1000 个并发）
ab -n 100000 -c 1000 -k http://127.0.0.1:8080/
```

## 代码说明

- `main.zig`: 主程序文件
  - `main()`: 初始化 ZCO 并启动服务器
  - `runServer()`: 服务器主循环，接受连接并为每个连接创建协程
  - `handleClient()`: 处理客户端请求，支持 keep-alive

## 响应格式

服务器返回标准的 HTTP 响应：

```
HTTP/1.1 200 OK
Content-Type: text/plain
Connection: keep-alive
Content-Length: 10

helloworld
```

## 依赖

- ZCO 协程库
- nets 网络模块
- libxev 异步事件循环库

