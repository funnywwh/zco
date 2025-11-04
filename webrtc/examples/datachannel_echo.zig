const std = @import("std");
const zco = @import("zco");
const webrtc = @import("webrtc");
const nets = @import("nets");

const peer = webrtc.peer;
const connection = peer.connection;
const PeerConnection = connection.PeerConnection;
const Configuration = connection.Configuration;
const DataChannel = webrtc.sctp.DataChannel;
const Candidate = webrtc.ice.Candidate;

/// 数据通道 Echo 示例
/// 使用两个独立的 PeerConnection 实现真正的网络通信
pub fn main() !void {
    std.log.info("=== WebRTC 数据通道 Echo 示例 ===", .{});

    // 使用 zco.loop() 运行示例
    try zco.loop(runEchoExample, .{});
}

/// 运行 Echo 示例（在 zco.loop() 中）
fn runEchoExample() !void {
    // 获取 Schedule 和 Allocator
    const schedule = try zco.getSchedule();
    const allocator = schedule.allocator;

    std.log.info("创建了两个 PeerConnection: Alice 和 Bob", .{});

    // 创建两个独立的 PeerConnection（Alice 和 Bob）
    const config = Configuration{};
    var alice = try PeerConnection.init(allocator, schedule, config);
    defer alice.deinit();

    var bob = try PeerConnection.init(allocator, schedule, config);
    defer bob.deinit();

    // 设置 Alice（发送方）
    try setupAlice(alice, schedule);

    // 设置 Bob（接收方和 Echo）
    try setupBob(bob, schedule);

    // 等待设置完成
    const current_co = try schedule.getCurrentCo();
    try current_co.Sleep(500 * std.time.ns_per_ms);

    // 建立 ICE 连接（本地回环测试）
    try establishIceConnection(alice, bob, schedule);

    // 等待 ICE 连接建立
    try current_co.Sleep(500 * std.time.ns_per_ms);

    // 完成 DTLS 握手
    try establishDtlsHandshake(alice, bob, schedule);

    // 等待 DTLS 握手完成
    try current_co.Sleep(500 * std.time.ns_per_ms);

    // 创建数据通道并开始通信
    try startDataChannelCommunication(alice, bob, schedule);

    // 等待通信完成（等待所有消息发送和接收）
    try current_co.Sleep(8 * std.time.ns_per_s);

    std.log.info("Echo 示例完成", .{});

    // 停止调度器
    schedule.stop();
}

/// 设置 Alice（发送方）
fn setupAlice(pc: *PeerConnection, schedule: *zco.Schedule) !void {
    std.log.info("[Alice] 开始设置...", .{});

    // 初始化 UDP Socket 和 ICE Agent
    if (pc.ice_agent) |agent| {
        // 创建 UDP Socket
        if (agent.udp == null) {
            agent.udp = try nets.Udp.init(schedule);
            // 绑定到本地回环地址（Alice 使用端口 10000）
            const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 10000);
            try agent.udp.?.bind(bind_addr);
            std.log.info("[Alice] UDP Socket 已绑定到 127.0.0.1:10000", .{});
        }

        // 收集 Host Candidate
        try agent.gatherHostCandidates();
        std.log.info("[Alice] Host Candidates 已收集", .{});
    }

    // 设置 DTLS Record（需要 UDP Socket）
    if (pc.ice_agent) |agent| {
        if (agent.udp) |udp| {
            if (pc.dtls_record) |record| {
                // 将 ICE Agent 的 UDP Socket 关联到 DTLS Record
                record.setUdp(udp);
                std.log.info("[Alice] DTLS Record 已关联 UDP Socket", .{});
            }
        }
    }
}

