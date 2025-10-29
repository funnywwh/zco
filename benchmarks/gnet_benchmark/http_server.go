package main

import (
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/panjf2000/gnet/v2"
)

// HTTP 基准测试服务器
type HTTPBenchmarkServer struct {
	*gnet.BuiltinEventEngine

	port      string
	multicore bool
	async     bool
}

func main() {
	var (
		port      = flag.String("port", "8082", "服务器端口")
		multicore = flag.Bool("multicore", false, "是否使用多核")
		async     = flag.Bool("async", false, "是否使用异步模式")
		verbose   = flag.Bool("verbose", false, "详细日志")
	)
	flag.Parse()

	if *verbose {
		log.SetFlags(log.LstdFlags | log.Lshortfile)
	}

	server := &HTTPBenchmarkServer{
		port:      *port,
		multicore: *multicore,
		async:     *async,
	}

	// 启动服务器
	addr := fmt.Sprintf("tcp://:%s", *port)
	log.Printf("启动 gnet HTTP 基准测试服务器: %s", addr)
	log.Printf("配置: multicore=%v, async=%v", *multicore, *async)

	err := gnet.Run(server,
		addr,
		gnet.WithTCPNoDelay(gnet.TCPNoDelay),
		gnet.WithReusePort(true),
		gnet.WithMulticore(server.multicore),
		gnet.WithLockOSThread(false),
		gnet.WithTicker(true),
	)
	if err != nil {
		log.Fatalf("服务器启动失败: %v", err)
	}
}

// OnBoot 服务器启动时调用
func (s *HTTPBenchmarkServer) OnBoot(eng gnet.Engine) (action gnet.Action) {
	log.Printf("gnet HTTP 服务器已启动")
	return
}

// OnOpen 新连接建立时调用
func (s *HTTPBenchmarkServer) OnOpen(c gnet.Conn) (out []byte, action gnet.Action) {
	return
}

// OnTraffic 接收到数据时调用
func (s *HTTPBenchmarkServer) OnTraffic(c gnet.Conn) (action gnet.Action) {
	data, _ := c.Next(-1) // 读取所有可用数据
	if len(data) == 0 {
		return
	}

	// 检查是否是完整的HTTP请求
	if !s.isCompleteHTTPRequest(data) {
		return gnet.None
	}

	// 优化的 HTTP 响应
	response := []byte("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld")

	// 直接写入响应并关闭连接
	_, err := c.Write(response)
	if err != nil {
		return gnet.Close
	}

	// 发送完响应后关闭连接
	return gnet.Close
}

// OnClose 连接关闭时调用
func (s *HTTPBenchmarkServer) OnClose(c gnet.Conn, err error) (action gnet.Action) {

	return
}

// isCompleteHTTPRequest 检查是否是完整的HTTP请求
func (s *HTTPBenchmarkServer) isCompleteHTTPRequest(data []byte) bool {
	// 查找HTTP请求结束标志 \r\n\r\n
	for i := 0; i < len(data)-3; i++ {
		if data[i] == '\r' && data[i+1] == '\n' &&
			data[i+2] == '\r' && data[i+3] == '\n' {
			return true
		}
	}
	return false
}

// OnShutdown 服务器关闭时调用
func (s *HTTPBenchmarkServer) OnShutdown(eng gnet.Engine) {
	log.Printf("gnet HTTP 服务器正在关闭...")
}

// OnTick 定时器事件
func (s *HTTPBenchmarkServer) OnTick() (delay time.Duration, action gnet.Action) {
	// 每秒触发一次统计报告
	return time.Second, gnet.None
}
