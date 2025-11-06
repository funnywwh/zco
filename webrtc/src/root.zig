const std = @import("std");

// 增加协程栈大小以支持 WebRTC 复杂的调用栈
// 临时增加到 10MB 用于诊断栈溢出问题
// Debug 模式：10MB
// Release 模式：10MB
pub const DEFAULT_ZCO_STACK_SZIE = if (@import("builtin").mode == .Debug)
    1024 * 1024 * 10 // 10MB for Debug (诊断用)
else
    1024 * 1024 * 10; // 10MB for Release (诊断用)

// 导出所有 WebRTC 模块
pub const signaling = @import("./signaling/root.zig");
pub const ice = @import("./ice/root.zig");
pub const dtls = @import("./dtls/root.zig");
pub const srtp = @import("./srtp/root.zig");
pub const rtp = @import("./rtp/root.zig");
pub const sctp = @import("./sctp/root.zig");
pub const media = @import("./media/root.zig");
pub const peer = @import("./peer/root.zig");
pub const utils = @import("./utils/root.zig");

// 公共类型导出（部分模块尚未实现，暂时注释）
pub const SignalingServer = signaling.server.SignalingServer;
pub const Sdp = signaling.sdp.Sdp;
pub const Stun = ice.stun.Stun;
pub const Candidate = ice.candidate.Candidate;
pub const IceAgent = ice.agent.IceAgent;
pub const Turn = ice.turn.Turn;
pub const Packet = rtp.packet.Packet;
// pub const PeerConnection = peer.connection.PeerConnection;
