package main

import (
	"fmt"
	"log"
	"net/http"
	"runtime"
	"time"
)

func main() {
	// 设置 GOMAXPROCS 为 1，模拟单线程协程调度
	runtime.GOMAXPROCS(1)

	// 设置路由
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {

		// 返回响应
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w, "helloworld\n")
	})

	// 启动服务器
	server := &http.Server{
		Addr:         ":8081",
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	fmt.Println("Go HTTP server starting on :8081")
	fmt.Printf("GOMAXPROCS: %d\n", runtime.GOMAXPROCS(0))

	if err := server.ListenAndServe(); err != nil {
		log.Fatal("Server failed to start:", err)
	}
}
