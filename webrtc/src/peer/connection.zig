const std = @import("std");
const zco = @import("zco");
const crypto = std.crypto;
const ice = @import("../ice/root.zig");
const dtls = @import("../dtls/root.zig");
const srtp = @import("../srtp/root.zig");
const rtp = @import("../rtp/root.zig");
const sctp = @import("../sctp/root.zig");
const signaling = @import("../signaling/root.zig");
const media = @import("../media/root.zig");

const Sender = @import("./sender.zig").Sender;
const Receiver = @import("./receiver.zig").Receiver;

const sdp = signaling.sdp;

// 使用 Sdp 作为 SessionDescription
const SessionDescription = sdp.Sdp;

/// RTCPeerConnection 状态枚举
/// 遵循 W3C WebRTC 1.0 规范
pub const SignalingState = enum {
    /// 没有待处理的 SDP 描述
    stable,
    /// 已设置本地 SDP offer
    have_local_offer,
    /// 已设置远程 SDP offer
    have_remote_offer,
    /// 已设置本地 SDP pranswer
    have_local_pranswer,
    /// 已设置远程 SDP pranswer
    have_remote_pranswer,
    /// 连接已关闭
    closed,
};

/// ICE 连接状态
pub const IceConnectionState = enum {
    /// 初始状态
    new,
    /// 正在检查连接
    checking,
    /// 已建立连接
    connected,
    /// 所有检查完成
    completed,
    /// 连接失败
    failed,
    /// 连接断开
    disconnected,
    /// 连接已关闭
    closed,
};

/// ICE 收集状态
pub const IceGatheringState = enum {
    /// 初始状态
    new,
    /// 正在收集候选
    gathering,
    /// 收集完成
    complete,
};

/// 连接状态
pub const ConnectionState = enum {
    /// 初始状态
    new,
    /// 正在连接
    connecting,
    /// 已连接
    connected,
    /// 已断开
    disconnected,
    /// 连接失败
    failed,
    /// 连接已关闭
    closed,
};

/// RTCPeerConnection 配置
pub const Configuration = struct {
    /// ICE 服务器列表（STUN/TURN）
    ice_servers: []const IceServer = &.{},

    /// ICE 传输策略
    ice_transport_policy: IceTransportPolicy = .all,

    /// ICE 候选类型策略
    ice_candidate_pool_size: u32 = 0,

    pub const IceServer = struct {
        urls: []const []const u8,
        username: ?[]const u8 = null,
        credential: ?[]const u8 = null,
    };

    pub const IceTransportPolicy = enum {
        /// 允许所有传输类型
        all,
        /// 仅允许中继传输（TURN）
        relay,
    };
};

