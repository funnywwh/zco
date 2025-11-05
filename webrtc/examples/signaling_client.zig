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
// 注意：在单进程测试场景中，Alice 和 Bob 在不同进程中运行，所以是安全的
const ConnectionReadyChan = zco.CreateChan(bool);
const MessageChan = zco.CreateChan([]const u8);

var alice_connection_chan: ?*ConnectionReadyChan = null;
var bob_connection_chan: ?*ConnectionReadyChan = null;

// 全局变量用于存储消息 Channel（ping/pong 状态机）
var alice_message_chan: ?*MessageChan = null;
var bob_message_chan: ?*MessageChan = null;

// 全局 buffer 用于 WebSocket 消息读取（4096 字节）
// 注意：在单进程测试场景中，Alice 和 Bob 在不同进程中运行，所以是安全的
var ws_buffer: [4096]u8 = undefined;

/// WebRTC 信令客户端示例
/// 通过信令服务器连接两个 PeerConnection
pub fn main() !void {
    std.log.info("=== WebRTC 信令客户端示例 ===", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    // 检查命令行参数
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.log.err("用法: {s} <alice|bob> <room_id>", .{args[0]});
        return error.InvalidArguments;
    }

    const role = args[1];
    const room_id = args[2];

    // 创建 WaitGroup 来等待工作协程完成
    var wg = try zco.WaitGroup.init(schedule);
    defer wg.deinit();
    try wg.add(1);

    // 在协程中运行客户端
    if (std.mem.eql(u8, role, "alice")) {
        _ = try schedule.go(runAlice, .{ schedule, room_id, &wg });
    } else if (std.mem.eql(u8, role, "bob")) {
        _ = try schedule.go(runBob, .{ schedule, room_id, &wg });
    } else {
        std.log.err("角色必须是 'alice' 或 'bob'", .{});
        return error.InvalidArguments;
    }

    // 创建协程来等待工作协程完成（WaitGroup.wait() 必须在协程中调用）
    _ = try schedule.go(waitForWorker, .{ schedule, &wg });

    // 运行调度器（会阻塞直到 schedule.stop() 被调用）
    // waitForWorker 协程会等待所有工作协程完成，然后调用 schedule.stop()
    try schedule.loop();
    std.log.info("[Main] 调度器 loop 已退出，所有协程已安全退出", .{});
}

/// 等待工作协程完成的协程（WaitGroup 必须在协程中使用）
fn waitForWorker(schedule: *zco.Schedule, wg: *zco.WaitGroup) !void {
    std.log.info("[Main] 等待工作协程完成...", .{});
    // WaitGroup.wait() 必须在协程中调用
    // 这会阻塞直到工作协程调用 wg.done()
    wg.wait();
    std.log.info("[Main] 工作协程已完成，准备停止调度器", .{});
    // 在退出前停止调度器（这会导致 schedule.loop() 退出）
    schedule.stop();
    std.log.info("[Main] 调度器已停止", .{});
}

