const std = @import("std");
const testing = std.testing;
const Crypto = @import("./crypto.zig").Crypto;

test "Crypto generateIV" {
    var session_salt: [14]u8 = undefined;
    @memset(&session_salt, 0x42);

    const ssrc: u32 = 0x12345678;
    const index: u48 = 0x0000000000FF;

    const iv = Crypto.generateIV(session_salt, ssrc, index);

    // IV 应该是 16 字节
    try testing.expect(iv.len == 16);

    // 前 14 字节应该是 Salt XOR (SSRC | index)
    // 验证 IV 不是全零
    var has_non_zero = false;
    for (iv) |b| {
        if (b != 0) {
            has_non_zero = true;
            break;
        }
    }
    try testing.expect(has_non_zero);
}

test "Crypto generateIV different inputs" {
    var salt1: [14]u8 = undefined;
    @memset(&salt1, 0x42);
    var salt2: [14]u8 = undefined;
    @memset(&salt2, 0x24);

    const ssrc: u32 = 0x12345678;
    const index: u48 = 0x0000000000FF;

    const iv1 = Crypto.generateIV(salt1, ssrc, index);
    const iv2 = Crypto.generateIV(salt2, ssrc, index);

    // 不同的 Salt 应该产生不同的 IV
    try testing.expect(!std.mem.eql(u8, &iv1, &iv2));
}

test "Crypto hmacSha1 basic" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const key = "test key";
    const data = "test data";

    const tag = try Crypto.hmacSha1(key, data, allocator);
    defer allocator.free(tag);

    // HMAC-SHA1 输出应该是 20 字节
    try testing.expect(tag.len == 20);
}

test "Crypto hmacSha1 consistency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const key = "test key";
    const data = "test data";

    const tag1 = try Crypto.hmacSha1(key, data, allocator);
    defer allocator.free(tag1);

    const tag2 = try Crypto.hmacSha1(key, data, allocator);
    defer allocator.free(tag2);

    // 相同输入应该产生相同输出
    try testing.expect(std.mem.eql(u8, tag1, tag2));
}

test "Crypto verifyHmacSha1 valid" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const key = "test key";
    const data = "test data";

    const tag = try Crypto.hmacSha1(key, data, allocator);
    defer allocator.free(tag);

    // 验证应该通过
    try testing.expect(Crypto.verifyHmacSha1(key, data, tag));
}

test "Crypto verifyHmacSha1 invalid" {
    const key = "test key";
    const data = "test data";
    const wrong_tag = "wrong tag data that is 20 bytes long";

    // 验证应该失败
    try testing.expect(!Crypto.verifyHmacSha1(key, data, wrong_tag[0..20]));
}

test "Crypto aes128Ctr encrypt and decrypt" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var key: [16]u8 = undefined;
    @memset(&key, 0x42);

    var iv: [16]u8 = undefined;
    @memset(&iv, 0x24);

    const plaintext = "Hello, SRTP!";

    // 加密
    const ciphertext = try Crypto.aes128Ctr(key, iv, plaintext, allocator);
    defer allocator.free(ciphertext);

    // CTR 模式：密文长度等于明文长度（无填充，无 tag）
    try testing.expect(ciphertext.len == plaintext.len);

    // 解密
    const decrypted = try Crypto.aes128CtrDecrypt(key, iv, ciphertext, allocator);
    defer allocator.free(decrypted);

    // 验证解密结果
    try testing.expect(std.mem.eql(u8, plaintext, decrypted));
}

test "Crypto aes128CtrDecrypt any length" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var key: [16]u8 = undefined;
    @memset(&key, 0x42);

    var iv: [16]u8 = undefined;
    @memset(&iv, 0x24);

    // CTR 模式可以处理任何长度的密文（包括短密文）
    const short_ciphertext = "short";
    const result = try Crypto.aes128CtrDecrypt(key, iv, short_ciphertext, allocator);
    defer allocator.free(result);

    // CTR 模式应该能解密任何长度的数据
    try testing.expect(result.len == short_ciphertext.len);
}