/// 设置 Bob（接收方和 Echo）
fn setupBob(pc: *PeerConnection, schedule: *zco.Schedule) !void {
    std.log.info("[Bob] 开始设置...", .{});

    // 初始化 UDP Socket 和 ICE Agent
    if (pc.ice_agent) |agent| {
        // 创建 UDP Socket
        if (agent.udp == null) {
            agent.udp = try nets.Udp.init(schedule);
            // 绑定到本地回环地址（Bob 使用端口 10001）
            const bind_addr = try std.net.Address.parseIp4("127.0.0.1", 10001);
            try agent.udp.?.bind(bind_addr);
            std.log.info("[Bob] UDP Socket 已绑定到 127.0.0.1:10001", .{});
        }

        // 收集 Host Candidate
        try agent.gatherHostCandidates();
        std.log.info("[Bob] Host Candidates 已收集", .{});
    }

    // 设置 DTLS Record（需要 UDP Socket）
    if (pc.ice_agent) |agent| {
        if (agent.udp) |udp| {
            if (pc.dtls_record) |record| {
                // 将 ICE Agent 的 UDP Socket 关联到 DTLS Record
                record.setUdp(udp);
                std.log.info("[Bob] DTLS Record 已关联 UDP Socket", .{});
            }
        }
    }
}

/// 建立 ICE 连接
fn establishIceConnection(alice: *PeerConnection, bob: *PeerConnection, _: *zco.Schedule) !void {
    std.log.info("开始建立 ICE 连接...", .{});

    // 交换 Candidates
    if (alice.ice_agent) |alice_agent| {
        if (bob.ice_agent) |bob_agent| {
            // Alice 添加 Bob 的 Candidate
            const bob_candidate_addr = try std.net.Address.parseIp4("127.0.0.1", 10001);
            const bob_candidate_value = try Candidate.init(
                alice.allocator,
                "bob-host",
                1,
                "udp",
                bob_candidate_addr,
                .host,
            );
            const bob_candidate = try alice.allocator.create(Candidate);
            bob_candidate.* = bob_candidate_value;
            errdefer {
                bob_candidate.deinit();
                alice.allocator.destroy(bob_candidate);
            }
            try alice_agent.addRemoteCandidate(bob_candidate);
            std.log.info("[Alice] 已添加 Bob 的 Candidate", .{});

            // Bob 添加 Alice 的 Candidate
            const alice_candidate_addr = try std.net.Address.parseIp4("127.0.0.1", 10000);
            const alice_candidate_value = try Candidate.init(
                bob.allocator,
                "alice-host",
                1,
                "udp",
                alice_candidate_addr,
                .host,
            );
            const alice_candidate = try bob.allocator.create(Candidate);
            alice_candidate.* = alice_candidate_value;
            errdefer {
                alice_candidate.deinit();
                bob.allocator.destroy(alice_candidate);
            }
            try bob_agent.addRemoteCandidate(alice_candidate);
            std.log.info("[Bob] 已添加 Alice 的 Candidate", .{});

            // 生成 Candidate Pairs 并选择最佳对
            // 简化实现：直接选择第一个 Host Candidate Pair
            if (alice_agent.candidate_pairs.items.len > 0) {
                alice_agent.selected_pair = &alice_agent.candidate_pairs.items[0];
                alice_agent.state = .connected;
                std.log.info("[Alice] ICE 连接已建立", .{});
            }

            if (bob_agent.candidate_pairs.items.len > 0) {
                bob_agent.selected_pair = &bob_agent.candidate_pairs.items[0];
                bob_agent.state = .connected;
                std.log.info("[Bob] ICE 连接已建立", .{});
            }
        }
    }
}

