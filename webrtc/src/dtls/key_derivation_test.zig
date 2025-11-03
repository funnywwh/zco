const std = @import("std");
const testing = std.testing;
const KeyDerivation = @import("./key_derivation.zig").KeyDerivation;

test "KeyDerivation deriveSrtpKeys client" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var master_secret: [48]u8 = undefined;
    @memset(&master_secret, 0x01);

    var client_random: [32]u8 = undefined;
    @memset(&client_random, 0x02);

    var server_random: [32]u8 = undefined;
    @memset(&server_random, 0x03);

    const keys = try KeyDerivation.deriveSrtpKeys(
        master_secret,
        client_random,
        server_random,
        true, // is_client
    );

    // 检查密钥长度
    try testing.expect(keys.client_master_key.len == 16);
    try testing.expect(keys.server_master_key.len == 16);
    try testing.expect(keys.client_master_salt.len == 14);
    try testing.expect(keys.server_master_salt.len == 14);

    // 检查密钥不为全零
    var all_zero: [16]u8 = undefined;
    @memset(&all_zero, 0);
    try testing.expect(!std.mem.eql(u8, &keys.client_master_key, &all_zero));
    try testing.expect(!std.mem.eql(u8, &keys.server_master_key, &all_zero));
}

test "KeyDerivation deriveSrtpKeys server" {
    var master_secret: [48]u8 = undefined;
    @memset(&master_secret, 0x01);

    var client_random: [32]u8 = undefined;
    @memset(&client_random, 0x02);

    var server_random: [32]u8 = undefined;
    @memset(&server_random, 0x03);

    const keys = try KeyDerivation.deriveSrtpKeys(
        master_secret,
        client_random,
        server_random,
        false, // is_server
    );

    // 检查密钥长度
    try testing.expect(keys.client_master_key.len == 16);
    try testing.expect(keys.server_master_key.len == 16);
    try testing.expect(keys.client_master_salt.len == 14);
    try testing.expect(keys.server_master_salt.len == 14);
}

test "KeyDerivation deriveSrtpKeys consistency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var master_secret: [48]u8 = undefined;
    @memset(&master_secret, 0x42);

    var client_random: [32]u8 = undefined;
    @memset(&client_random, 0xAA);

    var server_random: [32]u8 = undefined;
    @memset(&server_random, 0xBB);

    const keys1 = try KeyDerivation.deriveSrtpKeys(
        master_secret,
        client_random,
        server_random,
        true,
    );

    const keys2 = try KeyDerivation.deriveSrtpKeys(
        master_secret,
        client_random,
        server_random,
        true,
    );

    // 相同输入应该产生相同输出
    try testing.expect(std.mem.eql(u8, &keys1.client_master_key, &keys2.client_master_key));
    try testing.expect(std.mem.eql(u8, &keys1.server_master_key, &keys2.server_master_key));
    try testing.expect(std.mem.eql(u8, &keys1.client_master_salt, &keys2.client_master_salt));
    try testing.expect(std.mem.eql(u8, &keys1.server_master_salt, &keys2.server_master_salt));
}

test "KeyDerivation computeFingerprint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const certificate = "test certificate data";
    const fingerprint = try KeyDerivation.computeFingerprint(certificate);

    // SHA-256 应该产生 32 字节的指纹
    try testing.expect(fingerprint.len == 32);

    // 相同输入应该产生相同指纹
    const fingerprint2 = try KeyDerivation.computeFingerprint(certificate);
    try testing.expect(std.mem.eql(u8, &fingerprint, &fingerprint2));
}

test "KeyDerivation formatFingerprint" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fingerprint: [32]u8 = undefined;
    @memset(&fingerprint, 0xAB);

    const formatted = try KeyDerivation.formatFingerprint(fingerprint, allocator);
    defer allocator.free(formatted);

    // 格式化后的字符串应该包含冒号分隔的十六进制数
    try testing.expect(std.mem.indexOf(u8, formatted, ":") != null);

    // 应该包含 32 个字节，每个用 2 个十六进制字符表示，用冒号分隔
    // 格式：XX:XX:XX:...:XX (63 个字符：32*2 + 31 个冒号)
    try testing.expect(formatted.len >= 32 * 2);
}

test "KeyDerivation formatFingerprint empty" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var fingerprint: [32]u8 = undefined;
    @memset(&fingerprint, 0);

    const formatted = try KeyDerivation.formatFingerprint(fingerprint, allocator);
    defer allocator.free(formatted);

    // 应该正确格式化全零指纹
    try testing.expect(formatted.len >= 32 * 2);
}

test "KeyDerivation deriveSrtpKeys different inputs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var master_secret1: [48]u8 = undefined;
    @memset(&master_secret1, 0x01);

    var master_secret2: [48]u8 = undefined;
    @memset(&master_secret2, 0x02);

    var random: [32]u8 = undefined;
    @memset(&random, 0xAA);

    const keys1 = try KeyDerivation.deriveSrtpKeys(
        master_secret1,
        random,
        random,
        true,
    );

    const keys2 = try KeyDerivation.deriveSrtpKeys(
        master_secret2,
        random,
        random,
        true,
    );

    // 不同的 master_secret 应该产生不同的密钥
    try testing.expect(!std.mem.eql(u8, &keys1.client_master_key, &keys2.client_master_key));
}

test "KeyDerivation deriveSrtpKeys client server swap" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var master_secret: [48]u8 = undefined;
    @memset(&master_secret, 0x42);

    var client_random: [32]u8 = undefined;
    @memset(&client_random, 0xAA);

    var server_random: [32]u8 = undefined;
    @memset(&server_random, 0xBB);

    const client_keys = try KeyDerivation.deriveSrtpKeys(
        master_secret,
        client_random,
        server_random,
        true, // is_client
    );

    const server_keys = try KeyDerivation.deriveSrtpKeys(
        master_secret,
        client_random,
        server_random,
        false, // is_server
    );

    // 客户端和服务器应该交换密钥
    try testing.expect(std.mem.eql(u8, &client_keys.client_master_key, &server_keys.server_master_key));
    try testing.expect(std.mem.eql(u8, &client_keys.server_master_key, &server_keys.client_master_key));
    try testing.expect(std.mem.eql(u8, &client_keys.client_master_salt, &server_keys.server_master_salt));
    try testing.expect(std.mem.eql(u8, &client_keys.server_master_salt, &server_keys.client_master_salt));
}
