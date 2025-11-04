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
            .ice_candidate => "ice-candidate",
            .@"error" => "error",
            .join => "join",
            .leave => "leave",
            .user_joined => "user-joined",
        };
        try json.encodeJsonString(str, .{}, out_stream);
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: json.ParseOptions,
    ) !MessageType {
        // 从 TokenStream 读取字符串 token
        const token = try source.next();
        const str_slice = switch (token) {
            .string => |s| s.slice,
            .string_escaped => |s| s.slice,
            else => return error.InvalidEnumTag,
        };
        
        // 匹配 JSON 字符串格式（注意：JSON 中的枚举值格式）
        if (std.mem.eql(u8, str_slice, "offer")) {
            return .offer;
        } else if (std.mem.eql(u8, str_slice, "answer")) {
            return .answer;
        } else if (std.mem.eql(u8, str_slice, "ice-candidate")) {
            return .ice_candidate;
        } else if (std.mem.eql(u8, str_slice, "error")) {
            return .@"error";
        } else if (std.mem.eql(u8, str_slice, "join")) {
            return .join;
        } else if (std.mem.eql(u8, str_slice, "leave")) {
            return .leave;
        } else if (std.mem.eql(u8, str_slice, "user-joined")) {
            return .user_joined;
        } else {
            return error.InvalidEnumTag;
        }
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
            .ice_candidate => "ice-candidate",
            .@"error" => "error",
            .join => "join",
            .leave => "leave",
            .user_joined => "user-joined",
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