/// 运行 Alice（发起方）
fn runAlice(schedule: *zco.Schedule, room_id: []const u8, wg: *zco.WaitGroup) !void {
    std.log.info("[Alice] 启动客户端...", .{});

    // 创建 PeerConnection
    const config = Configuration{};
    const pc = try PeerConnection.init(schedule.allocator, schedule, config);
    errdefer pc.deinit(); // 错误路径清理
    // 注意：正常路径手动控制清理顺序

    // 跟踪创建的 UDP socket，以便在函数结束时清理
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
    errdefer tcp.deinit(); // 错误路径清理

    // 尝试连接，如果失败则等待后重试（与 Bob 保持一致）
    const max_retries = 5;
    var retry_count: u32 = 0;
    var connected = false;

    while (retry_count < max_retries and !connected) {
        tcp.connect(server_addr) catch |err| {
            if (err == error.ConnectionRefused) {
                retry_count += 1;
                if (retry_count < max_retries) {
                    std.log.info("[Alice] 连接被拒绝，等待后重试 ({}/{})...", .{ retry_count, max_retries });
                    const current_co_alice = try schedule.getCurrentCo();
                    try current_co_alice.Sleep(500 * std.time.ns_per_ms);
                    continue;
                }
            }
            return err;
        };
        connected = true;
    }

    if (!connected) {
        std.log.err("[Alice] 连接失败，已达到最大重试次数", .{});
        return error.ConnectionRefused;
    }
    // 注意：不在 defer 中关闭，手动控制清理顺序

    // 创建 WebSocket 连接
    var ws = try websocket.WebSocket.fromTcp(tcp);
    errdefer ws.deinit(); // 错误路径清理
    // 注意：正常路径手动控制清理顺序

    // 执行客户端握手
    try ws.clientHandshake("/", "127.0.0.1:8080");
    std.log.info("[Alice] 已连接到信令服务器", .{});

    // 加入房间
    const user_id = "alice";
    // 注意：这些内存会被 join_msg.deinit 释放
    const room_id_dup = try schedule.allocator.dupe(u8, room_id);
    const user_id_dup = try schedule.allocator.dupe(u8, user_id);

    var join_msg = SignalingMessage{
        .type = .join,
        .room_id = room_id_dup,
        .user_id = user_id_dup,
    };
    defer join_msg.deinit(schedule.allocator);

    const join_json = try join_msg.toJson(schedule.allocator);
    defer schedule.allocator.free(join_json);
    try ws.sendText(join_json);
    std.log.info("[Alice] 已加入房间: {s}", .{room_id});

    // 设置 UDP Socket（可选，如果指定地址，否则会在 setLocalDescription 时自动创建）
    // 注意：在浏览器 API 中，UDP Socket 会在 setLocalDescription 时自动创建
    // 这里提前创建是为了指定绑定地址（127.0.0.1）
    const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    created_udp = try pc.setupUdpSocket(bind_addr); // 跟踪创建的 UDP（用于后续清理）

    // 等待 Bob 的 user_joined 通知，然后发送 offer
    // 服务器会在 Bob 加入时发送 user_joined 通知给 Alice
    std.log.info("[Alice] 等待 Bob 加入房间的通知...", .{});
    var bob_joined = false;

    // 直接读取消息，readMessage 会阻塞等待数据（在协程中）
    while (!bob_joined) {
        // 尝试读取消息（readMessage 会阻塞等待，直到有数据或连接关闭）
        const frame = ws.readMessage(ws_buffer[0..]) catch |err| {
            if (err == websocket.WebSocketError.ConnectionClosed or err == error.EOF) {
                std.log.info("[Alice] WebSocket 连接已关闭（EOF），停止等待", .{});
                break;
            } else {
                std.log.err("[Alice] 读取消息失败: {}", .{err});
                break;
            }
        };
        // 注意：readMessage 返回的 payload 总是新分配的内存（根据 websocket.zig 注释），需要释放
        defer ws.allocator.free(frame.payload);

        if (frame.opcode == .CLOSE) {
            std.log.info("[Alice] WebSocket 连接已关闭", .{});
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
        ) catch |err| {
            std.log.err("[Alice] 解析消息失败（等待 Bob 加入）: {}，消息内容: {s}", .{ err, frame.payload });
            continue;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        std.log.info("[Alice] 收到消息类型: {}", .{msg.type});

        // 处理 user_joined 通知
        if (msg.type == .user_joined) {
            if (msg.user_id) |joined_user_id| {
                std.log.info("[Alice] 收到 user_joined 通知: {s} 已加入房间", .{joined_user_id});
                if (std.mem.eql(u8, joined_user_id, "bob")) {
                    bob_joined = true;
                    std.log.info("[Alice] Bob 已上线，准备发送 offer", .{});
                }
            }
            // 注意：parsed.deinit() 会释放 msg 内部的所有内存，不需要单独调用 msg.deinit()
            if (bob_joined) break;
            continue;
        } else {
            // 其他消息类型，先保存起来，稍后处理
            std.log.info("[Alice] 收到其他类型消息: {}（等待 Bob 加入后处理）", .{msg.type});
            // 注意：parsed.deinit() 会释放 msg 内部的所有内存，不需要单独调用 msg.deinit()
            continue;
        }
    }

    if (!bob_joined) {
        std.log.warn("[Alice] 等待超时，未收到 Bob 的 user_joined 通知，继续发送 offer（Bob 可能稍后加入）", .{});
    } else {
        std.log.info("[Alice] Bob 已上线，准备发送 offer", .{});
    }

    // 创建 offer
    const offer = try pc.createOffer(schedule.allocator, null);
    // 注意：offer 会被 setLocalDescription 接管，不需要手动 deinit
    // setLocalDescription 会负责释放旧的描述（如果有）
    const offer_sdp = try offer.generate();

    try pc.setLocalDescription(offer);
    std.log.info("[Alice] 已创建并设置本地 offer", .{});

    // 发送 offer
    // 注意：这些内存会被 offer_msg.deinit 释放，不需要手动释放
    const offer_room_id_dup = try schedule.allocator.dupe(u8, room_id);
    const offer_user_id_dup = try schedule.allocator.dupe(u8, user_id);
    const offer_sdp_dup = try schedule.allocator.dupe(u8, offer_sdp);

    var offer_msg = SignalingMessage{
        .type = .offer,
        .room_id = offer_room_id_dup,
        .user_id = offer_user_id_dup,
        .sdp = offer_sdp_dup,
    };
    defer offer_msg.deinit(schedule.allocator);
    defer schedule.allocator.free(offer_sdp); // 释放原始 offer_sdp（由 generate() 返回）

    const offer_json = try offer_msg.toJson(schedule.allocator);
    defer schedule.allocator.free(offer_json);
    try ws.sendText(offer_json);
    std.log.info("[Alice] 已发送 offer", .{});

    // 等待接收 answer 和 ICE candidates
    // 使用全局 ws_buffer 读取消息
    var received_answer = false;

    std.log.info("[Alice] 开始等待 answer 和 ICE candidates...", .{});
    // 事件驱动：持续接收消息，直到收到 answer
    // 收到 answer 后，立即退出循环（ICE candidates 会通过 onicecandidate 回调处理）
    while (!received_answer) {
        const frame = ws.readMessage(ws_buffer[0..]) catch |err| {
            // 区分连接关闭和真正的错误
            if (err == websocket.WebSocketError.ConnectionClosed or err == error.EOF) {
                std.log.info("[Alice] WebSocket 连接已关闭（EOF）", .{});
            } else {
                std.log.err("[Alice] 读取消息失败: {}", .{err});
            }
            break;
        };
        // 注意：readMessage 返回的 payload 总是新分配的内存（根据 websocket.zig 注释），需要释放
        defer ws.allocator.free(frame.payload);

        if (frame.opcode == .CLOSE) {
            std.log.info("[Alice] WebSocket 连接已关闭", .{});
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
            std.log.err("[Alice] 解析消息失败", .{});
            continue;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        std.log.info("[Alice] 收到消息类型: {}", .{msg.type});

        // 处理消息
        switch (msg.type) {
            .user_joined => {
                // 如果收到 user_joined（在等待 answer 期间），记录日志
                if (msg.user_id) |joined_user_id| {
                    std.log.info("[Alice] 收到 user_joined 通知: {s} 已加入房间（等待 answer 期间）", .{joined_user_id});
                }
                continue;
            },
            .answer => {
                if (msg.sdp) |sdp| {
                    std.log.info("[Alice] 收到 answer，开始解析...", .{});
                    const remote_sdp = try webrtc.signaling.sdp.Sdp.parse(schedule.allocator, sdp);
                    // 注意：remote_sdp 是值类型，需要转换为堆分配
                    // setRemoteDescription 会负责释放旧的描述和新的描述
                    const remote_sdp_ptr = try schedule.allocator.create(webrtc.signaling.sdp.Sdp);
                    errdefer schedule.allocator.destroy(remote_sdp_ptr);

                    // 拷贝 remote_sdp 到 remote_sdp_ptr（注意：这是浅拷贝，字段指针会共享）
                    remote_sdp_ptr.* = remote_sdp;
                    // 注意：由于浅拷贝，remote_sdp 和 remote_sdp_ptr 共享字段指针
                    // 一旦 remote_sdp_ptr 的所有权转移给 PeerConnection，remote_sdp 的字段就不应该再被清理
                    // 为了避免 errdefer 清理 remote_sdp，我们使用不同的策略：
                    // 在成功转移后，我们不清空 remote_sdp 的字段，而是确保 errdefer 不会执行
                    // 但实际上，由于 errdefer 只在错误路径执行，成功路径上不会执行
                    // 所以问题可能是：在 continue 之后，remote_sdp 仍然在作用域中，但它的字段已经被转移
                    // 解决方案：在成功转移后，我们不需要做任何事情，因为 errdefer 不会执行
                    // 但为了安全，我们仍然可以清空字段引用（虽然这不是必需的）
                    
                    // 如果 setRemoteDescription 失败，需要清理 remote_sdp_ptr（包括内部的字段）
                    try pc.setRemoteDescription(remote_sdp_ptr);
                    // 注意：如果成功，remote_sdp_ptr 的所有权转移给 PeerConnection
                    // remote_sdp 的字段指针已经转移到 remote_sdp_ptr，不需要清理
                    // errdefer 不会执行（因为函数没有返回错误）
                    std.log.info("[Alice] 已设置远程 answer，ICE 连接状态: {}", .{pc.getIceConnectionState()});
                    received_answer = true;
                    std.log.info("[Alice] 已收到 answer，退出等待循环", .{});
                    break; // 收到 answer 后立即退出
                }
            },
            .ice_candidate => {
                if (msg.candidate) |candidate| {
                    std.log.info("[Alice] 收到 ICE candidate: {s}", .{candidate.candidate});
                    var ice_candidate = try webrtc.ice.candidate.Candidate.fromSdpCandidate(
                        schedule.allocator,
                        candidate.candidate,
                    );
                    defer ice_candidate.deinit();

                    // 创建堆分配的 candidate
                    const candidate_ptr = try schedule.allocator.create(webrtc.ice.candidate.Candidate);
                    candidate_ptr.* = ice_candidate;
                    try pc.addIceCandidate(candidate_ptr);
                    std.log.info("[Alice] 已添加远程 ICE candidate，ICE 连接状态: {}", .{pc.getIceConnectionState()});
                    continue;
                }
            },
            else => {
                std.log.info("[Alice] 收到其他类型消息: {}", .{msg.type});
            },
        }
    }

    if (!received_answer) {
        std.log.warn("[Alice] 未收到 answer，可能连接失败", .{});
        return;
    }

    // 获取当前协程用于等待
    const current_co_alice = try schedule.getCurrentCo();

    // 等待一段时间让 ICE candidates 交换完成
    std.log.info("[Alice] 等待 ICE candidates 交换完成...", .{});
    try current_co_alice.Sleep(100 * std.time.ns_per_ms);

    // 事件驱动：使用回调驱动，等待连接建立（ICE + DTLS）
    std.log.info("[Alice] 等待 ICE 连接建立和 DTLS 握手完成（回调驱动）...", .{});

    // 创建 Channel 来接收连接就绪的信号
    var connection_ready_chan = try ConnectionReadyChan.init(schedule, 1);
    defer connection_ready_chan.deinit();

    // 检查连接状态
    const connection_state = pc.getConnectionState();
    if (connection_state == .failed) {
        std.log.err("[Alice] 连接失败", .{});
        return;
    }

    // 如果连接已经建立，直接继续
    var connection_ready = false;
    if (connection_state == .connected) {
        // 确认 DTLS 握手也已完成
        if (pc.isDtlsHandshakeComplete()) {
            connection_ready = true;
            std.log.info("[Alice] 连接已就绪（ICE + DTLS）", .{});
        }
    }

    // 设置回调（无论连接是否已就绪，都设置回调以便后续状态变化时能收到通知）
    // 由于回调函数签名限制（?*const fn (*Self) void），不能携带额外参数
    // 使用全局变量存储 Channel 指针（在单进程测试场景中是安全的）
    alice_connection_chan = connection_ready_chan;

    // 设置连接状态变化回调（回调驱动）
    pc.onconnectionstatechange = struct {
        fn callback(pc_self: *PeerConnection) void {
            const state = pc_self.getConnectionState();
            std.log.info("[Alice] 连接状态变化回调被触发: {}", .{state});
            // 只有在连接成功建立时才发送信号
            if (state == .connected) {
                // 确认 DTLS 握手也已完成
                if (pc_self.isDtlsHandshakeComplete()) {
                    if (alice_connection_chan) |ch| {
                        _ = ch.send(true) catch |e| {
                            std.log.err("[Alice] 发送连接就绪信号失败: {}", .{e});
                        };
                    }
                }
            }
        }
    }.callback;

    // 同时监听 DTLS 握手完成回调（确保在 DTLS 完成时也能发送信号）
    pc.ondtlshandshakecomplete = struct {
        fn callback(pc_self: *PeerConnection) void {
            std.log.info("[Alice] DTLS 握手完成回调被触发", .{});
            // 检查连接状态是否为 connected
            const state = pc_self.getConnectionState();
            if (state == .connected) {
                // 确认 DTLS 握手已完成
                if (pc_self.isDtlsHandshakeComplete()) {
                    if (alice_connection_chan) |ch| {
                        _ = ch.send(true) catch |e| {
                            std.log.err("[Alice] 发送连接就绪信号失败: {}", .{e});
                        };
                    }
                }
            }
        }
    }.callback;

    // 如果还未就绪，等待回调通知
    if (!connection_ready) {
        // 设置回调后，再次检查状态（避免竞态条件：回调可能在设置回调之前就触发）
        const state_after_setup = pc.getConnectionState();
        if (state_after_setup == .connected) {
            if (pc.isDtlsHandshakeComplete()) {
                // 连接已经就绪，直接发送信号
                _ = connection_ready_chan.send(true) catch |e| {
                    std.log.err("[Alice] 发送连接就绪信号失败: {}", .{e});
                };
                connection_ready = true;
            }
        }

        // 如果还未就绪，等待 Channel 接收信号（事件驱动，协程会被挂起）
        if (!connection_ready) {
            _ = try connection_ready_chan.recv();
            connection_ready = true;
            std.log.info("[Alice] 连接已就绪（通过回调）", .{});
        }
    } else {
        // 连接已经就绪，不需要等待回调
        // 注意：不要手动触发回调，因为回调可能会尝试发送消息到 channel，
        // 而 channel 可能已经发送过消息了，这会导致错误
        std.log.info("[Alice] 连接已就绪（检查时发现已就绪），跳过回调触发", .{});
    }

    // 清理
    alice_connection_chan = null;

    // 注意：DataChannel 的所有权由 PeerConnection 管理，不需要手动 deinit
    // PeerConnection.deinit() 会自动释放所有 DataChannel
    const channel = try pc.createDataChannel("test-channel", null);
    std.log.info("[Alice] 已创建数据通道", .{});

    // 创建消息 Channel 用于 ping-pong 状态机
    const message_chan = try MessageChan.init(schedule, 10);
    defer message_chan.deinit();
    alice_message_chan = message_chan;

    // 设置数据通道事件
    channel.setOnOpen(struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[Alice] 数据通道已打开", .{});
        }
    }.callback);

    channel.setOnMessage(struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            std.log.info("[Alice] 收到消息: {s}", .{data});
            // 将消息发送到 Channel（用于状态机）
            if (alice_message_chan) |msg_chan| {
                // 使用 PeerConnection 的 allocator 来分配内存
                const pc_ptr = @as(*PeerConnection, @ptrCast(@alignCast(ch.peer_connection orelse {
                    std.log.err("[Alice] DataChannel 没有关联 PeerConnection", .{});
                    return;
                })));
                const data_copy = pc_ptr.allocator.dupe(u8, data) catch {
                    std.log.err("[Alice] 复制消息数据失败", .{});
                    return;
                };
                _ = msg_chan.send(data_copy) catch |err| {
                    // 如果是调度器已退出，这是正常的，不需要报错
                    if (err != error.ScheduleExited) {
                        std.log.err("[Alice] 发送消息到 Channel 失败: {}", .{err});
                    }
                    pc_ptr.allocator.free(data_copy);
                };
            }
        }
    }.callback);

    // 打开数据通道
    channel.setState(.open);

    // 发送 ICE candidates
    const local_candidates = pc.getLocalCandidates();
    for (local_candidates) |candidate| {
        const candidate_str = try candidate.toSdpCandidate(schedule.allocator);
        defer schedule.allocator.free(candidate_str);

        // 注意：这些内存会被 ice_msg.deinit 释放
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
    std.log.info("[Alice] 已发送所有 ICE candidates", .{});

    // 等待一段时间，让连接建立
    try current_co_alice.Sleep(200 * std.time.ns_per_ms);

    // 创建 WaitGroup 来等待接收协程完成
    var recv_wg = try zco.WaitGroup.init(schedule);
    defer recv_wg.deinit();
    try recv_wg.add(1);

    // 接收数据通道消息（通过 recvSctpData 处理传入的数据）
    _ = try schedule.go(receiveDataChannelMessages, .{ pc, &recv_wg });

    // Ping-Pong 状态机：Alice 发送 ping，等待 pong
    if (channel.getState() == .open) {
        const ping_msg = "ping";
        if (channel.send(ping_msg, null)) {
            std.log.info("[Alice] 已发送 ping", .{});
        } else |err| {
            std.log.err("[Alice] 发送 ping 失败: {}", .{err});
            return;
        }
    }

    // 等待接收 pong（状态机）
    std.log.info("[Alice] 等待接收 pong...", .{});
    const received_msg = try message_chan.recv();
    defer schedule.allocator.free(received_msg);

    if (std.mem.eql(u8, received_msg, "pong")) {
        std.log.info("[Alice] 收到 pong，退出", .{});
    } else {
        std.log.warn("[Alice] 收到非预期消息: {s}", .{received_msg});
    }

    // 清理：先清理 message_chan，避免回调尝试发送消息
    alice_message_chan = null;

    // 关闭 DataChannel，让 recvSctpData 返回，使 receiveDataChannelMessages 协程退出
    channel.setState(.closed);
    std.log.info("[Alice] 已关闭数据通道", .{});

    // 等待一小段时间，确保所有回调都已完成
    try current_co_alice.Sleep(50 * std.time.ns_per_ms);

    // 等待接收协程完成（在停止调度器之前）
    // 注意：关闭 channel 后，receiveDataChannelMessages 会检测到 ChannelClosed 并退出，主动调用 recv_wg.done()
    std.log.info("[Alice] 等待接收协程完成...", .{});
    // 在调度器还在运行时等待 WaitGroup
    // recv_wg.wait() 会发送信号，如果 count > 0，done() 会接收这个信号
    // 如果 count == 0，说明协程已经退出，直接返回
    recv_wg.wait();
    // wait() 的 send() 会阻塞等待，直到 done() 的 recv() 完成
    // 所以 wait() 返回时，done() 已经完成，不需要额外的 sleep

    // 在停止调度器之前，先关闭所有 socket 和资源
    std.log.info("[Alice] 程序完成，准备退出", .{});

    // 1. 关闭 WebSocket 连接（会触发 tcp.close）
    ws.deinit();

    // 2. 关闭 TCP 连接（如果还没有关闭）
    tcp.close();
    tcp.deinit();

    // 3. 关闭 UDP socket（如果存在）
    if (created_udp) |udp| {
        if (udp.xobj) |_| {
            udp.close();
        }
        schedule.allocator.destroy(udp);
        created_udp = null;
    }

    // 4. 清理 PeerConnection（deinit 内部会调用 close() 等待所有协程退出）
    pc.deinit();

    // 5. 通知等待协程工作完成（WaitGroup 需要在调度器运行时工作）
    std.log.info("[Alice] 通知等待协程工作完成", .{});
    wg.done();
    std.log.info("[Alice] 工作完成，协程即将退出", .{});
}