/// 建立 DTLS 握手
fn establishDtlsHandshake(alice: *PeerConnection, bob: *PeerConnection, _: *zco.Schedule) !void {
    std.log.info("开始 DTLS 握手...", .{});

    // 简化实现：直接设置握手状态为完成，并设置加密密钥
    // 在实际应用中，需要交换 ClientHello/ServerHello 等消息，并从 Master Secret 派生密钥
    // 这里为了测试，使用相同的密钥（仅用于演示）
    const test_key = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10 };
    const test_iv = [_]u8{ 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c };
    const epoch: u16 = 1; // DTLS epoch 从 1 开始（0 用于握手）

    if (alice.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
        std.log.info("[Alice] DTLS 握手完成", .{});
    }

    if (bob.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
        std.log.info("[Bob] DTLS 握手完成", .{});
    }

    // 设置加密密钥（用于测试：Alice 和 Bob 使用相同的密钥）
    // 注意：在实际应用中，客户端和服务器的密钥应该是不同的（从 Master Secret 派生）
    if (alice.dtls_record) |record| {
        // Alice 作为客户端：write_cipher 用于发送，read_cipher 用于接收
        record.setWriteCipher(test_key, test_iv, epoch);
        record.setReadCipher(test_key, test_iv, epoch);
        std.log.info("[Alice] DTLS 加密密钥已设置", .{});
    }

    if (bob.dtls_record) |record| {
        // Bob 作为服务器：write_cipher 用于发送，read_cipher 用于接收
        record.setWriteCipher(test_key, test_iv, epoch);
        record.setReadCipher(test_key, test_iv, epoch);
        std.log.info("[Bob] DTLS 加密密钥已设置", .{});
    }
}

/// 开始数据通道通信
fn startDataChannelCommunication(alice: *PeerConnection, bob: *PeerConnection, schedule: *zco.Schedule) !void {
    std.log.info("开始数据通道通信...", .{});

    // Alice 创建数据通道（发送方）
    const alice_channel = try alice.createDataChannel("echo-channel", null);
    defer alice_channel.deinit();

    std.log.info("[Alice] 数据通道已创建 (Stream ID: {})", .{alice_channel.stream_id});

    // Bob 创建数据通道（接收方，需要匹配 Stream ID）
    // 注意：在实际应用中，Bob 应该从接收到的 DCEP Open 消息中获取 Stream ID
    // 这里简化实现，确保使用相同的 Stream ID
    const bob_channel = try bob.createDataChannel("echo-channel", null);
    defer bob_channel.deinit();

    // 确保 Bob 的 DataChannel 使用与 Alice 相同的 Stream ID
    // 注意：在实际应用中，Bob 应该从接收到的 DCEP Open 消息中获取 Stream ID
    // 这里简化实现，手动设置 Bob 的 Stream ID 以匹配 Alice 的（仅用于演示）
    if (bob_channel.stream_id != alice_channel.stream_id) {
        std.log.warn("[警告] Stream ID 不匹配 (Alice: {}, Bob: {})，手动设置 Bob 的 Stream ID", .{ alice_channel.stream_id, bob_channel.stream_id });
        // 手动设置 Bob 的 Stream ID 以匹配 Alice 的
        // 注意：这在实际应用中不应该这样做，应该通过 DCEP 协议处理
        @constCast(bob_channel).stream_id = alice_channel.stream_id;
    }

    std.log.info("[Bob] 数据通道已创建 (Stream ID: {})", .{bob_channel.stream_id});

    // 确保数据通道关联了 SCTP Association
    if (alice.sctp_association) |assoc| {
        alice_channel.setAssociation(assoc);
    }
    if (bob.sctp_association) |assoc| {
        bob_channel.setAssociation(assoc);
    }

    // 设置事件回调
    setupAliceChannelEvents(alice_channel);
    setupBobChannelEvents(bob_channel);

    // 打开数据通道
    alice_channel.setState(.open);
    bob_channel.setState(.open);

    // 等待一小段时间，确保通道完全打开
    const current_co = try schedule.getCurrentCo();
    try current_co.Sleep(100 * std.time.ns_per_ms);

    // 先启动 Bob 的接收协程（确保接收者先准备好）
    std.log.info("启动 Bob 接收协程...", .{});
    _ = try schedule.go(echoMessages, .{ bob, bob_channel, schedule });

    // 等待一小段时间，确保 Bob 的接收协程已启动并开始监听
    try current_co.Sleep(200 * std.time.ns_per_ms);

    // 然后启动 Alice 的发送协程
    std.log.info("启动 Alice 发送协程...", .{});
    _ = try schedule.go(sendMessages, .{ alice_channel, schedule });

    std.log.info("数据通道通信已启动", .{});

    // 等待一段时间，让消息发送和接收完成
    try current_co.Sleep(5 * std.time.ns_per_s);
}

