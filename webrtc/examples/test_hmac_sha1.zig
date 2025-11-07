const std = @import("std");
const zco = @import("zco");
const Stun = zco.Stun;

// 测试 HMAC-SHA1 实现
// 使用 RFC 2202 的测试向量
test "HMAC-SHA1 RFC 2202 Test Case 1" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 1: key = 0x0b (20 times), data = "Hi There"
    const key = "\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b\x0b";
    const data = "Hi There";
    const expected_hex = "b617318655057264e28bc0b6fb378c8ef146be00";

    const mac = try Stun.computeHmacSha1(allocator, key, data);
    defer allocator.free(mac);

    // 转换为十六进制字符串进行比较
    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 1:\n", .{});
    std.debug.print("  Key: {s}\n", .{std.fmt.fmtSliceHexLower(key)});
    std.debug.print("  Data: {s}\n", .{data});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}

test "HMAC-SHA1 RFC 2202 Test Case 2" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 2: key = "Jefe", data = "what do ya want for nothing?"
    const key = "Jefe";
    const data = "what do ya want for nothing?";
    const expected_hex = "effcdf6ae5eb2fa2d27416d5f184df9c259a7c79";

    const mac = try Stun.computeHmacSha1(allocator, key, data);
    defer allocator.free(mac);

    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 2:\n", .{});
    std.debug.print("  Key: {s}\n", .{key});
    std.debug.print("  Data: {s}\n", .{data});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}

test "HMAC-SHA1 RFC 2202 Test Case 3" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 3: key = 0xaa (20 times), data = 0xdd (50 times)
    var key: [20]u8 = undefined;
    @memset(&key, 0xaa);
    var data: [50]u8 = undefined;
    @memset(&data, 0xdd);
    const expected_hex = "125d7342b9ac11cd91a39af48aa17b4f63f175d3";

    const mac = try Stun.computeHmacSha1(allocator, &key, &data);
    defer allocator.free(mac);

    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 3:\n", .{});
    std.debug.print("  Key: {s}\n", .{std.fmt.fmtSliceHexLower(&key)});
    std.debug.print("  Data: {s} (50 bytes of 0xdd)\n", .{std.fmt.fmtSliceHexLower(data[0..10])});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}

test "HMAC-SHA1 RFC 2202 Test Case 4" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 4: key = 0x0102030405060708090a0b0c0d0e0f10111213141516171819, data = 0xcd (50 times)
    const key = "\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19";
    var data: [50]u8 = undefined;
    @memset(&data, 0xcd);
    const expected_hex = "4c9007f4026250c6bc8414f9bf50c86c2d7235da";

    const mac = try stun.Stun.computeHmacSha1(allocator, key, &data);
    defer allocator.free(mac);

    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 4:\n", .{});
    std.debug.print("  Key: {s}\n", .{std.fmt.fmtSliceHexLower(key)});
    std.debug.print("  Data: {s} (50 bytes of 0xcd)\n", .{std.fmt.fmtSliceHexLower(data[0..10])});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}

test "HMAC-SHA1 RFC 2202 Test Case 5" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 5: key = 0x0c (20 times), data = "Test With Truncation"
    const key = "\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c\x0c";
    const data = "Test With Truncation";
    const expected_hex = "4c1a03424b55e07fe7f27be1d58bb9324a9a5a04";

    const mac = try Stun.computeHmacSha1(allocator, key, data);
    defer allocator.free(mac);

    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 5:\n", .{});
    std.debug.print("  Key: {s}\n", .{std.fmt.fmtSliceHexLower(key)});
    std.debug.print("  Data: {s}\n", .{data});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}

test "HMAC-SHA1 RFC 2202 Test Case 6" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 6: key = 0xaa (80 times), data = "Test Using Larger Than Block-Size Key - Hash Key First"
    var key: [80]u8 = undefined;
    @memset(&key, 0xaa);
    const data = "Test Using Larger Than Block-Size Key - Hash Key First";
    const expected_hex = "aa4ae5e15272d00e95705637ce8a3b55ed402112";

    const mac = try stun.Stun.computeHmacSha1(allocator, &key, data);
    defer allocator.free(mac);

    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 6:\n", .{});
    std.debug.print("  Key: {s}... (80 bytes of 0xaa)\n", .{std.fmt.fmtSliceHexLower(key[0..10])});
    std.debug.print("  Data: {s}\n", .{data});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}

test "HMAC-SHA1 RFC 2202 Test Case 7" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test Case 7: key = 0xaa (80 times), data = "Test Using Larger Than Block-Size Key and Larger Than One Block-Size Data"
    var key: [80]u8 = undefined;
    @memset(&key, 0xaa);
    const data = "Test Using Larger Than Block-Size Key and Larger Than One Block-Size Data";
    const expected_hex = "e8e99d0f45237d786d6bbaa7965c7808bbff1a91";

    const mac = try stun.Stun.computeHmacSha1(allocator, &key, data);
    defer allocator.free(mac);

    var hex_buf: [40]u8 = undefined;
    for (mac, 0..) |byte, i| {
        _ = std.fmt.bufPrint(hex_buf[i * 2 .. i * 2 + 2], "{x:0>2}", .{byte}) catch unreachable;
    }
    const hex_result = hex_buf[0..40];

    std.debug.print("Test Case 7:\n", .{});
    std.debug.print("  Key: {s}... (80 bytes of 0xaa)\n", .{std.fmt.fmtSliceHexLower(key[0..10])});
    std.debug.print("  Data: {s}\n", .{data});
    std.debug.print("  Expected: {s}\n", .{expected_hex});
    std.debug.print("  Got:      {s}\n", .{hex_result});

    try std.testing.expect(std.mem.eql(u8, hex_result, expected_hex));
}