/// 运行 Bob（接收方）
fn runBob(schedule: *zco.Schedule, room_id: []const u8, wg: *zco.WaitGroup) !void {
    std.log.info("[Bob] 启动客户端...", .{});

    // 创建 PeerConnection
    const config = Configuration{};
    const pc = try PeerConnection.init(schedule.allocator, schedule, config);
    errdefer pc.deinit(); // 错误路径清理
    // 注意：正常路径手动控制清理顺序

    // 跟踪创建的 UDP socket，以便在函数结束时清理
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
    errdefer tcp.deinit(); // 错误路径清理

    // 尝试连接，如果失败则等待后重试
    const max_retries = 5;
    var retry_count: u32 = 0;
    while (retry_count < max_retries) {
        tcp.connect(server_addr) catch |err| {
            if (err == error.ConnectionRefused) {
                retry_count += 1;
                if (retry_count < max_retries) {
                    std.log.info("[Bob] 连接被拒绝，等待后重试 ({}/{})...", .{ retry_count, max_retries });
                    const current_co_bob = try schedule.getCurrentCo();
                    try current_co_bob.Sleep(500 * std.time.ns_per_ms);
                    continue;
                }
            }
            std.log.err("[Bob] 连接到信令服务器失败: {}", .{err});
            return err;
        };
        break;
    }
    // 注意：不在 defer 中关闭，手动控制清理顺序

    // 创建 WebSocket 连接
    var ws = try websocket.WebSocket.fromTcp(tcp);
    errdefer ws.deinit(); // 错误路径清理
    // 注意：正常路径手动控制清理顺序

    // 执行客户端握手
    try ws.clientHandshake("/", "127.0.0.1:8080");
    std.log.info("[Bob] 已连接到信令服务器", .{});

    // 加入房间
    const user_id = "bob";
    const bob_room_id_dup = try schedule.allocator.dupe(u8, room_id);
    const bob_user_id_dup = try schedule.allocator.dupe(u8, user_id);

    var join_msg = SignalingMessage{
        .type = .join,
        .room_id = bob_room_id_dup,
        .user_id = bob_user_id_dup,
    };
    defer join_msg.deinit(schedule.allocator);

    const join_json = try join_msg.toJson(schedule.allocator);
    defer schedule.allocator.free(join_json);
    try ws.sendText(join_json);
    std.log.info("[Bob] 已加入房间: {s}", .{room_id});

    // 设置 UDP Socket（可选，如果指定地址，否则会在 setLocalDescription 时自动创建）
    // 注意：在浏览器 API 中，UDP Socket 会在 setLocalDescription 时自动创建
    // 这里提前创建是为了指定绑定地址（127.0.0.1）
    const bob_bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    created_udp = try pc.setupUdpSocket(bob_bind_addr); // 跟踪创建的 UDP（用于后续清理）

    // 等待接收 user_joined 通知（Alice 上线）或 offer
    std.log.info("[Bob] 开始等待 user_joined 通知或 offer...", .{});
    var offer_received = false;
    var alice_joined = false;
    var message_count: u32 = 0;

    while (message_count < 20) { // 增加最大消息数
        const frame = ws.readMessage(ws_buffer[0..]) catch |err| {
            // 区分连接关闭和真正的错误
            if (err == websocket.WebSocketError.ConnectionClosed or err == error.EOF) {
                std.log.info("[Bob] WebSocket 连接已关闭（EOF）", .{});
            } else {
                std.log.err("[Bob] 读取消息失败: {}", .{err});
            }
            break;
        };
        // 注意：readMessage 返回的 payload 总是新分配的内存（根据 websocket.zig 注释），需要释放
        defer ws.allocator.free(frame.payload);

        if (frame.opcode == .CLOSE) {
            std.log.info("[Bob] WebSocket 连接已关闭", .{});
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
        ) catch |err| {
            std.log.err("[Bob] 解析消息失败: {}，消息内容: {s}", .{ err, frame.payload });
            continue;
        };
        defer parsed.deinit();
        const msg = parsed.value;

        std.log.info("[Bob] 收到消息类型: {}", .{msg.type});

        // 处理消息
        switch (msg.type) {
            .user_joined => {
                // 收到 user_joined 通知，说明 Alice 已经上线
                if (msg.user_id) |joined_user_id| {
                    std.log.info("[Bob] 收到 user_joined 通知: {s} 已加入房间", .{joined_user_id});
                    if (std.mem.eql(u8, joined_user_id, "alice")) {
                        alice_joined = true;
                        std.log.info("[Bob] Alice 已上线，准备接收 offer", .{});
                    }
                }
                // 注意：parsed.deinit() 会释放 msg 内部的所有内存，不需要单独调用 msg.deinit()
                message_count += 1;
                continue;
            },
            .offer => {
                if (msg.sdp) |sdp| {
                    std.log.info("[Bob] 收到 offer，开始处理... (SDP 长度: {} 字节)", .{sdp.len});
                    var remote_sdp = webrtc.signaling.sdp.Sdp.parse(schedule.allocator, sdp) catch |err| {
                        std.log.err("[Bob] 解析 SDP 失败: {}", .{err});
                        continue;
                    };
                    // 注意：remote_sdp 是值类型，需要转换为堆分配
                    // setRemoteDescription 会负责释放旧的描述和新的描述
                    const remote_sdp_ptr = schedule.allocator.create(webrtc.signaling.sdp.Sdp) catch |err| {
                        std.log.err("[Bob] 分配 SDP 内存失败: {}", .{err});
                        // 在 continue 前清理 remote_sdp
                        remote_sdp.deinit();
                        continue;
                    };
                    errdefer schedule.allocator.destroy(remote_sdp_ptr);

                    // 拷贝 remote_sdp 到 remote_sdp_ptr（注意：这是浅拷贝，字段指针会共享）
                    remote_sdp_ptr.* = remote_sdp;
                    // 注意：由于浅拷贝，remote_sdp 和 remote_sdp_ptr 共享字段指针
                    // 一旦 remote_sdp_ptr 的所有权转移给 PeerConnection，remote_sdp 的字段就不应该再被清理
                    // 为了避免 errdefer 清理 remote_sdp，我们使用不同的策略：
                    // 在成功转移后，我们不清空 remote_sdp 的字段，而是确保 errdefer 不会执行
                    // 但实际上，由于 errdefer 只在错误路径执行，成功路径上不会执行
                    // 所以问题可能是：在 continue 之后，remote_sdp 仍然在作用域中，但它的字段已经被转移
                    // 解决方案：在成功转移后，我们不需要做任何事情，因为 errdefer 不会执行
                    // 但为了安全，我们仍然可以清空字段引用（虽然这不是必需的）
                    
                    // 如果 setRemoteDescription 失败，需要清理 remote_sdp_ptr（包括内部的字段）
                    pc.setRemoteDescription(remote_sdp_ptr) catch |err| {
                        std.log.err("[Bob] 设置远程 offer 失败: {}", .{err});
                        // 清理 remote_sdp_ptr 中的字段（通过 deinit）
                        remote_sdp_ptr.deinit();
                        schedule.allocator.destroy(remote_sdp_ptr);
                        // 注意：remote_sdp 的字段指针已被 remote_sdp_ptr 共享，所以不需要再清理
                        continue;
                    };
                    // 注意：如果成功，remote_sdp_ptr 的所有权转移给 PeerConnection
                    // remote_sdp 的字段指针已经转移到 remote_sdp_ptr，不需要清理
                    // errdefer 不会执行（因为函数没有返回错误）
                    std.log.info("[Bob] 已设置远程 offer，ICE 连接状态: {}", .{pc.getIceConnectionState()});

                    // 创建 answer
                    std.log.info("[Bob] 开始创建 answer...", .{});
                    const answer = try pc.createAnswer(schedule.allocator, null);
                    // 注意：answer 会被 setLocalDescription 接管，不需要手动 deinit
                    const answer_sdp = try answer.generate();
                    defer schedule.allocator.free(answer_sdp);

                    try pc.setLocalDescription(answer);
                    std.log.info("[Bob] 已创建并设置本地 answer", .{});

                    // 发送 answer
                    std.log.info("[Bob] 准备发送 answer...", .{});
                    // 注意：这些内存会被 answer_msg.deinit 释放
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
                    // 注意：answer_sdp 会被 answer_msg.deinit 释放（通过 answer_sdp_dup），不需要再次释放

                    const answer_json = try answer_msg.toJson(schedule.allocator);
                    defer schedule.allocator.free(answer_json);
                    try ws.sendText(answer_json);
                    std.log.info("[Bob] ✅ 已发送 answer (SDP 长度: {} 字节)", .{answer_sdp.len});

                    offer_received = true;
                    std.log.info("[Bob] 已收到 offer 并发送 answer，退出等待循环", .{});
                    break; // 收到 offer 并发送 answer 后立即退出
                }
            },
            .ice_candidate => {
                if (msg.candidate) |candidate| {
                    std.log.info("[Bob] 收到 ICE candidate: {s}", .{candidate.candidate});
                    var ice_candidate = try webrtc.ice.candidate.Candidate.fromSdpCandidate(
                        schedule.allocator,
                        candidate.candidate,
                    );
                    defer ice_candidate.deinit();

                    // 创建堆分配的 candidate
                    const candidate_ptr = try schedule.allocator.create(webrtc.ice.candidate.Candidate);
                    candidate_ptr.* = ice_candidate;
                    try pc.addIceCandidate(candidate_ptr);
                    std.log.info("[Bob] 已添加远程 ICE candidate，ICE 连接状态: {}", .{pc.getIceConnectionState()});
                }
            },
            else => {
                std.log.info("[Bob] 收到其他类型消息: {}", .{msg.type});
            },
        }

        // 注意：parsed.deinit() 会释放 msg 内部的所有内存，不需要单独调用 msg.deinit()
        message_count += 1;

        // 如果已收到 offer，等待少量消息后退出（类似 Alice 的逻辑）
        if (offer_received and message_count >= 5) {
            std.log.info("[Bob] 已收到 offer 和足够的消息，退出等待循环", .{});
            break;
        }
    }

    // 发送 ICE candidates
    const bob_local_candidates = pc.getLocalCandidates();
    for (bob_local_candidates) |candidate| {
        const candidate_str = try candidate.toSdpCandidate(schedule.allocator);
        defer schedule.allocator.free(candidate_str);

        // 注意：这些内存会被 ice_msg.deinit 释放
        const bob_ice_room_id_dup = try schedule.allocator.dupe(u8, room_id);
        const bob_ice_user_id_dup = try schedule.allocator.dupe(u8, user_id);
        const bob_ice_candidate_str_dup = try schedule.allocator.dupe(u8, candidate_str);

        var ice_msg = SignalingMessage{
            .type = .ice_candidate,
            .room_id = bob_ice_room_id_dup,
            .user_id = bob_ice_user_id_dup,
            .candidate = .{
                .candidate = bob_ice_candidate_str_dup,
            },
        };
        defer ice_msg.deinit(schedule.allocator);

        const ice_json = try ice_msg.toJson(schedule.allocator);
        defer schedule.allocator.free(ice_json);
        try ws.sendText(ice_json);
    }
    std.log.info("[Bob] 已发送所有 ICE candidates", .{});

    // 设置 SCTP Verification Tags（简化实现）
    // 注意：在实际应用中，verification tags 应该从 SCTP 握手过程中获取
    // 这里暂时跳过，等待后续完善

    // 获取当前协程用于等待
    const current_co_bob_final = try schedule.getCurrentCo();

    // 事件驱动：使用回调驱动，等待连接建立（ICE + DTLS）
    std.log.info("[Bob] 等待 ICE 连接建立和 DTLS 握手完成（回调驱动）...", .{});

    // 创建 Channel 来接收连接就绪的信号
    var connection_ready_chan = try ConnectionReadyChan.init(schedule, 1);
    defer connection_ready_chan.deinit();

    // 检查连接状态
    const connection_state = pc.getConnectionState();
    if (connection_state == .failed) {
        std.log.err("[Bob] 连接失败", .{});
        return;
    }

    // 如果连接已经建立，直接继续
    var connection_ready = false;
    if (connection_state == .connected) {
        // 确认 DTLS 握手也已完成
        if (pc.isDtlsHandshakeComplete()) {
            connection_ready = true;
            std.log.info("[Bob] 连接已就绪（ICE + DTLS）", .{});
        }
    }

    // 设置回调（无论连接是否已就绪，都设置回调以便后续状态变化时能收到通知）
    // 由于回调函数签名限制（?*const fn (*Self) void），不能携带额外参数
    // 使用全局变量存储 Channel 指针（在单进程测试场景中是安全的）
    bob_connection_chan = connection_ready_chan;

    // 设置连接状态变化回调（回调驱动）
    pc.onconnectionstatechange = struct {
        fn callback(pc_self: *PeerConnection) void {
            const state = pc_self.getConnectionState();
            std.log.info("[Bob] 连接状态变化回调被触发: {}", .{state});
            // 只有在连接成功建立时才发送信号
            if (state == .connected) {
                // 确认 DTLS 握手也已完成
                if (pc_self.isDtlsHandshakeComplete()) {
                    if (bob_connection_chan) |ch| {
                        _ = ch.send(true) catch |e| {
                            std.log.err("[Bob] 发送连接就绪信号失败: {}", .{e});
                        };
                    }
                }
            }
        }
    }.callback;

    // 同时监听 DTLS 握手完成回调（确保在 DTLS 完成时也能发送信号）
    pc.ondtlshandshakecomplete = struct {
        fn callback(pc_self: *PeerConnection) void {
            std.log.info("[Bob] DTLS 握手完成回调被触发", .{});
            // 检查连接状态是否为 connected
            const state = pc_self.getConnectionState();
            if (state == .connected) {
                // 确认 DTLS 握手已完成
                if (pc_self.isDtlsHandshakeComplete()) {
                    if (bob_connection_chan) |ch| {
                        _ = ch.send(true) catch |e| {
                            std.log.err("[Bob] 发送连接就绪信号失败: {}", .{e});
                        };
                    }
                }
            }
        }
    }.callback;

    // 如果还未就绪，等待回调通知
    if (!connection_ready) {
        // 设置回调后，再次检查状态（避免竞态条件：回调可能在设置回调之前就触发）
        const state_after_setup = pc.getConnectionState();
        if (state_after_setup == .connected) {
            if (pc.isDtlsHandshakeComplete()) {
                // 连接已经就绪，直接发送信号
                _ = connection_ready_chan.send(true) catch |e| {
                    std.log.err("[Bob] 发送连接就绪信号失败: {}", .{e});
                };
                connection_ready = true;
            }
        }

        // 如果还未就绪，等待 Channel 接收信号（事件驱动，协程会被挂起）
        if (!connection_ready) {
            _ = try connection_ready_chan.recv();
            connection_ready = true;
            std.log.info("[Bob] 连接已就绪（通过回调）", .{});
        }
    } else {
        // 连接已经就绪，不需要等待回调
        // 注意：不要手动触发回调，因为回调可能会尝试发送消息到 channel，
        // 而 channel 可能已经发送过消息了，这会导致错误
        std.log.info("[Bob] 连接已就绪（检查时发现已就绪），跳过回调触发", .{});
    }

    // 清理
    bob_connection_chan = null;

    // 创建数据通道（匹配 Alice 创建的通道）
    if (!connection_ready) {
        std.log.warn("[Bob] 连接未就绪，跳过数据通道创建", .{});
        try current_co_bob_final.Sleep(200 * std.time.ns_per_ms);
        return;
    }

    // Bob 也需要创建匹配的数据通道来接收和发送消息
    // 注意：在实际 WebRTC 中，接收方会自动创建数据通道，这里需要手动创建匹配的通道
    // 注意：DataChannel 的所有权由 PeerConnection 管理，不需要手动 deinit
    // PeerConnection.deinit() 会自动释放所有 DataChannel
    const channel = try pc.createDataChannel("test-channel", null);
    std.log.info("[Bob] 已创建数据通道", .{});

    // 设置数据通道事件
    channel.setOnOpen(struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[Bob] 数据通道已打开", .{});
        }
    }.callback);

    // 创建消息 Channel 用于 ping-pong 状态机
    const message_chan = try MessageChan.init(schedule, 10);
    defer message_chan.deinit();
    bob_message_chan = message_chan;

    // 设置消息接收回调，收到 ping 后发送 pong
    channel.setOnMessage(struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            std.log.info("[Bob] 收到消息: {s}", .{data});

            // 如果收到 ping，发送 pong
            if (std.mem.eql(u8, data, "ping")) {
                const pong_msg = "pong";
                ch.send(pong_msg, null) catch |err| {
                    std.log.err("[Bob] 发送 pong 失败: {}", .{err});
                    return;
                };
                std.log.info("[Bob] 已发送 pong", .{});
            }

            // 将消息发送到 Channel（用于状态机）
            if (bob_message_chan) |msg_chan| {
                // 使用 PeerConnection 的 allocator 来分配内存
                const pc_ptr = @as(*PeerConnection, @ptrCast(@alignCast(ch.peer_connection orelse {
                    std.log.err("[Bob] DataChannel 没有关联 PeerConnection", .{});
                    return;
                })));
                const data_copy = pc_ptr.allocator.dupe(u8, data) catch {
                    std.log.err("[Bob] 复制消息数据失败", .{});
                    return;
                };
                _ = msg_chan.send(data_copy) catch |err| {
                    // 如果是调度器已退出，这是正常的，不需要报错
                    if (err != error.ScheduleExited) {
                        std.log.err("[Bob] 发送消息到 Channel 失败: {}", .{err});
                    }
                    pc_ptr.allocator.free(data_copy);
                };
            }
        }
    }.callback);

    // 打开数据通道
    channel.setState(.open);

    // 等待连接建立
    try current_co_bob_final.Sleep(200 * std.time.ns_per_ms);

    // 创建 WaitGroup 来等待接收协程完成
    var recv_wg = try zco.WaitGroup.init(schedule);
    defer recv_wg.deinit();
    try recv_wg.add(1);

    // 接收数据通道消息（通过 recvSctpData 处理传入的数据）
    _ = try schedule.go(receiveDataChannelMessages, .{ pc, &recv_wg });

    // Ping-Pong 状态机：Bob 等待接收 ping，收到后发送 pong，然后退出
    // 注意：只有发送 offer 的一方（Alice）发送 ping，Bob 只回复 pong
    std.log.info("[Bob] 等待接收 ping...", .{});
    const received_msg = try message_chan.recv();
    defer schedule.allocator.free(received_msg);

    if (std.mem.eql(u8, received_msg, "ping")) {
        std.log.info("[Bob] 收到 ping，已发送 pong（在回调中），退出", .{});
    } else {
        std.log.warn("[Bob] 收到非预期消息: {s}", .{received_msg});
    }

    // 清理：先清理 message_chan，避免回调尝试发送消息
    bob_message_chan = null;

    // 关闭 DataChannel，让 recvSctpData 返回，使 receiveDataChannelMessages 协程退出
    channel.setState(.closed);
    std.log.info("[Bob] 已关闭数据通道", .{});

    // 等待一小段时间，确保所有回调都已完成
    try current_co_bob_final.Sleep(50 * std.time.ns_per_ms);

    // 等待接收协程完成（在停止调度器之前）
    // 注意：关闭 channel 后，receiveDataChannelMessages 会检测到 ChannelClosed 并退出，主动调用 recv_wg.done()
    std.log.info("[Bob] 等待接收协程完成...", .{});
    // 在调度器还在运行时等待 WaitGroup
    // recv_wg.wait() 会发送信号，如果 count > 0，done() 会接收这个信号
    // 如果 count == 0，说明协程已经退出，直接返回
    recv_wg.wait();
    // wait() 的 send() 会阻塞等待，直到 done() 的 recv() 完成
    // 所以 wait() 返回时，done() 已经完成，不需要额外的 sleep

    // 在停止调度器之前，先关闭所有 socket 和资源
    std.log.info("[Bob] 程序完成，准备退出", .{});

    // 1. 关闭 WebSocket 连接（会触发 tcp.close）
    ws.deinit();

    // 2. 关闭 TCP 连接（如果还没有关闭）
    tcp.close();
    tcp.deinit();

    // 3. 关闭 UDP socket（如果存在）
    if (created_udp) |udp| {
        if (udp.xobj) |_| {
            udp.close();
        }
        schedule.allocator.destroy(udp);
        created_udp = null;
    }

    // 4. 清理 PeerConnection（deinit 内部会调用 close() 等待所有协程退出）
    pc.deinit();

    // 5. 通知等待协程工作完成（WaitGroup 需要在调度器运行时工作）
    std.log.info("[Bob] 通知等待协程工作完成", .{});
    wg.done();
    std.log.info("[Bob] 工作完成，协程即将退出", .{});
}

