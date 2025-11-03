const std = @import("std");

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
// pub const PeerConnection = peer.connection.PeerConnection;
