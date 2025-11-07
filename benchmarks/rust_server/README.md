# Rust Hello World Benchmark Server

这是一个简单的 Rust HTTP 服务器 benchmark 程序，用于性能对比测试。

## 功能

- 监听 8082 端口
- 返回 "helloworld\n" 响应
- 基于 tokio 的异步 HTTP 服务器
- 轻量级实现，最小化依赖

## 构建要求

- Rust 1.70+ (推荐使用 rustup 安装，已测试 Rust 1.81+)
- Cargo (Rust 包管理器)

## 安装 Rust

如果还没有安装 Rust，可以使用以下命令：

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source $HOME/.cargo/env
```

## 构建

```bash
cd benchmark/rust_server
cargo build --release
```

编译后的可执行文件位于 `target/release/rust_server`

## 运行

```bash
# 开发模式
cargo run

# 发布模式（推荐用于 benchmark）
cargo run --release
```

服务器将在 `http://127.0.0.1:8082` 启动。

## 测试

使用 curl 测试：

```bash
curl http://127.0.0.1:8082
```

预期输出：`helloworld`

## 性能测试

可以使用 ApacheBench (ab) 进行性能测试：

```bash
ab -n 10000 -c 100 http://127.0.0.1:8082/
```

## 端口

默认端口：**8082**

注意：Go 服务器使用 8081，Zig 服务器使用 8080，Rust 服务器使用 8082。
