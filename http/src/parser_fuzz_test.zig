const std = @import("std");
const Parser = @import("./parser.zig").Parser;
const HeaderBuffer = @import("./header_buffer.zig").HeaderBuffer;
const crypto = std.crypto;

fn is_valid_state(state: Parser.State) bool {
    return switch (state) {
        .START, .REQUEST_LINE_METHOD, .REQUEST_LINE_PATH, .REQUEST_LINE_VERSION, .HEADER_NAME, .HEADER_VALUE, .HEADERS_COMPLETE, .BODY_IDENTITY, .BODY_CHUNKED_SIZE, .BODY_CHUNKED_DATA, .BODY_CHUNKED_CR, .BODY_CHUNKED_LF, .MESSAGE_COMPLETE => true,
    };
}

test "streaming parser fuzz stress (random bytes, chunked, CL/粘包边界)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var buf = try alloc.alloc(u8, 512);
    var parser = Parser.init(.request);
    var header_buf = HeaderBuffer.init();

    for (0..128) |it| {
        if ((it % 4) == 0) {
            const valid = "POST /f HTTP/1.1\r\nHost: foo\r\nContent-Length: 7\r\n\r\n1234567";
            @memcpy(buf[0..valid.len], valid);
            _ = try header_buf.append(valid);
            var events = std.ArrayList(Parser.Event).init(alloc);
            defer events.deinit();
            _ = try parser.feed(header_buf.slice(), buf[0..valid.len], &events);
            if (!is_valid_state(parser.state)) return error.InvalidStateReach;
            parser.reset();
        } else {
            crypto.random.bytes(buf);
            var remain = buf.len;
            var start: usize = 0;
            var slice_len: usize = 1;
            while (remain > 0) {
                // 每次分片递增，模拟分片
                const n = if (remain > slice_len) slice_len else remain;
                var events = std.ArrayList(Parser.Event).init(alloc);
                defer events.deinit();
                _ = parser.feed(header_buf.slice(), buf[start .. start + n], &events) catch |err| {
                    if (std.mem.eql(u8, @errorName(err), "InvalidChunk") or std.mem.eql(u8, @errorName(err), "InvalidRequest") or std.mem.eql(u8, @errorName(err), "InvalidContentLength")) {
                        // skip
                    } else {
                        std.debug.print("fatal error: {}\n", .{err});
                        return err;
                    }
                    break;
                };
                if (!is_valid_state(parser.state)) return error.InvalidStateReach;
                remain -= n;
                start += n;
                slice_len = (slice_len % 32) + 1;
            }
            parser.reset();
        }
    }
}
