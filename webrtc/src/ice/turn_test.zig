const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const turn_mod = @import("./turn.zig");
const Turn = turn_mod.Turn;

test "TURN init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "test_user", "test_pass");
    defer turn.deinit();

    try testing.expect(turn.state == .idle);
    try testing.expect(turn.server_address.getPort() == 3478);
    try testing.expect(std.mem.eql(u8, turn.username, "test_user"));
    try testing.expect(std.mem.eql(u8, turn.password, "test_pass"));
}

test "TURN getState" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    try testing.expect(turn.getState() == .idle);
}

test "TURN getAllocation initially null" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    try testing.expect(turn.getAllocation() == null);
}

test "TURN State enum values" {
    try testing.expect(@intFromEnum(Turn.State.idle) == 0);
    try testing.expect(@intFromEnum(Turn.State.allocating) == 1);
    try testing.expect(@intFromEnum(Turn.State.allocated) == 2);
    try testing.expect(@intFromEnum(Turn.State.refreshing) == 3);
    try testing.expect(@intFromEnum(Turn.State.error_state) == 4);
}

test "TURN TurnMethod enum values" {
    try testing.expect(@intFromEnum(Turn.TurnMethod.allocate) == 0x003);
    try testing.expect(@intFromEnum(Turn.TurnMethod.refresh) == 0x004);
    try testing.expect(@intFromEnum(Turn.TurnMethod.send_indication) == 0x006);
    try testing.expect(@intFromEnum(Turn.TurnMethod.data_indication) == 0x007);
    try testing.expect(@intFromEnum(Turn.TurnMethod.create_permission) == 0x008);
    try testing.expect(@intFromEnum(Turn.TurnMethod.channel_bind) == 0x009);
}

test "TURN TurnAttributeType enum values" {
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.channel_number) == 0x000C);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.lifetime) == 0x000D);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.xor_peer_address) == 0x0012);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.data) == 0x0013);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.xor_relayed_address) == 0x0016);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.requested_transport) == 0x0019);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.even_port) == 0x0018);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.requested_address_family) == 0x0017);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.dont_fragment) == 0x001A);
    try testing.expect(@intFromEnum(Turn.TurnAttributeType.reservation_token) == 0x0022);
}

test "TURN Allocation init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const relay_addr = try std.net.Address.parseIp4("192.168.1.1", 5000);
    const relayed_addr = try std.net.Address.parseIp4("10.0.0.1", 6000);

    var allocation = Turn.Allocation{
        .relay_address = relay_addr,
        .relayed_address = relayed_addr,
        .lifetime = 3600,
        .reservation_token = null,
    };

    try testing.expect(allocation.relay_address.getPort() == 5000);
    try testing.expect(allocation.relayed_address.getPort() == 6000);
    try testing.expect(allocation.lifetime == 3600);
    try testing.expect(allocation.reservation_token == null);

    allocation.deinit(allocator);
}

test "TURN Allocation with reservation token" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const relay_addr = try std.net.Address.parseIp4("192.168.1.1", 5000);
    const relayed_addr = try std.net.Address.parseIp4("10.0.0.1", 6000);
    const token = try allocator.dupe(u8, "test_token_12345");

    var allocation = Turn.Allocation{
        .relay_address = relay_addr,
        .relayed_address = relayed_addr,
        .lifetime = 1800,
        .reservation_token = token,
    };

    try testing.expect(allocation.reservation_token != null);
    if (allocation.reservation_token) |t| {
        try testing.expect(std.mem.eql(u8, t, "test_token_12345"));
    }

    allocation.deinit(allocator);
}

test "TURN allocate invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    turn.state = .allocating; // 设置为非 idle/error_state 状态

    const result = turn.allocate();
    try testing.expectError(error.InvalidState, result);
}

test "TURN refresh invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    // 状态不是 allocated，应该失败
    const result = turn.refresh(3600);
    try testing.expectError(error.InvalidState, result);
}

test "TURN createPermission invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    const peer_addr = try std.net.Address.parseIp4("192.168.1.1", 5000);

    // 状态不是 allocated，应该失败
    const result = turn.createPermission(peer_addr);
    try testing.expectError(error.InvalidState, result);
}

test "TURN send invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    const peer_addr = try std.net.Address.parseIp4("192.168.1.1", 5000);
    const data = "test data";

    // 状态不是 allocated，应该失败
    const result = turn.send(data, peer_addr);
    try testing.expectError(error.InvalidState, result);
}

test "TURN recv invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    var buffer: [1024]u8 = undefined;

    // 状态不是 allocated，应该失败
    const result = turn.recv(&buffer);
    try testing.expectError(error.InvalidState, result);
}

test "TURN init with empty username and password" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "", "");
    defer turn.deinit();

    try testing.expect(std.mem.eql(u8, turn.username, ""));
    try testing.expect(std.mem.eql(u8, turn.password, ""));
}

test "TURN init with long username and password" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const long_username = "very_long_username_that_might_cause_issues_with_memory_allocation_and_could_potentially_overflow";
    const long_password = "very_long_password_that_might_cause_issues_with_memory_allocation_and_could_potentially_overflow_123456789";

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, long_username, long_password);
    defer turn.deinit();

    try testing.expect(std.mem.eql(u8, turn.username, long_username));
    try testing.expect(std.mem.eql(u8, turn.password, long_password));
}

test "TURN server address preservation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("192.168.1.100", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    // 验证服务器地址被正确保存
    var addr_buf: [64]u8 = undefined;
    var fmt_buf = std.io.fixedBufferStream(&addr_buf);
    try turn.server_address.format("", .{}, fmt_buf.writer());
    const addr_str = fmt_buf.getWritten();

    try testing.expect(std.mem.indexOf(u8, addr_str, "192.168.1.100") != null);
    try testing.expect(turn.server_address.getPort() == 3478);
}

test "TURN multiple allocations deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const relay_addr = try std.net.Address.parseIp4("192.168.1.1", 5000);
    const relayed_addr = try std.net.Address.parseIp4("10.0.0.1", 6000);

    var allocation1 = Turn.Allocation{
        .relay_address = relay_addr,
        .relayed_address = relayed_addr,
        .lifetime = 3600,
        .reservation_token = null,
    };

    var allocation2 = Turn.Allocation{
        .relay_address = relay_addr,
        .relayed_address = relayed_addr,
        .lifetime = 1800,
        .reservation_token = try allocator.dupe(u8, "token"),
    };

    allocation1.deinit(allocator);
    allocation2.deinit(allocator);
}

test "TURN state transitions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const server_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    const turn = try Turn.init(allocator, schedule, server_addr, "user", "pass");
    defer turn.deinit();

    // 初始状态应该是 idle
    try testing.expect(turn.getState() == .idle);

    // 手动设置状态（用于测试状态机）
    turn.state = .allocating;
    try testing.expect(turn.getState() == .allocating);

    turn.state = .allocated;
    try testing.expect(turn.getState() == .allocated);

    turn.state = .refreshing;
    try testing.expect(turn.getState() == .refreshing);

    turn.state = .error_state;
    try testing.expect(turn.getState() == .error_state);
}
