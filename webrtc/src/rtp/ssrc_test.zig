const std = @import("std");
const testing = std.testing;
const ssrc = @import("./ssrc.zig");

test "SsrcManager init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = ssrc.SsrcManager.init(allocator);
    defer manager.deinit();

    // 管理器应该为空
    try testing.expect(manager.ssrcs.count() == 0);
}

test "SsrcManager generateSsrc" {
    const ssrc1 = ssrc.generateSsrc();
    const ssrc2 = ssrc.generateSsrc();

    // SSRC 应该是非零的有效值
    try testing.expect(ssrc.isValidSsrc(ssrc1));
    try testing.expect(ssrc.isValidSsrc(ssrc2));

    // 生成的 SSRC 应该不同（虽然理论上可能相同，但概率极低）
    // 这里我们至少验证它们都是有效的
}

test "SsrcManager add and contains" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = ssrc.SsrcManager.init(allocator);
    defer manager.deinit();

    const test_ssrc: u32 = 0x12345678;

    // 初始不应该包含
    try testing.expect(!manager.containsSsrc(test_ssrc));

    // 添加后应该包含
    try manager.addSsrc(test_ssrc);
    try testing.expect(manager.containsSsrc(test_ssrc));
}

test "SsrcManager remove" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = ssrc.SsrcManager.init(allocator);
    defer manager.deinit();

    const test_ssrc: u32 = 0x87654321;

    // 添加 SSRC
    try manager.addSsrc(test_ssrc);
    try testing.expect(manager.containsSsrc(test_ssrc));

    // 移除 SSRC
    const removed = manager.removeSsrc(test_ssrc);
    try testing.expect(removed);
    try testing.expect(!manager.containsSsrc(test_ssrc));

    // 移除不存在的 SSRC
    const not_removed = manager.removeSsrc(0x11111111);
    try testing.expect(!not_removed);
}

test "SsrcManager generateAndAddSsrc" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = ssrc.SsrcManager.init(allocator);
    defer manager.deinit();

    // 生成并添加多个 SSRC
    const ssrc1 = try manager.generateAndAddSsrc();
    const ssrc2 = try manager.generateAndAddSsrc();
    const ssrc3 = try manager.generateAndAddSsrc();

    // 所有 SSRC 应该都是有效的
    try testing.expect(ssrc.isValidSsrc(ssrc1));
    try testing.expect(ssrc.isValidSsrc(ssrc2));
    try testing.expect(ssrc.isValidSsrc(ssrc3));

    // 所有 SSRC 应该在管理器中
    try testing.expect(manager.containsSsrc(ssrc1));
    try testing.expect(manager.containsSsrc(ssrc2));
    try testing.expect(manager.containsSsrc(ssrc3));

    // SSRC 应该不同
    try testing.expect(ssrc1 != ssrc2);
    try testing.expect(ssrc2 != ssrc3);
    try testing.expect(ssrc1 != ssrc3);
}

test "SsrcManager getAllSsrcs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var manager = ssrc.SsrcManager.init(allocator);
    defer manager.deinit();

    // 添加一些 SSRC
    const ssrc1: u32 = 0x11111111;
    const ssrc2: u32 = 0x22222222;
    const ssrc3: u32 = 0x33333333;

    try manager.addSsrc(ssrc1);
    try manager.addSsrc(ssrc2);
    try manager.addSsrc(ssrc3);

    // 获取所有 SSRC
    const all_ssrcs = try manager.getAllSsrcs(allocator);
    defer allocator.free(all_ssrcs);

    // 应该包含 3 个 SSRC
    try testing.expect(all_ssrcs.len == 3);

    // 验证包含所有添加的 SSRC（顺序可能不同）
    var found1 = false;
    var found2 = false;
    var found3 = false;
    for (all_ssrcs) |s| {
        if (s == ssrc1) found1 = true;
        if (s == ssrc2) found2 = true;
        if (s == ssrc3) found3 = true;
    }
    try testing.expect(found1);
    try testing.expect(found2);
    try testing.expect(found3);
}

test "isValidSsrc" {
    // 0 不是有效的 SSRC
    try testing.expect(!ssrc.isValidSsrc(0));

    // 非零值是有效的
    try testing.expect(ssrc.isValidSsrc(1));
    try testing.expect(ssrc.isValidSsrc(0xFFFFFFFF));
    try testing.expect(ssrc.isValidSsrc(0x12345678));
}
