# C epoll Hello World HTTP Server

这是一个基于 epoll 的简单 C 语言 HTTP 服务器 benchmark 程序，用于性能对比测试。

## 功能

- 监听 8083 端口
- 返回 "helloworld\n" 响应
- 基于 epoll 的高性能事件驱动服务器
- 边缘触发模式（ET）
- 非阻塞 IO

## 构建要求

- GCC 编译器
- Linux 系统（epoll 是 Linux 特有的）
- Make 工具

## 构建

```bash
cd benchmark/c_server
make
```

编译后的可执行文件为 `c_server`

## 运行

```bash
# 直接运行
./c_server

# 或使用 make
make run
```

服务器将在 `http://127.0.0.1:8083` 启动。

## 测试

使用 curl 测试：

```bash
curl http://127.0.0.1:8083
```

预期输出：`helloworld`

## 性能测试

可以使用 ApacheBench (ab) 进行性能测试：

```bash
ab -n 10000 -c 100 http://127.0.0.1:8083/
```

## 端口

默认端口：**8083**

注意：

- Go 服务器使用 8081
- Zig 服务器使用 8080
- Rust 服务器使用 8082
- C 服务器使用 8083

## 技术特点

### epoll 边缘触发模式

- 使用 `EPOLLET` 标志启用边缘触发
- 更高效的事件通知机制
- 需要非阻塞 IO 配合使用

### 非阻塞 IO

- 所有 socket 都设置为非阻塞模式
- 避免阻塞事件循环
- 提高并发处理能力

### 事件驱动架构

- 单线程事件循环
- 高效处理大量并发连接
- 低延迟响应

## 清理

```bash
make clean
```

## 注意事项

1. **Linux 专用**：epoll 是 Linux 特有的系统调用，此程序只能在 Linux 系统上运行
2. **权限**：如果使用小于 1024 的端口，需要 root 权限
3. **性能**：在 Release 模式下编译以获得最佳性能
