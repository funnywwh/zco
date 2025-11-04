const std = @import("std");

/// 编解码器接口
/// 所有编解码器必须实现此接口
pub const Codec = struct {
    const Self = @This();

    /// 编解码器类型
    pub const Type = enum {
        audio,
        video,
    };

    /// 编码器接口
    pub const Encoder = struct {
        const SelfEncoder = @This();

        vtable: *const VTable,
        context: *anyopaque,

        /// 编码器虚函数表
        pub const VTable = struct {
            /// 编码媒体数据
            /// input: 原始媒体数据
            /// output: 编码后的数据（调用者负责释放）
            encode: *const fn (context: *anyopaque, input: []const u8, allocator: std.mem.Allocator) anyerror![]u8,

            /// 清理编码器资源
            deinit: *const fn (context: *anyopaque, allocator: std.mem.Allocator) void,

            /// 获取编码器信息
            getInfo: *const fn (context: *anyopaque) CodecInfo,
        };

        /// 编码媒体数据
        pub fn encode(self: *SelfEncoder, input: []const u8, allocator: std.mem.Allocator) ![]u8 {
            return self.vtable.encode(self.context, input, allocator);
        }

        /// 清理资源
        pub fn deinit(self: *SelfEncoder, allocator: std.mem.Allocator) void {
            self.vtable.deinit(self.context, allocator);
        }

        /// 获取编码器信息
        pub fn getInfo(self: *const SelfEncoder) CodecInfo {
            return self.vtable.getInfo(self.context);
        }
    };

    /// 解码器接口
    pub const Decoder = struct {
        const SelfDecoder = @This();

        vtable: *const VTable,
        context: *anyopaque,

        /// 解码器虚函数表
        pub const VTable = struct {
            /// 解码媒体数据
            /// input: 编码后的数据
            /// output: 解码后的原始数据（调用者负责释放）
            decode: *const fn (context: *anyopaque, input: []const u8, allocator: std.mem.Allocator) anyerror![]u8,

            /// 清理解码器资源
            deinit: *const fn (context: *anyopaque, allocator: std.mem.Allocator) void,

            /// 获取解码器信息
            getInfo: *const fn (context: *anyopaque) CodecInfo,
        };

        /// 解码媒体数据
        pub fn decode(self: *SelfDecoder, input: []const u8, allocator: std.mem.Allocator) ![]u8 {
            return self.vtable.decode(self.context, input, allocator);
        }

        /// 清理资源
        pub fn deinit(self: *SelfDecoder, allocator: std.mem.Allocator) void {
            self.vtable.deinit(self.context, allocator);
        }

        /// 获取解码器信息
        pub fn getInfo(self: *const SelfDecoder) CodecInfo {
            return self.vtable.getInfo(self.context);
        }
    };

    /// 编解码器信息
    pub const CodecInfo = struct {
        name: []const u8, // 编解码器名称（如 "opus", "vp8"）
        mime_type: []const u8, // MIME 类型（如 "audio/opus", "video/vp8"）
        payload_type: u7, // RTP 载荷类型（0-127）
        clock_rate: u32, // 采样率/时钟频率（Hz）
        channels: ?u8 = null, // 声道数（仅音频，null 表示不适用）
        type: Type, // 编解码器类型
    };
};
