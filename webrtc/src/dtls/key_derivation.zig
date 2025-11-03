const std = @import("std");
const crypto = std.crypto;

/// DTLS-SRTP 密钥派生
/// 遵循 RFC 5763 和 RFC 5705
pub const KeyDerivation = struct {
    const Self = @This();

    /// 密钥派生结果
    pub const SrtpKeys = struct {
        client_master_key: [16]u8,
        server_master_key: [16]u8,
        client_master_salt: [14]u8,
        server_master_salt: [14]u8,
    };

    /// 派生 SRTP 密钥（使用 TLS keying material exporter）
    /// 遵循 RFC 5763
    pub fn deriveSrtpKeys(
        master_secret: [48]u8,
        client_random: [32]u8,
        server_random: [32]u8,
        is_client: bool,
    ) !SrtpKeys {
        // RFC 5763 定义的标签
        const label_client_key = "EXTRACTOR-dtls_srtp";
        const label_server_key = "EXTRACTOR-dtls_srtp";
        const label_client_salt = "EXTRACTOR-dtls_srtp";
        const label_server_salt = "EXTRACTOR-dtls_srtp";

        var result: SrtpKeys = undefined;

        // 派生客户端主密钥（16 字节）
        const client_key = try Self.exportKeyingMaterial(
            master_secret,
            client_random,
            server_random,
            label_client_key,
            16,
        );
        defer std.heap.page_allocator.free(client_key);
        @memcpy(&result.client_master_key, client_key[0..16]);

        // 派生服务器主密钥（16 字节）
        const server_key = try Self.exportKeyingMaterial(
            master_secret,
            client_random,
            server_random,
            label_server_key,
            16,
        );
        defer std.heap.page_allocator.free(server_key);
        @memcpy(&result.server_master_key, server_key[0..16]);

        // 派生客户端 Salt（14 字节）
        const client_salt = try Self.exportKeyingMaterial(
            master_secret,
            client_random,
            server_random,
            label_client_salt,
            14,
        );
        defer std.heap.page_allocator.free(client_salt);
        @memcpy(&result.client_master_salt, client_salt[0..14]);

        // 派生服务器 Salt（14 字节）
        const server_salt = try Self.exportKeyingMaterial(
            master_secret,
            client_random,
            server_random,
            label_server_salt,
            14,
        );
        defer std.heap.page_allocator.free(server_salt);
        @memcpy(&result.server_master_salt, server_salt[0..14]);

        // 根据角色交换密钥
        if (!is_client) {
            // 服务器角色：交换 client 和 server 密钥
            var temp_key: [16]u8 = undefined;
            @memcpy(&temp_key, &result.client_master_key);
            @memcpy(&result.client_master_key, &result.server_master_key);
            @memcpy(&result.server_master_key, &temp_key);

            var temp_salt: [14]u8 = undefined;
            @memcpy(&temp_salt, &result.client_master_salt);
            @memcpy(&result.client_master_salt, &result.server_master_salt);
            @memcpy(&result.server_master_salt, &temp_salt);
        }

        return result;
    }

    /// TLS Keying Material Exporter (RFC 5705)
    /// 使用 PRF (Pseudo-Random Function) 导出密钥材料
    fn exportKeyingMaterial(
        master_secret: [48]u8,
        client_random: [32]u8,
        server_random: [32]u8,
        label: []const u8,
        length: usize,
    ) ![]u8 {
        // 构建种子：client_random + server_random
        var seed: [64]u8 = undefined;
        @memcpy(seed[0..32], &client_random);
        @memcpy(seed[32..64], &server_random);

        // 构建 PRF 输入：label + seed
        var prf_input = std.ArrayList(u8).init(std.heap.page_allocator);
        defer prf_input.deinit();

        try prf_input.appendSlice(label);
        try prf_input.appendSlice(&seed);

        // 使用 PRF (简化：使用 HMAC-SHA256)
        // 实际应该使用 TLS PRF (P_SHA256 for TLS 1.2)
        const result = try Self.prfSha256(master_secret, prf_input.items, length);
        return result;
    }

    /// PRF-SHA256（TLS 1.2 的 PRF）
    /// 简化实现：使用 HMAC-SHA256
    fn prfSha256(secret: [48]u8, seed: []const u8, length: usize) ![]u8 {
        var result = try std.heap.page_allocator.alloc(u8, length);
        errdefer std.heap.page_allocator.free(result);

        // TLS PRF: P_hash(secret, seed)
        // 简化：使用 HMAC-SHA256 迭代生成
        var output_offset: usize = 0;

        // 简化 PRF 实现：直接使用 HMAC-SHA256 迭代
        var a: [32]u8 = undefined;
        // A(0) = HMAC(secret, seed)
        const HmacSha256 = crypto.auth.hmac.sha2.HmacSha256;
        HmacSha256.create(&a, seed, &secret);

        while (output_offset < length) {
            // P_hash = HMAC(secret, A(i) + seed)
            var hmac_input = std.ArrayList(u8).init(std.heap.page_allocator);
            defer hmac_input.deinit();

            try hmac_input.appendSlice(&a);
            try hmac_input.appendSlice(seed);

            var output: [32]u8 = undefined;
            HmacSha256.create(&output, hmac_input.items, &secret);

            // 复制输出
            const copy_len = @min(length - output_offset, 32);
            @memcpy(result[output_offset..][0..copy_len], output[0..copy_len]);
            output_offset += copy_len;

            // 更新 A(i+1) = HMAC(secret, A(i))
            HmacSha256.create(&a, &a, &secret);
        }

        return result;
    }

    /// 计算 DTLS 指纹（用于 SDP）
    /// 使用 SHA-256 哈希证书
    pub fn computeFingerprint(certificate: []const u8) ![32]u8 {
        var fingerprint: [32]u8 = undefined;
        crypto.hash.sha2.Sha256.hash(certificate, &fingerprint, .{});
        return fingerprint;
    }

    /// 格式化指纹为十六进制字符串（用于 SDP）
    pub fn formatFingerprint(fingerprint: [32]u8, allocator: std.mem.Allocator) ![]u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        for (fingerprint, 0..) |byte, i| {
            if (i > 0) try buffer.append(':');
            try buffer.writer().print("{X:0>2}", .{byte});
        }

        return try buffer.toOwnedSlice();
    }

    pub const Error = error{
        OutOfMemory,
    };
};
