const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const websocket = @import("websocket");
const webrtc = @import("webrtc");

const PeerConnection = webrtc.peer.connection.PeerConnection;
const Configuration = webrtc.peer.connection.Configuration;
const SignalingMessage = webrtc.signaling.message.SignalingMessage;
const DataChannel = webrtc.sctp.datachannel.DataChannel;

// 用于回调驱动的 Channel 指针（由于回调函数签名限制，使用全局变量）
const ConnectionReadyChan = zco.CreateChan(bool);
var server_connection_chan: ?*ConnectionReadyChan = null;

// 自定义 panic handler，显示完整的栈跟踪
pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    std.debug.print("\n!!! PANIC !!!\n", .{});
    std.debug.print("Message: {s}\n\n", .{msg});

    // 打印栈跟踪
    if (error_return_trace) |trace| {
        std.debug.dumpStackTrace(trace.*);
    } else {
        std.debug.print("(no error return trace available)\n", .{});
    }

    // 打印当前栈跟踪（如果可用）
    std.debug.print("\nCurrent stack trace:\n", .{});
    std.debug.dumpCurrentStackTrace(ret_addr);

    std.process.exit(1);
}

/// 浏览器兼容性测试服务器
/// 作为服务器端处理浏览器的 WebRTC 连接
pub fn main() !void {
    std.log.info("=== WebRTC DataChannel 浏览器兼容性测试服务器 ===", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 启动信令服务器（在协程中）
    const signaling_addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    std.log.info("启动信令服务器在 ws://127.0.0.1:8080", .{});

    _ = try schedule.go(runSignalingServer, .{ schedule, signaling_addr });

    // 等待一小段时间让信令服务器启动
    // 注意：在协程中等待，而不是在主线程中
    _ = try schedule.go(waitAndConnect, .{ schedule, "browser-test-room" });

    // 运行调度器
    try schedule.loop();

    // 注意：deinit 在协程环境中进行，但 schedule.loop() 返回后，我们不再有协程环境
    // 所以这里不调用 deinit，让资源在进程退出时自动清理
    // 或者，如果需要在退出前清理，应该在协程中处理
    std.log.info("服务器已退出", .{});
}

/// 等待并连接（在协程中）
fn waitAndConnect(schedule: *zco.Schedule, room_id: []const u8) !void {
    // 等待一小段时间让信令服务器启动
    const current_co = try schedule.getCurrentCo();
    try current_co.Sleep(100 * std.time.ns_per_ms);

    // 连接到信令服务器作为服务器端 PeerConnection
    _ = try schedule.go(connectAsServer, .{ schedule, room_id });
}

/// 发送连接就绪信号（在协程中）
fn sendConnectionReady(chan: *ConnectionReadyChan, ready: bool) !void {
    _ = chan.send(ready) catch |e| {
        std.log.err("[服务器] 发送连接信号失败: {}", .{e});
    };
}

/// 运行信令服务器
/// 在协程中创建和运行信令服务器
fn runSignalingServer(schedule: *zco.Schedule, signaling_addr: std.net.Address) !void {
    std.log.info("信令服务器正在运行...", .{});

    // 创建信令服务器
    const signaling_server = try webrtc.signaling.server.SignalingServer.init(schedule, signaling_addr);
    defer signaling_server.deinit();

    // 启动服务器（会阻塞直到服务器停止）
    try signaling_server.start();
}

/// 作为服务器端连接到信令服务器
fn connectAsServer(schedule: *zco.Schedule, room_id: []const u8) !void {
    std.log.info("[服务器] 连接到信令服务器...", .{});

    // 创建 PeerConnection
    const config = Configuration{};
    const pc = try PeerConnection.init(schedule.allocator, schedule, config);
    errdefer pc.deinit();

    // 跟踪创建的 UDP socket
    var created_udp: ?*nets.Udp = null;
    errdefer if (created_udp) |udp| {
        if (udp.xobj) |_| {
            udp.close();
        }
        schedule.allocator.destroy(udp);
    };

    // 连接到信令服务器
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const tcp = try nets.Tcp.init(schedule);
    errdefer tcp.deinit();

    // 尝试连接，如果失败则等待后重试
    const max_retries = 5;
    var retry_count: u32 = 0;
    var connected = false;

    while (retry_count < max_retries and !connected) {
        tcp.connect(server_addr) catch |err| {
            if (err == error.ConnectionRefused) {
                retry_count += 1;
                if (retry_count < max_retries) {
                    std.log.info("[服务器] 连接被拒绝，等待后重试 ({}/{})...", .{ retry_count, max_retries });
                    const current_co = try schedule.getCurrentCo();
                    try current_co.Sleep(500 * std.time.ns_per_ms);
                    continue;
                }
            }
            return err;
        };
        connected = true;
    }

    if (!connected) {
        std.log.err("[服务器] 连接失败，已达到最大重试次数", .{});
        return error.ConnectionRefused;
    }

    // 创建 WebSocket 连接
    var ws = try websocket.WebSocket.fromTcp(tcp);
    errdefer ws.deinit();

    // 执行客户端握手
    try ws.clientHandshake("/", "127.0.0.1:8080");
    std.log.info("[服务器] 已连接到信令服务器", .{});

    // 加入房间
    std.log.info("[服务器] [connectAsServer] 准备加入房间: {s}", .{room_id});
    const user_id = "server";
    const room_id_dup = try schedule.allocator.dupe(u8, room_id);
    const user_id_dup = try schedule.allocator.dupe(u8, user_id);

    var join_msg = SignalingMessage{
        .type = .join,
        .room_id = room_id_dup,
        .user_id = user_id_dup,
    };
    defer join_msg.deinit(schedule.allocator);

    std.log.info("[服务器] [connectAsServer] 创建 join 消息", .{});
    const join_json = try join_msg.toJson(schedule.allocator);
    defer schedule.allocator.free(join_json);
    std.log.info("[服务器] [connectAsServer] join JSON 长度: {} 字节", .{join_json.len});
    std.log.info("[服务器] [connectAsServer] 调用 ws.sendText() 发送 join 消息", .{});
    try ws.sendText(join_json);
    std.log.info("[服务器] [connectAsServer] ✅ 已发送 join 消息，等待服务器处理", .{});

    // 设置 UDP Socket
    const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    created_udp = try pc.setupUdpSocket(bind_addr);

    // 消息缓冲区
    var ws_buffer: [4096]u8 = undefined;
    var offer_received = false;

    // 等待接收 offer
    std.log.info("[服务器] 等待浏览器发送 offer...", .{});
    while (!offer_received) {
        const frame = ws.readMessage(ws_buffer[0..]) catch |err| {
            if (err == websocket.WebSocketError.ConnectionClosed or err == error.EOF) {
                std.log.info("[服务器] WebSocket 连接已关闭", .{});
                break;
            } else {
                std.log.err("[服务器] 读取消息失败: {}", .{err});
                break;
            }
        };
        defer if (frame.payload.len > ws_buffer.len) ws.allocator.free(frame.payload);

        if (frame.opcode == .CLOSE) {
            std.log.info("[服务器] WebSocket 连接已关闭", .{});
            break;
        }

        if (frame.opcode != .TEXT) {
            continue;
        }

        // 解析信令消息
        var parsed = std.json.parseFromSlice(
            SignalingMessage,
            schedule.allocator,
            frame.payload,
            .{},
        ) catch {
            std.log.err("[服务器] 解析消息失败", .{});
            continue;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        std.log.info("[服务器] 收到消息类型: {}", .{msg.type});

        switch (msg.type) {
            .offer => {
                if (msg.sdp) |sdp| {
                    std.log.info("[服务器] 收到 offer，开始处理... (SDP 长度: {} 字节)", .{sdp.len});
                    var remote_sdp = webrtc.signaling.sdp.Sdp.parse(schedule.allocator, sdp) catch |err| {
                        std.log.err("[服务器] 解析 SDP 失败: {}", .{err});
                        continue;
                    };

                    const remote_sdp_ptr = schedule.allocator.create(webrtc.signaling.sdp.Sdp) catch |err| {
                        std.log.err("[服务器] 分配 SDP 内存失败: {}", .{err});
                        remote_sdp.deinit();
                        continue;
                    };
                    errdefer schedule.allocator.destroy(remote_sdp_ptr);

                    remote_sdp_ptr.* = remote_sdp;

                    pc.setRemoteDescription(remote_sdp_ptr) catch |err| {
                        std.log.err("[服务器] 设置远程 offer 失败: {}", .{err});
                        remote_sdp_ptr.deinit();
                        schedule.allocator.destroy(remote_sdp_ptr);
                        continue;
                    };

                    remote_sdp.fingerprint = null;
                    remote_sdp.times.deinit();
                    remote_sdp.times = std.ArrayList(webrtc.signaling.sdp.Sdp.Time).init(schedule.allocator);
                    std.log.info("[服务器] 已设置远程 offer", .{});

                    // 创建 answer
                    std.log.info("[服务器] 开始创建 answer...", .{});
                    const answer = try pc.createAnswer(schedule.allocator, null);
                    const answer_sdp = try answer.generate();
                    defer schedule.allocator.free(answer_sdp);

                    try pc.setLocalDescription(answer);
                    std.log.info("[服务器] 已创建并设置本地 answer", .{});

                    // 发送 answer
                    const answer_room_id_dup = try schedule.allocator.dupe(u8, room_id);
                    const answer_user_id_dup = try schedule.allocator.dupe(u8, user_id);
                    const answer_sdp_dup = try schedule.allocator.dupe(u8, answer_sdp);

                    var answer_msg = SignalingMessage{
                        .type = .answer,
                        .room_id = answer_room_id_dup,
                        .user_id = answer_user_id_dup,
                        .sdp = answer_sdp_dup,
                    };
                    defer answer_msg.deinit(schedule.allocator);

                    const answer_json = try answer_msg.toJson(schedule.allocator);
                    defer schedule.allocator.free(answer_json);
                    try ws.sendText(answer_json);
                    std.log.info("[服务器] ✅ 已发送 answer (SDP 长度: {} 字节)", .{answer_sdp.len});

                    offer_received = true;
                }
            },
            .ice_candidate => {
                if (msg.candidate) |candidate| {
                    std.log.info("[服务器] 收到 ICE candidate: {s}", .{candidate.candidate});
                    var ice_candidate = webrtc.ice.candidate.Candidate.fromSdpCandidate(
                        schedule.allocator,
                        candidate.candidate,
                    ) catch |err| {
                        std.log.err("[服务器] 解析 ICE candidate 失败: {}", .{err});
                        continue;
                    };
                    defer ice_candidate.deinit();

                    const candidate_ptr = schedule.allocator.create(webrtc.ice.candidate.Candidate) catch |err| {
                        std.log.err("[服务器] 分配 ICE candidate 内存失败: {}", .{err});
                        continue;
                    };
                    candidate_ptr.* = ice_candidate;
                    pc.addIceCandidate(candidate_ptr) catch |err| {
                        std.log.err("[服务器] 添加 ICE candidate 失败: {}", .{err});
                        schedule.allocator.destroy(candidate_ptr);
                        continue;
                    };
                    std.log.info("[服务器] 已添加远程 ICE candidate", .{});
                }
            },
            else => {
                std.log.info("[服务器] 收到其他类型消息: {}", .{msg.type});
            },
        }
    }

    if (!offer_received) {
        std.log.warn("[服务器] 未收到 offer", .{});
        return;
    }

    // 发送 ICE candidates
    const local_candidates = pc.getLocalCandidates();
    for (local_candidates) |candidate| {
        const candidate_str = try candidate.toSdpCandidate(schedule.allocator);
        defer schedule.allocator.free(candidate_str);

        const ice_room_id_dup = try schedule.allocator.dupe(u8, room_id);
        const ice_user_id_dup = try schedule.allocator.dupe(u8, user_id);
        const ice_candidate_str_dup = try schedule.allocator.dupe(u8, candidate_str);

        var ice_msg = SignalingMessage{
            .type = .ice_candidate,
            .room_id = ice_room_id_dup,
            .user_id = ice_user_id_dup,
            .candidate = .{
                .candidate = ice_candidate_str_dup,
            },
        };
        defer ice_msg.deinit(schedule.allocator);

        const ice_json = try ice_msg.toJson(schedule.allocator);
        defer schedule.allocator.free(ice_json);
        try ws.sendText(ice_json);
    }
    std.log.info("[服务器] 已发送所有 ICE candidates", .{});

    // 等待连接建立
    const current_co_server = try schedule.getCurrentCo();
    try current_co_server.Sleep(200 * std.time.ns_per_ms);

    // 等待 ICE 和 DTLS 连接建立
    std.log.info("[服务器] 等待 ICE 连接建立和 DTLS 握手完成...", .{});

    var connection_ready = false;
    const connection_state = pc.getConnectionState();
    if (connection_state == .failed or connection_state == .closed) {
        std.log.err("[服务器] 连接失败或已关闭，状态: {}", .{connection_state});
        return;
    }
    if (connection_state == .connected) {
        if (pc.isDtlsHandshakeComplete()) {
            connection_ready = true;
            std.log.info("[服务器] 连接已就绪（ICE + DTLS）", .{});
        }
    }

    // 设置连接状态回调
    if (!connection_ready) {
        // 注意：CreateChan.init() 已经返回堆分配的指针
        var chan_ptr = try ConnectionReadyChan.init(schedule, 1);
        errdefer chan_ptr.deinit();

        server_connection_chan = chan_ptr;

        pc.onconnectionstatechange = struct {
            fn callback(pc_self: *PeerConnection) void {
                const state = pc_self.getConnectionState();
                std.log.info("[服务器] 连接状态变化: {}", .{state});
                // 注意：回调可能在非协程环境中执行，不能直接调用 channel.send()
                // 改为在协程中发送信号
                if (server_connection_chan) |ch| {
                    // 检查是否在协程环境中
                    if (pc_self.schedule.getCurrentCo()) |current_co| {
                        _ = current_co;
                        // 在协程环境中，可以发送
                        if (state == .connected) {
                            if (pc_self.isDtlsHandshakeComplete()) {
                                _ = ch.send(true) catch |e| {
                                    std.log.err("[服务器] 发送连接就绪信号失败: {}", .{e});
                                };
                            }
                        } else if (state == .failed or state == .closed) {
                            _ = ch.send(false) catch |e| {
                                std.log.err("[服务器] 发送连接失败信号失败: {}", .{e});
                            };
                        }
                    } else |_| {
                        // 不在协程环境中，启动协程发送信号
                        const pc_schedule = pc_self.schedule;
                        if (state == .connected) {
                            if (pc_self.isDtlsHandshakeComplete()) {
                                _ = pc_schedule.go(sendConnectionReady, .{ ch, true }) catch |e| {
                                    std.log.err("[服务器] 启动协程发送连接就绪信号失败: {}", .{e});
                                };
                            }
                        } else if (state == .failed or state == .closed) {
                            _ = pc_schedule.go(sendConnectionReady, .{ ch, false }) catch |e| {
                                std.log.err("[服务器] 启动协程发送连接失败信号失败: {}", .{e});
                            };
                        }
                    }
                }
            }
        }.callback;

        pc.ondtlshandshakecomplete = struct {
            fn callback(pc_self: *PeerConnection) void {
                std.log.info("[服务器] DTLS 握手完成", .{});
                const state = pc_self.getConnectionState();
                if (state == .connected) {
                    if (pc_self.isDtlsHandshakeComplete()) {
                        if (server_connection_chan) |ch| {
                            // 检查是否在协程环境中
                            if (pc_self.schedule.getCurrentCo()) |current_co| {
                                _ = current_co;
                                // 在协程环境中，可以发送
                                _ = ch.send(true) catch |e| {
                                    std.log.err("[服务器] 发送连接就绪信号失败: {}", .{e});
                                };
                            } else |_| {
                                // 不在协程环境中，启动协程发送信号
                                const pc_schedule = pc_self.schedule;
                                _ = pc_schedule.go(sendConnectionReady, .{ ch, true }) catch |e| {
                                    std.log.err("[服务器] 启动协程发送连接就绪信号失败: {}", .{e});
                                };
                            }
                        }
                    }
                }
            }
        }.callback;

        const state_after_setup = pc.getConnectionState();
        if (state_after_setup == .connected) {
            if (pc.isDtlsHandshakeComplete()) {
                _ = chan_ptr.send(true) catch {};
                connection_ready = true;
            }
        }

        if (!connection_ready) {
            const ready = try chan_ptr.recv();
            if (!ready) {
                std.log.err("[服务器] 连接失败，退出", .{});
                // 清理资源
                chan_ptr.deinit();
                server_connection_chan = null;
                return;
            }
            connection_ready = true;
            std.log.info("[服务器] 连接已就绪（通过回调）", .{});
        }

        // 清理资源（deinit 会同时销毁对象）
        chan_ptr.deinit();
        server_connection_chan = null;
    } else {
        server_connection_chan = null;
    }

    // 创建数据通道（匹配浏览器创建的通道）
    const channel = try pc.createDataChannel("test-channel", null);
    std.log.info("[服务器] 已创建数据通道", .{});

    // 设置数据通道事件
    channel.setOnOpen(struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[服务器] 数据通道已打开", .{});
        }
    }.callback);

    channel.setOnMessage(struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            std.log.info("[服务器] 收到消息 ({} 字节): {s}", .{ data.len, data });

            // Echo 回显消息
            if (ch.send(data, null)) {
                std.log.info("[服务器] ✓ 已回显消息: {s}", .{data});
            } else |err| {
                std.log.err("[服务器] 回显消息失败: {}", .{err});
            }
        }
    }.callback);

    channel.setOnClose(struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[服务器] 数据通道已关闭", .{});
        }
    }.callback);

    channel.setOnError(struct {
        fn callback(ch: *DataChannel, err: anyerror) void {
            _ = ch;
            std.log.err("[服务器] 数据通道错误: {}", .{err});
        }
    }.callback);

    // 打开数据通道
    channel.setState(.open);

    // 启动接收协程
    var recv_wg = try zco.WaitGroup.init(schedule);
    defer recv_wg.deinit();
    try recv_wg.add(1);

    _ = try schedule.go(receiveDataChannelMessages, .{ pc, &recv_wg });

    std.log.info("[服务器] 服务器已就绪，等待浏览器连接和数据...", .{});

    // 持续运行，直到调度器停止
    while (true) {
        try current_co_server.Sleep(1 * std.time.ns_per_s);

        // 检查连接状态
        if (pc.getConnectionState() == .closed or pc.getConnectionState() == .failed) {
            std.log.info("[服务器] 连接已关闭，退出", .{});
            break;
        }
    }

    // 清理
    channel.setState(.closed);
    try current_co_server.Sleep(100 * std.time.ns_per_ms);
    recv_wg.wait();

    ws.deinit();
    tcp.close();
    tcp.deinit();

    if (created_udp) |udp| {
        if (udp.xobj) |_| {
            udp.close();
        }
        schedule.allocator.destroy(udp);
    }

    pc.deinit();
    schedule.stop();
}

