const std = @import("std");
const chunk = @import("./chunk.zig");

/// SCTP 流状态
pub const StreamState = enum {
    idle, // 空闲
    open, // 打开
    closing, // 关闭中
    closed, // 已关闭
};

/// SCTP 流
/// 遵循 RFC 4960 Section 6
pub const Stream = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    stream_id: u16, // 流标识符
    state: StreamState,

    // 序列号管理
    next_sequence: u16, // 下一个要发送的序列号
    expected_sequence: u16, // 期望接收的序列号

    // 有序/无序传输
    ordered: bool, // true = 有序传输，false = 无序传输

    // 接收缓冲区（用于有序传输）
    receive_buffer: std.ArrayList(u8),

    // 发送队列（待发送的数据块）
    send_queue: std.ArrayList([]const u8),

    /// 初始化流
    pub fn init(
        allocator: std.mem.Allocator,
        stream_id: u16,
        ordered: bool,
    ) !Self {
        return Self{
            .allocator = allocator,
            .stream_id = stream_id,
            .state = .idle,
            .next_sequence = 0,
            .expected_sequence = 0,
            .ordered = ordered,
            .receive_buffer = std.ArrayList(u8).init(allocator),
            .send_queue = std.ArrayList([]const u8).init(allocator),
        };
    }

    /// 释放流资源
    pub fn deinit(self: *Self) void {
        self.receive_buffer.deinit();
        // 注意：send_queue 中的切片是借用的，不需要释放
        self.send_queue.deinit();
    }

    /// 打开流
    pub fn open(self: *Self) void {
        self.state = .open;
    }

    /// 关闭流
    pub fn close(self: *Self) void {
        self.state = .closing;
    }

    /// 检查流是否打开
    pub fn isOpen(self: *const Self) bool {
        return self.state == .open;
    }

    /// 创建 DATA 块
    /// 用于有序传输
    pub fn createDataChunk(
        self: *Self,
        allocator: std.mem.Allocator,
        tsn: u32,
        payload_protocol_id: u32,
        data: []const u8,
        beginning: bool,
        ending: bool,
    ) !chunk.DataChunk {
        var flags: u8 = if (!self.ordered) 0x04 else 0; // U flag (Unordered)
        if (beginning) flags |= 0x02; // B flag (Beginning)
        if (ending) flags |= 0x01; // E flag (Ending)

        const total_len = 16 + data.len;

        const user_data = try allocator.alloc(u8, data.len);
        errdefer allocator.free(user_data);
        @memcpy(user_data, data);

        const data_chunk = chunk.DataChunk{
            .flags = flags,
            .length = @as(u16, @intCast(total_len)),
            .tsn = tsn,
            .stream_id = self.stream_id,
            .stream_sequence = self.next_sequence,
            .payload_protocol_id = payload_protocol_id,
            .user_data = user_data,
        };

        // 更新序列号（仅有序传输）
        if (self.ordered) {
            self.next_sequence +%= 1; // 使用饱和加法
        }

        return data_chunk;
    }

    /// 处理接收到的 DATA 块
    /// 返回是否需要立即处理（有序）或可以立即处理（无序）
    pub fn processDataChunk(
        self: *Self,
        _: std.mem.Allocator,
        data_chunk: *const chunk.DataChunk,
    ) !bool {
        // 检查流状态
        if (self.state != .open) {
            return error.InvalidStreamState;
        }

        const is_unordered = (data_chunk.flags & 0x04) != 0;
        _ = (data_chunk.flags & 0x02) != 0; // is_beginning (保留用于未来扩展)
        const is_ending = (data_chunk.flags & 0x01) != 0;

        // 无序传输：立即处理
        if (is_unordered or !self.ordered) {
            // 将数据复制到接收缓冲区（需要复制，因为 data_chunk 可能在之后被释放）
            try self.receive_buffer.appendSlice(data_chunk.user_data);
            return true; // 可以立即处理
        }

        // 有序传输：检查序列号
        if (data_chunk.stream_sequence == self.expected_sequence) {
            // 序列号匹配，可以处理
            // 将数据复制到接收缓冲区（需要复制，因为 data_chunk 可能在之后被释放）
            try self.receive_buffer.appendSlice(data_chunk.user_data);
            self.expected_sequence +%= 1; // 更新期望序列号

            // 如果这是结束块，流可以关闭
            if (is_ending) {
                self.state = .closed;
            }

            return true; // 可以立即处理
        } else {
            // 序列号不匹配，需要等待（在实际实现中应该缓存）
            // 当前简化实现：返回 false 表示需要等待
            return false; // 需要等待
        }
    }

    /// 获取流标识符
    pub fn getStreamId(self: *const Self) u16 {
        return self.stream_id;
    }

    /// 获取当前状态
    pub fn getState(self: *const Self) StreamState {
        return self.state;
    }

    /// 获取接收缓冲区数据
    pub fn getReceiveBuffer(self: *Self) []u8 {
        return self.receive_buffer.items;
    }

    /// 清空接收缓冲区
    pub fn clearReceiveBuffer(self: *Self) void {
        self.receive_buffer.clearAndFree();
    }

    pub const Error = error{
        InvalidStreamState,
        OutOfMemory,
    };
};

/// SCTP 流管理器
/// 管理多个流的创建、查找和删除
pub const StreamManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    streams: std.ArrayList(Stream),

    /// 初始化流管理器
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .streams = std.ArrayList(Stream).init(allocator),
        };
    }

    /// 释放流管理器资源
    pub fn deinit(self: *Self) void {
        for (self.streams.items) |*stream| {
            stream.deinit();
        }
        self.streams.deinit();
    }

    /// 创建新流
    pub fn createStream(
        self: *Self,
        stream_id: u16,
        ordered: bool,
    ) !*Stream {
        // 检查流是否已存在
        for (self.streams.items) |*stream| {
            if (stream.stream_id == stream_id) {
                return error.StreamAlreadyExists;
            }
        }

        // 创建新流
        const stream = try self.streams.addOne();
        stream.* = try Stream.init(self.allocator, stream_id, ordered);
        stream.open();

        return stream;
    }

    /// 查找流
    pub fn findStream(self: *Self, stream_id: u16) ?*Stream {
        for (self.streams.items) |*stream| {
            if (stream.stream_id == stream_id) {
                return stream;
            }
        }
        return null;
    }

    /// 删除流
    pub fn removeStream(self: *Self, stream_id: u16) !void {
        for (self.streams.items, 0..) |stream, i| {
            if (stream.stream_id == stream_id) {
                var stream_ptr = &self.streams.items[i];
                stream_ptr.deinit();
                _ = self.streams.swapRemove(i);
                return;
            }
        }
        return error.StreamNotFound;
    }

    /// 获取所有流
    pub fn getAllStreams(self: *Self) []Stream {
        return self.streams.items;
    }

    pub const Error = error{
        StreamAlreadyExists,
        StreamNotFound,
        OutOfMemory,
    };
};
