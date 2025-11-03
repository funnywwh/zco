const std = @import("std");
const zco = @import("zco");

/// ICE Candidate 实现
/// 用于 ICE Agent 中的候选地址收集和管理
pub const Candidate = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    foundation: []const u8, // 基础标识符
    component_id: u32, // 组件 ID（1=RTP, 2=RTCP）
    transport: []const u8, // 传输协议（通常是 "udp"）
    priority: u32, // 优先级
    address: std.net.Address, // 候选地址
    typ: Type, // 候选类型
    related_address: ?std.net.Address = null, // 相关地址（用于 srflx/relay）
    related_port: ?u16 = null, // 相关端口

    /// Candidate 类型
    pub const Type = enum {
        host, // 本地主机候选
        server_reflexive, // 服务器反射候选（通过 STUN）
        peer_reflexive, // 对等反射候选
        relayed, // 中继候选（通过 TURN）
    };

    /// 创建新的 Candidate
    pub fn init(
        allocator: std.mem.Allocator,
        foundation: []const u8,
        component_id: u32,
        transport: []const u8,
        address: std.net.Address,
        typ: Type,
    ) !Self {
        return .{
            .allocator = allocator,
            .foundation = try allocator.dupe(u8, foundation),
            .component_id = component_id,
            .transport = try allocator.dupe(u8, transport),
            .priority = 0, // 将在 calculatePriority 中设置
            .address = address,
            .typ = typ,
        };
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.foundation);
        self.allocator.free(self.transport);
    }

    /// 计算候选优先级（根据 RFC 8445）
    /// priority = (2^24)*(type preference) + (2^8)*(local preference) + (2^0)*(component ID)
    pub fn calculatePriority(self: *Self, type_preference: u8, local_preference: u16) void {
        const type_pref: u32 = @as(u32, type_preference) << 24;
        const local_pref: u32 = @as(u32, local_preference) << 8;
        const component: u32 = self.component_id;
        self.priority = type_pref | local_pref | component;
    }

    /// 获取类型优先级（默认值）
    pub fn getTypePreference(typ: Type) u8 {
        return switch (typ) {
            .host => 126, // 最高优先级
            .peer_reflexive => 110,
            .server_reflexive => 100,
            .relayed => 0, // 最低优先级
        };
    }

    /// 转换为 SDP candidate 字符串
    pub fn toSdpCandidate(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        var writer = buffer.writer();

        const typ_str = switch (self.typ) {
            .host => "host",
            .server_reflexive => "srflx",
            .peer_reflexive => "prflx",
            .relayed => "relay",
        };

        // 格式化地址字符串（只获取 IP 部分，不包括端口）
        var addr_buf: [64]u8 = undefined;
        var fmt_buf = std.io.fixedBufferStream(&addr_buf);
        try self.address.format("", .{}, fmt_buf.writer());
        const addr_str = fmt_buf.getWritten();

        try writer.print(
            "candidate {s} {} {s} {} {s} {} typ {s}",
            .{
                self.foundation,
                self.component_id,
                self.transport,
                self.priority,
                addr_str,
                self.address.getPort(),
                typ_str,
            },
        );

        // 添加相关地址（如果有）
        if (self.related_address) |rel_addr| {
            var ip_str_buf: [64]u8 = undefined;
            var rel_fmt_buf = std.io.fixedBufferStream(&ip_str_buf);
            try rel_addr.format("", .{}, rel_fmt_buf.writer());
            const ip_str = rel_fmt_buf.getWritten();
            try writer.print(" raddr {s} rport {}", .{ ip_str, self.related_port orelse 0 });
        }

        return buffer.toOwnedSlice();
    }

    /// 从 SDP candidate 字符串解析
    pub fn fromSdpCandidate(allocator: std.mem.Allocator, candidate_str: []const u8) !Self {
        // 解析格式：candidate foundation component transport priority address port typ [raddr] [rport]
        var parts = std.mem.splitScalar(u8, candidate_str, ' ');

        _ = parts.next(); // 跳过 "candidate"
        const foundation_str = parts.next() orelse return error.InvalidCandidate;
        const component_str = parts.next() orelse return error.InvalidCandidate;
        const transport_str = parts.next() orelse return error.InvalidCandidate;
        const priority_str = parts.next() orelse return error.InvalidCandidate;
        const address_str = parts.next() orelse return error.InvalidCandidate;
        const port_str = parts.next() orelse return error.InvalidCandidate;
        _ = parts.next(); // 跳过 "typ"
        const typ_str = parts.next() orelse return error.InvalidCandidate;

        const component_id = try std.fmt.parseInt(u32, component_str, 10);
        const priority = try std.fmt.parseInt(u32, priority_str, 10);
        const port = try std.fmt.parseInt(u16, port_str, 10);
        // 尝试解析 IP 地址
        const address = blk: {
            const addr4 = std.net.Address.parseIp4(address_str, port) catch {
                break :blk try std.net.Address.parseIp6(address_str, port);
            };
            break :blk addr4;
        };

        const typ = if (std.mem.eql(u8, typ_str, "host"))
            Type.host
        else if (std.mem.eql(u8, typ_str, "srflx"))
            Type.server_reflexive
        else if (std.mem.eql(u8, typ_str, "prflx"))
            Type.peer_reflexive
        else if (std.mem.eql(u8, typ_str, "relay"))
            Type.relayed
        else
            return error.InvalidCandidateType;

        var candidate = Self{
            .allocator = allocator,
            .foundation = try allocator.dupe(u8, foundation_str),
            .component_id = component_id,
            .transport = try allocator.dupe(u8, transport_str),
            .priority = priority,
            .address = address,
            .typ = typ,
        };

        // 解析相关地址（如果有）
        if (parts.next()) |raddr_str| {
            if (std.mem.eql(u8, raddr_str, "raddr")) {
                const raddr_ip = parts.next() orelse return error.InvalidCandidate;
                if (parts.next()) |rport_str| {
                    if (std.mem.eql(u8, rport_str, "rport")) {
                        const rport = parts.next() orelse return error.InvalidCandidate;
                        const rport_num = try std.fmt.parseInt(u16, rport, 10);
                        candidate.related_port = rport_num;
                        candidate.related_address = blk2: {
                            const addr4 = std.net.Address.parseIp4(raddr_ip, rport_num) catch {
                                break :blk2 try std.net.Address.parseIp6(raddr_ip, rport_num);
                            };
                            break :blk2 addr4;
                        };
                    }
                }
            }
        }

        return candidate;
    }

    pub const Error = error{
        InvalidCandidate,
        InvalidCandidateType,
        UnsupportedAddressFamily,
        OutOfMemory,
    };
};
