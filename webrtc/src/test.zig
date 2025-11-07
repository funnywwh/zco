const std = @import("std");

// 测试入口文件：统一导入所有子模块和测试文件
// 使用 test.zig 作为根文件，避免测试文件作为根模块时的相对路径导入问题
// 通过 webrtc 模块访问子模块，避免相对路径导入问题
const webrtc = @import("webrtc");

// 重新导出所有 WebRTC 模块
pub const signaling = webrtc.signaling;
pub const ice = webrtc.ice;
pub const dtls = webrtc.dtls;
pub const srtp = webrtc.srtp;
pub const rtp = webrtc.rtp;
pub const sctp = webrtc.sctp;
pub const media = webrtc.media;
pub const peer = webrtc.peer;
pub const utils = webrtc.utils;

// 导出常用类型
pub const SignalingServer = signaling.server.SignalingServer;
pub const Sdp = signaling.sdp.Sdp;
pub const Stun = ice.stun.Stun;
pub const Candidate = ice.candidate.Candidate;
pub const IceAgent = ice.agent.IceAgent;
pub const Turn = ice.turn.Turn;
pub const Packet = rtp.packet.Packet;
pub const PeerConnection = peer.PeerConnection;
pub const Configuration = peer.Configuration;
pub const SignalingState = peer.SignalingState;
pub const IceConnectionState = peer.IceConnectionState;
pub const IceGatheringState = peer.IceGatheringState;
pub const ConnectionState = peer.ConnectionState;
pub const Sender = peer.Sender;
pub const Receiver = peer.Receiver;
pub const Track = media.Track;
pub const DataChannel = sctp.DataChannel;

// 导入所有测试文件（让它们作为 test.zig 的子模块运行）
// 这样可以避免相对路径导入问题
// 使用 comptime 导入，确保测试代码被编译和执行
comptime {
    _ = @import("./signaling/sdp_test.zig");
    _ = @import("./signaling/message_test.zig");
    _ = @import("./ice/stun_test.zig");
    _ = @import("./ice/candidate_test.zig");
    _ = @import("./ice/agent_test.zig");
    _ = @import("./ice/turn_test.zig");
    _ = @import("./dtls/record_test.zig");
    _ = @import("./dtls/key_derivation_test.zig");
    _ = @import("./dtls/handshake_test.zig");
    _ = @import("./dtls/ecdh_test.zig");
    _ = @import("./srtp/replay_test.zig");
    _ = @import("./srtp/crypto_test.zig");
    _ = @import("./srtp/context_test.zig");
    _ = @import("./srtp/transform_test.zig");
    _ = @import("./rtp/packet_test.zig");
    _ = @import("./rtp/ssrc_test.zig");
    _ = @import("./rtp/rtcp_test.zig");
    _ = @import("./sctp/chunk_test.zig");
    _ = @import("./sctp/association_test.zig");
    _ = @import("./sctp/stream_test.zig");
    _ = @import("./sctp/datachannel_test.zig");
    _ = @import("./sctp/datachannel_send_test.zig");
    _ = @import("./sctp/datachannel_events_test.zig");
    _ = @import("./media/track_test.zig");
    _ = @import("./media/codec_test.zig");
    _ = @import("./peer/sender_test.zig");
    _ = @import("./peer/receiver_test.zig");
    _ = @import("./peer/connection_test.zig");
    _ = @import("./peer/connection_datachannel_test.zig");
    _ = @import("./peer/connection_datachannel_list_test.zig");
    _ = @import("./peer/connection_sctp_receive_test.zig");
    _ = @import("./peer/connection_integration_test.zig");
}