/// 接收数据通道消息（处理 SCTP 数据包）
/// 事件驱动：持续接收 SCTP 数据，直到出错或调度器退出
/// 注意：这个协程只负责接收和处理 SCTP 数据，实际的用户消息通过 onmessage 回调处理
fn receiveDataChannelMessages(pc: *PeerConnection, wg: *zco.WaitGroup) !void {
    // 注意：不在 defer 中调用 done()，而是在退出前主动调用，确保在调度器停止前执行
    errdefer wg.done(); // 只在错误路径调用 done()

    const current_co = try pc.schedule.getCurrentCo();
    std.log.info("开始接收数据通道消息（事件驱动）...", .{});

    var consecutive_errors: u32 = 0;
    const max_consecutive_errors = 10; // 最多连续错误 10 次后退出

    // 事件驱动：recvSctpData 会挂起协程直到数据到达
    // 持续接收，直到调度器退出、channel 关闭或连续错误太多
    while (true) {
        pc.recvSctpData() catch |err| {
            // 如果调度器已退出，立即退出协程
            if (err == error.ScheduleExited) {
                std.log.info("调度器已退出，数据通道消息接收协程退出", .{});
                wg.done(); // 在退出前主动调用 done()
                return;
            }

            // 如果 channel 已关闭，退出协程
            if (err == error.ChannelClosed) {
                std.log.info("数据通道已关闭，数据通道消息接收协程退出", .{});
                wg.done(); // 在退出前主动调用 done()
                return;
            }

            consecutive_errors += 1;
            if (consecutive_errors >= max_consecutive_errors) {
                // 连续错误太多，可能连接已断开，退出
                std.log.info("数据通道消息接收连续失败，退出", .{});
                wg.done(); // 在退出前主动调用 done()
                return;
            }

            // 如果是非阻塞错误（如没有数据），等待后重试
            std.log.debug("接收 SCTP 数据失败: {}，等待后重试 ({}/{})", .{ err, consecutive_errors, max_consecutive_errors });

            // 在 Sleep 时也可能收到 ScheduleExited 错误
            current_co.Sleep(50 * std.time.ns_per_ms) catch |sleep_err| {
                if (sleep_err == error.ScheduleExited) {
                    std.log.info("调度器已退出，数据通道消息接收协程退出", .{});
                    wg.done(); // 在退出前主动调用 done()
                    return;
                }
                wg.done(); // 错误路径也调用 done()
                return sleep_err;
            };
            continue;
        };
        // 成功接收（即使是非 application_data 类型，也会正常返回）
        // 重置错误计数，继续接收
        consecutive_errors = 0;
    }
}
