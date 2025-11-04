const std = @import("std");
const zco = @import("zco");
const crypto = std.crypto;
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
    ice_agent: ?*ice.agent.IceAgent = null,
    dtls_certificate: ?*dtls.Certificate = null, // DTLS 证书（用于指纹计算）
    dtls_record: ?*dtls.Record = null, // DTLS 记录层
    dtls_handshake: ?*dtls.Handshake = null, // DTLS 握手协议
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

        // 初始化 DTLS 证书（生成自签名证书）
        self.dtls_certificate = try Self.initDtlsCertificate(allocator);
        errdefer if (self.dtls_certificate) |cert| cert.deinit();

        // 初始化 DTLS 记录层
        self.dtls_record = try dtls.Record.init(allocator, schedule);
        errdefer if (self.dtls_record) |record| record.deinit();

        // 初始化 DTLS 握手协议
        self.dtls_handshake = try dtls.Handshake.init(allocator, self.dtls_record.?);
        errdefer if (self.dtls_handshake) |handshake| handshake.deinit();

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

        // 更新 ICE 收集状态
        self.ice_gathering_state = .gathering;

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
            for (description.media_descriptions.items) |media| {
                for (media.attributes.items) |attr| {
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
                self.ice_connection_state = .checking;

                // 注意：generateCandidatePairs 会在 addRemoteCandidate 时自动调用
                // 所以如果所有远程 candidates 都已添加，pairs 应该已经生成

                // 开始连接检查
                agent.startConnectivityChecks() catch |err| {
                    std.log.warn("Failed to start connectivity checks: {}", .{err});
                    self.ice_connection_state = .failed;
                };

                // TODO: 监听 ICE 连接状态变化，在连接成功时启动 DTLS 握手
                // 当 ICE 连接状态变为 .connected 或 .completed 时，调用 startDtlsHandshake()
                // 简化：在当前检查成功后假设连接建立（实际应通过回调或事件机制）
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
            } else {
                // 服务器：等待 ClientHello
                // TODO: 实现服务器端握手流程
                std.log.info("DTLS server mode: waiting for ClientHello", .{});
            }
        }
    }

    /// 确定 DTLS role（客户端或服务器）
    /// 返回 true 表示客户端，false 表示服务器
    fn determineDtlsRole(self: *Self) bool {
        // 简化逻辑：
        // - 如果本地有 offer，则作为服务器（等待客户端连接）
        // - 如果远程有 offer，则作为客户端（主动连接）
        // 实际应该根据 SDP 中的 setup 属性确定

        // TODO: 从 SDP 中解析 setup 属性
        // 当前简化：如果本地描述先设置，作为服务器；否则作为客户端
        if (self.local_description != null and self.remote_description == null) {
            return false; // 服务器
        }
        return true; // 客户端
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
        NoSelectedPair,
        NoDtlsRecord,
        NoUdpSocket,
    };
};
