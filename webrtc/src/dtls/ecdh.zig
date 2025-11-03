const std = @import("std");
const crypto = std.crypto;

/// P-256 曲线（secp256r1）
const P256 = crypto.ecc.P256;

/// ECDHE (Elliptic Curve Diffie-Hellman Ephemeral) 密钥交换
/// 支持 P-256 曲线（secp256r1）
pub const Ecdh = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    /// P-256 曲线点（公钥或私钥）
    pub const Point = struct {
        x: []u8, // X 坐标（32 字节）
        y: []u8, // Y 坐标（32 字节）

        pub fn deinit(self: *Point, allocator: std.mem.Allocator) void {
            allocator.free(self.x);
            allocator.free(self.y);
        }
    };

    /// 私钥（32 字节标量）
    pub const PrivateKey = struct {
        scalar_bytes: [32]u8, // 小端序标量字节

        pub fn generate(_: std.mem.Allocator) !PrivateKey {
            // 使用 P-256 生成随机标量
            const scalar_bytes = P256.scalar.random(.little);
            return PrivateKey{ .scalar_bytes = scalar_bytes };
        }

        /// 从字节数组创建私钥
        pub fn fromBytes(data: []const u8) !PrivateKey {
            if (data.len != 32) return error.InvalidPrivateKeySize;
            var scalar_bytes: [32]u8 = undefined;
            @memcpy(&scalar_bytes, data);
            return PrivateKey{ .scalar_bytes = scalar_bytes };
        }
    };

    /// 公钥（64 字节未压缩点：X || Y）
    pub const PublicKey = struct {
        point: Point,

        pub fn deinit(self: *PublicKey, allocator: std.mem.Allocator) void {
            self.point.deinit(allocator);
        }

        /// 从字节数组创建公钥（X || Y，共 64 字节）
        pub fn fromBytes(allocator: std.mem.Allocator, data: []const u8) !PublicKey {
            if (data.len != 64) return error.InvalidPublicKeySize;
            
            const x = try allocator.dupe(u8, data[0..32]);
            errdefer allocator.free(x);
            const y = try allocator.dupe(u8, data[32..64]);
            errdefer allocator.free(y);

            return PublicKey{
                .point = .{
                    .x = x,
                    .y = y,
                },
            };
        }

        /// 导出为字节数组（X || Y，共 64 字节）
        pub fn toBytes(self: PublicKey, allocator: std.mem.Allocator) ![]u8 {
            const bytes = try allocator.alloc(u8, 64);
            @memcpy(bytes[0..32], self.point.x);
            @memcpy(bytes[32..64], self.point.y);
            return bytes;
        }
    };

    /// 共享密钥（32 字节）
    pub const SharedSecret = struct {
        secret: [32]u8,
    };

    /// 生成密钥对（使用 P-256）
    pub fn generateKeyPair(allocator: std.mem.Allocator) !struct { private: PrivateKey, public: PublicKey } {
        // 生成私钥（随机标量）
        const private = try PrivateKey.generate(allocator);

        // 计算公钥：公钥 = 基点 * 私钥
        const scalar = try P256.scalar.Scalar.fromBytes(private.scalar_bytes, .little);
        const public_point = try P256.basePoint.mul(scalar.toBytes(.little), .little);
        
        // 转换为仿射坐标并序列化
        const affine = public_point.affineCoordinates();
        const x_bytes = affine.x.toBytes(.big);
        const y_bytes = affine.y.toBytes(.big);

        // 构建 64 字节公钥（X || Y）
        var public_key_bytes: [64]u8 = undefined;
        @memcpy(public_key_bytes[0..32], &x_bytes);
        @memcpy(public_key_bytes[32..64], &y_bytes);

        const public = try PublicKey.fromBytes(allocator, &public_key_bytes);

        return .{
            .private = private,
            .public = public,
        };
    }

    /// 计算共享密钥
    /// 使用自己的私钥和对方的公钥
    /// 共享密钥 = 对方的公钥点 * 自己的私钥标量
    pub fn computeSharedSecret(
        allocator: std.mem.Allocator,
        private_key: PrivateKey,
        public_key: PublicKey,
    ) !SharedSecret {
        _ = allocator;
        
        // 从公钥字节恢复 P-256 点
        const public_point = try P256.fromSerializedAffineCoordinates(
            public_key.point.x[0..32].*,
            public_key.point.y[0..32].*,
            .big,
        );
        
        // 验证公钥不是单位元
        try public_point.rejectIdentity();
        
        // 计算共享密钥点：shared_point = public_key * private_key
        const scalar = try P256.scalar.Scalar.fromBytes(private_key.scalar_bytes, .little);
        const shared_point = try public_point.mul(scalar.toBytes(.little), .little);
        
        // 验证共享密钥点不是单位元
        try shared_point.rejectIdentity();
        
        // 提取共享密钥：使用共享点的 X 坐标（32 字节）
        const shared_affine = shared_point.affineCoordinates();
        const shared_secret_bytes = shared_affine.x.toBytes(.big);
        
        return SharedSecret{ .secret = shared_secret_bytes };
    }

    /// 验证公钥有效性
    pub fn validatePublicKey(public_key: PublicKey) !void {
        // 检查坐标长度
        if (public_key.point.x.len != 32 or public_key.point.y.len != 32) {
            return error.InvalidPublicKey;
        }
        
        // 验证点在 P-256 曲线上
        const point = P256.fromSerializedAffineCoordinates(
            public_key.point.x[0..32].*,
            public_key.point.y[0..32].*,
            .big,
        ) catch return error.InvalidPublicKey;
        
        // 验证不是单位元
        point.rejectIdentity() catch return error.IdentityElement;
    }

    pub const Error = error{
        InvalidPublicKeySize,
        InvalidPublicKey,
        InvalidPrivateKeySize,
        OutOfMemory,
        IdentityElement,
        InvalidEncoding,
    };
};

