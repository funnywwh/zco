const std = @import("std");
const crypto = std.crypto;

/// SRTP 加密算法
/// 遵循 RFC 3711 和 RFC 6188
pub const Crypto = struct {
    const Self = @This();

    /// AES-128-CTR（Counter Mode）加密/解密
    /// SRTP 使用 CTR 模式，加密和解密使用相同的函数
    pub fn aes128Ctr(
        key: [16]u8,
        iv: [16]u8,
        input: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // TODO: 实现 AES-128-CTR 模式
        // 当前简化实现：使用 AES-128-GCM（实际应使用 CTR 模式）
        //
        // SRTP 使用 AES-128-CTR，这是一个流密码模式
        // CTR 模式加密：ciphertext = plaintext XOR AES(IV + counter)
        //
        // 简化：暂时使用 AES-128-GCM（已实现），后续需要实现 CTR 模式

        const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;
        const output = try allocator.alloc(u8, input.len + Aes128Gcm.tag_length);
        errdefer allocator.free(output);

        const output_only = output[0..input.len];
        var tag: [Aes128Gcm.tag_length]u8 = undefined;
        const ad: []const u8 = &[_]u8{};

        Aes128Gcm.encrypt(output_only, &tag, input, ad, iv[0..12].*, key);
        @memcpy(output[input.len..], &tag);

        return output;
    }

    /// AES-128-CTR 解密（与加密相同）
    pub fn aes128CtrDecrypt(
        key: [16]u8,
        iv: [16]u8,
        input: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;

        if (input.len < Aes128Gcm.tag_length) return error.InvalidCiphertext;

        const tag: [Aes128Gcm.tag_length]u8 = input[input.len - Aes128Gcm.tag_length ..][0..Aes128Gcm.tag_length].*;
        const encrypted_data = input[0 .. input.len - Aes128Gcm.tag_length];

        const output = try allocator.alloc(u8, encrypted_data.len);
        errdefer allocator.free(output);

        const ad: []const u8 = &[_]u8{};

        try Aes128Gcm.decrypt(output, encrypted_data, tag, ad, iv[0..12].*, key);

        return output;
    }

    /// 生成 SRTP IV（Initialization Vector）
    /// 遵循 RFC 3711 Section 4.1.1
    /// IV = (salt[0..14] XOR (SSRC << 32 | index))
    pub fn generateIV(
        session_salt: [14]u8,
        ssrc: u32,
        index: u48,
    ) [16]u8 {
        var iv: [16]u8 = undefined;

        // IV 前 14 字节 = Salt XOR (SSRC | index 的低部分)
        // Salt 是 14 字节
        var salt_xor: [14]u8 = undefined;

        // 计算 XOR 值：SSRC (4 字节) + index (6 字节，u48 低 6 字节)
        var xor_bytes: [14]u8 = undefined;
        std.mem.writeInt(u32, xor_bytes[0..4], ssrc, .big);
        // index 是 u48，写入到接下来的 6 字节（大端序）
        // 将 u48 写入 6 字节大端序
        var index_temp = index;
        for (0..6) |i| {
            xor_bytes[9 - i] = @as(u8, @truncate(index_temp));
            index_temp >>= 8;
        }
        // 剩余 4 字节为零
        @memset(xor_bytes[10..14], 0);

        // XOR Salt
        for (&salt_xor, 0..) |*b, i| {
            b.* = session_salt[i] ^ xor_bytes[i];
        }

        @memcpy(iv[0..14], &salt_xor);
        // 最后 2 字节：对于 SRTP，通常是 0 或者用于其他目的
        // RFC 3711 规定 IV 的完整格式，这里简化
        @memset(iv[14..16], 0);

        return iv;
    }

    /// HMAC-SHA1 认证标签生成
    /// 遵循 RFC 3711 Section 4.2
    pub fn hmacSha1(
        key: []const u8,
        data: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // TODO: 使用真实的 HMAC-SHA1
        // 当前使用 HMAC-SHA256 作为占位符，取前 20 字节（SHA1 输出长度）
        const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
        var output_full: [HmacSha256.mac_length]u8 = undefined;
        HmacSha256.create(&output_full, data, key);

        const output = try allocator.alloc(u8, 20); // SHA1 输出长度是 20 字节
        @memcpy(output, output_full[0..20]);

        return output;
    }

    /// 验证 HMAC-SHA1 认证标签
    pub fn verifyHmacSha1(
        key: []const u8,
        data: []const u8,
        tag: []const u8,
    ) bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const computed_tag = Self.hmacSha1(key, data, allocator) catch return false;
        defer allocator.free(computed_tag);

        if (computed_tag.len != tag.len) return false;

        return std.mem.eql(u8, computed_tag, tag);
    }

    pub const Error = error{
        InvalidCiphertext,
        OutOfMemory,
    };
};
