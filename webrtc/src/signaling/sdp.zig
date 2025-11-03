const std = @import("std");
const allocator = std.mem.Allocator;

/// SDP (Session Description Protocol) 解析器和生成器
/// 实现 RFC 4566
pub const Sdp = struct {
    const Self = @This();

    allocator: allocator,
    version: ?u32 = null,
    origin: ?Origin = null,
    session_name: ?[]const u8 = null,
    session_info: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    email: ?[]const u8 = null,
    phone: ?[]const u8 = null,
    connection: ?Connection = null,
    bandwidths: std.ArrayList(Bandwidth),
    times: std.ArrayList(Time),
    media_descriptions: std.ArrayList(MediaDescription),
    attributes: std.ArrayList(Attribute),
    ice_ufrag: ?[]const u8 = null,
    ice_pwd: ?[]const u8 = null,
    fingerprint: ?Fingerprint = null,

    /// SDP 原点信息
    pub const Origin = struct {
        username: []const u8,
        session_id: u64,
        session_version: u64,
        nettype: []const u8 = "IN",
        addrtype: []const u8 = "IP4",
        address: []const u8,
    };

    /// 连接信息
    pub const Connection = struct {
        nettype: []const u8 = "IN",
        addrtype: []const u8 = "IP4",
        address: []const u8,
    };

    /// 带宽信息
    pub const Bandwidth = struct {
        type: []const u8, // CT, AS, etc.
        value: u32,
    };

    /// 时间信息
    pub const Time = struct {
        start: u64,
        stop: u64,
    };

    /// 媒体描述
    pub const MediaDescription = struct {
        media_type: []const u8, // audio, video
        port: u16,
        proto: []const u8, // RTP/AVP, UDP/TLS/RTP/SAVPF
        formats: std.ArrayList([]const u8), // payload types
        title: ?[]const u8 = null,
        connection: ?Connection = null,
        bandwidths: std.ArrayList(Bandwidth),
        attributes: std.ArrayList(Attribute),
    };

    /// 属性
    pub const Attribute = struct {
        name: []const u8,
        value: ?[]const u8 = null,
    };

    /// DTLS 指纹
    pub const Fingerprint = struct {
        hash: []const u8, // sha-256
        value: []const u8,
    };

    /// ICE Candidate
    pub const IceCandidate = struct {
        foundation: []const u8,
        component: u32, // 1 for RTP, 2 for RTCP
        transport: []const u8, // udp
        priority: u32,
        address: []const u8,
        port: u16,
        typ: []const u8, // host, srflx, relay
        rel_address: ?[]const u8 = null,
        rel_port: ?u16 = null,
    };

    /// 创建新的 SDP 实例
    pub fn init(alloc: allocator) Self {
        return .{
            .allocator = alloc,
            .bandwidths = std.ArrayList(Bandwidth).init(alloc),
            .times = std.ArrayList(Time).init(alloc),
            .media_descriptions = std.ArrayList(MediaDescription).init(alloc),
            .attributes = std.ArrayList(Attribute).init(alloc),
        };
    }

    /// 清理 SDP 资源
    pub fn deinit(self: *Self) void {
        if (self.origin) |*o| {
            self.allocator.free(o.username);
            self.allocator.free(o.nettype);
            self.allocator.free(o.addrtype);
            self.allocator.free(o.address);
        }
        if (self.session_name) |name| {
            self.allocator.free(name);
        }
        if (self.session_info) |info| {
            self.allocator.free(info);
        }
        if (self.uri) |u| {
            self.allocator.free(u);
        }
        if (self.email) |e| {
            self.allocator.free(e);
        }
        if (self.phone) |p| {
            self.allocator.free(p);
        }
        if (self.connection) |*conn| {
            self.allocator.free(conn.nettype);
            self.allocator.free(conn.addrtype);
            self.allocator.free(conn.address);
        }
        if (self.ice_ufrag) |ufrag| {
            self.allocator.free(ufrag);
        }
        if (self.ice_pwd) |pwd| {
            self.allocator.free(pwd);
        }
        if (self.fingerprint) |*fp| {
            self.allocator.free(fp.hash);
            self.allocator.free(fp.value);
        }

        for (self.bandwidths.items) |*bw| {
            self.allocator.free(bw.type);
        }
        self.bandwidths.deinit();

        for (self.media_descriptions.items) |*md| {
            self.allocator.free(md.media_type);
            self.allocator.free(md.proto);
            for (md.formats.items) |fmt| {
                self.allocator.free(fmt);
            }
            md.formats.deinit();
            if (md.title) |title| {
                self.allocator.free(title);
            }
            if (md.connection) |*conn| {
                self.allocator.free(conn.nettype);
                self.allocator.free(conn.addrtype);
                self.allocator.free(conn.address);
            }
            for (md.bandwidths.items) |*bw| {
                self.allocator.free(bw.type);
            }
            md.bandwidths.deinit();
            for (md.attributes.items) |*attr| {
                self.allocator.free(attr.name);
                if (attr.value) |val| {
                    self.allocator.free(val);
                }
            }
            md.attributes.deinit();
        }
        self.media_descriptions.deinit();

        for (self.attributes.items) |*attr| {
            self.allocator.free(attr.name);
            if (attr.value) |val| {
                self.allocator.free(val);
            }
        }
        self.attributes.deinit();
    }

    /// 解析 SDP 字符串
    pub fn parse(alloc: allocator, sdp_text: []const u8) !Self {
        var sdp = Self.init(alloc);
        errdefer sdp.deinit();

        var lines = std.mem.splitScalar(u8, sdp_text, '\n');
        var current_media: ?*MediaDescription = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r");
            if (trimmed.len < 2) continue;

            const field = trimmed[0];
            const value = trimmed[2..];

            switch (field) {
                'v' => {
                    // Version
                    sdp.version = try std.fmt.parseInt(u32, value, 10);
                },
                'o' => {
                    // Origin
                    var parts = std.mem.splitScalar(u8, value, ' ');
                    const username = parts.next() orelse return error.InvalidSdp;
                    const session_id = parts.next() orelse return error.InvalidSdp;
                    const session_version = parts.next() orelse return error.InvalidSdp;
                    const nettype = parts.next() orelse return error.InvalidSdp;
                    const addrtype = parts.next() orelse return error.InvalidSdp;
                    const address = parts.rest();

                    sdp.origin = Origin{
                        .username = try alloc.dupe(u8, username),
                        .session_id = try std.fmt.parseInt(u64, session_id, 10),
                        .session_version = try std.fmt.parseInt(u64, session_version, 10),
                        .nettype = try alloc.dupe(u8, nettype),
                        .addrtype = try alloc.dupe(u8, addrtype),
                        .address = try alloc.dupe(u8, address),
                    };
                },
                's' => {
                    // Session name
                    sdp.session_name = try alloc.dupe(u8, value);
                },
                'i' => {
                    // Session info
                    sdp.session_info = try alloc.dupe(u8, value);
                },
                'u' => {
                    // URI
                    sdp.uri = try alloc.dupe(u8, value);
                },
                'e' => {
                    // Email
                    sdp.email = try alloc.dupe(u8, value);
                },
                'p' => {
                    // Phone
                    sdp.phone = try alloc.dupe(u8, value);
                },
                'c' => {
                    // Connection
                    var parts = std.mem.splitScalar(u8, value, ' ');
                    const nettype = parts.next() orelse return error.InvalidSdp;
                    const addrtype = parts.next() orelse return error.InvalidSdp;
                    const address = parts.rest();

                    const conn = Connection{
                        .nettype = try alloc.dupe(u8, nettype),
                        .addrtype = try alloc.dupe(u8, addrtype),
                        .address = try alloc.dupe(u8, address),
                    };

                    if (current_media) |md| {
                        md.connection = conn;
                    } else {
                        sdp.connection = conn;
                    }
                },
                'b' => {
                    // Bandwidth
                    const colon = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidSdp;
                    const bw_type = try alloc.dupe(u8, value[0..colon]);
                    const val_str = value[colon + 1 ..];
                    const val = try std.fmt.parseInt(u32, val_str, 10);

                    const bw = Bandwidth{
                        .type = bw_type,
                        .value = val,
                    };

                    if (current_media) |md| {
                        try md.bandwidths.append(bw);
                    } else {
                        try sdp.bandwidths.append(bw);
                    }
                },
                't' => {
                    // Timing
                    var parts = std.mem.splitScalar(u8, value, ' ');
                    const start = parts.next() orelse return error.InvalidSdp;
                    const stop = parts.next() orelse return error.InvalidSdp;

                    try sdp.times.append(Time{
                        .start = try std.fmt.parseInt(u64, start, 10),
                        .stop = try std.fmt.parseInt(u64, stop, 10),
                    });
                },
                'm' => {
                    // Media
                    var parts = std.mem.splitScalar(u8, value, ' ');
                    const media_type_str = parts.next() orelse return error.InvalidSdp;
                    const port_str = parts.next() orelse return error.InvalidSdp;
                    const proto_str = parts.next() orelse return error.InvalidSdp;

                    var formats = std.ArrayList([]const u8).init(alloc);
                    while (parts.next()) |fmt| {
                        try formats.append(try alloc.dupe(u8, fmt));
                    }

                    const md = MediaDescription{
                        .media_type = try alloc.dupe(u8, media_type_str),
                        .port = try std.fmt.parseInt(u16, port_str, 10),
                        .proto = try alloc.dupe(u8, proto_str),
                        .formats = formats,
                        .bandwidths = std.ArrayList(Bandwidth).init(alloc),
                        .attributes = std.ArrayList(Attribute).init(alloc),
                    };
                    try sdp.media_descriptions.append(md);
                    current_media = &sdp.media_descriptions.items[sdp.media_descriptions.items.len - 1];
                },
                'a' => {
                    // Attribute
                    const colon = std.mem.indexOfScalar(u8, value, ':');
                    const name = if (colon) |c| value[0..c] else value;
                    const attr_value = if (colon) |c| value[c + 1 ..] else null;

                    const attr = Attribute{
                        .name = try alloc.dupe(u8, name),
                        .value = if (attr_value) |v| try alloc.dupe(u8, v) else null,
                    };

                    // 解析特殊属性
                    if (std.mem.eql(u8, name, "ice-ufrag")) {
                        if (attr_value) |v| {
                            if (current_media == null) {
                                sdp.ice_ufrag = try alloc.dupe(u8, v);
                            }
                        }
                    } else if (std.mem.eql(u8, name, "ice-pwd")) {
                        if (attr_value) |v| {
                            if (current_media == null) {
                                sdp.ice_pwd = try alloc.dupe(u8, v);
                            }
                        }
                    } else if (std.mem.eql(u8, name, "fingerprint")) {
                        if (attr_value) |v| {
                            var fp_parts = std.mem.splitScalar(u8, v, ' ');
                            const hash = fp_parts.next() orelse return error.InvalidSdp;
                            const fp_value = fp_parts.rest();
                            sdp.fingerprint = Fingerprint{
                                .hash = try alloc.dupe(u8, hash),
                                .value = try alloc.dupe(u8, fp_value),
                            };
                        }
                    } else if (std.mem.eql(u8, name, "candidate")) {
                        // ICE candidate will be parsed separately
                    }

                    if (current_media) |md| {
                        try md.attributes.append(attr);
                    } else {
                        try sdp.attributes.append(attr);
                    }
                },
                else => {
                    // 忽略未知字段
                },
            }
        }

        return sdp;
    }

    /// 生成 SDP 字符串
    pub fn generate(self: *const Self) ![]u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        errdefer result.deinit();

        var writer = result.writer();

        // Version
        if (self.version) |v| {
            try writer.print("v={}\r\n", .{v});
        } else {
            try writer.print("v=0\r\n", .{});
        }

        // Origin
        if (self.origin) |o| {
            try writer.print("o={s} {} {} {s} {s} {s}\r\n", .{
                o.username,
                o.session_id,
                o.session_version,
                o.nettype,
                o.addrtype,
                o.address,
            });
        }

        // Session name
        if (self.session_name) |name| {
            try writer.print("s={s}\r\n", .{name});
        } else {
            try writer.print("s=-\r\n", .{});
        }

        // Session info
        if (self.session_info) |info| {
            try writer.print("i={s}\r\n", .{info});
        }

        // URI
        if (self.uri) |u| {
            try writer.print("u={s}\r\n", .{u});
        }

        // Email
        if (self.email) |e| {
            try writer.print("e={s}\r\n", .{e});
        }

        // Phone
        if (self.phone) |p| {
            try writer.print("p={s}\r\n", .{p});
        }

        // Connection
        if (self.connection) |c| {
            try writer.print("c={s} {s} {s}\r\n", .{ c.nettype, c.addrtype, c.address });
        }

        // Bandwidths
        for (self.bandwidths.items) |bw| {
            try writer.print("b={s}:{}\r\n", .{ bw.type, bw.value });
        }

        // Timing
        if (self.times.items.len > 0) {
            for (self.times.items) |time| {
                try writer.print("t={} {}\r\n", .{ time.start, time.stop });
            }
        } else {
            try writer.print("t=0 0\r\n", .{});
        }

        // Attributes (session level)
        if (self.ice_ufrag) |ufrag| {
            try writer.print("a=ice-ufrag:{s}\r\n", .{ufrag});
        }
        if (self.ice_pwd) |pwd| {
            try writer.print("a=ice-pwd:{s}\r\n", .{pwd});
        }
        if (self.fingerprint) |fp| {
            try writer.print("a=fingerprint:{s} {s}\r\n", .{ fp.hash, fp.value });
        }

        for (self.attributes.items) |attr| {
            if (attr.value) |val| {
                try writer.print("a={s}:{s}\r\n", .{ attr.name, val });
            } else {
                try writer.print("a={s}\r\n", .{attr.name});
            }
        }

        // Media descriptions
        for (self.media_descriptions.items) |md| {
            // Media line
            var formats_str = std.ArrayList(u8).init(self.allocator);
            defer formats_str.deinit();
            for (md.formats.items, 0..) |fmt, i| {
                if (i > 0) try formats_str.writer().writeByte(' ');
                try formats_str.writer().print("{s}", .{fmt});
            }
            try writer.print("m={s} {} {s} {s}\r\n", .{
                md.media_type,
                md.port,
                md.proto,
                formats_str.items,
            });

            // Media title
            if (md.title) |title| {
                try writer.print("i={s}\r\n", .{title});
            }

            // Media connection
            if (md.connection) |c| {
                try writer.print("c={s} {s} {s}\r\n", .{ c.nettype, c.addrtype, c.address });
            }

            // Media bandwidths
            for (md.bandwidths.items) |bw| {
                try writer.print("b={s}:{}\r\n", .{ bw.type, bw.value });
            }

            // Media attributes
            for (md.attributes.items) |attr| {
                if (attr.value) |val| {
                    try writer.print("a={s}:{s}\r\n", .{ attr.name, val });
                } else {
                    try writer.print("a={s}\r\n", .{attr.name});
                }
            }
        }

        return result.toOwnedSlice();
    }

    /// 解析 ICE candidate 字符串
    pub fn parseIceCandidate(candidate_str: []const u8, alloc: allocator) !IceCandidate {
        // candidate format: foundation component transport priority address port typ type-value [rel-address] [rel-port]
        var parts = std.mem.splitScalar(u8, candidate_str, ' ');

        _ = parts.next(); // Skip "candidate" keyword

        const foundation = parts.next() orelse return error.InvalidCandidate;
        const component_str = parts.next() orelse return error.InvalidCandidate;
        const transport = parts.next() orelse return error.InvalidCandidate;
        const priority_str = parts.next() orelse return error.InvalidCandidate;
        const address = parts.next() orelse return error.InvalidCandidate;
        const port_str = parts.next() orelse return error.InvalidCandidate;
        _ = parts.next(); // Skip "typ" keyword
        const typ = parts.next() orelse return error.InvalidCandidate;

        var candidate = IceCandidate{
            .foundation = try alloc.dupe(u8, foundation),
            .component = try std.fmt.parseInt(u32, component_str, 10),
            .transport = try alloc.dupe(u8, transport),
            .priority = try std.fmt.parseInt(u32, priority_str, 10),
            .address = try alloc.dupe(u8, address),
            .port = try std.fmt.parseInt(u16, port_str, 10),
            .typ = try alloc.dupe(u8, typ),
        };

        // Optional rel-address and rel-port
        if (parts.next()) |rel_addr| {
            candidate.rel_address = try alloc.dupe(u8, rel_addr);
            if (parts.next()) |rel_port_str| {
                candidate.rel_port = try std.fmt.parseInt(u16, rel_port_str, 10);
            }
        }

        return candidate;
    }

    /// 生成 ICE candidate 字符串
    pub fn formatIceCandidate(candidate: IceCandidate, writer: anytype) !void {
        try writer.print("a=candidate:{} {} {} {} {} {} {}", .{
            candidate.foundation,
            candidate.component,
            candidate.transport,
            candidate.priority,
            candidate.address,
            candidate.port,
            candidate.typ,
        });
        if (candidate.rel_address) |rel_addr| {
            try writer.print(" {} {}", .{ rel_addr, candidate.rel_port orelse 0 });
        }
        try writer.print("\r\n", .{});
    }

    pub const Error = error{
        InvalidSdp,
        InvalidCandidate,
        OutOfMemory,
    };
};
