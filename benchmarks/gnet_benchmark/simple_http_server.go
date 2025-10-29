package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"runtime"
	"sync/atomic"
	"time"
)

// HTTP 性能统计结构
type HTTPStats struct {
	connections   int64
	requests      int64
	bytesReceived int64
	bytesSent     int64
	startTime     time.Time
}

// HTTP 基准测试服务器
type HTTPBenchmarkServer struct {
	stats *HTTPStats
}

func main() {
	var (
		port    = flag.String("port", "8082", "服务器端口")
		verbose = flag.Bool("verbose", false, "详细日志")
	)
	flag.Parse()

	if *verbose {
		log.SetFlags(log.LstdFlags | log.Lshortfile)
	}

	server := &HTTPBenchmarkServer{
		stats: &HTTPStats{
			startTime: time.Now(),
		},
	}

	// 启动统计报告
	go server.reportStats()

	// 设置路由
	http.HandleFunc("/", server.handleRequest)

	// 启动服务器
	addr := fmt.Sprintf(":%s", *port)
	log.Printf("启动 HTTP 基准测试服务器: %s", addr)

	err := http.ListenAndServe(addr, nil)
	if err != nil {
		log.Fatalf("服务器启动失败: %v", err)
	}
}

// handleRequest 处理 HTTP 请求
func (s *HTTPBenchmarkServer) handleRequest(w http.ResponseWriter, r *http.Request) {
	atomic.AddInt64(&s.stats.requests, 1)
	atomic.AddInt64(&s.stats.bytesReceived, int64(r.ContentLength))

	// 简单的响应
	response := "Hello, gnet!"
	w.Header().Set("Content-Type", "text/html")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(response)))
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(response))

	atomic.AddInt64(&s.stats.bytesSent, int64(len(response)))
}

// reportStats 定期报告性能统计
func (s *HTTPBenchmarkServer) reportStats() {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			s.printStats()
		}
	}
}

// printStats 打印性能统计信息
func (s *HTTPBenchmarkServer) printStats() {
	now := time.Now()
	duration := now.Sub(s.stats.startTime)

	requests := atomic.LoadInt64(&s.stats.requests)
	bytesReceived := atomic.LoadInt64(&s.stats.bytesReceived)
	bytesSent := atomic.LoadInt64(&s.stats.bytesSent)

	var m runtime.MemStats
	runtime.ReadMemStats(&m)

	log.Printf("=== HTTP 性能统计 (运行时间: %v) ===", duration.Round(time.Second))
	log.Printf("总请求数: %d", requests)
	log.Printf("接收字节数: %d (%.2f MB)", bytesReceived, float64(bytesReceived)/1024/1024)
	log.Printf("发送字节数: %d (%.2f MB)", bytesSent, float64(bytesSent)/1024/1024)
	log.Printf("请求速率: %.2f req/s", float64(requests)/duration.Seconds())
	log.Printf("吞吐量: %.2f MB/s", float64(bytesReceived)/duration.Seconds()/1024/1024)
	log.Printf("内存使用: %.2f MB", float64(m.Alloc)/1024/1024)
	log.Printf("GC 次数: %d", m.NumGC)
	log.Printf("Goroutine 数: %d", runtime.NumGoroutine())
	log.Printf("================================")
}
