const std = @import("std");
const testing = std.testing;
const Parser = @import("./parser.zig").Parser;
const HeaderBuffer = @import("./header_buffer.zig").HeaderBuffer;

test "解析简单GET请求（无Body）" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();

    const req = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";

    try hb.append(req);

    var events = std.ArrayList(Parser.Event).init(testing.allocator);
    defer events.deinit();

    // 使用整块作为本次 chunk
    _ = try parser.feed(hb.slice(), req, &events);

    var got_complete = false;
    var got_host = false;
    for (events.items) |ev| {
        switch (ev) {
            .on_header => |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "Host")) got_host = true;
            },
            .on_message_complete => got_complete = true,
            else => {},
        }
    }

    try testing.expect(got_host);
    try testing.expect(got_complete);
}

test "Content-Length Body 流式输出" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();

    const head = "POST /data HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n";
    const body1 = "he";
    const body2 = "llo";

    // 第一次：仅头部
    try hb.append(head);
    var ev1 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev1.deinit();
    const c1 = try parser.feed(hb.slice(), head, &ev1);
    try testing.expect(c1 > 0);

    // 第二次：Body 片段1
    var ev2 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev2.deinit();
    const c2 = try parser.feed(hb.slice(), body1, &ev2);
    try testing.expectEqual(@as(usize, body1.len), c2);

    // 第三次：Body 片段2
    var ev3 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev3.deinit();
    const c3 = try parser.feed(hb.slice(), body2, &ev3);
    try testing.expectEqual(@as(usize, body2.len), c3);

    // 汇总检查：应收到两个 body chunk，且完成
    var chunks: usize = 0;
    var complete = false;
    for (ev2.items) |ev| switch (ev) {
        .on_body_chunk => chunks += 1,
        else => {},
    };
    for (ev3.items) |ev| switch (ev) {
        .on_body_chunk => chunks += 1,
        .on_message_complete => complete = true,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), chunks);
    try testing.expect(complete);
}

test "CRLF 跨分片（头部被分两次读入）" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();

    const part1 = "GET / HTTP/1.1\r";
    const part2 = "\nHost: a\r\n\r\n";

    try hb.append(part1);
    var e1 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer e1.deinit();
    _ = try parser.feed(hb.slice(), part1, &e1);

    try hb.append(part2);
    var e2 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer e2.deinit();
    _ = try parser.feed(hb.slice(), part2, &e2);

    var ok = false;
    for (e2.items) |ev| switch (ev) {
        .on_message_complete => ok = true,
        else => {},
    };
    try testing.expect(ok);
}

test "HTTP 0.9 行为 (无头部)" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();
    const raw = "GET /\r\n";
    try hb.append(raw);
    var ev = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev.deinit();
    _ = parser.feed(hb.slice(), raw, &ev) catch {
        return;
    };
}

test "HTTP 1.0 有/无Host兼容" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();
    const raw = "GET /foo HTTP/1.0\r\n\r\n";
    try hb.append(raw);
    var ev = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev.deinit();
    _ = try parser.feed(hb.slice(), raw, &ev);
    try testing.expect(ev.items.len > 0);
}

test "超长头部行(>256)报错" {
    var parser = Parser.init(.request);
    parser.config.max_header_lines = 8;
    var hb = HeaderBuffer.init();
    var buf = try testing.allocator.alloc(u8, 512);
    defer testing.allocator.free(buf);
    var pos: usize = 0;
    for (0..16) |i| {
        const k = "X-Long";
        const v = "abcde";
        pos += (try std.fmt.bufPrint(buf[pos..], "{s}{d}: {s}\r\n", .{ k, i, v })).len;
    }
    // 拼接 HTTP 包和动态头集
    var arr = std.ArrayList(u8).init(testing.allocator);
    defer arr.deinit();
    try arr.appendSlice("GET / HTTP/1.1\r\n");
    try arr.appendSlice(buf[0..pos]);
    try arr.appendSlice("\r\n");
    const all = arr.items;
    _ = hb.append(all) catch {};
    var ev = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev.deinit();
    const err = parser.feed(hb.slice(), all, &ev) catch |e| e;
    try testing.expectError(error.HeaderTooLarge, err);
}

test "Content-Length+chunked并存，仅chunked有效" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();
    const head = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 99\r\nTransfer-Encoding: chunked\r\n\r\n";
    try hb.append(head);
    var ev = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev.deinit();
    _ = try parser.feed(hb.slice(), head, &ev);
    const body = "4\r\nAABB\r\n0\r\n\r\n";
    _ = try parser.feed(hb.slice(), body, &ev);
    var chunkbuf: usize = 0;
    for (ev.items) |e| {
        std.debug.print("event: {any}\n", .{e});
        if (e == .on_body_chunk) chunkbuf += e.on_body_chunk.len;
    }
    try testing.expect(chunkbuf == 4);
}

test "Header大小写、无冒号、异常空头测试" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();
    const raw = "GET / HTTP/1.1\r\nFOO: bar\r\nbaz:Qux\r\nMISSINGSEPARATOR\r\n\r\n";
    try hb.append(raw);
    var ev = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev.deinit();
    const result = parser.feed(hb.slice(), raw, &ev) catch |e| e;
    try testing.expectError(error.InvalidRequest, result);
}

test "粘包（两个GET串连）" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();
    const full = "GET /a HTTP/1.1\r\nHost: h\r\n\r\nGET /b HTTP/1.1\r\nHost: h\r\n\r\n";
    try hb.append(full);
    var ev = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev.deinit();
    const consumed = try parser.feed(hb.slice(), full, &ev);
    try testing.expect(ev.items.len > 0);
    parser.reset();
    // 继续第二条
    var ev2 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer ev2.deinit();
    _ = try parser.feed(hb.slice(), full[consumed..], &ev2);
    try testing.expect(ev2.items.len > 0);
}
