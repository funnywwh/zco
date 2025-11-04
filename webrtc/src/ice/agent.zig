const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const posix = std.posix;
const Candidate = @import("./candidate.zig").Candidate;
const Stun = @import("./stun.zig").Stun;
const Turn = @import("./turn.zig").Turn;

/// ICE Agent 实现
/// 负责 Candidate 收集、Connectivity Checks 和连接建立
/// 遵循 RFC 8445
pub const IceAgent = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,

    // Candidate 集合
    local_candidates: std.ArrayList(*Candidate),
    remote_candidates: std.ArrayList(*Candidate),

    // Candidate Pair
    candidate_pairs: std.ArrayList(CandidatePair),

    // 状态
    state: State,

    // STUN 配置
    stun_servers: std.ArrayList(StunServer),

    // TURN 配置
    turn_servers: std.ArrayList(TurnServer),

    // 检查状态
    check_list: std.ArrayList(Check),

    // 选中的对
    selected_pair: ?*CandidatePair,

    // 等待响应的 pending requests（transaction_id -> pair）
    pending_requests: std.StringHashMap(*CandidatePair),

    // 组件 ID（RTP 通常为 1，RTCP 为 2）
    component_id: u32,

    // UDP socket（用于 Host Candidate 和 Connectivity Checks）
    udp: ?*nets.Udp = null,

    // STUN 客户端（用于 Server Reflexive Candidate）
    stun: ?*Stun = null,

    // TURN 客户端（用于 Relay Candidate）
    turn: ?*Turn = null,

    // 状态变化回调
    // 注意：第一个参数是上下文（用于传递 PeerConnection 指针），第二个参数是状态
    on_state_change: ?*const fn (*anyopaque, State) void = null,
    on_state_change_ctx: ?*anyopaque = null,

    /// ICE 状态枚举
    pub const State = enum {
        new, // 初始状态
        gathering, // 收集 Candidate
        checking, // 进行 Connectivity Checks
        connected, // 找到可用连接
        completed, // 所有检查完成
        failed, // 连接失败
        closed, // 已关闭
    };

    /// Candidate Pair 状态
    pub const PairState = enum {
        waiting, // 等待检查
        in_progress, // 正在检查
        succeeded, // 检查成功
        failed, // 检查失败
        frozen, // 被冻结（等待触发）
    };

    /// Candidate Pair
    pub const CandidatePair = struct {
        local: *Candidate,
        remote: *Candidate,
        priority: u64,
        state: PairState,
        foundation: []const u8, // 用于配对匹配

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.foundation);
        }
    };

    /// STUN Server 配置
    pub const StunServer = struct {
        address: std.net.Address,
        username: ?[]const u8 = null,
        password: ?[]const u8 = null,

        pub fn deinit(self: *StunServer, allocator: std.mem.Allocator) void {
            if (self.username) |u| allocator.free(u);
            if (self.password) |p| allocator.free(p);
        }
    };

    /// TURN Server 配置
    pub const TurnServer = struct {
        address: std.net.Address,
        username: []const u8,
        password: []const u8,
        realm: ?[]const u8 = null,
        nonce: ?[]const u8 = null,

        pub fn deinit(self: *TurnServer, allocator: std.mem.Allocator) void {
            allocator.free(self.username);
            allocator.free(self.password);
            if (self.realm) |r| allocator.free(r);
            if (self.nonce) |n| allocator.free(n);
        }
    };

    /// Check 状态
    pub const CheckState = enum {
        pending, // 待发送
        sent, // 已发送
        received, // 已收到响应
        timed_out, // 超时
    };

    /// Connectivity Check
    pub const Check = struct {
        pair: *CandidatePair,
        stun_transaction_id: [12]u8,
        state: CheckState,
        retry_count: u32,
        last_sent: ?i64 = null, // 最后发送时间（时间戳）
    };

    /// 初始化 ICE Agent
    pub fn init(
        allocator: std.mem.Allocator,
        schedule: *zco.Schedule,
        component_id: u32,
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .schedule = schedule,
            .local_candidates = std.ArrayList(*Candidate).init(allocator),
            .remote_candidates = std.ArrayList(*Candidate).init(allocator),
            .candidate_pairs = std.ArrayList(CandidatePair).init(allocator),
            .state = .new,
            .stun_servers = std.ArrayList(StunServer).init(allocator),
            .turn_servers = std.ArrayList(TurnServer).init(allocator),
            .check_list = std.ArrayList(Check).init(allocator),
            .selected_pair = null,
            .pending_requests = std.StringHashMap(*CandidatePair).init(allocator),
            .component_id = component_id,
        };
        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        // 清理 pending_requests
        self.pending_requests.deinit();

        // 清理本地 Candidates
        for (self.local_candidates.items) |candidate| {
            candidate.deinit();
            self.allocator.destroy(candidate);
        }
        self.local_candidates.deinit();

        // 清理远程 Candidates（不销毁，它们可能由外部管理）
        self.remote_candidates.deinit();

        // 清理 Candidate Pairs
        for (self.candidate_pairs.items) |*pair| {
            pair.deinit(self.allocator);
        }
        self.candidate_pairs.deinit();

        // 清理 STUN 服务器
        for (self.stun_servers.items) |*server| {
            server.deinit(self.allocator);
        }
        self.stun_servers.deinit();

        // 清理 TURN 服务器
        for (self.turn_servers.items) |*server| {
            server.deinit(self.allocator);
        }
        self.turn_servers.deinit();

        // 清理 Checks
        self.check_list.deinit();

        // 清理 UDP
        // 注意：UDP 可能由外部管理（在 signaling_client 中创建），所以这里只清理引用
        // 实际的清理应该由创建者负责
        if (self.udp) |_| {
            // 只清理引用，不销毁对象（由创建者负责清理）
            self.udp = null;
        }

        // 清理 STUN
        if (self.stun) |_| {
            // STUN 目前没有 deinit，需要添加
            // TODO: 添加 STUN deinit 方法
            self.allocator.destroy(self.stun.?);
        }

        // 清理 TURN 客户端
        if (self.turn) |turn| {
            turn.deinit();
        }

        self.allocator.destroy(self);
    }

    /// 获取当前状态
    pub fn getState(self: *const Self) State {
        return self.state;
    }

    /// 获取选中的 Pair
    pub fn getSelectedPair(self: *const Self) ?*CandidatePair {
        return self.selected_pair;
    }

    /// 获取所有本地 Candidates
    pub fn getLocalCandidates(self: *const Self) []const *Candidate {
        return self.local_candidates.items;
    }

    /// 获取所有远程 Candidates
    pub fn getRemoteCandidates(self: *const Self) []const *Candidate {
        return self.remote_candidates.items;
    }

    /// 添加 STUN 服务器
    pub fn addStunServer(
        self: *Self,
        address: std.net.Address,
        username: ?[]const u8,
        password: ?[]const u8,
    ) !void {
        var server = StunServer{
            .address = address,
        };
        if (username) |u| {
            server.username = try self.allocator.dupe(u8, u);
        }
        if (password) |p| {
            server.password = try self.allocator.dupe(u8, p);
        }
        try self.stun_servers.append(server);
    }

    /// 添加 TURN 服务器
    pub fn addTurnServer(
        self: *Self,
        address: std.net.Address,
        username: []const u8,
        password: []const u8,
        realm: ?[]const u8,
        nonce: ?[]const u8,
    ) !void {
        var server = TurnServer{
            .address = address,
            .username = try self.allocator.dupe(u8, username),
            .password = try self.allocator.dupe(u8, password),
            .realm = null,
            .nonce = null,
        };
        errdefer server.deinit(self.allocator);

        if (realm) |r| {
            server.realm = try self.allocator.dupe(u8, r);
        }
        if (nonce) |n| {
            server.nonce = try self.allocator.dupe(u8, n);
        }
        try self.turn_servers.append(server);
    }

    /// 开始收集 Host Candidates
    /// 遍历本地网络接口，为每个接口创建 Host Candidate
    pub fn gatherHostCandidates(self: *Self) !void {
        if (self.state != .new and self.state != .gathering) {
            return error.InvalidState;
        }

        self.setState(.gathering);

        // 创建 UDP socket（如果没有）
        if (self.udp == null) {
            self.udp = try nets.Udp.init(self.schedule);
        }

        // 收集本地地址
        // 如果 UDP socket 已经绑定，使用 getsockname 获取实际绑定的地址
        // 否则绑定到 0.0.0.0（让系统分配端口）
        const candidate_addr = if (self.udp) |udp| blk: {
            // 检查 UDP socket 是否已经绑定
            if (udp.xobj == null) {
                // 还没有绑定，绑定到 0.0.0.0（让系统分配端口）
                const bind_addr = try std.net.Address.parseIp4("0.0.0.0", 0);
                udp.bind(bind_addr) catch |err| {
                    // 如果绑定失败，返回错误
                    return err;
                };
                // 绑定后，使用 getsockname 获取实际绑定的地址
                const actual_addr = udp.getBoundAddress() catch |err| {
                    std.log.warn("ICE: 无法获取绑定地址，使用原始地址: {}", .{err});
                    break :blk bind_addr;
                };
                std.log.debug("ICE: 获取到实际绑定地址: {}", .{actual_addr});
                break :blk actual_addr;
            } else {
                // 已经绑定，使用 getsockname 获取实际绑定的地址
                const actual_addr = udp.getBoundAddress() catch |err| {
                    std.log.warn("ICE: 无法获取绑定地址，使用默认地址: {}", .{err});
                    // 如果获取失败，使用默认地址（但端口不能为 0）
                    break :blk try std.net.Address.parseIp4("127.0.0.1", 5000);
                };
                std.log.debug("ICE: 获取到实际绑定地址: {}", .{actual_addr});
                break :blk actual_addr;
            }
        } else blk: {
            // 创建并绑定 UDP socket
            self.udp = try nets.Udp.init(self.schedule);
            const bind_addr = try std.net.Address.parseIp4("0.0.0.0", 0);
            self.udp.?.bind(bind_addr) catch |err| {
                return err;
            };
            // 绑定后，使用 getsockname 获取实际绑定的地址
            const actual_addr = self.udp.?.getBoundAddress() catch |err| {
                std.log.warn("ICE: 无法获取绑定地址，使用原始地址: {}", .{err});
                break :blk bind_addr;
            };
            std.log.debug("ICE: 获取到实际绑定地址: {}", .{actual_addr});
            break :blk actual_addr;
        };

        // 创建 Host Candidate
        const foundation = try std.fmt.allocPrint(self.allocator, "host-{}-0", .{self.component_id});
        errdefer self.allocator.free(foundation);
        const transport = try self.allocator.dupe(u8, "udp");
        errdefer self.allocator.free(transport);

        const candidate = try self.allocator.create(Candidate);
        errdefer self.allocator.destroy(candidate);

        // Candidate.init() 会复制 foundation 和 transport，所以可以释放原始的
        candidate.* = try Candidate.init(
            self.allocator,
            foundation,
            self.component_id,
            transport,
            candidate_addr,
            .host,
        );

        // 释放原始分配的字符串（Candidate.init() 已经复制了）
        self.allocator.free(foundation);
        self.allocator.free(transport);

        // 计算优先级
        const type_pref = Candidate.getTypePreference(.host);
        candidate.calculatePriority(type_pref, 65535); // 使用最大 local preference

        try self.local_candidates.append(candidate);
        std.log.info("ICE: 已收集 Host Candidate: {}", .{candidate.address});

        // 如果已有远程 Candidates，立即生成 Candidate Pairs
        // 这样当本地 candidates 收集完成后，如果远程 candidates 已经添加，就可以生成 pairs
        if (self.remote_candidates.items.len > 0) {
            try self.generateCandidatePairs();
            std.log.debug("ICE: 已生成 Candidate Pairs (本地: {}, 远程: {}, Pairs: {})", .{
                self.local_candidates.items.len,
                self.remote_candidates.items.len,
                self.candidate_pairs.items.len,
            });
        }
    }

    /// 收集 Server Reflexive Candidates
    /// 向 STUN 服务器发送 Binding Request，获取反射地址
    pub fn gatherServerReflexiveCandidates(self: *Self) !void {
        if (self.stun_servers.items.len == 0) {
            return; // 没有 STUN 服务器配置
        }

        // 确保 UDP 已初始化
        if (self.udp == null) {
            self.udp = try nets.Udp.init(self.schedule);
        }

        // 创建 STUN 客户端（如果还没有）
        if (self.stun == null) {
            const stun_ptr = try self.allocator.create(Stun);
            stun_ptr.* = Stun.init(self.allocator, self.schedule);
            // 设置 UDP（共享 Agent 的 UDP socket）
            stun_ptr.udp = self.udp;
            self.stun = stun_ptr;
        }

        const stun = self.stun.?;

        // 为每个 STUN 服务器收集 Server Reflexive Candidate
        for (self.stun_servers.items, 0..) |*server, i| {
            // 在协程中发送 STUN Binding Request
            var response = try stun.sendBindingRequest(server.address);
            defer response.deinit();

            // 从响应中提取 XOR-MAPPED-ADDRESS
            const xor_attr_opt = response.findAttribute(.xor_mapped_address);
            const xor_attr = if (xor_attr_opt) |attr| attr else {
                // 如果没有 XOR-MAPPED-ADDRESS，尝试 MAPPED-ADDRESS
                const mapped_attr = response.findAttribute(.mapped_address) orelse {
                    continue; // 跳过这个服务器
                };
                const mapped_addr_attr = try Stun.MappedAddress.parse(mapped_attr);
                const mapped_address = mapped_addr_attr.address;

                // 创建 Server Reflexive Candidate
                const foundation = try std.fmt.allocPrint(self.allocator, "srflx-{}-{}", .{ self.component_id, i });
                const transport = try self.allocator.dupe(u8, "udp");
                errdefer self.allocator.free(foundation);
                errdefer self.allocator.free(transport);

                const candidate = try self.allocator.create(Candidate);
                errdefer self.allocator.destroy(candidate);

                candidate.* = try Candidate.init(
                    self.allocator,
                    foundation,
                    self.component_id,
                    transport,
                    mapped_address,
                    .server_reflexive,
                );

                // 设置相关地址（本地地址）
                if (self.udp) |_| {
                    // TODO: 获取 UDP 绑定的实际地址作为 related_address
                }

                // 计算优先级
                const type_pref = Candidate.getTypePreference(.server_reflexive);
                candidate.calculatePriority(type_pref, 65534); // 稍低于 Host

                try self.local_candidates.append(candidate);
                continue;
            };

            // 解析 XOR-MAPPED-ADDRESS（需要事务 ID）
            const transaction_id = response.header.transaction_id;
            const xor_addr_attr = try Stun.XorMappedAddress.parse(xor_attr, transaction_id);
            const xor_address = xor_addr_attr.address;

            // 创建 Server Reflexive Candidate
            const foundation = try std.fmt.allocPrint(self.allocator, "srflx-{}-{}", .{ self.component_id, i });
            const transport = try self.allocator.dupe(u8, "udp");
            errdefer self.allocator.free(foundation);
            errdefer self.allocator.free(transport);

            const candidate = try self.allocator.create(Candidate);
            errdefer self.allocator.destroy(candidate);

            candidate.* = try Candidate.init(
                self.allocator,
                foundation,
                self.component_id,
                transport,
                xor_address,
                .server_reflexive,
            );

            // 设置相关地址（本地地址）
            // TODO: 获取 UDP 绑定的实际地址作为 related_address

            // 计算优先级
            const type_pref = Candidate.getTypePreference(.server_reflexive);
            candidate.calculatePriority(type_pref, 65534); // 稍低于 Host

            try self.local_candidates.append(candidate);
        }
    }

    /// 收集 Relay Candidates（通过 TURN 服务器）
    /// 向 TURN 服务器发送 Allocation 请求，获取中继地址
    pub fn gatherRelayCandidates(self: *Self) !void {
        if (self.turn_servers.items.len == 0) {
            return; // 没有 TURN 服务器配置
        }

        // 为每个 TURN 服务器收集 Relay Candidate
        for (self.turn_servers.items, 0..) |*server, i| {
            // 创建 TURN 客户端（如果需要）
            if (self.turn == null) {
                self.turn = try Turn.init(
                    self.allocator,
                    self.schedule,
                    server.address,
                    server.username,
                    server.password,
                );
            }

            const turn = self.turn.?;

            // 发送 Allocation 请求
            // 注意：这里简化处理，实际应该处理认证（realm/nonce）
            const allocation = turn.allocate() catch {
                // Allocation 失败，跳过这个 TURN 服务器
                continue;
            };

            // 从 Allocation 中提取 relayed_address
            const relayed_address = allocation.relayed_address;

            // 创建 Relay Candidate
            const foundation = try std.fmt.allocPrint(self.allocator, "relay-{}-{}", .{ self.component_id, i });
            const transport = try self.allocator.dupe(u8, "udp");
            errdefer self.allocator.free(foundation);
            errdefer self.allocator.free(transport);

            const candidate = try self.allocator.create(Candidate);
            errdefer self.allocator.destroy(candidate);

            candidate.* = try Candidate.init(
                self.allocator,
                foundation,
                self.component_id,
                transport,
                relayed_address,
                .relayed,
            );

            // 设置相关地址（TURN 服务器地址）
            candidate.related_address = server.address;
            candidate.related_port = null;

            // 计算优先级（Relay Candidate 优先级最低）
            const type_pref = Candidate.getTypePreference(.relayed);
            candidate.calculatePriority(type_pref, 65534);

            try self.local_candidates.append(candidate);
        }
    }

    /// 添加远程 Candidate
    pub fn addRemoteCandidate(self: *Self, candidate: *Candidate) !void {
        if (candidate.component_id != self.component_id) {
            return error.InvalidComponentId;
        }

        try self.remote_candidates.append(candidate);

        // 如果已有本地 Candidates，立即生成 Candidate Pairs
        if (self.local_candidates.items.len > 0) {
            try self.generateCandidatePairs();
        }
    }

    /// 生成 Candidate Pairs
    /// 根据 RFC 8445，每个本地 Candidate 与每个远程 Candidate 配对
    pub fn generateCandidatePairs(self: *Self) !void {
        for (self.local_candidates.items) |local| {
            for (self.remote_candidates.items) |remote| {
                // 跳过不同类型的配对（简化实现）
                if (local.component_id != remote.component_id) continue;

                // 计算 Pair 优先级
                // priority = (2^32) * MIN(G,d) + (2^1) * MAX(G,d) + (G>d?1:0)
                const G = local.priority;
                const d = remote.priority;
                const min_priority = @min(G, d);
                const max_priority = @max(G, d);
                const priority = (@as(u64, 1) << 32) * @as(u64, min_priority) +
                    (@as(u64, 2) * @as(u64, max_priority)) +
                    (if (G > d) @as(u64, 1) else @as(u64, 0));

                // 创建 Foundation（用于配对匹配）
                const foundation = try std.fmt.allocPrint(
                    self.allocator,
                    "{s}-{s}",
                    .{ local.foundation, remote.foundation },
                );

                const pair = CandidatePair{
                    .local = local,
                    .remote = remote,
                    .priority = priority,
                    .state = .frozen, // 初始状态为 frozen
                    .foundation = foundation,
                };

                try self.candidate_pairs.append(pair);
            }
        }

        // 按优先级排序（优先级高的在前）
        std.mem.sort(CandidatePair, self.candidate_pairs.items, {}, struct {
            fn lessThan(_context: void, a: CandidatePair, b: CandidatePair) bool {
                _ = _context; // context parameter unused
                return a.priority > b.priority; // 降序
            }
        }.lessThan);
    }

    /// 开始 Connectivity Checks
    pub fn startConnectivityChecks(self: *Self) !void {
        if (self.state != .gathering and self.state != .checking) {
            return error.InvalidState;
        }

        if (self.candidate_pairs.items.len == 0) {
            return error.NoCandidatePairs;
        }

        self.state = .checking;

        // 确保 UDP 已初始化
        if (self.udp == null) {
            self.udp = try nets.Udp.init(self.schedule);
        }

        // 创建 STUN 客户端（如果还没有）
        if (self.stun == null) {
            const stun_ptr = try self.allocator.create(Stun);
            stun_ptr.* = Stun.init(self.allocator, self.schedule);
            stun_ptr.udp = self.udp;
            self.stun = stun_ptr;
        }

        // 为每个 Frozen Pair 创建 Check 并开始检查
        for (self.candidate_pairs.items) |*pair| {
            if (pair.state == .frozen) {
                pair.state = .waiting;
            }
        }

        // 按优先级排序后，从高到低进行检查
        // 简化实现：立即对所有 Waiting 的 Pair 进行检查
        for (self.candidate_pairs.items) |*pair| {
            if (pair.state == .waiting) {
                pair.state = .in_progress;
                // 在协程中执行 Connectivity Check
                _ = try self.schedule.go(performCheck, .{ self, pair });
            }
        }

        // 启动协程监听接收到的 STUN 消息并响应
        _ = try self.schedule.go(handleIncomingStunMessages, .{self});
    }

    /// 执行 Connectivity Check（协程函数）
    fn performCheck(self: *Self, pair: *CandidatePair) !void {
        const stun = self.stun orelse return error.StunNotInitialized;
        const remote_addr = pair.remote.address;

        std.log.info("ICE.performCheck: 开始 Connectivity Check (远程地址: {})", .{remote_addr});

        // 生成 transaction_id
        const transaction_id = try stun.generateTransactionId();

        // 创建并发送 STUN Binding Request（不等待响应）
        const message_type = Stun.MessageHeader.setType(.request, .binding);
        var request = Stun.Message.init(self.allocator);
        errdefer request.deinit();

        request.header = .{
            .message_type = message_type,
            .message_length = 0,
            .transaction_id = transaction_id,
        };

        const request_data = try request.encode(self.allocator);
        defer self.allocator.free(request_data);

        // 将 transaction_id 转换为字符串作为 key
        var trans_id_str: [12]u8 = undefined;
        @memcpy(&trans_id_str, &transaction_id);
        const trans_id_key = try std.fmt.allocPrint(self.allocator, "{s}", .{trans_id_str});
        defer self.allocator.free(trans_id_key);

        // 记录 pending request
        try self.pending_requests.put(trans_id_key, pair);

        // 发送请求
        _ = try stun.udp.?.sendTo(request_data, remote_addr);
        std.log.debug("ICE.performCheck: 已发送 STUN Binding Request (transaction_id: {s})", .{trans_id_key});

        // 等待响应（最多等待 5 秒）
        const current_co = try self.schedule.getCurrentCo();
        const max_wait: u64 = 5 * std.time.ns_per_s;
        const check_interval: u64 = 100 * std.time.ns_per_ms;
        var waited: u64 = 0;
        var got_response = false;

        while (waited < max_wait and !got_response) {
            try current_co.Sleep(check_interval);
            waited += check_interval;

            // 检查 pair 状态是否已更新（handleIncomingStunMessages 会更新）
            if (pair.state == .succeeded) {
                got_response = true;
                std.log.info("ICE.performCheck: Connectivity Check 成功 (远程地址: {})", .{remote_addr});

                // 检查是否应该选择这个 Pair
                if (self.selected_pair == null) {
                    self.selected_pair = pair;
                    self.setState(.connected);
                    std.log.info("ICE.performCheck: 已选择 Candidate Pair，ICE 状态变为 connected", .{});
                }
                break;
            } else if (pair.state == .failed) {
                got_response = true;
                std.log.debug("ICE.performCheck: Connectivity Check 失败", .{});
                break;
            }
        }

        // 清理 pending request
        _ = self.pending_requests.remove(trans_id_key);

        if (!got_response) {
            std.log.warn("ICE.performCheck: 等待响应超时", .{});
            pair.state = .failed;
        }

        // 检查是否所有检查都完成
        self.checkConnectionState();
    }

    /// 处理接收到的 STUN 消息（协程函数）
    /// 监听 UDP 接收到的消息，如果是 STUN Binding Request，则响应
    fn handleIncomingStunMessages(self: *Self) !void {
        if (self.udp == null) {
            return;
        }

        const udp = self.udp.?;
        var buffer: [2048]u8 = undefined;
        const current_co = try self.schedule.getCurrentCo();

        std.log.debug("ICE: 开始监听接收到的 STUN 消息", .{});

        // 持续监听，直到 ICE 连接建立或失败
        // 一旦连接建立，所有消息应该由 DTLS/SCTP 处理
        while (self.state != .connected and self.state != .completed and self.state != .failed and self.state != .closed) {
            // 接收 UDP 数据（事件驱动，会挂起协程直到数据到达）
            const result = udp.recvFrom(&buffer) catch |err| {
                // 如果是非阻塞错误（如没有数据），等待后重试
                std.log.debug("ICE.handleIncomingStunMessages: 接收数据失败: {}，等待后重试", .{err});
                try current_co.Sleep(50 * std.time.ns_per_ms);
                continue;
            };

            // 检查是否是 STUN 消息（至少 20 字节）
            if (result.data.len < 20) {
                // 可能是 DTLS 消息（最小 13 字节），跳过让 DTLS Record 处理
                continue;
            }

            // 检查是否是 DTLS 消息（DTLS 记录头第一个字节是 content_type，范围 20-255）
            // DTLS content_type: 20=change_cipher_spec, 21=alert, 22=handshake, 23=application_data
            // 如果第一个字节是 DTLS content_type，且 ICE 已连接，跳过让 DTLS Record 处理
            if (self.state == .connected or self.state == .completed) {
                if (result.data[0] >= 20 and result.data[0] <= 23) {
                    // ICE 已连接，DTLS 消息应该由 DTLS Record 处理
                    std.log.debug("ICE.handleIncomingStunMessages: ICE 已连接，收到 DTLS 消息 (首字节: {})，跳过", .{result.data[0]});
                    continue;
                }
            }

            // 检查 STUN magic cookie（在第 4-7 字节）
            if (result.data.len >= 8) {
                const magic_cookie = std.mem.readInt(u32, result.data[4..8], .big);
                if (magic_cookie != 0x2112A442) {
                    // 不是 STUN 消息，可能是 DTLS 或其他协议，跳过
                    std.log.debug("ICE.handleIncomingStunMessages: 不是 STUN 消息 (magic cookie: 0x{X})，跳过", .{magic_cookie});
                    continue;
                }
            } else {
                // 数据太短，不是有效的 STUN 消息
                continue;
            }

            // 解析 STUN 消息
            var stun_msg = Stun.Message.parse(result.data, self.allocator) catch |err| {
                std.log.debug("ICE.handleIncomingStunMessages: 解析 STUN 消息失败: {}", .{err});
                continue;
            };
            defer stun_msg.deinit();

            // 检查消息类型
            const msg_class = stun_msg.header.getClass();
            const msg_method = stun_msg.header.getMethod();

            if (msg_class == .request and msg_method == .binding) {
                // 收到 Binding Request，发送 Response
                std.log.info("ICE.handleIncomingStunMessages: 收到 STUN Binding Request 来自 {}", .{result.addr});

                if (self.stun) |stun| {
                    stun.sendBindingResponse(stun_msg, result.addr) catch |err| {
                        std.log.warn("ICE.handleIncomingStunMessages: 发送 Binding Response 失败: {}", .{err});
                    };
                }
            } else if (msg_class == .success_response and msg_method == .binding) {
                // 收到 Binding Response，查找对应的 pending request
                // 将 transaction_id 转换为字符串作为 key
                const trans_id_key = try std.fmt.allocPrint(self.allocator, "{s}", .{stun_msg.header.transaction_id});
                defer self.allocator.free(trans_id_key);

                if (self.pending_requests.get(trans_id_key)) |pair| {
                    std.log.info("ICE.handleIncomingStunMessages: 收到 STUN Binding Response，匹配到 pending request", .{});
                    pair.state = .succeeded;

                    // 检查是否应该选择这个 Pair
                    if (self.selected_pair == null) {
                        self.selected_pair = pair;
                        self.setState(.connected);
                        std.log.info("ICE.handleIncomingStunMessages: 已选择 Candidate Pair，ICE 状态变为 connected", .{});
                    }

                    // 检查是否所有检查都完成
                    self.checkConnectionState();
                } else {
                    std.log.debug("ICE.handleIncomingStunMessages: 收到 Binding Response，但没有匹配的 pending request", .{});
                }
            }
        }

        std.log.debug("ICE: 停止监听 STUN 消息 (状态: {})", .{self.state});
    }

    /// Error 类型定义
    pub const Error = error{
        InvalidState,
        UdpNotInitialized,
        StunNotInitialized,
        InvalidComponentId,
        NoCandidatePairs,
        OutOfMemory,
    };

    /// 设置状态并触发回调
    fn setState(self: *Self, new_state: State) void {
        const old_state = self.state;
        if (old_state != new_state) {
            self.state = new_state;
            std.log.info("ICE Agent 状态变化: {} -> {}", .{ old_state, new_state });

            // 触发状态变化回调
            if (self.on_state_change) |callback| {
                if (self.on_state_change_ctx) |ctx| {
                    callback(ctx, new_state);
                }
            }
        }
    }

    /// 检查状态是否已连接
    fn checkConnectionState(self: *Self) void {
        // 检查是否有成功的 Pair
        for (self.candidate_pairs.items) |*pair| {
            if (pair.state == .succeeded) {
                if (self.selected_pair == null) {
                    self.selected_pair = pair;
                    self.setState(.connected);
                }
            }
        }

        // 检查是否所有检查都完成
        var all_checked = true;
        for (self.candidate_pairs.items) |*pair| {
            if (pair.state == .frozen or pair.state == .waiting or pair.state == .in_progress) {
                all_checked = false;
                break;
            }
        }

        if (all_checked) {
            if (self.state == .connected) {
                self.setState(.completed);
            } else {
                self.setState(.failed);
            }
        }
    }
};
