const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const websocket = @import("websocket");
const webrtc = @import("webrtc");

const PeerConnection = webrtc.peer.connection.PeerConnection;
const Configuration = webrtc.peer.connection.Configuration;
const SignalingMessage = webrtc.signaling.message.SignalingMessage;
const DataChannel = webrtc.sctp.datachannel.DataChannel;

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

    // 在协程中运行客户端
    if (std.mem.eql(u8, role, "alice")) {
        _ = try schedule.go(runAlice, .{ schedule, room_id });
    } else if (std.mem.eql(u8, role, "bob")) {
        _ = try schedule.go(runBob, .{ schedule, room_id });
    } else {
        std.log.err("角色必须是 'alice' 或 'bob'", .{});
        return error.InvalidArguments;
    }

    // 运行调度器
    try schedule.loop();
}

/// 运行 Alice（发起方）
fn runAlice(schedule: *zco.Schedule, room_id: []const u8) !void {
    std.log.info("[Alice] 启动客户端...", .{});

    // 创建 PeerConnection
    const config = Configuration{};
    const pc = try PeerConnection.init(schedule.allocator, schedule, config);
    defer pc.deinit();

    // 跟踪创建的 UDP socket，以便在函数结束时清理
    var created_udp: ?*nets.Udp = null;
    defer if (created_udp) |udp| {
        // 清理 UDP socket（在 pc.deinit 之前）
        if (udp.xobj) |_| {
            udp.close();
        }
        schedule.allocator.destroy(udp);
    };

    // 连接到信令服务器
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const tcp = try nets.Tcp.init(schedule);
    defer tcp.deinit();

    try tcp.connect(server_addr);
    defer tcp.close();

    // 创建 WebSocket 连接
    var ws = try websocket.WebSocket.fromTcp(tcp);
    defer ws.deinit();

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

    // 设置 ICE Agent 的 UDP Socket
    if (pc.ice_agent) |agent| {
        if (agent.udp == null) {
            const udp = try nets.Udp.init(schedule);
            created_udp = udp; // 跟踪创建的 UDP
            agent.udp = udp;
            const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
            try udp.bind(bind_addr);
        }
        try agent.gatherHostCandidates();
        std.log.info("[Alice] 已收集 Host Candidates", .{});
    }

    // 设置 DTLS Record 的 UDP Socket
    if (pc.dtls_record) |record| {
        if (pc.ice_agent) |agent| {
            if (agent.udp) |udp| {
                record.setUdp(udp);
                std.log.info("[Alice] DTLS Record 已关联 UDP Socket", .{});
            }
        }
    }

    // 等待一小段时间，让 Bob 有时间加入房间
    // 注意：如果 Bob 已经加入，服务器会发送 user_joined 通知，但我们不在这里等待
    // 因为 readMessage 是阻塞的，会导致程序卡住
    // 我们直接等待一小段时间，然后发送 offer
    // 如果 Bob 还没加入，他会在加入后收到 offer
    const current_co = try schedule.getCurrentCo();
    std.log.info("[Alice] 等待 Bob 加入房间（1 秒）...", .{});
    try current_co.Sleep(1 * std.time.ns_per_s);

    // 创建 offer
    const offer = try pc.createOffer(schedule.allocator);
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
    // 注意：buffer 已经在上面声明了，这里重新使用
    var message_count: u32 = 0;
    var received_answer = false;

    std.log.info("[Alice] 开始等待 answer 和 ICE candidates...", .{});
    while (message_count < 10) {
        const frame = ws.readMessage(buffer[0..]) catch |err| {
            // 区分连接关闭和真正的错误
            if (err == websocket.WebSocketError.ConnectionClosed) {
                std.log.info("[Alice] WebSocket 连接已关闭（EOF）", .{});
            } else {
                std.log.err("[Alice] 读取消息失败: {}", .{err});
            }
            break;
        };
        defer if (frame.payload.len > buffer.len) ws.allocator.free(frame.payload);

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
        var msg = parsed.value;

        std.log.info("[Alice] 收到消息类型: {}", .{msg.type});

        // 处理消息
        switch (msg.type) {
            .user_joined => {
                // 如果收到 user_joined（在等待 answer 期间），记录日志
                if (msg.user_id) |joined_user_id| {
                    std.log.info("[Alice] 收到 user_joined 通知: {s} 已加入房间（等待 answer 期间）", .{joined_user_id});
                }
                msg.deinit(schedule.allocator);
                message_count += 1;
                continue;
            },
            .answer => {
                if (msg.sdp) |sdp| {
                    std.log.info("[Alice] 收到 answer，开始解析...", .{});
                    const remote_sdp = try webrtc.signaling.sdp.Sdp.parse(schedule.allocator, sdp);
                    // 注意：remote_sdp 是值类型，需要转换为堆分配
                    // setRemoteDescription 会负责释放旧的描述和新的描述
                    const remote_sdp_ptr = try schedule.allocator.create(webrtc.signaling.sdp.Sdp);
                    remote_sdp_ptr.* = remote_sdp;
                    try pc.setRemoteDescription(remote_sdp_ptr);
                    std.log.info("[Alice] 已设置远程 answer，ICE 连接状态: {}", .{pc.getIceConnectionState()});
                    received_answer = true;
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
                }
            },
            else => {
                std.log.info("[Alice] 收到其他类型消息: {}", .{msg.type});
            },
        }

        msg.deinit(schedule.allocator);
        message_count += 1;
    }

    if (!received_answer) {
        std.log.warn("[Alice] 未收到 answer，可能连接失败", .{});
        return;
    }

    // 获取当前协程用于等待
    const current_co_alice = try schedule.getCurrentCo();

    // 等待一段时间让 ICE candidates 交换完成
    std.log.info("[Alice] 等待 ICE candidates 交换完成...", .{});
    try current_co_alice.Sleep(2 * std.time.ns_per_s);

    // 等待 ICE 连接建立和 DTLS 握手完成
    // 注意：在创建数据通道前，需要完成 DTLS 握手
    std.log.info("[Alice] 等待 ICE 连接建立和 DTLS 握手完成...", .{});

    // 轮询检查 ICE 连接和 DTLS 握手状态
    const max_wait_time: u64 = 10 * std.time.ns_per_s; // 最多等待 10 秒
    const check_interval: u64 = 500 * std.time.ns_per_ms; // 每 500ms 检查一次
    var waited_time: u64 = 0;
    var dtls_ready = false;

    while (waited_time < max_wait_time and !dtls_ready) {
        try current_co_alice.Sleep(check_interval);
        waited_time += check_interval;

        // 检查 ICE 连接状态
        const ice_state = pc.getIceConnectionState();
        std.log.debug("[Alice] ICE 连接状态: {}", .{ice_state});

        // 检查 DTLS 握手状态
        if (pc.dtls_handshake) |handshake| {
            std.log.debug("[Alice] DTLS 握手状态: {}", .{handshake.state});
            if (handshake.state == .handshake_complete) {
                dtls_ready = true;
                std.log.info("[Alice] DTLS 握手已完成", .{});
                break;
            }
        }

        // 如果 ICE 连接失败，提前退出
        if (ice_state == .failed) {
            std.log.err("[Alice] ICE 连接失败", .{});
            return;
        }
    }

    // 创建数据通道（如果 DTLS 握手已完成）
    if (!dtls_ready) {
        std.log.warn("[Alice] DTLS 握手未完成（等待超时），跳过数据通道创建", .{});
        // 等待一段时间后退出
        try current_co_alice.Sleep(2 * std.time.ns_per_s);
        return;
    }

    const channel = try pc.createDataChannel("test-channel", null);
    defer channel.deinit();
    std.log.info("[Alice] 已创建数据通道", .{});

    // 设置数据通道事件
    channel.setOnOpen(struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[Alice] 数据通道已打开", .{});
        }
    }.callback);

    channel.setOnMessage(struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            _ = ch;
            std.log.info("[Alice] 收到消息: {s}", .{data});
        }
    }.callback);

    // 打开数据通道
    channel.setState(.open);

    // 发送 ICE candidates
    if (pc.ice_agent) |agent| {
        for (agent.local_candidates.items) |candidate| {
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
    }

    // 等待一段时间，让连接建立
    try current_co_alice.Sleep(3 * std.time.ns_per_s);

    // 发送测试消息
    if (channel.getState() == .open) {
        const test_msg = "Hello from Alice!";
        if (channel.send(test_msg, null)) {
            std.log.info("[Alice] 已发送测试消息", .{});
        } else |err| {
            std.log.err("[Alice] 发送消息失败: {}", .{err});
        }
    }

    // 等待接收消息
    try current_co_alice.Sleep(2 * std.time.ns_per_s);
}

