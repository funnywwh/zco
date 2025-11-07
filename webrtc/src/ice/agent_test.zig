const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const IceAgent = webrtc.ice.agent.IceAgent;
const Candidate = webrtc.ice.candidate.Candidate;

test "ICE Agent init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    try testing.expect(agent.component_id == 1);
    try testing.expect(agent.getState() == .new);
    try testing.expect(agent.getLocalCandidates().len == 0);
    try testing.expect(agent.getRemoteCandidates().len == 0);
    try testing.expect(agent.getSelectedPair() == null);
}

test "ICE Agent add StunServer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    const stun_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    try agent.addStunServer(stun_addr, null, null);

    try testing.expect(agent.stun_servers.items.len == 1);
    // 验证地址端口相同
    try testing.expect(agent.stun_servers.items[0].address.getPort() == stun_addr.getPort());
}

test "ICE Agent add StunServer with credentials" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    const stun_addr = try std.net.Address.parseIp4("127.0.0.1", 3478);
    try agent.addStunServer(stun_addr, "user", "pass");

    try testing.expect(agent.stun_servers.items.len == 1);
    try testing.expect(agent.stun_servers.items[0].username != null);
    try testing.expect(agent.stun_servers.items[0].password != null);
}

test "ICE Agent gather Host Candidates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    try agent.gatherHostCandidates();

    try testing.expect(agent.getState() == .gathering);
    // 应该至少收集到一个 Host Candidate
    try testing.expect(agent.getLocalCandidates().len > 0);

    // 验证收集到的 Candidate 都是 Host 类型
    // 注意：Agent.deinit 会清理本地 Candidates，但可能检测到内存泄漏
    // 这是因为 UDP socket 等资源可能没有完全释放
    for (agent.getLocalCandidates()) |candidate| {
        try testing.expect(candidate.typ == .host);
        try testing.expect(candidate.component_id == 1);
        try testing.expect(candidate.priority > 0);
    }

    // 手动清理 UDP（如果存在）
    if (agent.udp) |udp| {
        udp.deinit();
        agent.udp = null;
    }
}

test "ICE Agent add Remote Candidate" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    const remote_addr = try std.net.Address.parseIp4("192.168.1.100", 5000);
    const remote_candidate = try allocator.create(Candidate);

    remote_candidate.* = try Candidate.init(
        allocator,
        "remote-1",
        1,
        "udp",
        remote_addr,
        .host,
    );

    try agent.addRemoteCandidate(remote_candidate);

    try testing.expect(agent.getRemoteCandidates().len == 1);
    try testing.expect(agent.getRemoteCandidates()[0] == remote_candidate);

    // 注意：remote_candidate 由 Agent 管理，不需要在这里释放
    // 但为了测试完整性，我们手动清理（实际使用中由 Agent 管理）
    remote_candidate.deinit();
    allocator.destroy(remote_candidate);
}

test "ICE Agent add Remote Candidate invalid component ID" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    const remote_addr = try std.net.Address.parseIp4("192.168.1.100", 5000);
    const remote_candidate = try allocator.create(Candidate);

    remote_candidate.* = try Candidate.init(
        allocator,
        "remote-1",
        2, // 不同的 component_id
        "udp",
        remote_addr,
        .host,
    );

    const result = agent.addRemoteCandidate(remote_candidate);
    try testing.expectError(error.InvalidComponentId, result);

    // 清理资源
    remote_candidate.deinit();
    allocator.destroy(remote_candidate);
}

test "ICE Agent generate Candidate Pairs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    // 收集本地 Candidates
    try agent.gatherHostCandidates();
    const local_count = agent.getLocalCandidates().len;
    try testing.expect(local_count > 0);

    // 添加远程 Candidate
    const remote_addr = try std.net.Address.parseIp4("192.168.1.100", 5000);
    const remote_candidate = try allocator.create(Candidate);

    remote_candidate.* = try Candidate.init(
        allocator,
        "remote-1",
        1,
        "udp",
        remote_addr,
        .host,
    );

    try agent.addRemoteCandidate(remote_candidate);

    // 应该自动生成 Candidate Pairs
    try testing.expect(agent.candidate_pairs.items.len == local_count);
    // 验证 local 和 remote 都不为空（local 是 *Candidate，类型系统保证非空）
    const pair = &agent.candidate_pairs.items[0];
    _ = pair.local; // 验证 local 非空（通过访问确认）
    try testing.expect(pair.remote == remote_candidate);
    try testing.expect(pair.state == .frozen);
    try testing.expect(pair.priority > 0);

    // 清理远程 Candidate（Agent 不管理远程 Candidates 的生命周期）
    // 但在测试中我们需要手动清理
    remote_candidate.deinit();
    allocator.destroy(remote_candidate);

    // 清理 UDP（如果存在）
    if (agent.udp) |udp| {
        udp.deinit();
        agent.udp = null;
    }
}