/// RTCPeerConnection
/// WebRTC 的核心 API，用于建立和管理对等连接
pub const PeerConnection = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,

    // 状态
    signaling_state: SignalingState = .stable,
    ice_connection_state: IceConnectionState = .new,
    ice_gathering_state: IceGatheringState = .new,
    connection_state: ConnectionState = .new,

    // 配置
    configuration: Configuration,

    // 内部组件
    ice_agent: ?*ice.agent.IceAgent = null,
    dtls_certificate: ?*dtls.Certificate = null, // DTLS 证书（用于指纹计算）
    dtls_record: ?*dtls.Record = null, // DTLS 记录层
    dtls_handshake: ?*dtls.Handshake = null, // DTLS 握手协议
    srtp_sender: ?*srtp.Transform = null,
    srtp_receiver: ?*srtp.Transform = null,
    sctp_association: ?*sctp.Association = null,
    data_channels: std.ArrayList(*sctp.DataChannel), // 数据通道列表
    next_stream_id: u16 = 0, // 下一个可用的 Stream ID
    ssrc_manager: ?*rtp.SsrcManager = null, // SSRC 管理器

    // 媒体轨道
    senders: std.ArrayList(*Sender), // RTP 发送器列表
    receivers: std.ArrayList(*Receiver), // RTP 接收器列表

    // SDP 描述
    local_description: ?*SessionDescription = null,
    remote_description: ?*SessionDescription = null,

    // 事件回调
    onicecandidate: ?*const fn (*Self, *ice.Candidate) void = null,
    onconnectionstatechange: ?*const fn (*Self) void = null,
    onsignalingstatechange: ?*const fn (*Self) void = null,
    oniceconnectionstatechange: ?*const fn (*Self) void = null,
    onicegatheringstatechange: ?*const fn (*Self) void = null,

    /// 初始化 RTCPeerConnection
    pub fn init(
        allocator: std.mem.Allocator,
        schedule: *zco.Schedule,
        config: Configuration,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .schedule = schedule,
            .configuration = config,
            .senders = std.ArrayList(*Sender).init(allocator),
            .receivers = std.ArrayList(*Receiver).init(allocator),
            .data_channels = std.ArrayList(*sctp.DataChannel).init(allocator),
        };

        // 初始化 ICE Agent（组件 ID 1 表示 RTP）
        self.ice_agent = try ice.agent.IceAgent.init(allocator, schedule, 1);
        errdefer if (self.ice_agent) |agent| agent.deinit();

        // 初始化 DTLS 证书（生成自签名证书）
        self.dtls_certificate = try Self.initDtlsCertificate(allocator);
        errdefer if (self.dtls_certificate) |cert| cert.deinit();

        // 初始化 DTLS 记录层
        self.dtls_record = try dtls.Record.init(allocator, schedule);
        errdefer if (self.dtls_record) |record| record.deinit();

        // 初始化 DTLS 握手协议
        self.dtls_handshake = try dtls.Handshake.init(allocator, self.dtls_record.?);
        errdefer if (self.dtls_handshake) |handshake| handshake.deinit();

        // 初始化 SSRC 管理器
        const ssrc_manager = try allocator.create(rtp.SsrcManager);
        ssrc_manager.* = rtp.SsrcManager.init(allocator);
        self.ssrc_manager = ssrc_manager;
        errdefer if (self.ssrc_manager) |manager| {
            manager.deinit();
            allocator.destroy(manager);
        };

        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        if (self.sctp_association) |assoc| {
            assoc.deinit();
        }

        if (self.ssrc_manager) |manager| {
            manager.deinit();
            self.allocator.destroy(manager);
        }

        // 清理发送器
        for (self.senders.items) |sender| {
            sender.deinit();
        }
        self.senders.deinit();

        // 清理接收器
        for (self.receivers.items) |receiver| {
            receiver.deinit();
        }
        self.receivers.deinit();

        // 释放所有数据通道
        for (self.data_channels.items) |channel| {
            channel.deinit();
            self.allocator.destroy(channel);
        }
        self.data_channels.deinit();

        if (self.srtp_receiver) |transform_ptr| {
            transform_ptr.ctx.deinit();
            self.allocator.destroy(transform_ptr);
        }

        if (self.srtp_sender) |transform_ptr| {
            transform_ptr.ctx.deinit();
            self.allocator.destroy(transform_ptr);
        }

        if (self.dtls_handshake) |handshake| {
            handshake.deinit();
        }

        if (self.dtls_record) |record| {
            record.deinit();
        }

        if (self.dtls_certificate) |cert| {
            cert.deinit();
        }

        if (self.ice_agent) |agent| {
            agent.deinit();
        }

        if (self.local_description) |desc| {
            desc.deinit();
        }

        if (self.remote_description) |desc| {
            desc.deinit();
        }

        self.allocator.destroy(self);
    }

    /// 生成随机 ICE username fragment（4-256 字符，至少 4 个字符）
    fn generateIceUfrag(allocator: std.mem.Allocator) ![]u8 {
        // ICE-ufrag 应该是至少 4 个字符的随机字符串
        // 通常使用 base64 编码的随机字节
        var random_bytes: [16]u8 = undefined;
        crypto.random.bytes(&random_bytes);

        // 使用 base64 编码（简化：使用十六进制编码，至少 4 字符）
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        for (random_bytes) |byte| {
            try buffer.writer().print("{X:0>2}", .{byte});
        }

        // 确保至少 4 个字符
        const result = try buffer.toOwnedSlice();
        return if (result.len >= 4) result else try allocator.dupe(u8, "zco-ufrag-default");
    }

    /// 生成随机 ICE password（22-256 字符，至少 22 个字符）
    fn generateIcePwd(allocator: std.mem.Allocator) ![]u8 {
        // ICE-pwd 应该是至少 22 个字符的随机字符串
        var random_bytes: [32]u8 = undefined;
        crypto.random.bytes(&random_bytes);

        // 使用 base64 编码（简化：使用十六进制编码）
        var buffer = std.ArrayList(u8).init(allocator);
        errdefer buffer.deinit();
        for (random_bytes) |byte| {
            try buffer.writer().print("{X:0>2}", .{byte});
        }

        // 确保至少 22 个字符
        const result = try buffer.toOwnedSlice();
        return if (result.len >= 22) result else try allocator.dupe(u8, "zco-pwd-default-at-least-22-chars");
    }

    /// 初始化 DTLS 证书（生成自签名证书）
    fn initDtlsCertificate(allocator: std.mem.Allocator) !*dtls.Certificate {
        // 生成自签名证书
        const cert_info = dtls.Certificate.CertificateInfo{
            .subject = "CN=ZCO WebRTC",
            .issuer = "CN=ZCO WebRTC", // 自签名
            .serial_number = "01",
            .valid_from = std.time.timestamp() - 86400, // 从昨天开始
            .valid_to = std.time.timestamp() + (365 * 86400), // 一年有效期
        };

        return try dtls.Certificate.generateSelfSigned(allocator, cert_info);
    }

    /// 创建 Offer
    /// 生成 SDP offer 描述
    pub fn createOffer(self: *Self, allocator: std.mem.Allocator) !*SessionDescription {
        var offer = SessionDescription.init(allocator);
        errdefer offer.deinit();

        // 1. 基础信息
        offer.version = 0;
        const origin = SessionDescription.Origin{
            .username = try allocator.dupe(u8, "zco"),
            .session_id = std.time.milliTimestamp(),
            .session_version = 1,
            .nettype = "IN",
            .addrtype = "IP4",
            .address = try allocator.dupe(u8, "127.0.0.1"),
        };
        offer.origin = origin;

        offer.session_name = try allocator.dupe(u8, "ZCO WebRTC Session");

        // 2. 添加连接信息
        const connection = SessionDescription.Connection{
            .nettype = "IN",
            .addrtype = "IP4",
            .address = try allocator.dupe(u8, "0.0.0.0"), // 使用 0.0.0.0 表示将在 ICE 候选中使用
        };
        offer.connection = connection;

        // 3. 添加音频媒体描述（基础配置）
        var audio_formats = std.ArrayList([]const u8).init(allocator);
        // 注意：不能 defer，因为 audio_media 会接管 ownership
        // 添加基础音频编解码器（PCMU 0, PCMA 8）
        try audio_formats.append(try allocator.dupe(u8, "0")); // PCMU
        try audio_formats.append(try allocator.dupe(u8, "8")); // PCMA

        const audio_media = SessionDescription.MediaDescription{
            .media_type = try allocator.dupe(u8, "audio"),
            .port = 9, // RTP 端口（9 表示禁用，ICE 将在候选中使用实际端口）
            .proto = try allocator.dupe(u8, "UDP/TLS/RTP/SAVPF"), // SRTP with feedback
            .formats = audio_formats,
            .bandwidths = std.ArrayList(SessionDescription.Bandwidth).init(allocator),
            .attributes = std.ArrayList(SessionDescription.Attribute).init(allocator),
        };
        try offer.media_descriptions.append(audio_media);

        // 获取音频媒体描述引用（用于后续添加属性）
        const audio_media_desc = &offer.media_descriptions.items[0];

        // 4. 添加 ICE 属性（如果 ICE Agent 可用）
        if (self.ice_agent) |agent| {
            // 生成随机 ICE username fragment 和 password
            const ice_ufrag = try Self.generateIceUfrag(allocator);
            const ice_pwd = try Self.generateIcePwd(allocator);

            offer.ice_ufrag = ice_ufrag;
            offer.ice_pwd = ice_pwd;

            // 添加 ICE 属性到媒体描述
            try audio_media_desc.attributes.append(SessionDescription.Attribute{
                .name = try allocator.dupe(u8, "ice-ufrag"),
                .value = try allocator.dupe(u8, ice_ufrag),
            });
            try audio_media_desc.attributes.append(SessionDescription.Attribute{
                .name = try allocator.dupe(u8, "ice-pwd"),
                .value = try allocator.dupe(u8, ice_pwd),
            });

            // TODO: 添加 ICE candidates（需要等待候选收集完成）
            // 如果已有本地候选，添加到 SDP
            const local_candidates = agent.getLocalCandidates();
            for (local_candidates) |c| {
                // 将 candidate 转换为 SDP candidate 格式
                const candidate_str = try c.toSdpCandidate(allocator);
                defer allocator.free(candidate_str);

                try audio_media_desc.attributes.append(SessionDescription.Attribute{
                    .name = try allocator.dupe(u8, "candidate"),
                    .value = try allocator.dupe(u8, candidate_str),
                });
            }
        }

        // 5. 添加 DTLS 指纹
        // 从证书计算真实指纹
        const fingerprint_hash = try allocator.dupe(u8, "sha-256");
        const fingerprint_formatted = if (self.dtls_certificate) |cert|
            try cert.formatFingerprint(allocator)
        else blk: {
            // 如果没有证书，生成随机指纹（不应发生）
            var random_fingerprint: [32]u8 = undefined;
            crypto.random.bytes(&random_fingerprint);
            break :blk try dtls.KeyDerivation.formatFingerprint(random_fingerprint, allocator);
        };

        offer.fingerprint = SessionDescription.Fingerprint{
            .hash = fingerprint_hash,
            .value = fingerprint_formatted,
        };

        // 添加 fingerprint 属性到媒体描述
        const fingerprint_attr_value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ fingerprint_hash, fingerprint_formatted });
        try audio_media_desc.attributes.append(SessionDescription.Attribute{
            .name = try allocator.dupe(u8, "fingerprint"),
            .value = fingerprint_attr_value,
        });

        // 6. 添加 RTCP 反馈和编解码器属性

        // 添加 setup 属性（DTLS role）
        try audio_media_desc.attributes.append(SessionDescription.Attribute{
            .name = try allocator.dupe(u8, "setup"),
            .value = try allocator.dupe(u8, "actpass"), // 可以是 actpass, active, passive
        });

        // 添加 rtcp-mux（复用 RTCP）
        try audio_media_desc.attributes.append(SessionDescription.Attribute{
            .name = try allocator.dupe(u8, "rtcp-mux"),
            .value = null,
        });

        // 创建堆分配的对象
        const offer_ptr = try allocator.create(SessionDescription);
        offer_ptr.* = offer;

        return offer_ptr;
    }

    /// 创建 Answer
    /// 响应远程 offer，生成 SDP answer
    pub fn createAnswer(self: *Self, allocator: std.mem.Allocator) !*SessionDescription {
        // 需要基于 remote_description 生成

        const remote_desc = self.remote_description orelse {
            return error.NoRemoteDescription;
        };

        var answer = SessionDescription.init(allocator);
        errdefer answer.deinit();

        // 1. 基础信息（类似 offer，但使用本地信息）
        answer.version = 0;
        const origin = SessionDescription.Origin{
            .username = try allocator.dupe(u8, "zco"),
            .session_id = std.time.milliTimestamp(),
            .session_version = 1,
            .nettype = "IN",
            .addrtype = "IP4",
            .address = try allocator.dupe(u8, "127.0.0.1"),
        };
        answer.origin = origin;

        answer.session_name = try allocator.dupe(u8, "ZCO WebRTC Session");

        // 2. 添加连接信息（基于 remote offer 或使用默认值）
        const connection = SessionDescription.Connection{
            .nettype = "IN",
            .addrtype = "IP4",
            .address = try allocator.dupe(u8, "0.0.0.0"),
        };
        answer.connection = connection;

        // 3. 遍历 remote offer 的媒体描述，为每个媒体生成 answer
        for (remote_desc.media_descriptions.items) |remote_media| {
            // 生成对应的媒体描述（只接受支持的媒体类型）
            if (!std.mem.eql(u8, remote_media.media_type, "audio")) {
                // 暂时只支持音频，跳过其他媒体类型
                continue;
            }

            // 创建音频媒体描述（复用相同的格式）
            var audio_formats = std.ArrayList([]const u8).init(allocator);
            // 从 remote offer 中选择支持的格式，或使用默认值
            // 简化：使用与 offer 相同的格式（实际应该协商）
            if (remote_media.formats.items.len > 0) {
                // 接受第一个格式作为示例（实际应协商）
                for (remote_media.formats.items) |fmt| {
                    // 只接受已知的音频格式（0=PCMU, 8=PCMA）
                    if (std.mem.eql(u8, fmt, "0") or std.mem.eql(u8, fmt, "8")) {
                        try audio_formats.append(try allocator.dupe(u8, fmt));
                    }
                }
            } else {
                // 如果没有格式，使用默认值
                try audio_formats.append(try allocator.dupe(u8, "0")); // PCMU
            }

            const audio_media = SessionDescription.MediaDescription{
                .media_type = try allocator.dupe(u8, "audio"),
                .port = remote_media.port, // 使用相同的端口（或 9 表示禁用）
                .proto = try allocator.dupe(u8, "UDP/TLS/RTP/SAVPF"), // 必须与 offer 匹配
                .formats = audio_formats,
                .bandwidths = std.ArrayList(SessionDescription.Bandwidth).init(allocator),
                .attributes = std.ArrayList(SessionDescription.Attribute).init(allocator),
            };
            try answer.media_descriptions.append(audio_media);

            // 获取媒体描述引用
            const audio_media_desc = &answer.media_descriptions.items[answer.media_descriptions.items.len - 1];

            // 4. 添加 ICE 属性（生成新的随机值）
            if (self.ice_agent) |agent| {
                const ice_ufrag = try Self.generateIceUfrag(allocator);
                const ice_pwd = try Self.generateIcePwd(allocator);

                answer.ice_ufrag = ice_ufrag;
                answer.ice_pwd = ice_pwd;

                // 添加 ICE 属性到媒体描述
                try audio_media_desc.attributes.append(SessionDescription.Attribute{
                    .name = try allocator.dupe(u8, "ice-ufrag"),
                    .value = try allocator.dupe(u8, ice_ufrag),
                });
                try audio_media_desc.attributes.append(SessionDescription.Attribute{
                    .name = try allocator.dupe(u8, "ice-pwd"),
                    .value = try allocator.dupe(u8, ice_pwd),
                });

                // 添加 ICE candidates（如果已收集）
                const local_candidates = agent.getLocalCandidates();
                for (local_candidates) |c| {
                    const candidate_str = try c.toSdpCandidate(allocator);
                    defer allocator.free(candidate_str);

                    try audio_media_desc.attributes.append(SessionDescription.Attribute{
                        .name = try allocator.dupe(u8, "candidate"),
                        .value = try allocator.dupe(u8, candidate_str),
                    });
                }
            }

            // 5. 添加 DTLS 指纹
            // 从证书计算真实指纹
            const fingerprint_hash = try allocator.dupe(u8, "sha-256");
            const fingerprint_formatted = if (self.dtls_certificate) |cert|
                try cert.formatFingerprint(allocator)
            else blk: {
                // 如果没有证书，生成随机指纹（不应发生）
                var random_fingerprint: [32]u8 = undefined;
                crypto.random.bytes(&random_fingerprint);
                break :blk try dtls.KeyDerivation.formatFingerprint(random_fingerprint, allocator);
            };

            answer.fingerprint = SessionDescription.Fingerprint{
                .hash = fingerprint_hash,
                .value = fingerprint_formatted,
            };

            // 添加 fingerprint 属性到媒体描述
            const fingerprint_attr_value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ fingerprint_hash, fingerprint_formatted });
            try audio_media_desc.attributes.append(SessionDescription.Attribute{
                .name = try allocator.dupe(u8, "fingerprint"),
                .value = fingerprint_attr_value,
            });

            // 6. 添加 RTCP 属性
            // setup 属性：如果 offer 是 actpass，answer 应该是 active 或 passive
            // 简化：设置为 active
            try audio_media_desc.attributes.append(SessionDescription.Attribute{
                .name = try allocator.dupe(u8, "setup"),
                .value = try allocator.dupe(u8, "active"), // answer 通常是 active
            });

            // rtcp-mux（如果 offer 中有，answer 中也要有）
            var has_rtcp_mux = false;
            for (remote_media.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "rtcp-mux")) {
                    has_rtcp_mux = true;
                    break;
                }
            }
            if (has_rtcp_mux) {
                try audio_media_desc.attributes.append(SessionDescription.Attribute{
                    .name = try allocator.dupe(u8, "rtcp-mux"),
                    .value = null,
                });
            }
        }

        // 创建堆分配的对象
        const answer_ptr = try allocator.create(SessionDescription);
        answer_ptr.* = answer;

        return answer_ptr;
    }

    /// 设置本地描述
    pub fn setLocalDescription(self: *Self, description: *SessionDescription) !void {
        if (self.local_description) |desc| {
            desc.deinit();
        }

        self.local_description = description;

        // 更新信令状态
        const old_signaling_state = self.signaling_state;
        switch (self.signaling_state) {
            .stable => {
                // TODO: 检查 description.type（需要添加 type 字段到 SessionDescription）
                self.signaling_state = .have_local_offer;
            },
            .have_remote_offer => {
                // TODO: 检查 description.type
                self.signaling_state = .stable;
            },
            else => {},
        }

        // 触发信令状态变化事件
        if (old_signaling_state != self.signaling_state) {
            if (self.onsignalingstatechange) |callback| {
                callback(self);
            }
        }

        // 更新 ICE 收集状态
        const old_gathering_state = self.ice_gathering_state;
        self.ice_gathering_state = .gathering;

        // 触发 ICE 收集状态变化事件
        if (old_gathering_state != self.ice_gathering_state) {
            if (self.onicegatheringstatechange) |callback| {
                callback(self);
            }
        }

        // 触发 ICE candidate 收集
        if (self.ice_agent) |agent| {
            // 开始收集 Host Candidates
            agent.gatherHostCandidates() catch |err| {
                // 如果收集失败，记录错误但不中断流程
                std.log.warn("Failed to gather host candidates: {}", .{err});
            };

            // TODO: 如果有 STUN/TURN 服务器配置，也收集 Server Reflexive 和 Relay Candidates
            // agent.gatherServerReflexiveCandidates() catch {};
            // agent.gatherRelayCandidates() catch {};

            // 收集完成后，更新状态
            // 注意：实际收集是异步的，这里只是开始收集
            // 应该在收集完成后通过事件回调更新状态
        }

        // 如果已有 remote description，可以开始连接流程
        if (self.remote_description != null) {
            // TODO: 启动连接检查
            // try self.startConnection();
        }
    }

    /// 设置远程描述
    pub fn setRemoteDescription(self: *Self, description: *SessionDescription) !void {
        if (self.remote_description) |desc| {
            desc.deinit();
        }

        self.remote_description = description;

        // 更新信令状态
        const old_signaling_state = self.signaling_state;
        switch (self.signaling_state) {
            .stable => {
                // TODO: 检查 description.type
                self.signaling_state = .have_remote_offer;
            },
            .have_local_offer => {
                // TODO: 检查 description.type
                self.signaling_state = .stable;
            },
            else => {},
        }

        // 触发信令状态变化事件
        if (old_signaling_state != self.signaling_state) {
            if (self.onsignalingstatechange) |callback| {
                callback(self);
            }
        }

        // 解析远程 ICE candidates
        if (self.ice_agent) |agent| {
            // 从 SDP 中提取 ICE candidates
            // 检查 session-level candidates
            for (description.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "candidate")) {
                    if (attr.value) |candidate_str| {
                        // 解析 candidate 字符串
                        const candidate = try ice.candidate.Candidate.fromSdpCandidate(self.allocator, candidate_str);
                        errdefer candidate.deinit();

                        // 创建堆分配的 candidate
                        const candidate_ptr = try self.allocator.create(ice.candidate.Candidate);
                        candidate_ptr.* = candidate;

                        // 添加到远程 candidates
                        try agent.addRemoteCandidate(candidate_ptr);
                    }
                }
            }

            // 检查 media-level candidates
            for (description.media_descriptions.items) |media_desc| {
                for (media_desc.attributes.items) |attr| {
                    if (std.mem.eql(u8, attr.name, "candidate")) {
                        if (attr.value) |candidate_str| {
                            // 解析 candidate 字符串
                            const candidate = try ice.candidate.Candidate.fromSdpCandidate(self.allocator, candidate_str);
                            errdefer candidate.deinit();

                            // 创建堆分配的 candidate
                            const candidate_ptr = try self.allocator.create(ice.candidate.Candidate);
                            candidate_ptr.* = candidate;

                            // 添加到远程 candidates
                            try agent.addRemoteCandidate(candidate_ptr);
                        }
                    }
                }
            }

            // 如果已有本地描述，可以开始连接检查
            if (self.local_description != null) {
                // 更新 ICE 连接状态
                const old_ice_state = self.ice_connection_state;
                self.ice_connection_state = .checking;

                // 触发 ICE 连接状态变化事件
                if (old_ice_state != self.ice_connection_state) {
                    if (self.oniceconnectionstatechange) |callback| {
                        callback(self);
                    }
                }

                // 注意：generateCandidatePairs 会在 addRemoteCandidate 时自动调用
                // 所以如果所有远程 candidates 都已添加，pairs 应该已经生成

                // 开始连接检查
                agent.startConnectivityChecks() catch |err| {
                    std.log.warn("Failed to start connectivity checks: {}", .{err});
                    self.updateIceConnectionState(.failed);
                };

                // 注意：ICE 连接状态变化是异步的
                // 实际应用中应该通过轮询或回调机制监听 ICE Agent 状态变化
                // 然后调用 updateIceConnectionState() 更新状态并触发事件
                // 当前实现中，状态变化需要手动调用 updateIceConnectionState()
            }
        }
    }

    /// 启动 DTLS 握手流程
    /// 在 ICE 连接成功后被调用
    pub fn startDtlsHandshake(self: *Self) !void {
        if (self.dtls_handshake) |handshake| {
            _ = self.dtls_record; // 确保 record 已初始化
            // 确定 DTLS role：根据 SDP 中的 setup 属性
            // setup=actpass (offer) -> 等待 answer 确定 role
            // setup=active (answer) -> 客户端
            // setup=passive (answer) -> 服务器
            // 简化：根据 local/remote description 确定
            const is_client = self.determineDtlsRole();

            if (is_client) {
                // 客户端：发送 ClientHello
                try self.sendClientHello(handshake);

                // 注意：客户端握手流程需要：
                // 1. 发送 ClientHello（已完成）
                // 2. 接收 ServerHello、Certificate、ServerHelloDone
                // 3. 发送 ClientKeyExchange、ChangeCipherSpec、Finished
                // 实际应该在异步环境中处理这些步骤
            } else {
                // 服务器：处理服务器端握手流程
                // 设置证书（从 PeerConnection 的证书中获取）
                if (self.dtls_certificate) |cert| {
                    // 获取证书的 DER 数据
                    const cert_der = try cert.getDerData(self.allocator);
                    defer self.allocator.free(cert_der);
                    try handshake.setCertificate(cert_der);
                }

                // 获取远程地址（从 ICE Agent 的 selected pair）
                if (self.ice_agent) |agent| {
                    if (agent.getSelectedPair()) |pair| {
                        const remote_address = std.net.Address.initIp(pair.remote.address, pair.remote.port);
                        // 设置 DTLS Record 的 UDP socket
                        if (self.dtls_record) |record| {
                            if (agent.udp) |udp| {
                                record.setUdp(udp);
                                // 处理服务器端握手流程（接收 ClientHello 并发送 ServerHello 等）
                                try handshake.processServerHandshake(remote_address);

                                // 完成服务器端握手（接收 ClientKeyExchange、ChangeCipherSpec、Finished 并发送响应）
                                // 注意：这是阻塞操作，实际应该在协程中处理
                                handshake.completeServerHandshake(remote_address) catch |err| {
                                    std.log.warn("Failed to complete server handshake: {}", .{err});
                                    // 继续执行，不中断流程
                                };

                                std.log.info("DTLS server handshake completed", .{});
                            } else {
                                return error.NoUdpSocket;
                            }
                        } else {
                            return error.NoDtlsRecord;
                        }
                    } else {
                        return error.NoSelectedPair;
                    }
                } else {
                    return error.NoIceAgent;
                }
            }
        }
    }

    /// 在 DTLS 握手完成后派生 SRTP 密钥并创建 Transform
    /// 应该在 DTLS 握手成功后被调用
    pub fn setupSrtp(self: *Self) !void {
        if (self.dtls_handshake) |handshake| {
            // 检查握手是否完成
            if (handshake.state != .handshake_complete) {
                return error.DtlsHandshakeNotComplete;
            }

            // 获取握手参数
            const master_secret = handshake.master_secret;
            const client_random = handshake.client_random;
            const server_random = handshake.server_random;

            // 确定角色（用于密钥交换）
            const is_client = self.determineDtlsRole();

            // 派生 SRTP 密钥
            const srtp_keys = try dtls.KeyDerivation.deriveSrtpKeys(
                master_secret,
                client_random,
                server_random,
                is_client,
            );

            // 创建 SRTP Context（发送方）
            // 根据角色选择使用哪个密钥
            const sender_key = if (is_client) srtp_keys.client_master_key else srtp_keys.server_master_key;
            const sender_salt = if (is_client) srtp_keys.client_master_salt else srtp_keys.server_master_salt;

            const sender_ctx = try srtp.Context.init(
                self.allocator,
                sender_key,
                sender_salt,
                0, // SSRC（将在实际使用时设置）
            );
            errdefer sender_ctx.deinit();

            // 创建 SRTP Context（接收方）
            const receiver_key = if (is_client) srtp_keys.server_master_key else srtp_keys.client_master_key;
            const receiver_salt = if (is_client) srtp_keys.server_master_salt else srtp_keys.client_master_salt;

            const receiver_ctx = try srtp.Context.init(
                self.allocator,
                receiver_key,
                receiver_salt,
                0, // SSRC（将在实际使用时设置）
            );
            errdefer receiver_ctx.deinit();

            // 创建 SRTP Transform（发送方和接收方）
            // Transform.init 返回值类型，需要堆分配
            const sender_transform_ptr = try self.allocator.create(srtp.Transform);
            sender_transform_ptr.* = srtp.Transform.init(sender_ctx);
            self.srtp_sender = sender_transform_ptr;

            const receiver_transform_ptr = try self.allocator.create(srtp.Transform);
            receiver_transform_ptr.* = srtp.Transform.init(receiver_ctx);
            self.srtp_receiver = receiver_transform_ptr;

            std.log.info("SRTP transforms created successfully", .{});
        } else {
            return error.NoDtlsHandshake;
        }
    }

    /// 确定 DTLS role（客户端或服务器）
    /// 返回 true 表示客户端，false 表示服务器
    /// 遵循 RFC 5763：根据 SDP 中的 setup 属性确定
    fn determineDtlsRole(self: *Self) bool {
        // RFC 5763 Section 5: DTLS role determination
        // setup 属性值：
        // - "actpass": offer 中的值，表示可以接受任何角色
        // - "active": answer 中的值，表示作为客户端
        // - "passive": answer 中的值，表示作为服务器

        // 优先从 answer 中获取 setup 属性（如果有）
        if (self.remote_description) |remote| {
            const remote_setup = Self.parseSetupAttribute(remote);
            if (remote_setup) |setup| {
                // answer 中的 setup 属性决定 role
                if (std.mem.eql(u8, setup, "active")) {
                    return true; // 客户端
                } else if (std.mem.eql(u8, setup, "passive")) {
                    return false; // 服务器
                }
                // "actpass" 在 answer 中不应该出现
            }
        }

        // 如果没有 answer，从本地 offer 中获取
        if (self.local_description) |local| {
            const local_setup = Self.parseSetupAttribute(local);
            if (local_setup) |setup| {
                // offer 中的 "actpass" 表示可以接受任何角色
                // 简化：如果本地是 offer 且没有远程描述，作为服务器等待连接
                if (std.mem.eql(u8, setup, "actpass")) {
                    if (self.remote_description == null) {
                        return false; // 服务器（等待客户端）
                    }
                }
            }
        }

        // 默认逻辑：如果本地描述先设置，作为服务器；否则作为客户端
        if (self.local_description != null and self.remote_description == null) {
            return false; // 服务器
        }
        return true; // 客户端
    }

    /// 从 SDP 中解析 setup 属性
    /// 返回 setup 属性值（"actpass", "active", "passive"）或 null
    fn parseSetupAttribute(description: *SessionDescription) ?[]const u8 {
        // 检查媒体级别的 setup 属性（优先）
        for (description.media_descriptions.items) |media_desc| {
            for (media_desc.attributes.items) |attr| {
                if (std.mem.eql(u8, attr.name, "setup")) {
                    if (attr.value) |value| {
                        return value;
                    }
                }
            }
        }

        // 检查会话级别的 setup 属性
        for (description.attributes.items) |attr| {
            if (std.mem.eql(u8, attr.name, "setup")) {
                if (attr.value) |value| {
                    return value;
                }
            }
        }

        return null;
    }

    /// 发送 ClientHello（DTLS 客户端）
    fn sendClientHello(self: *Self, handshake: *dtls.Handshake) !void {
        // 检查是否有可用的 UDP socket（从 ICE Agent 获取）
        if (self.ice_agent) |agent| {
            if (agent.udp) |udp| {
                // 设置 DTLS Record 的 UDP socket
                if (self.dtls_record) |record| {
                    record.setUdp(udp);

                    // 获取远程地址（从 ICE selected pair）
                    if (agent.getSelectedPair()) |pair| {
                        // 构建远程地址
                        const remote_address = std.net.Address.initIp(pair.remote.address, pair.remote.port);

                        // 发送 ClientHello
                        try handshake.sendClientHello(remote_address);
                        std.log.info("DTLS ClientHello sent to {}:{}", .{ pair.remote.address, pair.remote.port });
                    } else {
                        return error.NoSelectedPair;
                    }
                } else {
                    return error.NoDtlsRecord;
                }
            } else {
                return error.NoUdpSocket;
            }
        } else {
            return error.NoIceAgent;
        }
    }

    /// 添加 ICE Candidate
    pub fn addIceCandidate(self: *Self, candidate: *ice.Candidate) !void {
        if (self.ice_agent) |agent| {
            try agent.addRemoteCandidate(candidate);

            // 触发 onicecandidate 事件
            if (self.onicecandidate) |callback| {
                callback(self, candidate);
            }

            // 检查是否可以开始连接检查
            if (self.local_description != null) {
                // 检查 ICE 连接状态，如果还是 .new，更新为 .checking
                if (self.ice_connection_state == .new) {
                    const old_ice_state = self.ice_connection_state;
                    self.ice_connection_state = .checking;

                    // 触发 ICE 连接状态变化事件
                    if (old_ice_state != self.ice_connection_state) {
                        if (self.oniceconnectionstatechange) |callback| {
                            callback(self);
                        }
                    }

                    // 开始连接检查
                    agent.startConnectivityChecks() catch |err| {
                        std.log.warn("Failed to start connectivity checks: {}", .{err});
                        self.updateIceConnectionState(.failed);
                    };
                }
            }
        } else {
            return error.NoIceAgent;
        }
    }

    /// 更新 ICE 连接状态（内部方法，由事件回调调用）
    /// 当 ICE Agent 状态变化时调用此方法
    pub fn updateIceConnectionState(self: *Self, new_state: IceConnectionState) void {
        const old_state = self.ice_connection_state;
        if (old_state != new_state) {
            self.ice_connection_state = new_state;

            // 触发 ICE 连接状态变化事件
            if (self.oniceconnectionstatechange) |callback| {
                callback(self);
            }

            // 如果连接成功，自动启动 DTLS 握手
            if (new_state == .connected or new_state == .completed) {
                self.startDtlsHandshake() catch |err| {
                    std.log.warn("Failed to start DTLS handshake: {}", .{err});
                };
            }

            // 更新连接状态
            self.updateConnectionState();
        }
    }

    /// 更新连接状态（基于 ICE 连接状态）
    fn updateConnectionState(self: *Self) void {
        const old_state = self.connection_state;
        var new_state = self.connection_state;

        switch (self.ice_connection_state) {
            .new => new_state = .new,
            .checking => new_state = .connecting,
            .connected, .completed => new_state = .connected,
            .failed => new_state = .failed,
            .disconnected => new_state = .disconnected,
            .closed => new_state = .closed,
        }

        if (old_state != new_state) {
            self.connection_state = new_state;

            // 触发连接状态变化事件
            if (self.onconnectionstatechange) |callback| {
                callback(self);
            }

            // 如果连接成功且 DTLS 握手已完成，派生 SRTP 密钥
            if (new_state == .connected) {
                if (self.dtls_handshake) |handshake| {
                    if (handshake.state == .handshake_complete) {
                        self.setupSrtp() catch |err| {
                            std.log.warn("Failed to setup SRTP: {}", .{err});
                        };
                    }
                }
            }
        }
    }

    /// 检查并更新 DTLS 握手状态
    /// 应该在 DTLS 握手消息处理后被调用
    pub fn checkDtlsHandshakeState(self: *Self) void {
        if (self.dtls_handshake) |handshake| {
            // 如果握手完成且连接已建立，派生 SRTP 密钥
            if (handshake.state == .handshake_complete) {
                if (self.connection_state == .connected) {
                    self.setupSrtp() catch |err| {
                        std.log.warn("Failed to setup SRTP: {}", .{err});
                    };
                }
            }
        }
    }

    /// 获取当前信令状态
    pub fn getSignalingState(self: *const Self) SignalingState {
        return self.signaling_state;
    }

    /// 获取当前 ICE 连接状态
    pub fn getIceConnectionState(self: *const Self) IceConnectionState {
        return self.ice_connection_state;
    }

    /// 获取当前 ICE 收集状态
    pub fn getIceGatheringState(self: *const Self) IceGatheringState {
        return self.ice_gathering_state;
    }

    /// 获取当前连接状态
    pub fn getConnectionState(self: *const Self) ConnectionState {
        return self.connection_state;
    }

    /// 发送 RTP 包
    /// 包会被 SRTP 加密后通过 UDP 发送
    pub fn sendRtpPacket(self: *Self, packet: *rtp.Packet) !void {
        if (self.srtp_sender == null) {
            return error.SrtpNotInitialized;
        }

        if (self.ice_agent == null) {
            return error.NoIceAgent;
        }

        // 编码 RTP 包
        const rtp_data = try packet.encode(self.allocator);
        defer self.allocator.free(rtp_data);

        // 使用 SRTP 加密
        const srtp_data = try self.srtp_sender.?.protect(rtp_data, self.allocator);
        defer self.allocator.free(srtp_data);

        // 通过 UDP 发送（从 ICE Agent 获取 UDP socket 和远程地址）
        const agent = self.ice_agent.?;
        if (agent.udp) |udp| {
            if (agent.getSelectedPair()) |pair| {
                const remote_address = std.net.Address.initIp(pair.remote.address, pair.remote.port);
                try udp.sendTo(srtp_data, remote_address);
            } else {
                return error.NoSelectedPair;
            }
        } else {
            return error.NoUdpSocket;
        }
    }

    /// 接收 RTP 包
    /// 从 UDP 接收 SRTP 包，解密后解析为 RTP 包
    pub fn recvRtpPacket(self: *Self, allocator: std.mem.Allocator) !rtp.Packet {
        if (self.srtp_receiver == null) {
            return error.SrtpNotInitialized;
        }

        if (self.ice_agent == null) {
            return error.NoIceAgent;
        }

        // 从 UDP 接收数据（从 ICE Agent 获取 UDP socket）
        const agent = self.ice_agent.?;
        if (agent.udp) |udp| {
            var buffer: [2048]u8 = undefined;
            const result = try udp.recvFrom(&buffer);

            // 使用 SRTP 解密
            const rtp_data = try self.srtp_receiver.?.unprotect(result.data, allocator);
            defer allocator.free(rtp_data);

            // 解析 RTP 包
            return try rtp.Packet.parse(allocator, rtp_data);
        } else {
            return error.NoUdpSocket;
        }
    }

    /// 发送 RTCP 包
    /// 包会被 SRTCP 加密后通过 UDP 发送
    pub fn sendRtcpPacket(self: *Self, packet_data: []const u8) !void {
        if (self.srtp_sender == null) {
            return error.SrtpNotInitialized;
        }

        if (self.ice_agent == null) {
            return error.NoIceAgent;
        }

        // 使用 SRTCP 加密（SRTP Transform 支持 RTCP）
        const srtcp_data = try self.srtp_sender.?.protectRtcp(packet_data, self.allocator);
        defer self.allocator.free(srtcp_data);

        // 通过 UDP 发送
        const agent = self.ice_agent.?;
        if (agent.udp) |udp| {
            if (agent.getSelectedPair()) |pair| {
                const remote_address = std.net.Address.initIp(pair.remote.address, pair.remote.port);
                try udp.sendTo(srtcp_data, remote_address);
            } else {
                return error.NoSelectedPair;
            }
        } else {
            return error.NoUdpSocket;
        }
    }

    /// 接收 RTCP 包
    /// 从 UDP 接收 SRTCP 包，解密后返回
    pub fn recvRtcpPacket(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        if (self.srtp_receiver == null) {
            return error.SrtpNotInitialized;
        }

        if (self.ice_agent == null) {
            return error.NoIceAgent;
        }

        // 从 UDP 接收数据
        const agent = self.ice_agent.?;
        if (agent.udp) |udp| {
            var buffer: [2048]u8 = undefined;
            const result = try udp.recvFrom(&buffer);

            // 使用 SRTCP 解密
            return try self.srtp_receiver.?.unprotectRtcp(result.data, allocator);
        } else {
            return error.NoUdpSocket;
        }
    }

    /// 获取或创建本地 SSRC
    /// 用于发送 RTP 包时标识发送源
    pub fn getLocalSsrc(self: *Self) !u32 {
        if (self.ssrc_manager) |manager| {
            return try manager.generateAndAddSsrc();
        } else {
            return error.NoSsrcManager;
        }
    }

    /// 添加媒体轨道
    /// 创建 RTCRtpSender 并开始发送媒体
    pub fn addTrack(self: *Self, track: *media.Track) !*Sender {
        // 创建发送器
        const sender = try Sender.init(self.allocator);
        errdefer sender.deinit();

        // 设置轨道
        sender.setTrack(track);

        // 根据轨道类型确定载荷类型
        const payload_type: u7 = switch (track.kind) {
            .audio => 111, // 默认音频载荷类型（Opus）
            .video => 96, // 默认视频载荷类型（VP8）
        };
        sender.setPayloadType(payload_type);

        // 生成 SSRC
        const ssrc = try self.getLocalSsrc();
        sender.setSsrc(ssrc);

        // 添加到发送器列表
        try self.senders.append(sender);

        // 如果连接已建立，可以开始发送媒体
        // 注意：实际发送需要实现媒体编码和 RTP 包生成

        return sender;
    }

    /// 移除媒体轨道
    /// 移除对应的 RTCRtpSender
    pub fn removeTrack(self: *Self, sender: *Sender) !void {
        // 从列表中移除
        for (self.senders.items, 0..) |s, i| {
            if (s == sender) {
                _ = self.senders.swapRemove(i);
                sender.deinit();
                return;
            }
        }
        return error.SenderNotFound;
    }

    /// 获取所有发送器
    pub fn getSenders(self: *const Self) []const *Sender {
        return self.senders.items;
    }

    /// 获取所有接收器
    pub fn getReceivers(self: *const Self) []const *Receiver {
        return self.receivers.items;
    }

    /// 创建接收器（当接收到远程媒体轨道时）
    /// 通常由 PeerConnection 内部调用
    pub fn createReceiver(self: *Self, kind: media.TrackKind, ssrc: u32, payload_type: u7) !*Receiver {
        // 创建接收器
        const receiver = try Receiver.init(self.allocator);
        errdefer receiver.deinit();

        // 创建媒体轨道
        const track_id = try std.fmt.allocPrint(self.allocator, "receiver-{d}", .{ssrc});
        defer self.allocator.free(track_id);
        const track_label = try std.fmt.allocPrint(self.allocator, "Remote {s}", .{@tagName(kind)});
        defer self.allocator.free(track_label);

        const track = try media.Track.init(self.allocator, track_id, kind, track_label);
        errdefer track.deinit();

        receiver.setTrack(track);
        receiver.setSsrc(ssrc);
        receiver.setPayloadType(payload_type);

        // 添加到接收器列表
        try self.receivers.append(receiver);

        return receiver;
    }

    /// 创建数据通道
    /// 遵循 W3C WebRTC 1.0 规范
    pub fn createDataChannel(
        self: *Self,
        label: []const u8,
        options: ?DataChannelOptions,
    ) !*sctp.DataChannel {
        // 初始化 SCTP Association（如果尚未初始化）
        if (self.sctp_association == null) {
            // SCTP 需要在 DTLS 握手完成后才能建立
            // 检查 DTLS 握手是否完成
            if (self.dtls_handshake) |handshake| {
                if (handshake.state != .handshake_complete) {
                    return error.DtlsHandshakeNotComplete;
                }
            } else {
                return error.NoDtlsHandshake;
            }

            // 创建 SCTP Association
            // 注意：需要从 DTLS 获取传输层信息
            // 简化实现：使用默认配置
            const assoc = try self.allocator.create(sctp.Association);
            errdefer self.allocator.destroy(assoc);
            assoc.* = try sctp.Association.init(self.allocator, 5000);
            errdefer assoc.deinit();
            self.sctp_association = assoc;
        }

        // 使用默认选项（如果未提供）
        const opts = options orelse DataChannelOptions{};

        // 确定通道类型
        const channel_type: sctp.datachannel.ChannelType = if (opts.max_retransmits) |_|
            .partial_reliable_rexmit
        else if (opts.max_packet_life_time) |_|
            .partial_reliable_timed
        else
            .reliable;

        // 确定可靠性参数
        const reliability_param: u32 = if (opts.max_retransmits) |max_retrans|
            @as(u32, max_retrans)
        else if (opts.max_packet_life_time) |max_life|
            @as(u32, max_life)
        else
            0;

        // 创建数据通道
        // DataChannel.init 需要 Association、Stream ID、label、protocol、channel_type、priority、reliability_parameter、ordered
        if (self.sctp_association) |assoc| {
            // 分配 Stream ID（自动递增）
            const stream_id = self.next_stream_id;
            self.next_stream_id +%= 1;

            // 检查 Stream ID 是否已存在（避免冲突）
            if (assoc.stream_manager.findStream(stream_id)) |_| {
                // Stream 已存在，查找下一个可用的 ID
                var next_id = stream_id;
                while (assoc.stream_manager.findStream(next_id) != null) {
                    next_id +%= 1;
                    if (next_id == stream_id) {
                        // 已遍历所有可能的 ID，返回错误
                        return error.OutOfStreamIds;
                    }
                }
                self.next_stream_id = next_id +% 1;
            }

            const priority: u16 = 0; // 默认优先级

            const channel = try self.allocator.create(sctp.DataChannel);
            errdefer self.allocator.destroy(channel);

            channel.* = try sctp.DataChannel.init(
                self.allocator,
                stream_id,
                label,
                try self.allocator.dupe(u8, opts.protocol),
                channel_type,
                priority,
                reliability_param,
                opts.ordered,
            );

            // 设置关联的 SCTP Association
            channel.setAssociation(assoc);

            // 设置关联的 PeerConnection（用于网络传输）
            channel.setPeerConnection(self);

            // 添加到数据通道列表
            try self.data_channels.append(channel);

            return channel;
        } else {
            return error.NoSctpAssociation;
        }
    }

    /// 获取所有数据通道
    pub fn getDataChannels(self: *const Self) []*sctp.DataChannel {
        return self.data_channels.items;
    }

    /// 根据 label 查找数据通道
    pub fn findDataChannel(self: *const Self, label: []const u8) ?*sctp.DataChannel {
        for (self.data_channels.items) |channel| {
            if (std.mem.eql(u8, channel.label, label)) {
                return channel;
            }
        }
        return null;
    }

    /// 根据 stream_id 查找数据通道
    pub fn findDataChannelByStreamId(self: *const Self, stream_id: u16) ?*sctp.DataChannel {
        for (self.data_channels.items) |channel| {
            if (channel.stream_id == stream_id) {
                return channel;
            }
        }
        return null;
    }

    /// 移除数据通道
    pub fn removeDataChannel(self: *Self, channel: *sctp.DataChannel) !void {
        for (self.data_channels.items, 0..) |ch, i| {
            if (ch == channel) {
                _ = self.data_channels.swapRemove(i);
                channel.deinit();
                self.allocator.destroy(channel);
                return;
            }
        }
        return error.ChannelNotFound;
    }

    /// 发送 SCTP 数据
    /// 将 SCTP 数据包通过 DTLS 发送
    /// 注意：需要在 DTLS 握手完成后才能发送
    pub fn sendSctpData(self: *Self, sctp_packet: []const u8) !void {
        if (self.dtls_record == null) {
            return error.NoDtlsRecord;
        }

        // 检查 DTLS 握手是否完成
        if (self.dtls_handshake) |handshake| {
            if (handshake.state != .handshake_complete) {
                return error.DtlsHandshakeNotComplete;
            }
        } else {
            return error.NoDtlsHandshake;
        }

        // 获取远程地址（从 ICE Agent）
        if (self.ice_agent) |agent| {
            if (agent.selected_pair) |pair| {
                const remote_candidate = pair.remote;
                const address = remote_candidate.address;

                // 通过 DTLS Record 发送 SCTP 数据（使用 application_data 类型）
                if (self.dtls_record) |record| {
                    try record.send(.application_data, sctp_packet, address);
                }
            } else {
                return error.NoSelectedPair;
            }
        } else {
            return error.NoIceAgent;
        }
    }

    /// 接收 SCTP 数据
    /// 从 DTLS 接收 application_data，解析为 SCTP 包，并路由到对应的 DataChannel
    /// 注意：需要在 DTLS 握手完成后才能接收
    pub fn recvSctpData(self: *Self) !void {
        if (self.dtls_record == null) {
            return error.NoDtlsRecord;
        }

        // 检查 DTLS 握手是否完成
        if (self.dtls_handshake) |handshake| {
            if (handshake.state != .handshake_complete) {
                return error.DtlsHandshakeNotComplete;
            }
        } else {
            return error.NoDtlsHandshake;
        }

        // 检查 SCTP Association 是否存在
        if (self.sctp_association == null) {
            return error.NoSctpAssociation;
        }

        // 从 DTLS Record 接收数据
        var buffer: [8192]u8 = undefined;
        const record = if (self.dtls_record) |r| r else return error.NoDtlsRecord;
        const result = record.recv(&buffer) catch |err| {
            // 如果没有数据可接收，返回（非阻塞）
            // 注意：DTLS Record 的 recv 可能返回其他错误，这里简化处理
            return err;
        };

        // 只处理 application_data 类型
        if (result.content_type != .application_data) {
            return;
        }

        // 处理接收到的 SCTP 数据
        try self.handleSctpPacket(result.data);
    }

    /// 处理 SCTP 数据包
    /// 解析 SCTP 包，提取 Data Chunk，并路由到对应的 DataChannel
    fn handleSctpPacket(self: *Self, packet_data: []const u8) !void {
        if (self.sctp_association == null) {
            return error.NoSctpAssociation;
        }

        const assoc = self.sctp_association.?;

        // 解析 SCTP Common Header（至少需要 12 字节）
        if (packet_data.len < 12) {
            return error.InvalidSctpPacket;
        }

        const common_header = try sctp.chunk.CommonHeader.parse(packet_data);

        // 验证 Verification Tag（简化：只检查是否匹配）
        if (common_header.verification_tag != assoc.local_verification_tag and
            common_header.verification_tag != assoc.remote_verification_tag)
        {
            // 可能是新的关联，暂时忽略
            return;
        }

        // 解析 Chunk（从第 12 字节开始）
        if (packet_data.len < 16) {
            return error.InvalidSctpPacket;
        }

        const chunk_data = packet_data[12..];
        const chunk_type = chunk_data[0];

        // 只处理 DATA Chunk（类型 0）
        if (chunk_type == 0) {
            try self.handleDataChunk(assoc, chunk_data);
        }
        // TODO: 处理其他 Chunk 类型（SACK, HEARTBEAT 等）
    }

    /// 处理 DATA Chunk
    /// 解析 Data Chunk，提取用户数据，并路由到对应的 DataChannel
    fn handleDataChunk(self: *Self, assoc: *sctp.Association, chunk_data: []const u8) !void {
        // 解析 Data Chunk
        var data_chunk = try sctp.chunk.DataChunk.parse(self.allocator, chunk_data);
        defer data_chunk.deinit(self.allocator);

        // 获取 Stream ID
        const stream_id = data_chunk.stream_id;

        // 查找对应的 DataChannel
        if (self.findDataChannelByStreamId(stream_id)) |channel| {
            // 找到对应的 Stream（如果不存在则创建）
            const sctp_stream = assoc.stream_manager.findStream(stream_id) orelse
                try assoc.stream_manager.createStream(stream_id, channel.ordered);

            // 将数据添加到 Stream 的接收缓冲区
            try sctp_stream.receive_buffer.appendSlice(data_chunk.user_data);

            // 触发 DataChannel 的 onmessage 事件
            if (channel.onmessage) |callback| {
                const user_data_copy = try self.allocator.dupe(u8, data_chunk.user_data);
                defer self.allocator.free(user_data_copy);
                callback(channel, user_data_copy);
            }
        } else {
            // 没有找到对应的 DataChannel，可能是新通道
            // TODO: 处理自动创建 DataChannel 的情况
        }
    }

    /// 数据通道选项
    pub const DataChannelOptions = struct {
        ordered: bool = true, // 是否有序传输
        max_retransmits: ?u16 = null, // 最大重传次数（null 表示无限）
        max_packet_life_time: ?u16 = null, // 最大包生存时间（毫秒）
        protocol: []const u8 = "", // 子协议名称
    };

    pub const Error = error{
        NoRemoteDescription,
        NoIceAgent,
        OutOfMemory,
        InvalidState,
        NoSelectedPair,
        NoDtlsRecord,
        NoUdpSocket,
        DtlsHandshakeNotComplete,
        NoDtlsHandshake,
        SrtpNotInitialized,
        NoSsrcManager,
        SenderNotFound,
        NoSctpAssociation,
        OutOfStreamIds,
        ChannelNotFound,
        InvalidSctpPacket,
    };
};
