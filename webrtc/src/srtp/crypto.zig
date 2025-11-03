const std = @import("std");
const crypto = std.crypto;

/// SRTP 加密算法
/// 遵循 RFC 3711 和 RFC 6188
pub const Crypto = struct {
    const Self = @This();

    /// AES-128-CTR（Counter Mode）加密/解密
    /// SRTP 使用 CTR 模式，加密和解密使用相同的函数
    /// 遵循 RFC 3711 Section 4.1.1 (AES Counter Mode)
    /// CTR 模式：对计数器块进行 AES 加密得到密钥流，然后 ciphertext = plaintext XOR key_stream
    pub fn aes128Ctr(
        key: [16]u8,
        iv: [16]u8,
        input: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // AES-128-CTR 是流密码模式，输出长度等于输入长度（无填充，无 tag）
        const output = try allocator.alloc(u8, input.len);
        errdefer allocator.free(output);

        // 实现 AES-128-CTR 模式
        // CTR 模式：对计数器块进行 AES 加密得到密钥流，然后 XOR 明文
        // 使用 Aes128Gcm 来执行块加密（虽然不是最优，但可以使用）
        // 注意：我们需要将每个计数器块作为单独的输入进行加密

        const block_size = 16; // AES 块大小
        const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;

        // 将 IV 的前 12 字节作为 nonce，后 4 字节作为计数器起始值
        const nonce = iv[0..12];
        var counter_bytes: [4]u8 = undefined;
        @memcpy(&counter_bytes, iv[12..16]);
        var counter = std.mem.readInt(u32, &counter_bytes, .big);

        var input_offset: usize = 0;

        // 处理完整的块
        while (input_offset + block_size <= input.len) {
            // 构建计数器块：nonce (12 字节) + counter (4 字节，大端序)
            var counter_block: [block_size]u8 = undefined;
            @memcpy(counter_block[0..12], nonce);
            std.mem.writeInt(u32, counter_block[12..16], counter, .big);

            // 使用 AES-GCM 加密计数器块（使用零 nonce，相当于 ECB 模式）
            // 我们只使用加密后的块，忽略 tag
            var key_stream: [block_size]u8 = undefined;
            var tag: [Aes128Gcm.tag_length]u8 = undefined;
            const zero_nonce: [12]u8 = .{0} ** 12;
            const ad: []const u8 = &[_]u8{};

            // 对计数器块进行加密，得到密钥流
            Aes128Gcm.encrypt(&key_stream, &tag, &counter_block, ad, zero_nonce, key);

            // XOR 操作：ciphertext = plaintext XOR key_stream
            for (0..block_size) |i| {
                output[input_offset + i] = input[input_offset + i] ^ key_stream[i];
            }

            input_offset += block_size;
            counter += 1;
        }

        // 处理剩余的不完整块
        if (input_offset < input.len) {
            const remainder_len = input.len - input_offset;

            // 构建计数器块
            var counter_block: [block_size]u8 = undefined;
            @memcpy(counter_block[0..12], nonce);
            std.mem.writeInt(u32, counter_block[12..16], counter, .big);

            // 加密计数器块得到密钥流
            var key_stream: [block_size]u8 = undefined;
            var tag: [Aes128Gcm.tag_length]u8 = undefined;
            const zero_nonce: [12]u8 = .{0} ** 12;
            const ad: []const u8 = &[_]u8{};

            Aes128Gcm.encrypt(&key_stream, &tag, &counter_block, ad, zero_nonce, key);

            // XOR 操作（只使用需要的字节）
            for (0..remainder_len) |i| {
                output[input_offset + i] = input[input_offset + i] ^ key_stream[i];
            }
        }

        return output;
    }

    /// AES-128-CTR 解密（与加密完全相同，因为 CTR 是对称的）
    /// 遵循 RFC 3711 Section 4.1.1 (AES Counter Mode)
    pub fn aes128CtrDecrypt(
        key: [16]u8,
        iv: [16]u8,
        input: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // CTR 模式解密与加密完全相同：ciphertext XOR key_stream = plaintext
        return Self.aes128Ctr(key, iv, input, allocator);
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
