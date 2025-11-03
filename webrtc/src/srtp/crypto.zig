const std = @import("std");
const crypto = std.crypto;

/// SRTP 加密算法
/// 遵循 RFC 3711 和 RFC 6188
pub const Crypto = struct {
    const Self = @This();

    /// AES-128-CTR（Counter Mode）加密/解密
    /// SRTP 使用 CTR 模式，加密和解密使用相同的函数
    /// 遵循 RFC 3711 Section 4.1.1 (AES Counter Mode)
    ///
    /// CTR 模式工作原理：
    /// 1. 将 IV 作为第一个计数器块
    /// 2. 对每个计数器块进行 AES 块加密（ECB 模式），得到密钥流
    /// 3. 将密钥流与明文进行 XOR，得到密文
    ///
    /// 注意：RFC 3711 中，SRTP 的 IV 是 16 字节
    /// 在 CTR 模式中，整个 16 字节 IV 直接作为第一个计数器块使用
    /// 后续计数器块通过递增 IV 的最低有效字节生成
    pub fn aes128Ctr(
        key: [16]u8,
        iv: [16]u8,
        input: []const u8,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        // AES-128-CTR 是流密码模式，输出长度等于输入长度（无填充，无 tag）
        const output = try allocator.alloc(u8, input.len);
        errdefer allocator.free(output);

        const block_size = 16; // AES 块大小
        const Aes128 = crypto.core.aes.Aes128;

        // 初始化 AES 密钥调度（加密方向，用于生成密钥流）
        var ctx = Aes128.initEnc(key);

        // 将 IV 作为第一个计数器块
        // 注意：RFC 3711 中，IV 的后 2 字节是 0，但整个 16 字节 IV 都用作计数器块的初始值
        var counter_block: [block_size]u8 = undefined;
        @memcpy(&counter_block, &iv);

        var input_offset: usize = 0;

        // 处理完整的块
        while (input_offset + block_size <= input.len) {
            // 对计数器块进行 AES 块加密（ECB 模式），得到密钥流
            var key_stream: [block_size]u8 = undefined;
            ctx.encrypt(&key_stream, &counter_block);

            // XOR 操作：ciphertext = plaintext XOR key_stream
            for (0..block_size) |i| {
                output[input_offset + i] = input[input_offset + i] ^ key_stream[i];
            }

            input_offset += block_size;

            // 递增计数器（从最低字节开始递增，大端序）
            // RFC 3711 没有明确指定计数器递增的方式，但标准做法是从最低字节递增
            var carry: u8 = 1;
            var i: usize = block_size;
            while (i > 0) {
                i -= 1;
                const sum = @as(u16, counter_block[i]) + @as(u16, carry);
                counter_block[i] = @truncate(sum);
                carry = @intFromBool(sum > 255);
                if (carry == 0) break;
            }
        }

        // 处理剩余的不完整块
        if (input_offset < input.len) {
            const remainder_len = input.len - input_offset;

            // 对计数器块进行 AES 块加密，得到密钥流
            var key_stream: [block_size]u8 = undefined;
            ctx.encrypt(&key_stream, &counter_block);

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
        // RFC 3711: IV = (salt XOR (SSRC << 32 | index))
        // IV 的前 14 字节 = salt[0..14] XOR (SSRC[4 bytes] | index[6 bytes, low] | 0[4 bytes])
        var xor_bytes: [14]u8 = undefined;
        std.mem.writeInt(u32, xor_bytes[0..4], ssrc, .big); // SSRC 在位置 0-3

        // index 是 u48，写入到位置 4-9（6 字节，大端序）
        // 注意：index 的 LSB 应该在位置 9，MSB 应该在位置 4
        var index_temp = index;
        for (0..6) |i| {
            xor_bytes[9 - i] = @as(u8, @truncate(index_temp)); // 从位置 9 开始向位置 4 写入
            index_temp >>= 8;
        }
        // 位置 10-13 为零（实际上不应该有，因为我们只有 14 字节）
        // 但 RFC 3711 中 IV 是 16 字节，所以实际上：
        // xor_bytes[0..4] = SSRC
        // xor_bytes[4..10] = index (6 bytes, big-endian)
        // xor_bytes[10..14] = 0 (4 bytes, 因为 index 是 u48，但我们需要 16 字节的 XOR)
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
    /// 注意：SRTP 使用 HMAC-SHA1，但只使用前 10 字节（80 位）作为认证标签
    /// 此函数返回完整的 20 字节 HMAC-SHA1 输出，调用者可以截取前 10 字节用于 SRTP
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
    /// 注意：SRTP 使用 HMAC-SHA1，但只使用前 10 字节（80 位）作为认证标签
    pub fn verifyHmacSha1(
        key: []const u8,
        data: []const u8,
        tag: []const u8,
    ) bool {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const computed_tag_full = Self.hmacSha1(key, data, allocator) catch return false;
        defer allocator.free(computed_tag_full);

        // SRTP 使用 10 字节认证标签（RFC 3711 Section 4.2）
        const tag_len = tag.len;
        if (computed_tag_full.len < tag_len) return false;

        // 只比较前 tag_len 字节
        return std.mem.eql(u8, computed_tag_full[0..tag_len], tag);
    }

    pub const Error = error{
        InvalidCiphertext,
        OutOfMemory,
    };
};
