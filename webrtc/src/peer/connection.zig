const std = @import("std");
const zco = @import("zco");
const ice = @import("../ice/root.zig");
const dtls = @import("../dtls/root.zig");
const srtp = @import("../srtp/root.zig");
const rtp_packet = @import("../rtp/packet.zig");
const sctp = @import("../sctp/root.zig");
const signaling = @import("../signaling/root.zig");

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
    ice_agent: ?*ice.Agent = null,
    dtls_context: ?*dtls.Context = null,
    srtp_sender: ?*srtp.Transform = null,
    srtp_receiver: ?*srtp.Transform = null,
    sctp_association: ?*sctp.Association = null,

    // SDP 描述
    local_description: ?*SessionDescription = null,
    remote_description: ?*SessionDescription = null,

    // 事件回调（TODO: 实现事件系统）
    // onicecandidate: ?*const fn (*Self, *ice.Candidate) void = null,
    // onconnectionstatechange: ?*const fn (*Self) void = null,
    // onsignalingstatechange: ?*const fn (*Self) void = null,

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
        };

        // 初始化 ICE Agent
        self.ice_agent = try ice.agent.IceAgent.init(allocator, schedule);
        errdefer if (self.ice_agent) |agent| agent.deinit();
        
        // 初始化组件 ID（RTP 为 1）
        if (self.ice_agent) |agent| {
            agent.component_id = 1;
        }

        // TODO: 初始化 DTLS Context（需要时生成证书）

        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        if (self.sctp_association) |assoc| {
            assoc.deinit();
        }

        if (self.srtp_receiver) |transform| {
            transform.ctx.deinit();
        }

        if (self.srtp_sender) |transform| {
            transform.ctx.deinit();
        }

        if (self.dtls_context) |ctx| {
            ctx.deinit();
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
            // 生成 ICE username fragment 和 password
            // TODO: 实际实现应使用随机生成的值
            const ice_ufrag = try allocator.dupe(u8, "zco-ufrag");
            const ice_pwd = try allocator.dupe(u8, "zco-pwd");

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

        // 5. 添加 DTLS 指纹（如果 DTLS Context 已初始化）
        if (self.dtls_context) |dtls_ctx| {
            _ = dtls_ctx; // 暂时未使用
            // TODO: 从 DTLS context 获取证书并计算指纹
            // 当前使用占位符
            const fingerprint_hash = try allocator.dupe(u8, "sha-256");
            const fingerprint_value = try allocator.dupe(u8, "00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00");

            offer.fingerprint = SessionDescription.Fingerprint{
                .hash = fingerprint_hash,
                .value = fingerprint_value,
            };

            // 添加 fingerprint 属性到媒体描述
            const fingerprint_attr_value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ fingerprint_hash, fingerprint_value });
            try audio_media_desc.attributes.append(SessionDescription.Attribute{
                .name = try allocator.dupe(u8, "fingerprint"),
                .value = fingerprint_attr_value,
            });
        } else {
            // 如果没有 DTLS context，创建一个并生成证书
            // TODO: 初始化 DTLS context 并生成自签名证书
        }

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
        // TODO: 实现完整的 answer 生成
        // 需要基于 remote_description 生成

        if (self.remote_description == null) {
            return error.NoRemoteDescription;
        }

        var answer = SessionDescription.init(allocator);
        errdefer answer.deinit();

        // 基础信息（类似 offer）
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

        // TODO: 添加媒体描述和 ICE 信息

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

        // TODO: 触发 ICE candidate 收集
        // TODO: 启动连接流程（如果已有 remote description）
    }

    /// 设置远程描述
    pub fn setRemoteDescription(self: *Self, description: *SessionDescription) !void {
        if (self.remote_description) |desc| {
            desc.deinit();
        }

        self.remote_description = description;

        // 更新信令状态
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

        // TODO: 解析远程 ICE candidates
        // TODO: 启动连接检查
    }

    /// 添加 ICE Candidate
    pub fn addIceCandidate(self: *Self, candidate: *ice.Candidate) !void {
        if (self.ice_agent) |agent| {
            try agent.addRemoteCandidate(candidate);
        } else {
            return error.NoIceAgent;
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

    pub const Error = error{
        NoRemoteDescription,
        NoIceAgent,
        OutOfMemory,
        InvalidState,
    };
};