/// 接收数据通道消息
fn receiveDataChannelMessages(pc: *PeerConnection, wg: *zco.WaitGroup) !void {
    errdefer wg.done();

    std.log.info("[服务器] 开始接收数据通道消息...", .{});

    var consecutive_errors: u32 = 0;
    const max_consecutive_errors = 10;

    while (true) {
        if (pc.getConnectionState() == .closed) {
            std.log.info("[服务器] PeerConnection 已关闭，数据通道消息接收协程退出", .{});
            wg.done();
            return;
        }

        pc.recvSctpData() catch |err| {
            if (err == error.ScheduleExited) {
                std.log.info("[服务器] 调度器已退出，数据通道消息接收协程退出", .{});
                wg.done();
                return;
            }

            if (err == error.ChannelClosed) {
                std.log.info("[服务器] 数据通道已关闭，数据通道消息接收协程退出", .{});
                wg.done();
                return;
            }

            if (err == error.ConnectionClosed) {
                std.log.info("[服务器] PeerConnection 已关闭，数据通道消息接收协程退出", .{});
                wg.done();
                return;
            }

            consecutive_errors += 1;
            if (consecutive_errors >= max_consecutive_errors) {
                std.log.info("[服务器] 数据通道消息接收连续失败，退出", .{});
                wg.done();
                return;
            }

            std.log.debug("[服务器] 接收 SCTP 数据失败: {}，等待后重试 ({}/{})", .{ err, consecutive_errors, max_consecutive_errors });

            const current_co = try pc.schedule.getCurrentCo();
            current_co.Sleep(50 * std.time.ns_per_ms) catch |sleep_err| {
                if (sleep_err == error.ScheduleExited) {
                    std.log.info("[服务器] 调度器已退出，数据通道消息接收协程退出", .{});
                    wg.done();
                    return;
                }
                wg.done();
                return sleep_err;
            };
            continue;
        };

        consecutive_errors = 0;
    }
}
