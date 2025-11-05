const std = @import("std");

pub const connection = @import("./connection.zig");
pub const sender = @import("./sender.zig");
pub const receiver = @import("./receiver.zig");

pub const PeerConnection = connection.PeerConnection;
pub const SignalingState = connection.SignalingState;
pub const IceConnectionState = connection.IceConnectionState;
pub const IceGatheringState = connection.IceGatheringState;
pub const ConnectionState = connection.ConnectionState;
pub const Configuration = connection.Configuration;

// 浏览器兼容的类型别名
pub const RTCSessionDescription = connection.RTCSessionDescription;
pub const RTCIceCandidate = connection.RTCIceCandidate;
pub const RTCOfferOptions = connection.RTCOfferOptions;
pub const RTCAnswerOptions = connection.RTCAnswerOptions;
pub const RTCIceCandidateInit = connection.RTCIceCandidateInit;

pub const Sender = sender.Sender;
pub const Receiver = receiver.Receiver;
