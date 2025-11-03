const std = @import("std");
const testing = std.testing;
const Context = @import("./context.zig").Context;

test "Context init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);

    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);

    const ssrc: u32 = 0x12345678;

    var ctx = try Context.init(allocator, master_key, master_salt, ssrc);
    defer ctx.deinit();

    // 验证 SSRC
    try testing.expect(ctx.ssrc == ssrc);

    // 验证 Master Key/Salt 已保存
    try testing.expect(std.mem.eql(u8, &ctx.master_key, &master_key));
    try testing.expect(std.mem.eql(u8, &ctx.master_salt, &master_salt));

    // 验证会话密钥已派生
    var zero_key: [16]u8 = undefined;
    @memset(&zero_key, 0);
    try testing.expect(!std.mem.eql(u8, &ctx.session_key, &zero_key));
}

test "Context computeIndex" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);

    var ctx = try Context.init(allocator, master_key, master_salt, 0x12345678);
    defer ctx.deinit();

    ctx.rollover_counter = 1;
    ctx.sequence_number = 0x1234;

    const index = ctx.computeIndex();

    // 索引 = (1 << 16) | 0x1234 = 0x11234
    try testing.expect(index == 0x11234);
}

test "Context updateSequence" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);

    var ctx = try Context.init(allocator, master_key, master_salt, 0x12345678);
    defer ctx.deinit();

    // 更新序列号
    ctx.updateSequence(100);
    try testing.expect(ctx.sequence_number == 100);
    try testing.expect(ctx.rollover_counter == 0);

    // 序列号回绕
    ctx.updateSequence(65535);
    ctx.updateSequence(0);
    try testing.expect(ctx.rollover_counter > 0);
}

test "Context generateIV" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var master_key: [16]u8 = undefined;
    @memset(&master_key, 0x42);
    var master_salt: [14]u8 = undefined;
    @memset(&master_salt, 0x24);

    var ctx = try Context.init(allocator, master_key, master_salt, 0x12345678);
    defer ctx.deinit();

    ctx.rollover_counter = 1;
    ctx.sequence_number = 0x1234;

    const iv = ctx.generateIV();

    // IV 应该是 16 字节
    try testing.expect(iv.len == 16);

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

test "Context different keys produce different session keys" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var key1: [16]u8 = undefined;
    @memset(&key1, 0x42);
    var key2: [16]u8 = undefined;
    @memset(&key2, 0x24);

    var salt1: [14]u8 = undefined;
    @memset(&salt1, 0x11);
    var salt2: [14]u8 = undefined;
    @memset(&salt2, 0x22);

    var ctx1 = try Context.init(allocator, key1, salt1, 0x12345678);
    defer ctx1.deinit();

    var ctx2 = try Context.init(allocator, key2, salt2, 0x12345678);
    defer ctx2.deinit();

    // 不同的 Master Key 应该产生不同的会话密钥
    try testing.expect(!std.mem.eql(u8, &ctx1.session_key, &ctx2.session_key));
}
