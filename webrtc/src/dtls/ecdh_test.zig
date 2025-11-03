const std = @import("std");
const testing = std.testing;
const Ecdh = @import("./ecdh.zig").Ecdh;

test "ECDH generateKeyPair" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const keypair = try Ecdh.generateKeyPair(allocator);
    defer keypair.public.deinit(allocator);

    // 验证私钥长度
    try testing.expect(keypair.private.scalar_bytes.len == 32);

    // 验证公钥坐标长度
    try testing.expect(keypair.public.point.x.len == 32);
    try testing.expect(keypair.public.point.y.len == 32);
}

test "ECDH computeSharedSecret" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 生成两个密钥对（模拟 Alice 和 Bob）
    const alice = try Ecdh.generateKeyPair(allocator);
    defer alice.public.deinit(allocator);

    const bob = try Ecdh.generateKeyPair(allocator);
    defer bob.public.deinit(allocator);

    // Alice 计算共享密钥：使用自己的私钥和 Bob 的公钥
    const shared_alice = try Ecdh.computeSharedSecret(allocator, alice.private, bob.public);

    // Bob 计算共享密钥：使用自己的私钥和 Alice 的公钥
    const shared_bob = try Ecdh.computeSharedSecret(allocator, bob.private, alice.public);

    // 验证共享密钥相同
    try testing.expect(std.mem.eql(u8, &shared_alice.secret, &shared_bob.secret));
}

test "ECDH PublicKey fromBytes and toBytes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 生成密钥对
    const keypair = try Ecdh.generateKeyPair(allocator);
    defer keypair.public.deinit(allocator);

    // 导出公钥字节
    const public_bytes = try keypair.public.toBytes(allocator);
    defer allocator.free(public_bytes);

    // 验证长度
    try testing.expect(public_bytes.len == 64);

    // 从字节恢复公钥
    const restored_public = try Ecdh.PublicKey.fromBytes(allocator, public_bytes);
    defer restored_public.deinit(allocator);

    // 验证坐标相同
    try testing.expect(std.mem.eql(u8, restored_public.point.x, keypair.public.point.x));
    try testing.expect(std.mem.eql(u8, restored_public.point.y, keypair.public.point.y));
}

test "ECDH PrivateKey fromBytes" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 生成密钥对
    const keypair = try Ecdh.generateKeyPair(allocator);
    defer keypair.public.deinit(allocator);

    // 从字节恢复私钥
    const restored_private = try Ecdh.PrivateKey.fromBytes(&keypair.private.scalar_bytes);

    // 验证私钥相同
    try testing.expect(std.mem.eql(u8, &restored_private.scalar_bytes, &keypair.private.scalar_bytes));
}

test "ECDH PrivateKey fromBytes invalid size" {
    const invalid_data = &[_]u8{0} ** 16; // 长度不对
    const result = Ecdh.PrivateKey.fromBytes(invalid_data);
    try testing.expectError(error.InvalidPrivateKeySize, result);
}

test "ECDH validatePublicKey" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 生成密钥对
    const keypair = try Ecdh.generateKeyPair(allocator);
    defer keypair.public.deinit(allocator);

    // 验证公钥有效性
    try testing.expect(Ecdh.validatePublicKey(keypair.public));
}

test "ECDH multiple key pairs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 生成多个密钥对，验证它们不同
    const keypair1 = try Ecdh.generateKeyPair(allocator);
    defer keypair1.public.deinit(allocator);

    const keypair2 = try Ecdh.generateKeyPair(allocator);
    defer keypair2.public.deinit(allocator);

    // 私钥应该不同
    try testing.expect(!std.mem.eql(u8, &keypair1.private.scalar_bytes, &keypair2.private.scalar_bytes));

    // 公钥应该不同（大概率）
    const pub1_bytes = try keypair1.public.toBytes(allocator);
    defer allocator.free(pub1_bytes);
    const pub2_bytes = try keypair2.public.toBytes(allocator);
    defer allocator.free(pub2_bytes);

    try testing.expect(!std.mem.eql(u8, pub1_bytes, pub2_bytes));
}

test "ECDH shared secret consistency" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 生成两个密钥对（模拟 Alice 和 Bob）
    const alice = try Ecdh.generateKeyPair(allocator);
    defer alice.public.deinit(allocator);

    const bob = try Ecdh.generateKeyPair(allocator);
    defer bob.public.deinit(allocator);

    // 计算共享密钥
    const shared1 = try Ecdh.computeSharedSecret(allocator, alice.private, bob.public);
    const shared2 = try Ecdh.computeSharedSecret(allocator, bob.private, alice.public);

    // 验证共享密钥相同
    try testing.expect(std.mem.eql(u8, &shared1.secret, &shared2.secret));
}

