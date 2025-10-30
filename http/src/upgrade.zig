const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const websocket = @import("websocket");
const context = @import("./context.zig");

/// WebSocket升级处理器
pub const Upgrade = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,

    /// 初始化升级处理器
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule) Self {
        return .{
            .allocator = allocator,
            .schedule = schedule,
        };
    }

    /// 升级HTTP连接到WebSocket
    pub fn upgradeToWebSocket(_: *Self, ctx: *context.Context) !*websocket.WebSocket {
        // 检查是否是WebSocket升级请求
        const upgrade_header = ctx.req.getHeader("Upgrade") orelse {
            return error.NotUpgradeRequest;
        };

        if (!std.mem.eql(u8, std.mem.trim(u8, upgrade_header, " "), "websocket")) {
            return error.NotWebSocketUpgrade;
        }

        // 从上下文获取TCP连接
        const ws = try websocket.WebSocket.fromTcp(ctx.tcp);
        
        // 执行WebSocket握手
        try ws.handshake();

        return ws;
    }

    /// 处理WebSocket连接
    pub fn handleWebSocket(self: *Self, ctx: *context.Context, handler: *const fn (*websocket.WebSocket) anyerror!void) !void {
        const ws = try self.upgradeToWebSocket(ctx);
        defer ws.deinit();

        try handler(ws);
    }
};