/// 运行 Bob（接收方）
fn runBob(schedule: *zco.Schedule, room_id: []const u8) !void {
    std.log.info("[Bob] 启动客户端...", .{});

    // 创建 PeerConnection
    const config = Configuration{};
    const pc = try PeerConnection.init(schedule.allocator, schedule, config);
    defer pc.deinit();

    // 跟踪创建的 UDP socket，以便在函数结束时清理
    var created_udp: ?*nets.Udp = null;
    defer if (created_udp) |udp| {
        // 清理 UDP socket（在 pc.deinit 之前）
        if (udp.xobj) |_| {
            udp.close();
        }
        schedule.allocator.destroy(udp);
    };

    // 连接到信令服务器
    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 8080);
    const tcp = try nets.Tcp.init(schedule);
    defer tcp.deinit();

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
    defer tcp.close();

    // 创建 WebSocket 连接
    var ws = try websocket.WebSocket.fromTcp(tcp);
    defer ws.deinit();

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

    // 设置 ICE Agent 的 UDP Socket
    if (pc.ice_agent) |agent| {
        if (agent.udp == null) {
            const udp = try nets.Udp.init(schedule);
            created_udp = udp; // 跟踪创建的 UDP
            agent.udp = udp;
            const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 0);
            try udp.bind(bind_addr);
        }
        try agent.gatherHostCandidates();
        std.log.info("[Bob] 已收集 Host Candidates", .{});
    }

    // 设置 DTLS Record 的 UDP Socket
    if (pc.dtls_record) |record| {
        if (pc.ice_agent) |agent| {
            if (agent.udp) |udp| {
                record.setUdp(udp);
                std.log.info("[Bob] DTLS Record 已关联 UDP Socket", .{});
            }
        }
    }

    // 等待接收 user_joined 通知（Alice 上线）或 offer
    std.log.info("[Bob] 开始等待 user_joined 通知或 offer...", .{});
    var buffer: [8192]u8 = undefined;
    var offer_received = false;
    var alice_joined = false;
    var message_count: u32 = 0;

    while (message_count < 20) { // 增加最大消息数
        const frame = ws.readMessage(buffer[0..]) catch |err| {
            // 区分连接关闭和真正的错误
            if (err == websocket.WebSocketError.ConnectionClosed) {
                std.log.info("[Bob] WebSocket 连接已关闭（EOF）", .{});
            } else {
                std.log.err("[Bob] 读取消息失败: {}", .{err});
            }
            break;
        };
        defer if (frame.payload.len > buffer.len) ws.allocator.free(frame.payload);

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
        var msg = parsed.value;

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
                msg.deinit(schedule.allocator);
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
                    errdefer remote_sdp.deinit();

                    // 注意：remote_sdp 是值类型，需要转换为堆分配
                    // setRemoteDescription 会负责释放旧的描述和新的描述
                    const remote_sdp_ptr = schedule.allocator.create(webrtc.signaling.sdp.Sdp) catch |err| {
                        std.log.err("[Bob] 分配 SDP 内存失败: {}", .{err});
                        continue;
                    };
                    remote_sdp_ptr.* = remote_sdp;
                    pc.setRemoteDescription(remote_sdp_ptr) catch |err| {
                        std.log.err("[Bob] 设置远程 offer 失败: {}", .{err});
                        schedule.allocator.destroy(remote_sdp_ptr);
                        continue;
                    };
                    std.log.info("[Bob] 已设置远程 offer，ICE 连接状态: {}", .{pc.getIceConnectionState()});

                    // 创建 answer
                    std.log.info("[Bob] 开始创建 answer...", .{});
                    const answer = try pc.createAnswer(schedule.allocator);
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

        msg.deinit(schedule.allocator);
        message_count += 1;
    }

    // 发送 ICE candidates
    if (pc.ice_agent) |agent| {
        for (agent.local_candidates.items) |candidate| {
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
    }

    // 设置 SCTP Verification Tags（简化实现）
    // 注意：在实际应用中，verification tags 应该从 SCTP 握手过程中获取
    // 这里暂时跳过，等待后续完善

    // 获取当前协程用于等待
    const current_co_bob_final = try schedule.getCurrentCo();

    // 等待连接建立
    try current_co_bob_final.Sleep(3 * std.time.ns_per_s);

    // 接收数据通道消息
    _ = try schedule.go(receiveDataChannelMessages, .{pc});

    // 等待接收消息
    try current_co_bob_final.Sleep(5 * std.time.ns_per_s);
}

/// 接收数据通道消息
fn receiveDataChannelMessages(pc: *PeerConnection) !void {
    std.log.info("[Bob] 开始接收数据通道消息...", .{});

    var count: u32 = 0;
    while (count < 100) {
        pc.recvSctpData() catch |err| {
            _ = err catch {};
            continue;
        };
        count += 1;
    }
}
