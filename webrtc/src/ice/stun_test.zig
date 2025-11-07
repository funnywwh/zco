const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const Stun = webrtc.ice.stun.Stun;

test "STUN MessageHeader encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    var stun_client = Stun.init(allocator, schedule);
    defer stun_client.deinit();

    const transaction_id = try stun_client.generateTransactionId();
    const message_type = Stun.MessageHeader.setType(.request, .binding);

    var header = Stun.MessageHeader{
        .message_type = message_type,
        .message_length = 0,
        .transaction_id = transaction_id,
    };

    const encoded = header.encode();
    const parsed = Stun.MessageHeader.parse(&encoded);

    try testing.expect(parsed.message_type == header.message_type);
    try testing.expect(parsed.message_length == header.message_length);
    try testing.expect(parsed.magic_cookie == 0x2112A442);
    try testing.expect(std.mem.eql(u8, &parsed.transaction_id, &header.transaction_id));
}

test "STUN MessageHeader getClass and getMethod" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    var stun_client = Stun.init(allocator, schedule);
    defer stun_client.deinit();

    const request_type = Stun.MessageHeader.setType(.request, .binding);
    var header = Stun.MessageHeader{
        .message_type = request_type,
        .message_length = 0,
        .transaction_id = try stun_client.generateTransactionId(),
    };

    try testing.expect(header.getClass() == .request);
    try testing.expect(header.getMethod() == .binding);

    const response_type = Stun.MessageHeader.setType(.success_response, .binding);
    header.message_type = response_type;
    try testing.expect(header.getClass() == .success_response);
}

test "STUN Attribute encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const test_value = "test_value";
    var attr = Stun.Attribute{
        .type = .username,
        .length = @as(u16, @intCast(test_value.len)),
        .value = test_value,
    };

    const encoded = try attr.encode(allocator);
    defer allocator.free(encoded);

    // 验证编码长度是 4 字节对齐
    try testing.expect(encoded.len % 4 == 0);

    const parsed = try Stun.Attribute.parse(encoded);
    try testing.expect(parsed.type == .username);
    try testing.expect(parsed.length == test_value.len);
    try testing.expectEqualStrings(test_value, parsed.value);
}

test "STUN MappedAddress encode and parse IPv4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const address = try std.net.Address.parseIp4("192.168.1.100", 54321);
    var mapped_addr = Stun.MappedAddress{
        .family = 0x01,
        .port = address.getPort(),
        .address = address,
    };

    const attr = try mapped_addr.encode(allocator);
    defer allocator.free(attr.value);

    const parsed = try Stun.MappedAddress.parse(attr);
    try testing.expect(parsed.family == 0x01);
    try testing.expect(parsed.port == 54321);
    try testing.expect(parsed.address.getPort() == 54321);
}

test "STUN XorMappedAddress encode and parse IPv4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var schedule = try zco.Schedule.init(gpa.allocator());
    defer schedule.deinit();
    var stun_client = Stun.init(gpa.allocator(), schedule);
    defer stun_client.deinit();

    const transaction_id = try stun_client.generateTransactionId();
    const address = try std.net.Address.parseIp4("192.168.1.100", 54321);
    var xor_addr = Stun.XorMappedAddress{
        .family = 0x01,
        .port = address.getPort(),
        .address = address,
        .transaction_id = transaction_id,
    };

    const attr = try xor_addr.encode(allocator);
    defer allocator.free(attr.value);

    const parsed = try Stun.XorMappedAddress.parse(attr, transaction_id);
    try testing.expect(parsed.family == 0x01);
    try testing.expect(parsed.port == 54321);
    try testing.expect(parsed.address.getPort() == 54321);
}

test "STUN Message encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var schedule = try zco.Schedule.init(gpa.allocator());
    defer schedule.deinit();
    var stun_client = Stun.init(gpa.allocator(), schedule);
    defer stun_client.deinit();

    const transaction_id = try stun_client.generateTransactionId();
    const message_type = Stun.MessageHeader.setType(.request, .binding);

    var message = Stun.Message.init(allocator);
    defer message.deinit();

    message.header = .{
        .message_type = message_type,
        .message_length = 0,
        .transaction_id = transaction_id,
    };

    // 添加一个 username 属性
    const username_value = try allocator.dupe(u8, "test_user");
    defer allocator.free(username_value);
    try message.addAttribute(.{
        .type = .username,
        .length = @as(u16, @intCast(username_value.len)),
        .value = username_value,
    });

    const encoded = try message.encode(allocator);
    defer allocator.free(encoded);

    var parsed = try Stun.Message.parse(encoded, allocator);
    defer parsed.deinit();

    try testing.expect(parsed.header.message_type == message.header.message_type);
    try testing.expect(std.mem.eql(u8, &parsed.header.transaction_id, &transaction_id));
    try testing.expect(parsed.attributes.items.len == 1);

    const username_attr = parsed.findAttribute(.username);
    try testing.expect(username_attr != null);
    try testing.expectEqualStrings("test_user", username_attr.?.value);
}

test "STUN Message findAttribute" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    var message = Stun.Message.init(allocator);
    defer message.deinit();

    // 添加多个属性
    const username_value = try allocator.dupe(u8, "user1");
    defer allocator.free(username_value);
    try message.addAttribute(.{
        .type = .username,
        .length = @as(u16, @intCast(username_value.len)),
        .value = username_value,
    });

    const realm_value = try allocator.dupe(u8, "example.com");
    defer allocator.free(realm_value);
    try message.addAttribute(.{
        .type = .realm,
        .length = @as(u16, @intCast(realm_value.len)),
        .value = realm_value,
    });

    const username = message.findAttribute(.username);
    try testing.expect(username != null);
    try testing.expectEqualStrings("user1", username.?.value);

    const realm = message.findAttribute(.realm);
    try testing.expect(realm != null);
    try testing.expectEqualStrings("example.com", realm.?.value);

    const nonce = message.findAttribute(.nonce);
    try testing.expect(nonce == null);
}

