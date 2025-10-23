package main

import (
	"fmt"
	"log"
	"net/http"
	"runtime"
	"sync/atomic"
	"time"
)

// 性能监控
type PerfMonitor struct {
	requestCount int64
	totalLatency int64
	maxLatency   int64
}

func (pm *PerfMonitor) RecordRequest(latency time.Duration) {
	atomic.AddInt64(&pm.requestCount, 1)
	atomic.AddInt64(&pm.totalLatency, int64(latency))

	for {
		currentMax := atomic.LoadInt64(&pm.maxLatency)
		if int64(latency) <= currentMax {
			break
		}
		if atomic.CompareAndSwapInt64(&pm.maxLatency, currentMax, int64(latency)) {
			break
		}
	}
}

func (pm *PerfMonitor) PrintStats() {
	count := atomic.LoadInt64(&pm.requestCount)
	total := atomic.LoadInt64(&pm.totalLatency)
	max := atomic.LoadInt64(&pm.maxLatency)
	avg := int64(0)
	if count > 0 {
		avg = total / count
	}

	fmt.Printf("Performance Stats - Requests: %d, Avg Latency: %dns, Max Latency: %dns\n",
		count, avg, max)
}

var perfMonitor = &PerfMonitor{}

// 预编译的HTTP响应
var http200KeepAlive = []byte("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nContent-Length: 10\r\n\r\nhelloworld")
var http200Close = []byte("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\nContent-Length: 10\r\n\r\nhelloworld")

// 优化的请求处理函数
func handleRequestFast(w http.ResponseWriter, r *http.Request) bool {
	startTime := time.Now()

	// 快速检查请求类型
	if r.Method != "GET" {
		return false
	}

	// 检查是否是shutdown请求
	if r.URL.Path == "/shutdown" {
		w.Write(http200Close)
		return false
	}

	// 快速检查Connection头
	isKeepAlive := r.Header.Get("Connection") == "keep-alive"

	if isKeepAlive {
		w.Write(http200KeepAlive)
	} else {
		w.Write(http200Close)
	}

	// 记录性能指标
	latency := time.Since(startTime)
	perfMonitor.RecordRequest(latency)

	return isKeepAlive
}

func main() {
	// 设置GOMAXPROCS为CPU核心数
	runtime.GOMAXPROCS(runtime.NumCPU())

	fmt.Println("Starting Go HTTP Server...")
	fmt.Printf("GOMAXPROCS: %d\n", runtime.GOMAXPROCS(0))

	// 启动性能统计协程
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			perfMonitor.PrintStats()
		}
	}()

	// 设置HTTP服务器
	server := &http.Server{
		Addr: ":8081", // 使用不同端口避免冲突
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			handleRequestFast(w, r)
		}),
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	fmt.Println("Go server listening on port 8081")
	fmt.Println("Performance monitoring every 5 seconds...")

	// 启动服务器
	log.Fatal(server.ListenAndServe())
}
