const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const websocket = @import("websocket");
const message = @import("./message.zig");

/// WebRTC 信令服务器
/// 基于 WebSocket 实现信令消息路由
pub const SignalingServer = struct {
    const Self = @This();

    schedule: *zco.Schedule,
    tcp: *nets.Tcp,
    rooms: std.StringHashMap(Room),
    allocator: std.mem.Allocator,

    /// 房间信息
    const Room = struct {
        users: std.StringHashMap(*Client),
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Room {
            return .{
                .users = std.StringHashMap(*Client).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Room) void {
            var it = self.users.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.*.deinit();
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.users.deinit();
        }

        pub fn broadcast(self: *Room, sender_id: []const u8, msg: []const u8) !void {
            var it = self.users.iterator();
            while (it.next()) |entry| {
                const user_id = entry.key_ptr.*;
                const client = entry.value_ptr.*;

                // 不发送给发送者自己
                if (!std.mem.eql(u8, user_id, sender_id)) {
                    try client.send(msg);
                }
            }
        }
    };

    /// 客户端连接
    const Client = struct {
        ws: *websocket.WebSocket,
        room_id: ?[]const u8 = null,
        user_id: ?[]const u8 = null,
        allocator: std.mem.Allocator,

        pub fn init(ws: *websocket.WebSocket, allocator: std.mem.Allocator) *Client {
            const client = allocator.create(Client) catch unreachable;
            client.* = .{
                .ws = ws,
                .allocator = allocator,
            };
            return client;
        }

        pub fn deinit(self: *Client) void {
            if (self.room_id) |id| self.allocator.free(id);
            if (self.user_id) |id| self.allocator.free(id);
        }

        pub fn send(self: *Client, data: []const u8) !void {
            try self.ws.sendText(data);
        }
    };

    /// 创建新的信令服务器
    pub fn init(schedule: *zco.Schedule, address: std.net.Address) !*Self {
        const allocator = schedule.allocator;
        const tcp = try nets.Tcp.init(schedule);
        try tcp.bind(address);
        try tcp.listen(128);

        const server = try allocator.create(Self);
        server.* = .{
            .schedule = schedule,
            .tcp = tcp,
            .rooms = std.StringHashMap(Room).init(allocator),
            .allocator = allocator,
        };

        return server;
    }

    /// 清理信令服务器资源
    pub fn deinit(self: *Self) void {
        var it = self.rooms.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
        }
        self.rooms.deinit();
        self.tcp.deinit();
        self.allocator.destroy(self);
    }

    /// 启动信令服务器（在协程中运行）
    pub fn start(self: *Self) !void {
        while (true) {
            const client_tcp = try self.tcp.accept();
            _ = try self.schedule.go(handleClient, .{ self, client_tcp });
        }
    }

    /// 处理客户端连接
    fn handleClient(server: *Self, client_tcp: *nets.Tcp) !void {
        defer client_tcp.close();

        const ws = try websocket.WebSocket.fromTcp(client_tcp);
        defer ws.deinit();

        try ws.handshake();

        const client = Client.init(ws, server.allocator);
        defer client.deinit();
        defer server.allocator.destroy(client);

        var buffer: [8192]u8 = undefined;

        while (true) {
            const frame = try ws.readMessage(buffer[0..]);
            defer if (frame.payload.len > buffer.len) ws.allocator.free(frame.payload);

            if (frame.opcode == .CLOSE) {
                break;
            }

            if (frame.opcode != .TEXT) {
                continue;
            }

            // 解析 JSON 消息
            var parsed = std.json.parseFromSlice(
                message.SignalingMessage,
                server.allocator,
                frame.payload,
                .{},
            ) catch {
                std.log.err("Failed to parse signaling message", .{});
                continue;
            };
            defer parsed.deinit();
            var msg = parsed.value;

            // 处理消息
            try server.handleMessage(client, &msg);

            // 清理消息资源
            msg.deinit(server.allocator);
        }

        // 客户端断开连接，从房间中移除
        if (client.room_id) |room_id| {
            if (server.rooms.getPtr(room_id)) |room| {
                if (client.user_id) |user_id| {
                    if (room.users.fetchRemove(user_id)) |entry| {
                        server.allocator.free(entry.key);
                        // 通知其他用户
                        var leave_msg = message.SignalingMessage{
                            .type = .leave,
                            .user_id = user_id,
                        };
                        defer leave_msg.deinit(server.allocator);
                        const leave_json = try (@as(*const message.SignalingMessage, &leave_msg)).toJson(server.allocator);
                        defer server.allocator.free(leave_json);
                        try room.broadcast(user_id, leave_json);
                    }
                }
            }
        }
    }

    /// 处理信令消息
    fn handleMessage(self: *Self, client: *Client, msg: *message.SignalingMessage) !void {
        switch (msg.type) {
            .join => {
                if (msg.room_id == null or msg.user_id == null) {
                    const error_msg = try self.allocator.dupe(u8, "Missing room_id or user_id");
                    var err_msg = message.SignalingMessage{
                        .type = .@"error",
                        .@"error" = error_msg,
                    };
                    errdefer err_msg.deinit(self.allocator);
                    const err_json = try (@as(*const message.SignalingMessage, &err_msg)).toJson(self.allocator);
                    defer self.allocator.free(err_json);
                    try client.send(err_json);
                    return;
                }

                const room_id = msg.room_id.?;
                const user_id = msg.user_id.?;

                // 获取或创建房间
                const room_entry = try self.rooms.getOrPut(room_id);
                if (!room_entry.found_existing) {
                    room_entry.key_ptr.* = try self.allocator.dupe(u8, room_id);
                    room_entry.value_ptr.* = Room.init(self.allocator);
                }

                // 添加用户到房间
                const user_id_dup = try self.allocator.dupe(u8, user_id);
                try room_entry.value_ptr.*.users.put(user_id_dup, client);

                client.room_id = try self.allocator.dupe(u8, room_id);
                client.user_id = user_id_dup;
            },
            .offer, .answer, .ice_candidate => {
                // 转发消息到房间中的其他用户
                if (client.room_id) |room_id| {
                    if (self.rooms.getPtr(room_id)) |room| {
                        if (client.user_id) |user_id| {
                            const msg_json = try msg.toJson(self.allocator);
                            defer self.allocator.free(msg_json);
                            try room.broadcast(user_id, msg_json);
                        }
                    }
                }
            },
            .leave => {
                if (client.room_id) |room_id| {
                    if (self.rooms.getPtr(room_id)) |room| {
                        if (client.user_id) |user_id| {
                            if (room.users.fetchRemove(user_id)) |entry| {
                                self.allocator.free(entry.key);
                            }
                        }
                    }
                }
            },
            .@"error" => {
                // 错误消息直接返回给客户端
                const msg_json = try msg.toJson(self.allocator);
                defer self.allocator.free(msg_json);
                try client.send(msg_json);
            },
        }
    }
};