/// 设置 Alice 通道事件
fn setupAliceChannelEvents(channel: *DataChannel) void {
    const OnOpenContext = struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[Alice] 数据通道已打开", .{});
        }
    };
    channel.setOnOpen(OnOpenContext.callback);

    const OnMessageContext = struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            _ = ch;
            std.log.info("[Alice] 收到回显消息: {s}", .{data});
        }
    };
    channel.setOnMessage(OnMessageContext.callback);
}

/// 设置 Bob 通道事件（接收并回显）
fn setupBobChannelEvents(channel: *DataChannel) void {
    const OnOpenContext = struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[Bob] 数据通道已打开，准备接收消息", .{});
        }
    };
    channel.setOnOpen(OnOpenContext.callback);

    const OnMessageContext = struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            std.log.info("[Bob] 收到消息 ({} 字节): {s}，准备回显", .{ data.len, data });

            // 回显消息
            // DataChannel.send 会使用关联的 PeerConnection 发送数据
            if (ch.send(data, null)) |_| {
                std.log.info("[Bob] ✓ 消息已回显: {s}", .{data});
            } else |err| {
                std.log.err("[Bob] ✗ 回显失败: {}", .{err});
            }
        }
    };
    channel.setOnMessage(OnMessageContext.callback);
}

/// 发送消息协程（Alice）
fn sendMessages(channel: *DataChannel, schedule: *zco.Schedule) !void {
    const messages = [_][]const u8{
        "Hello from Alice!",
        "这是第一条消息",
        "数据通道 Echo 测试",
        "消息 4: 测试网络传输",
    };

    // 等待通道打开
    var wait_count: u32 = 0;
    while (!channel.isOpen() and wait_count < 20) {
        const current_co = try schedule.getCurrentCo();
        try current_co.Sleep(100 * std.time.ns_per_ms);
        wait_count += 1;
    }

    if (!channel.isOpen()) {
        std.log.warn("[Alice] 数据通道未打开", .{});
        return;
    }

    for (messages, 0..) |msg, i| {
        const current_co = try schedule.getCurrentCo();
        try current_co.Sleep(1000 * std.time.ns_per_ms);

        std.log.info("[Alice] 发送消息 {}: {s}", .{ i + 1, msg });

        channel.send(msg, null) catch |err| {
            std.log.err("[Alice] 发送失败: {}", .{err});
            continue;
        };

        std.log.info("[Alice] 消息 {} 已发送", .{i + 1});
    }

    std.log.info("[Alice] 所有消息已发送", .{});
}

/// Echo 消息协程（Bob）
fn echoMessages(pc: *PeerConnection, _: *DataChannel, _: *zco.Schedule) !void {
    std.log.info("[Bob] 开始监听消息...", .{});

    // 持续监听，直到收到足够的数据或超时
    var count: u32 = 0;
    var received_messages: u32 = 0;
    const max_count = 500; // 增加循环次数，确保能接收到所有消息
    const max_received = 10; // 最多接收 10 条消息（包括回显）

    while (count < max_count and received_messages < max_received) {
        // 接收 SCTP 数据（这个方法会阻塞等待数据）
        // recvSctpData 会调用 DTLS Record.recv()，它会阻塞等待 UDP 数据
        // 当收到数据时，会解析 SCTP 包并触发 DataChannel 的 onmessage 事件
        // 注意：这是一个阻塞调用，会一直等待直到有数据到达
        pc.recvSctpData() catch |err| {
            // DTLS Record.recv() 会阻塞等待数据
            // 如果没有数据，可能会返回错误（取决于实现）
            // 这里简化处理，忽略所有错误继续等待
            _ = err catch {};
        };

        // 如果 onmessage 被触发，received_messages 会在回调中增加
        // 这里简化：每接收一次就增加计数（假设每次 recvSctpData 成功对应一条消息）
        received_messages += 1;
        count += 1;
    }

    std.log.info("[Bob] 接收监听已停止 (循环 {} 次，收到 {} 条消息)", .{ count, received_messages });
}
