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
        // 保存最后一个 offer 和 answer，用于新用户加入时转发
        last_offer: ?[]const u8 = null,
        last_answer: ?[]const u8 = null,

        pub fn init(allocator: std.mem.Allocator) Room {
            return .{
                .users = std.StringHashMap(*Client).init(allocator),
                .allocator = allocator,
                .last_offer = null,
                .last_answer = null,
            };
        }

        pub fn deinit(self: *Room) void {
            // 注意：Room.deinit 只清理 room 自己的资源
            // Client 对象由 handleClient 协程负责清理，不应该在这里销毁
            // 只需要清理 HashMap 中的 key（user_id）和 room 自己的资源
            // 注意：在服务器退出时，handleClient 协程可能还在运行，所以需要安全地清理
            // 先收集所有的 key，然后再释放，避免在迭代时修改 HashMap
            var keys_to_free = std.ArrayList([]const u8).init(self.allocator);
            defer keys_to_free.deinit();
            
            var it = self.users.iterator();
            while (it.next()) |entry| {
                // 保存 key 的副本，因为 entry.key_ptr.* 可能已经被释放
                const key_dup = self.allocator.dupe(u8, entry.key_ptr.*) catch {
                    // 如果分配失败，跳过这个 key
                    continue;
                };
                keys_to_free.append(key_dup) catch {
                    // 如果追加失败，释放刚分配的 key
                    self.allocator.free(key_dup);
                    continue;
                };
            }
            
            // 释放所有收集到的 key
            for (keys_to_free.items) |key| {
                self.allocator.free(key);
            }
            
            self.users.deinit();
            // 释放保存的消息
            if (self.last_offer) |offer| {
                self.allocator.free(offer);
            }
            if (self.last_answer) |answer| {
                self.allocator.free(answer);
            }
        }

        pub fn broadcast(self: *Room, sender_id: []const u8, msg: []const u8) void {
            // 收集所有需要发送的用户（避免在迭代时修改 HashMap）
            var users_to_notify = std.ArrayList([]const u8).init(self.users.allocator);
            defer users_to_notify.deinit();

            var it = self.users.iterator();
            while (it.next()) |entry| {
                const user_id = entry.key_ptr.*;
                // 不发送给发送者自己
                if (!std.mem.eql(u8, user_id, sender_id)) {
                    users_to_notify.append(user_id) catch {
                        // 如果分配失败，记录错误但继续
                        std.log.err("[服务器] 收集用户列表失败，跳过广播", .{});
                        return;
                    };
                }
            }

            // 遍历收集到的用户列表，发送消息
            for (users_to_notify.items) |user_id| {
                // 再次检查用户是否还在房间中（可能在其他协程中断开连接）
                if (self.users.get(user_id)) |client| {
                    // 安全地发送消息，捕获所有可能的错误
                    // 注意：客户端可能正在断开连接，WebSocket 可能已经无效
                    // 注意：client 可能已经被 handleClient 销毁，所以需要检查指针是否有效
                    client.send(msg) catch |err| {
                        // 发送失败不应该导致整个连接关闭
                        // 记录错误但继续处理其他用户
                        // 注意：连接可能已经关闭，这是正常的（客户端断开连接）
                        std.log.debug("[服务器] 发送消息给 {s} 失败: {}（可能已断开连接）", .{ user_id, err });
                        // 可以选择从房间中移除该用户，但这里先只记录错误
                        // 因为用户可能在其他协程中正在断开连接，避免并发修改
                        // 注意：如果发送失败是因为 client 已被销毁，访问 client 会导致段错误
                        // 但 send() 方法内部已经检查了 ws.upgraded，应该能避免访问已销毁的对象
                    };
                } else {
                    // 用户已从房间中移除，跳过
                    std.log.debug("[服务器] 用户 {s} 已从房间中移除，跳过广播", .{user_id});
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
        // 标记客户端是否正在断开连接（用于避免在广播时访问已销毁的 client）
        is_disconnecting: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
            // 检查客户端是否正在断开连接
            if (self.is_disconnecting.load(.acquire)) {
                return error.ConnectionClosed;
            }
            // 检查 WebSocket 是否已经升级（已建立连接）
            if (!self.ws.upgraded) {
                return error.ConnectionClosed;
            }
            // 尝试发送消息，如果连接已关闭，返回错误而不是崩溃
            self.ws.sendText(data) catch |err| {
                // 如果连接已关闭，这是正常的，不需要报错
                if (err == error.ConnectionClosed or err == error.ConnectionReset or err == error.EOF) {
                    return error.ConnectionClosed;
                }
                return err;
            };
        }
    };

    /// 创建新的信令服务器
    pub fn init(schedule: *zco.Schedule, address: std.net.Address) !*Self {
        const allocator = schedule.allocator;
        const tcp = try nets.Tcp.init(schedule);
        errdefer tcp.deinit();

        try tcp.bind(address);
        errdefer tcp.deinit();

        try tcp.listen(128);

        const server = allocator.create(Self) catch |err| {
            // 如果创建失败，清理 tcp
            tcp.deinit();
            return err;
        };
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

        // 清理 TCP socket
        // 注意：tcp.deinit() 会调用 allocator.destroy(self.tcp)，所以不需要再次 destroy
        if (self.tcp.xobj) |_| {
            self.tcp.close();
        }
        self.tcp.deinit();

        // 最后销毁服务器对象
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
        // 注意：client 始终由 handleClient 负责清理
        // Room.deinit 只清理 room 自己的资源，不会销毁 client
        defer {
            client.deinit();
            server.allocator.destroy(client);
        }

        var buffer: [8192]u8 = undefined;

        while (true) {
            const frame = ws.readMessage(buffer[0..]) catch |err| {
                // 处理连接错误（客户端断开连接等）
                if (err == error.ConnectionReset or err == websocket.WebSocketError.ConnectionClosed or err == error.EOF) {
                    std.log.info("[服务器] 客户端断开连接: {}", .{err});
                    break;
                }
                // 其他错误也记录并退出
                std.log.err("[服务器] 读取消息失败: {}", .{err});
                break;
            };
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
            var msg = parsed.value;
            // 注意：parsed.deinit() 会释放 msg 内部的所有分配内存
            // 所以不需要单独调用 msg.deinit()
            defer parsed.deinit();

            // 处理消息
            server.handleMessage(client, &msg) catch |err| {
                // 处理消息失败不应该导致连接关闭
                std.log.err("[服务器] 处理消息失败: {}", .{err});
                // 继续处理下一个消息
            };

            // 不需要手动调用 msg.deinit()，因为 parsed.deinit() 会处理
        }

        // 客户端断开连接，从房间中移除
        // 注意：在清理资源之前先移除用户，避免在清理过程中访问已释放的资源
        if (client.room_id) |room_id| {
            if (server.rooms.getPtr(room_id)) |room| {
                if (client.user_id) |user_id| {
                    // 先标记客户端为正在断开连接，避免其他协程在广播时访问已销毁的 client
                    client.is_disconnecting.store(true, .release);

                    // 先保存 user_id 用于广播（因为 fetchRemove 会释放 key）
                    const user_id_dup_for_leave = try server.allocator.dupe(u8, user_id);
                    defer server.allocator.free(user_id_dup_for_leave);

                    if (room.users.fetchRemove(user_id)) |entry| {
                        server.allocator.free(entry.key);
                        // 注意：client 对象仍然由 handleClient 的 defer 负责清理
                        // Room.deinit 不会销毁 client，只清理 room 自己的资源

                        // 通知其他用户（在移除用户之后，避免通知自己）
                        // 注意：广播时可能其他客户端也在断开，所以需要安全处理
                        // 创建 leave 消息（不调用 deinit，因为 user_id 是我们自己分配的）
                        var leave_msg = message.SignalingMessage{
                            .type = .leave,
                            .user_id = user_id_dup_for_leave,
                        };
                        // 注意：leave_msg 的 user_id 是我们自己分配的，不会被 deinit 释放
                        // 所以不需要调用 leave_msg.deinit()
                        const leave_json = (@as(*const message.SignalingMessage, &leave_msg)).toJson(server.allocator) catch |err| {
                            std.log.err("[服务器] 创建 leave 消息失败: {}", .{err});
                            // 如果创建消息失败，跳过广播
                            return;
                        };
                        defer server.allocator.free(leave_json);

                        // 安全地广播 leave 消息（broadcast 内部已经处理了发送失败的情况）
                        // 注意：此时 client 已经标记为正在断开连接，broadcast 不会尝试通过它发送消息
                        room.broadcast(user_id_dup_for_leave, leave_json);
                    }
                }
            }
        }
    }

    /// 处理信令消息
    /// 注意：函数内部的错误会被捕获，不会导致连接关闭
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

                std.log.info("[服务器] 用户 {s} 加入房间 {s}", .{ user_id, room_id });

                // 获取或创建房间
                const room_entry = try self.rooms.getOrPut(room_id);
                if (!room_entry.found_existing) {
                    room_entry.key_ptr.* = try self.allocator.dupe(u8, room_id);
                    room_entry.value_ptr.* = Room.init(self.allocator);
                    std.log.info("[服务器] 创建新房间: {s}", .{room_id});
                }

                // 添加用户到房间
                const user_id_dup = try self.allocator.dupe(u8, user_id);
                try room_entry.value_ptr.*.users.put(user_id_dup, client);

                client.room_id = try self.allocator.dupe(u8, room_id);
                client.user_id = user_id_dup;

                std.log.info("[服务器] 房间 {s} 当前有 {} 个用户", .{ room_id, room_entry.value_ptr.*.users.count() });

                // 1. 通知新加入的用户：房间中已有的其他用户
                var it = room_entry.value_ptr.*.users.iterator();
                while (it.next()) |entry| {
                    const existing_user_id = entry.key_ptr.*;
                    // 不通知自己
                    if (!std.mem.eql(u8, existing_user_id, user_id)) {
                        const room_id_for_existing = try self.allocator.dupe(u8, room_id);
                        const existing_user_id_dup = try self.allocator.dupe(u8, existing_user_id);
                        var existing_user_msg = message.SignalingMessage{
                            .type = .user_joined,
                            .room_id = room_id_for_existing,
                            .user_id = existing_user_id_dup,
                        };
                        defer existing_user_msg.deinit(self.allocator);
                        const existing_user_json = try (@as(*const message.SignalingMessage, &existing_user_msg)).toJson(self.allocator);
                        defer self.allocator.free(existing_user_json);
                        std.log.info("[服务器] 通知新用户 {s}: 房间中已有用户 {s}", .{ user_id, existing_user_id });
                        try client.send(existing_user_json);
                    }
                }

                // 1.5. 如果房间中有未发送的 offer，转发给新加入的用户
                if (room_entry.value_ptr.*.last_offer) |offer| {
                    std.log.info("[服务器] 转发之前的 offer 给新用户 {s}", .{user_id});
                    try client.send(offer);
                }

                // 2. 广播新用户加入的通知给房间中的其他用户（不包括刚加入的用户）
                if (room_entry.value_ptr.*.users.count() > 1) {
                    const room_id_dup = try self.allocator.dupe(u8, room_id);
                    const user_id_for_notify = try self.allocator.dupe(u8, user_id);
                    var user_joined_msg = message.SignalingMessage{
                        .type = .user_joined,
                        .room_id = room_id_dup,
                        .user_id = user_id_for_notify,
                    };
                    defer user_joined_msg.deinit(self.allocator);
                    const notify_json = try (@as(*const message.SignalingMessage, &user_joined_msg)).toJson(self.allocator);
                    defer self.allocator.free(notify_json);
                    std.log.info("[服务器] 广播 user_joined 通知: {s} 加入房间 {s}", .{ user_id, room_id });
                    room_entry.value_ptr.*.broadcast(user_id, notify_json);
                }
            },
            .offer, .answer, .ice_candidate => {
                // 转发消息到房间中的其他用户
                if (client.room_id) |room_id| {
                    if (self.rooms.getPtr(room_id)) |room| {
                        if (client.user_id) |user_id| {
                            std.log.info("[服务器] 转发 {s} 消息从 {s} 到房间 {s} 的其他用户", .{ @tagName(msg.type), user_id, room_id });
                            const msg_json = try msg.toJson(self.allocator);
                            defer self.allocator.free(msg_json);
                            const recipient_count = room.users.count() - 1; // 排除发送者
                            std.log.info("[服务器] 房间 {s} 中有 {} 个接收者", .{ room_id, recipient_count });

                            // 保存 offer 和 answer 用于新用户加入时转发
                            if (msg.type == .offer) {
                                // 释放旧的 offer
                                if (room.last_offer) |old_offer| {
                                    self.allocator.free(old_offer);
                                }
                                // 保存新的 offer（深拷贝）
                                room.last_offer = try self.allocator.dupe(u8, msg_json);
                            } else if (msg.type == .answer) {
                                // 释放旧的 answer
                                if (room.last_answer) |old_answer| {
                                    self.allocator.free(old_answer);
                                }
                                // 保存新的 answer（深拷贝）
                                room.last_answer = try self.allocator.dupe(u8, msg_json);
                            }

                            room.broadcast(user_id, msg_json);
                            std.log.info("[服务器] ✅ 消息已广播", .{});
                        }
                    } else {
                        std.log.warn("[服务器] 房间 {s} 不存在", .{room_id});
                    }
                } else {
                    std.log.warn("[服务器] 客户端未加入房间", .{});
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
            .user_joined => {
                // user_joined 是服务器发送的通知，客户端不应该发送此类消息
                std.log.warn("[服务器] 客户端发送了 user_joined 消息，这是不允许的", .{});
            },
        }
    }
};
