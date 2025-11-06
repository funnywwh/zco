const std = @import("std");
const json = std.json;

/// WebRTC 信令消息类型
pub const MessageType = enum {
    offer,
    answer,
    ice_candidate,
    @"error",
    join,
    leave,
    user_joined, // 用户加入房间通知（服务器广播）

    pub fn jsonStringify(
        self: MessageType,
        _: json.StringifyOptions,
        out_stream: anytype,
    ) !void {
        const str = switch (self) {
            .offer => "offer",
            .answer => "answer",
            .ice_candidate => "ice_candidate", // 使用下划线，与枚举名一致
            .@"error" => "error",
            .join => "join",
            .leave => "leave",
            .user_joined => "user_joined", // 使用下划线，与枚举名一致
        };
        try json.encodeJsonString(str, .{}, out_stream);
    }
};

/// WebRTC 信令消息
pub const SignalingMessage = struct {
    type: MessageType,
    room_id: ?[]const u8 = null,
    user_id: ?[]const u8 = null,
    sdp: ?[]const u8 = null,
    candidate: ?IceCandidate = null,
    @"error": ?[]const u8 = null,

    /// ICE Candidate 信息
    pub const IceCandidate = struct {
        candidate: []const u8,
        sdp_mid: ?[]const u8 = null,
        sdp_mline_index: ?u32 = null,

        // 辅助函数：释放 token 中分配的内存
        // 注意：使用 anytype 来避免类型问题，因为 Token 是 union 类型
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

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: json.Value,
            _: json.ParseOptions,
        ) !IceCandidate {
            const obj = source.object;
            const candidate_val = obj.get("candidate") orelse return error.MissingField;
            const candidate_str = switch (candidate_val) {
                .string => |s| s,
                else => return error.InvalidCharacter, // 使用标准 JSON 错误
            };
            const candidate = try allocator.dupe(u8, candidate_str);

            var result = IceCandidate{
                .candidate = candidate,
                .sdp_mid = null,
                .sdp_mline_index = null,
            };

            // 处理 sdpMid（浏览器发送的驼峰命名）
            if (obj.get("sdpMid")) |mid_val| {
                switch (mid_val) {
                    .string => |s| {
                        result.sdp_mid = try allocator.dupe(u8, s);
                    },
                    else => {},
                }
            }

            // 处理 sdpMLineIndex（浏览器发送的驼峰命名）
            if (obj.get("sdpMLineIndex")) |idx_val| {
                switch (idx_val) {
                    .integer => |i| {
                        result.sdp_mline_index = @intCast(i);
                    },
                    else => {},
                }
            }

            return result;
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

    /// 从 JSON 解析信令消息
    pub fn fromJson(allocator: std.mem.Allocator, json_str: []const u8) !SignalingMessage {
        var parsed = try json.parseFromSlice(
            SignalingMessage,
            allocator,
            json_str,
            .{},
        );
        defer parsed.deinit();
        return parsed.value;
    }

    /// 将信令消息转换为 JSON
    pub fn toJson(self: *const SignalingMessage, allocator: std.mem.Allocator) ![]u8 {
        var result = std.ArrayList(u8).init(allocator);
        errdefer result.deinit();
        var writer = result.writer();

        try writer.writeByte('{');
        const type_str = switch (self.type) {
            .offer => "offer",
            .answer => "answer",
            .ice_candidate => "ice_candidate", // 使用下划线，与枚举名一致
            .@"error" => "error",
            .join => "join",
            .leave => "leave",
            .user_joined => "user_joined", // 使用下划线，与枚举名一致
        };
        try writer.print("\"type\":\"{s}\"", .{type_str});

        if (self.room_id) |rid| {
            try writer.writeAll(",\"room_id\":");
            try json.encodeJsonString(rid, .{}, writer);
        }
        if (self.user_id) |uid| {
            try writer.writeAll(",\"user_id\":");
            try json.encodeJsonString(uid, .{}, writer);
        }
        if (self.sdp) |s| {
            try writer.writeAll(",\"sdp\":");
            try json.encodeJsonString(s, .{}, writer);
        }
        if (self.candidate) |*cand| {
            try writer.writeAll(",\"candidate\":{");
            try writer.writeAll("\"candidate\":");
            try json.encodeJsonString(cand.candidate, .{}, writer);
            if (cand.sdp_mid) |mid| {
                try writer.writeAll(",\"sdpMid\":");
                try json.encodeJsonString(mid, .{}, writer);
            }
            if (cand.sdp_mline_index) |idx| {
                try writer.print(",\"sdpMLineIndex\":{}", .{idx});
            }
            try writer.writeByte('}');
        }
        if (self.@"error") |err| {
            try writer.writeAll(",\"error\":");
            try json.encodeJsonString(err, .{}, writer);
        }

        try writer.writeByte('}');
        return result.toOwnedSlice();
    }

    pub fn deinit(self: *SignalingMessage, allocator: std.mem.Allocator) void {
        if (self.room_id) |id| allocator.free(id);
        if (self.user_id) |id| allocator.free(id);
        if (self.sdp) |s| allocator.free(s);
        if (self.candidate) |*cand| {
            allocator.free(cand.candidate);
            if (cand.sdp_mid) |mid| allocator.free(mid);
        }
        if (self.@"error") |err| allocator.free(err);
    }
};
