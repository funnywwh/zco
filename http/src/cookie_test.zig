const std = @import("std");
const testing = std.testing;
const cookie = @import("./cookie.zig");

test "parse request cookies list" {
    const hdr = "sid=abc123; user=tom; lang=zh";
    const items = try cookie.parseCookies(testing.allocator, hdr);
    defer testing.allocator.free(items);

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("sid", items[0].name);
    try testing.expectEqualStrings("abc123", items[0].value);
}

test "parse Set-Cookie with attributes" {
    const sc = "session=val; Path=/; Domain=.ex.com; Secure; HttpOnly; SameSite=Strict; Max-Age=10";
    const c = try cookie.parseSetCookie(testing.allocator, sc);
    try testing.expectEqualStrings("session", c.name);
    try testing.expectEqualStrings("val", c.value);
    try testing.expectEqualStrings("/", c.path.?);
    try testing.expectEqualStrings(".ex.com", c.domain.?);
    try testing.expect(c.secure);
    try testing.expect(c.http_only);
    try testing.expectEqual(cookie.Cookie.SameSite.Strict, c.same_site.?);
    try testing.expect(c.max_age.? == 10);
}


