const std = @import("std");
const json = std.json;
// Token 类型定义在 json.scanner 模块中，但需要通过 json.Scanner 访问
// 实际上，我们可以直接使用 json.Scanner 返回的 union 类型
// 为了简化，我们直接使用类型推断

// 简化的 IceCandidate 结构（用于测试）
const IceCandidate = struct {
    candidate: []const u8,
    sdp_mid: ?[]const u8 = null,
    sdp_mline_index: ?u32 = null,

    // 辅助函数：释放 token 中分配的内存
    // 注意：这里使用 anytype 来避免类型问题，因为 Token 是 union 类型
    fn freeToken(allocator: std.mem.Allocator, token: anytype) void {
        switch (token) {
            .allocated_number, .allocated_string => |slice| {
                allocator.free(slice);
            },
            else => {},
        }
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: json.ParseOptions,
    ) !IceCandidate {
        // 直接从 token source 解析对象字段，避免双重解析导致栈溢出
        // 这样可以减少栈使用，避免在深栈上解析嵌套 JSON 时触发栈探测

        // 读取 object_begin token
        const obj_start = try source.next();
        if (obj_start != .object_begin) {
            return error.UnexpectedToken;
        }

        var candidate: ?[]const u8 = null;
        var sdp_mid: ?[]const u8 = null;
        var sdp_mline_index: ?u32 = null;

        // 循环读取字段
        while (true) {
            const name_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
            const field_name = switch (name_token) {
                inline .string, .allocated_string => |slice| slice,
                .object_end => break, // 对象结束
                else => {
                    freeToken(allocator, name_token);
                    return error.UnexpectedToken;
                },
            };

            // 匹配字段名
            if (std.mem.eql(u8, field_name, "candidate")) {
                freeToken(allocator, name_token);
                // 读取 candidate 字段的值（字符串）
                const value_token = try source.nextAllocMax(allocator, .alloc_always, options.max_value_len.?);
                const candidate_str = switch (value_token) {
                    .allocated_string => |s| s,
                    else => {
                        freeToken(allocator, value_token);
                        return error.UnexpectedToken;
                    },
                };
                candidate = candidate_str;
            } else if (std.mem.eql(u8, field_name, "sdpMid")) {
                freeToken(allocator, name_token);
                // 读取 sdpMid 字段的值（字符串）
                const value_token = try source.nextAllocMax(allocator, .alloc_always, options.max_value_len.?);
                const mid_str = switch (value_token) {
                    .allocated_string => |s| s,
                    else => {
                        freeToken(allocator, value_token);
                        return error.UnexpectedToken;
                    },
                };
                sdp_mid = mid_str;
            } else if (std.mem.eql(u8, field_name, "sdpMLineIndex")) {
                freeToken(allocator, name_token);
                // 读取 sdpMLineIndex 字段的值（整数）
                const value_token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                const idx = switch (value_token) {
                    .number, .allocated_number => |slice| try std.fmt.parseInt(u32, slice, 10),
                    else => {
                        freeToken(allocator, value_token);
                        return error.UnexpectedToken;
                    },
                };
                freeToken(allocator, value_token);
                sdp_mline_index = idx;
            } else {
                // 未知字段，跳过
                freeToken(allocator, name_token);
                try source.skipValue();
            }
        }

        // 验证必需字段
        const candidate_str = candidate orelse return error.MissingField;

        return IceCandidate{
            .candidate = candidate_str,
            .sdp_mid = sdp_mid,
            .sdp_mline_index = sdp_mline_index,
        };
    }

    pub fn jsonStringify(
        self: *const IceCandidate,
        _: json.StringifyOptions,
        out_stream: anytype,
    ) !void {
        try out_stream.writeByte('{');
        try out_stream.print("\"candidate\":\"{s}\"", .{self.candidate});
        if (self.sdp_mid) |mid| {
            try out_stream.print(",\"sdpMid\":\"{s}\"", .{mid});
        }
        if (self.sdp_mline_index) |idx| {
            try out_stream.print(",\"sdpMLineIndex\":{}", .{idx});
        }
        try out_stream.writeByte('}');
    }
};

const SignalingMessage = struct {
    type: []const u8,
    room_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    candidate: ?IceCandidate = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 测试 JSON 字符串
    const test_json =
        \\{"type":"ice_candidate","room_id":"browser-test-room","user_id":"browser-client","candidate":{"candidate":"candidate:664767767 1 udp 2113937151 192.168.3.8 42956 typ host generation 0 ufrag 1Ksr network-cost 999","sdpMid":"0","sdpMLineIndex":0}}
    ;

    std.log.info("=== 测试 IceCandidate JSON 解析 ===", .{});
    std.log.info("JSON 长度: {} 字节", .{test_json.len});
    std.log.info("JSON 内容: {s}", .{test_json});

    // 测试解析
    std.log.info("开始解析 JSON...", .{});

    var parsed = std.json.parseFromSlice(
        SignalingMessage,
        allocator,
        test_json,
        .{},
    ) catch |err| {
        std.log.err("解析失败: {}", .{err});
        return err;
    };
    defer parsed.deinit();

    const msg = parsed.value;
    std.log.info("✅ 解析成功！", .{});
    std.log.info("消息类型: {s}", .{msg.type});

    if (msg.candidate) |cand| {
        std.log.info("Candidate 信息:", .{});
        std.log.info("  candidate: {s}", .{cand.candidate});
        if (cand.sdp_mid) |mid| {
            std.log.info("  sdpMid: {s}", .{mid});
        }
        if (cand.sdp_mline_index) |idx| {
            std.log.info("  sdpMLineIndex: {}", .{idx});
        }
    } else {
        std.log.warn("⚠️ candidate 字段为 null", .{});
    }

    std.log.info("=== 测试完成 ===", .{});
}
