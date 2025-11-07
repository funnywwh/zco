#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/epoll.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <errno.h>

#define MAX_EVENTS 1024
#define BUFFER_SIZE 4096
#define PORT 8083

// HTTP 响应头
static const char *HTTP_RESPONSE = 
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 11\r\n"
    "\r\n"
    "helloworld\n";

// 设置非阻塞模式
static int set_nonblocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1) {
        perror("fcntl F_GETFL");
        return -1;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) {
        perror("fcntl F_SETFL");
        return -1;
    }
    return 0;
}

// 处理客户端连接
static void handle_client(int client_fd) {
    char buffer[BUFFER_SIZE];
    
    // 读取请求（简单处理，不解析）
    ssize_t n = read(client_fd, buffer, sizeof(buffer) - 1);
    if (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
        perror("read");
        close(client_fd);
        return;
    }
    
    // 发送响应
    ssize_t sent = write(client_fd, HTTP_RESPONSE, strlen(HTTP_RESPONSE));
    if (sent < 0) {
        perror("write");
    }
    
    // 关闭连接
    close(client_fd);
}

int main(void) {
    int server_fd, epoll_fd;
    struct sockaddr_in server_addr;
    struct epoll_event event, events[MAX_EVENTS];
    
    // 创建服务器 socket
    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd == -1) {
        perror("socket");
        exit(EXIT_FAILURE);
    }
    
    // 设置 socket 选项（重用地址）
    int opt = 1;
    if (setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) == -1) {
        perror("setsockopt");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // 绑定地址
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    server_addr.sin_port = htons(PORT);
    
    if (bind(server_fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) == -1) {
        perror("bind");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // 监听
    if (listen(server_fd, SOMAXCONN) == -1) {
        perror("listen");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // 设置非阻塞
    if (set_nonblocking(server_fd) == -1) {
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // 创建 epoll 实例
    epoll_fd = epoll_create1(0);
    if (epoll_fd == -1) {
        perror("epoll_create1");
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    // 注册服务器 socket 到 epoll
    event.events = EPOLLIN | EPOLLET;  // 边缘触发模式
    event.data.fd = server_fd;
    if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, server_fd, &event) == -1) {
        perror("epoll_ctl");
        close(epoll_fd);
        close(server_fd);
        exit(EXIT_FAILURE);
    }
    
    printf("C epoll HTTP server starting on :%d\n", PORT);
    
    // 事件循环
    while (1) {
        int nfds = epoll_wait(epoll_fd, events, MAX_EVENTS, -1);
        if (nfds == -1) {
            perror("epoll_wait");
            break;
        }
        
        for (int i = 0; i < nfds; i++) {
            if (events[i].data.fd == server_fd) {
                // 新的连接请求
                while (1) {
                    struct sockaddr_in client_addr;
                    socklen_t client_len = sizeof(client_addr);
                    int client_fd = accept(server_fd, (struct sockaddr *)&client_addr, &client_len);
                    
                    if (client_fd == -1) {
                        if (errno == EAGAIN || errno == EWOULDBLOCK) {
                            // 没有更多连接
                            break;
                        } else {
                            perror("accept");
                            break;
                        }
                    }
                    
                    // 设置非阻塞
                    if (set_nonblocking(client_fd) == -1) {
                        close(client_fd);
                        continue;
                    }
                    
                    // 注册客户端 socket 到 epoll
                    event.events = EPOLLIN | EPOLLET | EPOLLRDHUP;
                    event.data.fd = client_fd;
                    if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, client_fd, &event) == -1) {
                        perror("epoll_ctl client");
                        close(client_fd);
                        continue;
                    }
                }
            } else {
                // 客户端数据可读
                int client_fd = events[i].data.fd;
                
                if (events[i].events & (EPOLLRDHUP | EPOLLHUP | EPOLLERR)) {
                    // 连接关闭或错误
                    epoll_ctl(epoll_fd, EPOLL_CTL_DEL, client_fd, NULL);
                    close(client_fd);
                } else if (events[i].events & EPOLLIN) {
                    // 处理客户端请求
                    handle_client(client_fd);
                    
                    // 从 epoll 中移除并关闭
                    epoll_ctl(epoll_fd, EPOLL_CTL_DEL, client_fd, NULL);
                }
            }
        }
    }
    
    // 清理
    close(epoll_fd);
    close(server_fd);
    
    return 0;
}

