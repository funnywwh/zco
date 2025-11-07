use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

const RESPONSE: &[u8] = b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 11\r\n\r\nhelloworld\n";

/// 处理单个客户端连接
async fn handle_client(mut stream: TcpStream) {
    let mut buffer = [0; 1024];
    
    // 读取请求（简单处理，不解析）
    let _ = stream.read(&mut buffer).await;
    
    // 直接返回响应
    let _ = stream.write_all(RESPONSE).await;
    let _ = stream.flush().await;
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listener = TcpListener::bind("127.0.0.1:8082").await?;
    println!("Rust HTTP server starting on :8082");

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                tokio::spawn(async move {
                    handle_client(stream).await;
                });
            }
            Err(e) => {
                eprintln!("Error accepting connection: {}", e);
            }
        }
    }
}

