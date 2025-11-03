const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
const Handshake = @import("./handshake.zig").Handshake;
const Record = @import("./record.zig").Record;

test "Handshake init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    var record = try Record.init(allocator, schedule);
    defer record.deinit();

    const handshake = try Handshake.init(allocator, record);
    defer handshake.deinit();

    try testing.expect(handshake.state == .initial);
    try testing.expect(handshake.flight == 0);
}

test "HandshakeHeader encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const header = Handshake.HandshakeHeader{
        .msg_type = .client_hello,
        .length = 0x123456,
        .message_sequence = 1,
        .fragment_offset = 0,
        .fragment_length = 0x123456,
    };

    const encoded = header.encode();
    const parsed = try Handshake.HandshakeHeader.parse(&encoded);

    try testing.expect(parsed.msg_type == .client_hello);
    try testing.expect(parsed.length == 0x123456);
    try testing.expect(parsed.message_sequence == 1);
    try testing.expect(parsed.fragment_offset == 0);
    try testing.expect(parsed.fragment_length == 0x123456);
}

test "HandshakeHeader parse invalid header" {
    var buffer: [10]u8 = undefined; // 小于 12 字节
    const result = Handshake.HandshakeHeader.parse(&buffer);
    try testing.expectError(error.InvalidHandshakeHeader, result);
}

test "ClientHello encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client_random: [32]u8 = undefined;
    @memset(&client_random, 0xAA);

    const session_id = try allocator.dupe(u8, "test_session");
    defer allocator.free(session_id);

    const cookie = try allocator.dupe(u8, &[_]u8{ 0x01, 0x02 });
    defer allocator.free(cookie);

    const cipher_suites = &[_]u16{0xc02b};
    const compression_methods = &[_]u8{0};

    const client_hello = Handshake.ClientHello{
        .client_version = .dtls_1_2,
        .random = client_random,
        .session_id = session_id,
        .cookie = cookie,
        .cipher_suites = cipher_suites,
        .compression_methods = compression_methods,
    };

    const encoded = try client_hello.encode(allocator);
    defer allocator.free(encoded);

    var parsed = try Handshake.ClientHello.parse(encoded, allocator);
    defer parsed.deinit(allocator);

    try testing.expect(parsed.client_version == .dtls_1_2);
    try testing.expect(std.mem.eql(u8, &parsed.random, &client_random));
    try testing.expect(std.mem.eql(u8, parsed.session_id, session_id));
    try testing.expect(std.mem.eql(u8, parsed.cookie, cookie));
    try testing.expect(parsed.cipher_suites.len == 1);
    try testing.expect(parsed.cipher_suites[0] == 0xc02b);
    try testing.expect(parsed.compression_methods.len == 1);
    try testing.expect(parsed.compression_methods[0] == 0);
}

test "ClientHello parse invalid data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const invalid_data = &[_]u8{0}; // 数据太短
    const result = Handshake.ClientHello.parse(invalid_data, allocator);
    try testing.expectError(error.InvalidClientHello, result);
}

test "ServerHello encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server_random: [32]u8 = undefined;
    @memset(&server_random, 0xBB);

    const session_id = try allocator.dupe(u8, "server_session");
    defer allocator.free(session_id);

    const server_hello = Handshake.ServerHello{
        .server_version = .dtls_1_2,
        .random = server_random,
        .session_id = session_id,
        .cipher_suite = 0xc02b,
        .compression_method = 0,
    };

    const encoded = try server_hello.encode(allocator);
    defer allocator.free(encoded);

    var parsed = try Handshake.ServerHello.parse(encoded, allocator);
    defer parsed.deinit(allocator);

    try testing.expect(parsed.server_version == .dtls_1_2);
    try testing.expect(std.mem.eql(u8, &parsed.random, &server_random));
    try testing.expect(std.mem.eql(u8, parsed.session_id, session_id));
    try testing.expect(parsed.cipher_suite == 0xc02b);
    try testing.expect(parsed.compression_method == 0);
}

test "ServerHello parse invalid data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const invalid_data = &[_]u8{0}; // 数据太短
    const result = Handshake.ServerHello.parse(invalid_data, allocator);
    try testing.expectError(error.InvalidServerHello, result);
}

test "Handshake computeMasterSecret" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    var record = try Record.init(allocator, schedule);
    defer record.deinit();

    const handshake = try Handshake.init(allocator, record);
    defer handshake.deinit();

    // 设置客户端和服务器随机数
    @memset(&handshake.client_random, 0xAA);
    @memset(&handshake.server_random, 0xBB);

    try handshake.computeMasterSecret();

    // Master Secret 应该是 48 字节且不为全零
    var all_zero: [48]u8 = undefined;
    @memset(&all_zero, 0);
    try testing.expect(!std.mem.eql(u8, &handshake.master_secret, &all_zero));
}

test "Handshake sendClientHello invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    var record = try Record.init(allocator, schedule);
    defer record.deinit();

    const handshake = try Handshake.init(allocator, record);
    defer handshake.deinit();

    // 改变状态，使其不是 initial
    handshake.state = .client_hello_sent;

    const address = try std.net.Address.parseIp4("127.0.0.1", 12345);
    const result = handshake.sendClientHello(address);
    try testing.expectError(error.InvalidState, result);
}

test "HandshakeHeader message sequence" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const header = Handshake.HandshakeHeader{
        .msg_type = .finished,
        .length = 20,
        .message_sequence = 0xFFFF,
        .fragment_offset = 0,
        .fragment_length = 20,
    };

    const encoded = header.encode();
    const parsed = try Handshake.HandshakeHeader.parse(&encoded);

    try testing.expect(parsed.message_sequence == 0xFFFF);
}

test "HandshakeHeader fragment offset and length" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const header = Handshake.HandshakeHeader{
        .msg_type = .client_hello,
        .length = 0xFFFFFF,
        .message_sequence = 0,
        .fragment_offset = 0x100000,
        .fragment_length = 0x200000,
    };

    const encoded = header.encode();
    const parsed = try Handshake.HandshakeHeader.parse(&encoded);

    try testing.expect(parsed.fragment_offset == 0x100000);
    try testing.expect(parsed.fragment_length == 0x200000);
}

test "HandshakeHeader all message types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const message_types = [_]Handshake.HandshakeType{
        .hello_request,
        .client_hello,
        .server_hello,
        .hello_verify_request,
        .certificate,
        .server_key_exchange,
        .certificate_request,
        .server_hello_done,
        .certificate_verify,
        .client_key_exchange,
        .finished,
    };

    for (message_types) |msg_type| {
        const header = Handshake.HandshakeHeader{
            .msg_type = msg_type,
            .length = 0,
            .message_sequence = 0,
            .fragment_offset = 0,
            .fragment_length = 0,
        };

        const encoded = header.encode();
        const parsed = try Handshake.HandshakeHeader.parse(&encoded);

        try testing.expect(parsed.msg_type == msg_type);
    }
}
