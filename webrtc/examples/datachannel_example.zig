const std = @import("std");
const zco = @import("zco");
const webrtc = @import("webrtc");

const peer = webrtc.peer;
const connection = peer.connection;
const PeerConnection = connection.PeerConnection;
const Configuration = connection.Configuration;
const DataChannel = webrtc.sctp.DataChannel;

/// 数据通道示例应用
/// 演示如何使用 WebRTC 数据通道进行双向消息传输
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("=== WebRTC 数据通道示例 ===", .{});

    // 创建调度器
    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建 PeerConnection
    const config = Configuration{};
    var pc = try PeerConnection.init(allocator, schedule, config);
    defer pc.deinit();

    std.log.info("PeerConnection 已创建", .{});

    // 模拟 DTLS 握手完成（在实际应用中，这应该通过真实的 DTLS 握手完成）
    if (pc.dtls_handshake) |handshake| {
        handshake.state = .handshake_complete;
        std.log.info("DTLS 握手状态已设置为完成（模拟）", .{});
    }

    // 创建数据通道（createDataChannel 会自动创建 SCTP Association，但需要 DTLS 握手完成）
    const channel = try pc.createDataChannel("test-channel", null);
    defer channel.deinit();

    std.log.info("数据通道 'test-channel' 已创建 (Stream ID: {}, 状态: {})", .{ channel.stream_id, channel.getState() });

    // 确保数据通道关联了 SCTP Association
    if (pc.sctp_association) |assoc| {
        channel.setAssociation(assoc);
        std.log.info("数据通道已关联 SCTP Association", .{});
    } else {
        std.log.warn("警告：SCTP Association 未创建", .{});
    }

    // 先设置数据通道事件回调（在设置状态之前，这样 onopen 事件才能触发）
    setupDataChannelEvents(channel);

    // 模拟数据通道打开（在实际应用中，这应该通过接收 DCEP ACK 完成）
    // 在真实场景中，当接收到对方的 DCEP ACK 时，状态会自动变为 open
    channel.setState(.open);
    std.log.info("数据通道状态已设置为 open（模拟），应该看到 onopen 事件", .{});

    // 在协程中发送消息
    _ = try schedule.go(sendMessages, .{ channel, schedule });

    // 在协程中接收消息（模拟接收流程）
    _ = try schedule.go(receiveMessages, .{ pc, schedule });

    std.log.info("开始发送和接收消息...", .{});
    std.log.info("（注意：这是一个演示，实际需要完整的连接建立）", .{});
    std.log.info("（当前演示：数据通道状态管理、事件系统、消息发送流程）", .{});

    // 运行调度器
    try schedule.loop();
}

/// 设置数据通道事件回调
fn setupDataChannelEvents(channel: *DataChannel) void {
    // onopen 回调
    const OnOpenContext = struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[DataChannel] 通道已打开", .{});
        }
    };
    channel.setOnOpen(OnOpenContext.callback);

    // onclose 回调
    const OnCloseContext = struct {
        fn callback(ch: *DataChannel) void {
            _ = ch;
            std.log.info("[DataChannel] 通道已关闭", .{});
        }
    };
    channel.setOnClose(OnCloseContext.callback);

    // onmessage 回调
    const OnMessageContext = struct {
        fn callback(ch: *DataChannel, data: []const u8) void {
            _ = ch;
            std.log.info("[DataChannel] 收到消息 ({} 字节): {s}", .{ data.len, data });
        }
    };
    channel.setOnMessage(OnMessageContext.callback);

    // onerror 回调
    const OnErrorContext = struct {
        fn callback(ch: *DataChannel, err: anyerror) void {
            _ = ch;
            std.log.err("[DataChannel] 错误: {}", .{err});
        }
    };
    channel.setOnError(OnErrorContext.callback);
}

/// 发送消息协程
fn sendMessages(channel: *DataChannel, schedule: *zco.Schedule) !void {
    const messages = [_][]const u8{
        "Hello, WebRTC!",
        "这是第一条消息",
        "数据通道双向通信测试",
        "消息 4: 测试消息传输",
    };

    // 等待数据通道打开
    var wait_count: u32 = 0;
    while (!channel.isOpen() and wait_count < 10) {
        const current_co = try schedule.getCurrentCo();
        try current_co.Sleep(100 * std.time.ns_per_ms);
        wait_count += 1;
    }

    if (!channel.isOpen()) {
        std.log.warn("[发送] 数据通道未打开，无法发送消息", .{});
        return;
    }

    for (messages, 0..) |msg, i| {
        // 休眠 1 秒
        const current_co = try schedule.getCurrentCo();
        try current_co.Sleep(1000 * std.time.ns_per_ms);

        std.log.info("[发送] 消息 {}: {s}", .{ i + 1, msg });

        // 发送消息（association 参数为 null，使用 DataChannel 关联的 association）
        channel.send(msg, null) catch |err| {
            std.log.warn("[发送] 失败: {} (这可能是正常的，因为缺少完整的网络连接)", .{err});
            // 即使发送失败，也继续演示其他消息
            continue;
        };

        std.log.info("[发送] 消息 {} 已成功发送", .{i + 1});
    }

    std.log.info("[发送] 所有消息已处理", .{});
}

/// 接收消息协程（模拟）
fn receiveMessages(pc: *PeerConnection, schedule: *zco.Schedule) !void {
    // 在实际应用中，这里应该持续监听 DTLS 接收
    // 并调用 pc.recvSctpData() 来处理接收到的数据

    std.log.info("[接收] 开始监听消息...", .{});
    std.log.info("[接收] （注意：在没有完整连接的情况下，接收会失败，这是正常的）", .{});

    var count: u32 = 0;
    while (count < 10) {
        // 休眠 500ms
        const current_co = try schedule.getCurrentCo();
        try current_co.Sleep(500 * std.time.ns_per_ms);

        // 尝试接收数据（在实际应用中，这应该在 DTLS 握手完成后调用）
        pc.recvSctpData() catch |err| {
            // 如果没有数据可接收，这是正常的
            if (err == error.NoDtlsRecord) {
                // 这是正常的，因为 DTLS Record 可能未初始化或没有数据
            } else if (err == error.NoUdpSocket) {
                // 这是正常的，因为缺少 UDP Socket（需要完整的 ICE 连接）
            } else {
                std.log.warn("[接收] 错误: {}", .{err});
            }
        };

        count += 1;
    }

    std.log.info("[接收] 接收监听已停止", .{});
}