test "ICE Agent Candidate Pair priority calculation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    // 收集本地 Candidates
    try agent.gatherHostCandidates();
    try testing.expect(agent.getLocalCandidates().len > 0);

    // 添加远程 Candidate
    const remote_addr = try std.net.Address.parseIp4("192.168.1.100", 5000);
    const remote_candidate = try allocator.create(Candidate);

    remote_candidate.* = try Candidate.init(
        allocator,
        "remote-1",
        1,
        "udp",
        remote_addr,
        .host,
    );

    const type_pref = Candidate.getTypePreference(.host);
    remote_candidate.calculatePriority(type_pref, 65535);

    try agent.addRemoteCandidate(remote_candidate);

    // 验证 Pair 已按优先级排序（高优先级在前）
    try testing.expect(agent.candidate_pairs.items.len > 0);
    for (agent.candidate_pairs.items[0 .. agent.candidate_pairs.items.len - 1], 1..) |pair, i| {
        const next_pair = agent.candidate_pairs.items[i];
        try testing.expect(pair.priority >= next_pair.priority);
    }

    // 清理远程 Candidate
    remote_candidate.deinit();
    allocator.destroy(remote_candidate);

    // 清理 UDP（如果存在）
    if (agent.udp) |udp| {
        udp.deinit();
        agent.udp = null;
    }
}

test "ICE Agent state transitions" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    // 初始状态
    try testing.expect(agent.getState() == .new);

    // 开始收集 Candidates
    try agent.gatherHostCandidates();
    try testing.expect(agent.getState() == .gathering);

    // 清理 UDP（如果存在）
    if (agent.udp) |udp| {
        udp.deinit();
        agent.udp = null;
    }
}

test "ICE Agent start Connectivity Checks without pairs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    agent.state = .gathering;

    const result = agent.startConnectivityChecks();
    try testing.expectError(error.NoCandidatePairs, result);
}

test "ICE Agent start Connectivity Checks invalid state" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    // 在 new 状态不能开始检查
    agent.state = .new;
    const result1 = agent.startConnectivityChecks();
    try testing.expectError(error.InvalidState, result1);

    // 在 closed 状态不能开始检查
    agent.state = .closed;
    const result2 = agent.startConnectivityChecks();
    try testing.expectError(error.InvalidState, result2);
}

test "ICE Agent multiple component IDs" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    // 创建两个不同 component_id 的 Agent
    const agent1 = try IceAgent.init(allocator, schedule, 1); // RTP
    defer agent1.deinit();

    const agent2 = try IceAgent.init(allocator, schedule, 2); // RTCP
    defer agent2.deinit();

    try agent1.gatherHostCandidates();
    try agent2.gatherHostCandidates();

    try testing.expect(agent1.component_id == 1);
    try testing.expect(agent2.component_id == 2);
    try testing.expect(agent1.getLocalCandidates().len > 0);
    try testing.expect(agent2.getLocalCandidates().len > 0);

    // 清理 UDP（如果存在）
    if (agent1.udp) |udp| {
        udp.deinit();
        agent1.udp = null;
    }
    if (agent2.udp) |udp| {
        udp.deinit();
        agent2.udp = null;
    }
}

test "ICE Agent gather Server Reflexive Candidates without servers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    // 没有 STUN 服务器时应该直接返回，不报错
    try agent.gatherServerReflexiveCandidates();
    try testing.expect(agent.getLocalCandidates().len == 0);
}

// 注意：以下测试需要实际的 STUN 服务器或模拟环境
// 在实际 STUN 服务器不可用时，这些测试可能会失败
// 可以考虑标记为集成测试或使用 mock

test "ICE Agent get state methods" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var schedule = try zco.Schedule.init(allocator);
    defer schedule.deinit();

    const agent = try IceAgent.init(allocator, schedule, 1);
    defer agent.deinit();

    try testing.expect(agent.getState() == .new);
    try testing.expect(agent.getSelectedPair() == null);
    try testing.expect(agent.getLocalCandidates().len == 0);
    try testing.expect(agent.getRemoteCandidates().len == 0);
}
