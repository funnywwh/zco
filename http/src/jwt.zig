const std = @import("std");
const crypto = std.crypto;
const base64 = std.base64;

/// JWT错误类型
pub const JWTError = error{
    InvalidToken,
    InvalidSignature,
    ExpiredToken,
    InvalidFormat,
    InvalidAlgorithm,
    EncodeError,
};

/// JWT算法类型
pub const Algorithm = enum {
    HS256,
    HS512,
};

/// JWT Claims结构
pub const Claims = struct {
    iss: ?[]const u8 = null, // Issuer
    sub: ?[]const u8 = null, // Subject
    aud: ?[]const u8 = null, // Audience
    exp: ?i64 = null, // Expiration time
    nbf: ?i64 = null, // Not before
    iat: ?i64 = null, // Issued at
    jti: ?[]const u8 = null, // JWT ID
    
    /// 自定义claims
    custom: std.StringHashMap([]const u8),
    
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Claims {
        return .{
            .custom = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Claims) void {
        // 释放自定义claims
        var iter = self.custom.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.custom.deinit();
    }
};

/// JWT实现
pub const JWT = struct {
    const Self = @This();

    algorithm: Algorithm,
    secret: []const u8,

    /// 创建新的JWT实例
    pub fn init(algorithm: Algorithm, secret: []const u8) Self {
        return .{
            .algorithm = algorithm,
            .secret = secret,
        };
    }

    /// 生成JWT Token
    pub fn sign(self: Self, claims: *Claims, allocator: std.mem.Allocator) ![]u8 {
        // 编码Header
        var header_json = std.ArrayList(u8).init(allocator);
        defer header_json.deinit();

        const alg_str = switch (self.algorithm) {
            .HS256 => "HS256",
            .HS512 => "HS512",
        };

        try header_json.writer().print("{{\"alg\":\"{s}\",\"typ\":\"JWT\"}}", .{alg_str});
        const header_b64 = try self.base64UrlEncode(header_json.items, allocator);

        // 编码Payload
        var payload_json = std.ArrayList(u8).init(allocator);
        defer payload_json.deinit();

        try payload_json.writeAll("{");

        var first = true;

        // 标准claims
        if (claims.iss) |iss| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"iss\":\"{s}\"", .{iss});
            first = false;
        }
        if (claims.sub) |sub| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"sub\":\"{s}\"", .{sub});
            first = false;
        }
        if (claims.aud) |aud| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"aud\":\"{s}\"", .{aud});
            first = false;
        }
        if (claims.exp) |exp| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"exp\":{}", .{exp});
            first = false;
        }
        if (claims.nbf) |nbf| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"nbf\":{}", .{nbf});
            first = false;
        }
        if (claims.iat) |iat| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"iat\":{}", .{iat});
            first = false;
        }
        if (claims.jti) |jti| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"jti\":\"{s}\"", .{jti});
            first = false;
        }

        // 自定义claims
        var iter = claims.custom.iterator();
        while (iter.next()) |entry| {
            if (!first) try payload_json.writeAll(",");
            try payload_json.writer().print("\"{s}\":\"{s}\"", .{ entry.key_ptr.*, entry.value_ptr.* });
            first = false;
        }

        try payload_json.writeAll("}");

        const payload_b64 = try self.base64UrlEncode(payload_json.items, allocator);

        // 构建签名字符串
        const message = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64, payload_b64 });
        defer allocator.free(message);

        // 计算签名
        const signature = switch (self.algorithm) {
            .HS256 => try self.hmacSha256(message, allocator),
            .HS512 => try self.hmacSha512(message, allocator),
        };
        defer allocator.free(signature);

        const signature_b64 = try self.base64UrlEncode(signature, allocator);

        // 组合Token
        const token = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ header_b64, payload_b64, signature_b64 });

        allocator.free(header_b64);
        allocator.free(payload_b64);
        allocator.free(signature_b64);

        return token;
    }

    /// 验证并解析JWT Token
    pub fn verify(self: Self, token: []const u8, allocator: std.mem.Allocator) !Claims {
        var parts = std.mem.splitScalar(u8, token, '.');
        var part_count: usize = 0;
        var header_b64: ?[]const u8 = null;
        var payload_b64: ?[]const u8 = null;
        var signature_b64: ?[]const u8 = null;

        while (parts.next()) |part| {
            if (part_count == 0) {
                header_b64 = part;
            } else if (part_count == 1) {
                payload_b64 = part;
            } else if (part_count == 2) {
                signature_b64 = part;
            }
            part_count += 1;
        }

        if (part_count != 3) {
            return error.InvalidFormat;
        }

        const header_b64_val = header_b64.?;
        const payload_b64_val = payload_b64.?;
        const signature_b64_val = signature_b64.?;

        // 验证签名
        const message = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ header_b64_val, payload_b64_val });
        defer allocator.free(message);

        const expected_sig = switch (self.algorithm) {
            .HS256 => try self.hmacSha256(message, allocator),
            .HS512 => try self.hmacSha512(message, allocator),
        };
        defer allocator.free(expected_sig);

        const expected_sig_b64 = try self.base64UrlEncode(expected_sig, allocator);
        defer allocator.free(expected_sig_b64);

        if (!std.mem.eql(u8, signature_b64_val, expected_sig_b64)) {
            return error.InvalidSignature;
        }

        // 解码payload
        const payload = try self.base64UrlDecode(payload_b64_val, allocator);
        defer allocator.free(payload);

        // 解析claims
        var claims = Claims.init(allocator);
        errdefer claims.deinit();

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();

        if (parsed.value.object) |obj| {
            if (obj.get("iss")) |iss_val| {
                if (iss_val.string) |iss_str| {
                    claims.iss = try allocator.dupe(u8, iss_str);
                }
            }
            if (obj.get("sub")) |sub_val| {
                if (sub_val.string) |sub_str| {
                    claims.sub = try allocator.dupe(u8, sub_str);
                }
            }
            if (obj.get("aud")) |aud_val| {
                if (aud_val.string) |aud_str| {
                    claims.aud = try allocator.dupe(u8, aud_str);
                }
            }
            if (obj.get("exp")) |exp_val| {
                if (exp_val.integer) |exp_int| {
                    claims.exp = @as(i64, @intCast(exp_int));
                }
            }
            if (obj.get("nbf")) |nbf_val| {
                if (nbf_val.integer) |nbf_int| {
                    claims.nbf = @as(i64, @intCast(nbf_int));
                }
            }
            if (obj.get("iat")) |iat_val| {
                if (iat_val.integer) |iat_int| {
                    claims.iat = @as(i64, @intCast(iat_int));
                }
            }
            if (obj.get("jti")) |jti_val| {
                if (jti_val.string) |jti_str| {
                    claims.jti = try allocator.dupe(u8, jti_str);
                }
            }

            // 处理自定义claims
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "iss") or
                    std.mem.eql(u8, key, "sub") or
                    std.mem.eql(u8, key, "aud") or
                    std.mem.eql(u8, key, "exp") or
                    std.mem.eql(u8, key, "nbf") or
                    std.mem.eql(u8, key, "iat") or
                    std.mem.eql(u8, key, "jti")) continue;

                if (entry.value_ptr.string) |value_str| {
                    const key_dup = try allocator.dupe(u8, key);
                    const value_dup = try allocator.dupe(u8, value_str);
                    try claims.custom.put(key_dup, value_dup);
                }
            }
        }

        // 验证过期时间
        if (claims.exp) |exp| {
            const now = std.time.timestamp();
            if (now > exp) {
                return error.ExpiredToken;
            }
        }

        // 验证Not Before
        if (claims.nbf) |nbf| {
            const now = std.time.timestamp();
            if (now < nbf) {
                return error.ExpiredToken;
            }
        }

        return claims;
    }

    /// Base64URL编码
    fn base64UrlEncode(_: Self, data: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = _;
        _ = allocator;
        const standard = base64.standard;
        var encoded = std.ArrayList(u8).init(allocator);
        defer encoded.deinit();

        const encoded_len = standard.Encoder.calcSize(data.len);
        try encoded.ensureTotalCapacity(encoded_len);

        var enc = standard.Encoder.init(encoded.writer());
        _ = try enc.write(data);
        try enc.close();

        // 转换为URL安全格式
        for (encoded.items) |*c| {
            if (c.* == '+') {
                c.* = '-';
            } else if (c.* == '/') {
                c.* = '_';
            } else if (c.* == '=') {
                // 移除padding
            }
        }

        // 移除末尾的=字符
        while (encoded.items.len > 0 and encoded.items[encoded.items.len - 1] == '=') {
            _ = encoded.pop();
        }

        return encoded.toOwnedSlice();
    }

    /// Base64URL解码
    fn base64UrlDecode(_: Self, encoded: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = _;
        _ = allocator;
        var decoded = std.ArrayList(u8).init(allocator);
        defer decoded.deinit();

        // 转换URL安全格式为标准Base64
        var standard_encoded = std.ArrayList(u8).init(allocator);
        defer standard_encoded.deinit();

        for (encoded) |c| {
            if (c == '-') {
                try standard_encoded.append('+');
            } else if (c == '_') {
                try standard_encoded.append('/');
            } else {
                try standard_encoded.append(c);
            }
        }

        // 添加padding
        const padding_len = (4 - (standard_encoded.items.len % 4)) % 4;
        for (0..padding_len) |_| {
            try standard_encoded.append('=');
        }

        const decoded_len = base64.standard.Decoder.calcSizeForSlice(standard_encoded.items) catch return error.InvalidFormat;
        try decoded.ensureTotalCapacity(decoded_len);

        base64.standard.Decoder.decode(decoded.writer(), standard_encoded.items) catch return error.InvalidFormat;

        return decoded.toOwnedSlice();
    }

    /// HMAC-SHA256
    fn hmacSha256(self: Self, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = message;
        _ = allocator;
        var output: [crypto.auth.hmac.HmacSha256.mac_length]u8 = undefined;
        crypto.auth.hmac.HmacSha256.create(&output, message, self.secret);
        const result = try allocator.alloc(u8, output.len);
        @memcpy(result, &output);
        return result;
    }

    /// HMAC-SHA512
    fn hmacSha512(self: Self, message: []const u8, allocator: std.mem.Allocator) ![]u8 {
        _ = message;
        _ = allocator;
        var output: [crypto.auth.hmac.HmacSha512.mac_length]u8 = undefined;
        crypto.auth.hmac.HmacSha512.create(&output, message, self.secret);
        const result = try allocator.alloc(u8, output.len);
        @memcpy(result, &output);
        return result;
    }
};