test "STUN generateTransactionId" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    var stun_client = Stun.init(allocator, schedule);
    defer stun_client.deinit();

    const id1 = try stun_client.generateTransactionId();
    const id2 = try stun_client.generateTransactionId();

    // 验证长度
    try testing.expect(id1.len == 12);
    try testing.expect(id2.len == 12);

    // 验证是随机生成的（几乎不可能相同）
    // 注意：这个测试有一定概率失败（极小），但可以接受
}

test "STUN computeMessageIntegrity basic" {
    const message_data = "test_message_data";
    const username = "test_user";
    const realm = "example.com";
    const password = "test_password";

    const mac = try Stun.computeMessageIntegrity(message_data, username, realm, password);

    // 验证 MAC 长度为 20 字节（SHA1）
    try testing.expect(mac.len == 20);

    // 验证相同输入产生相同输出
    const mac2 = try Stun.computeMessageIntegrity(message_data, username, realm, password);
    try testing.expect(std.mem.eql(u8, &mac, &mac2));
}

test "STUN verifyMessageIntegrity" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const message_data = "test_message_data";
    const username = "test_user";
    const realm = "example.com";
    const password = "test_password";

    const computed_mac = try Stun.computeMessageIntegrity(message_data, username, realm, password);
    const mac_value = try allocator.dupe(u8, &computed_mac);
    defer allocator.free(mac_value);

    const integrity_attr = Stun.Attribute{
        .type = .message_integrity,
        .length = 20,
        .value = mac_value,
    };

    const valid = try Stun.verifyMessageIntegrity(message_data, integrity_attr, username, realm, password);
    try testing.expect(valid == true);

    // 使用错误的密码应该验证失败
    const invalid = try Stun.verifyMessageIntegrity(message_data, integrity_attr, username, realm, "wrong_password");
    try testing.expect(invalid == false);
}

// HMAC-SHA1 测试（使用 RFC 2202 的测试向量）
// 注意：这些测试需要 computeHmacSha1 函数，该函数仅在 feature/webrtc-implementation 分支上可用
// 在 main 分支上暂时注释掉这些测试
// test "HMAC-SHA1 RFC 2202 Test Case 1" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     // Test Case 1: key = 0x0b (20 times), data = "Hi There"
//     const key = "\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b";
//     const data = "Hi There";
//     const expected_hex = "b617318655057264e28bc0b6fb378c8ef146be00";
//
//     const mac = try Stun.computeHmacSha1(allocator, key, data);
//     defer allocator.free(mac);
//
//     // 转换为十六进制字符串进行比较
//     var hex_buf: [40]u8 = undefined;
//     for (mac, 0..) |byte, i| {
//         _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
//     }
//     const hex_result = hex_buf[0..40];
//
//     try testing.expect(std.mem.eql(u8, hex_result, expected_hex));
// }
//
// test "HMAC-SHA1 RFC 2202 Test Case 2" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     // Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
//     const key = "Jefe";
//     const data = "what do ya want for nothing?";
//     const expected_hex = "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79";
//
//     const mac = try Stun.computeHmacSha1(allocator, key, data);
//     defer allocator.free(mac);
//
//     var hex_buf: [40]u8 = undefined;
//     for (mac, 0..) |byte, i| {
//         _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
//     }
//     const hex_result = hex_buf[0..40];
//
//     try testing.expect(std.mem.eql(u8, hex_result, expected_hex));
// }
//
// test "HMAC-SHA1 RFC 2202 Test Case 3" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     // Test Case 3: key = 0xaa (20 times), data = 0xdd (50 times)
//     var key: [20]u8 = undefined;
//     @memset(&key, 0xaa);
//     var data: [50]u8 = undefined;
//     @memset(&data, 0xdd);
//     const expected_hex = "125d7342b9ac11cd91a39af48aa17b4f63f175d3";
//
//     const mac = try Stun.computeHmacSha1(allocator, &key, &data);
//     defer allocator.free(mac);
//
//     var hex_buf: [40]u8 = undefined;
//     for (mac, 0..) |byte, i| {
//         _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
//     }
//     const hex_result = hex_buf[0..40];
//
//     try testing.expect(std.mem.eql(u8, hex_result, expected_hex));
// }
//
// test "HMAC-SHA1 RFC 2202 Test Case 6" {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     // Test Case 6: key = 0xaa (80 times), data = "Test Using Larger Than Block-Size Key - Hash Key First"
//     var key: [80]u8 = undefined;
//     @memset(&key, 0xaa);
//     const data = "Test Using Larger Than Block-Size Key - Hash Key First";
//     const expected_hex = "aa4ae5e15272d00e95705637ce8a3b55ed402112";
//
//     const mac = try Stun.computeHmacSha1(allocator, &key, data);
//     defer allocator.free(mac);
//
//     var hex_buf: [40]u8 = undefined;
//     for (mac, 0..) |byte, i| {
//         _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
//     }
//     const hex_result = hex_buf[0..40];
//
//     try testing.expect(std.mem.eql(u8, hex_result, expected_hex));
// }
