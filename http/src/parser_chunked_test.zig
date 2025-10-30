const std = @import("std");
const testing = std.testing;
const Parser = @import("./parser.zig").Parser;
const HeaderBuffer = @import("./header_buffer.zig").HeaderBuffer;

test "chunked body streaming with two chunks" {
    var parser = Parser.init(.request);
    var hb = HeaderBuffer.init();

    const head = "POST /c HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n";
    try hb.append(head);
    var e1 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer e1.deinit();
    _ = try parser.feed(hb.slice(), head, &e1);

    const body = "4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n";

    var e2 = std.ArrayList(Parser.Event).init(testing.allocator);
    defer e2.deinit();
    _ = try parser.feed(hb.slice(), body, &e2);

    var chunk_bytes: usize = 0;
    var complete = false;
    for (e2.items) |ev| switch (ev) {
        .on_body_chunk => |s| chunk_bytes += s.len,
        .on_message_complete => complete = true,
        else => {},
    };

    try testing.expect(complete);
    try testing.expectEqual(@as(usize, 9), chunk_bytes); // Wiki + pedia
}
