const std = @import("std");
const zco = @import("zco");
const nets = @import("nets");
const crypto = std.crypto;

/// DTLS 记录层实现
/// 遵循 RFC 6347
pub const Record = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    schedule: *zco.Schedule,
    udp: ?*nets.Udp = null,

    // 记录层状态
    read_epoch: u16 = 0,
    write_epoch: u16 = 0,
    read_sequence_number: u48 = 0,
    write_sequence_number: u48 = 0,

    // 加密状态（简化：使用 AES-128-GCM）
    read_cipher: ?Cipher = null,
    write_cipher: ?Cipher = null,

    // 重放保护窗口
    replay_window: ReplayWindow = .{},

    /// DTLS 内容类型
    pub const ContentType = enum(u8) {
        change_cipher_spec = 20,
        alert = 21,
        handshake = 22,
        application_data = 23,
    };

    /// DTLS 协议版本
    pub const ProtocolVersion = enum(u16) {
        dtls_1_0 = 0xfeff,
        dtls_1_2 = 0xfefd,
        dtls_1_3 = 0xfe03,
    };

    /// DTLS 记录头（13 字节）
    pub const RecordHeader = struct {
        content_type: ContentType,
        version: ProtocolVersion,
        epoch: u16,
        sequence_number: u48,
        length: u16,

        /// 编码记录头
        pub fn encode(self: RecordHeader) [13]u8 {
            var data: [13]u8 = undefined;
            data[0] = @intFromEnum(self.content_type);
            std.mem.writeInt(u16, data[1..3], @intFromEnum(self.version), std.builtin.Endian.big);
            std.mem.writeInt(u16, data[3..5], self.epoch, std.builtin.Endian.big);

            // 序列号（48位 = 6字节）
            data[5] = @as(u8, @truncate(self.sequence_number >> 40));
            data[6] = @as(u8, @truncate(self.sequence_number >> 32));
            data[7] = @as(u8, @truncate(self.sequence_number >> 24));
            data[8] = @as(u8, @truncate(self.sequence_number >> 16));
            data[9] = @as(u8, @truncate(self.sequence_number >> 8));
            data[10] = @as(u8, @truncate(self.sequence_number));

            std.mem.writeInt(u16, data[11..13], self.length, std.builtin.Endian.big);
            return data;
        }

        /// 解析记录头
        pub fn parse(data: []const u8) !RecordHeader {
            if (data.len < 13) return error.InvalidRecordHeader;

            const content_type: ContentType = @enumFromInt(data[0]);
            const version: ProtocolVersion = @enumFromInt(std.mem.readInt(u16, data[1..3], std.builtin.Endian.big));
            const epoch = std.mem.readInt(u16, data[3..5], std.builtin.Endian.big);

            // 序列号（48位 = 6字节）
            const seq_high = @as(u48, data[5]) << 40;
            const seq_mid1 = @as(u48, data[6]) << 32;
            const seq_mid2 = @as(u48, data[7]) << 24;
            const seq_mid3 = @as(u48, data[8]) << 16;
            const seq_mid4 = @as(u48, data[9]) << 8;
            const seq_low = @as(u48, data[10]);
            const sequence_number = seq_high | seq_mid1 | seq_mid2 | seq_mid3 | seq_mid4 | seq_low;

            const length = std.mem.readInt(u16, data[11..13], std.builtin.Endian.big);

            return RecordHeader{
                .content_type = content_type,
                .version = version,
                .epoch = epoch,
                .sequence_number = sequence_number,
                .length = length,
            };
        }
    };

    /// 加密算法（简化：AES-128-GCM）
    pub const Cipher = struct {
        key: [16]u8,
        iv: [12]u8,

        pub fn init(key: [16]u8, iv: [12]u8) Cipher {
            return .{
                .key = key,
                .iv = iv,
            };
        }

        /// 加密数据（AES-128-GCM）
        pub fn encrypt(self: Cipher, plaintext: []const u8, allocator: std.mem.Allocator) ![]u8 {
            // AES-128-GCM 加密
            const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;

            // 分配密文空间（明文 + tag）
            const ciphertext = try allocator.alloc(u8, plaintext.len + Aes128Gcm.tag_length);
            errdefer allocator.free(ciphertext);

            // 密文部分（不包括 tag）
            const ciphertext_only = ciphertext[0..plaintext.len];
            // Tag 部分
            var tag: [Aes128Gcm.tag_length]u8 = undefined;

            // 关联数据（AAD）：DTLS 记录头（简化：使用空数据）
            const ad: []const u8 = &[_]u8{};

            // 执行加密
            Aes128Gcm.encrypt(ciphertext_only, &tag, plaintext, ad, self.iv, self.key);

            // 将 tag 追加到密文后面
            @memcpy(ciphertext[plaintext.len..], &tag);

            return ciphertext;
        }

        /// 解密数据（AES-128-GCM）
        pub fn decrypt(self: Cipher, ciphertext: []const u8, allocator: std.mem.Allocator) ![]u8 {
            const Aes128Gcm = crypto.aead.aes_gcm.Aes128Gcm;

            if (ciphertext.len < Aes128Gcm.tag_length) return error.InvalidCiphertext;

            // 提取 tag 和密文
            const tag: [Aes128Gcm.tag_length]u8 = ciphertext[ciphertext.len - Aes128Gcm.tag_length ..][0..Aes128Gcm.tag_length].*;
            const encrypted_data = ciphertext[0 .. ciphertext.len - Aes128Gcm.tag_length];

            // 分配明文空间
            const plaintext = try allocator.alloc(u8, encrypted_data.len);
            errdefer allocator.free(plaintext);

            // 关联数据（AAD）：DTLS 记录头（简化：使用空数据）
            const ad: []const u8 = &[_]u8{};

            // 执行解密
            try Aes128Gcm.decrypt(plaintext, encrypted_data, tag, ad, self.iv, self.key);

            return plaintext;
        }
    };

    /// 重放保护窗口（滑动窗口）
    pub const ReplayWindow = struct {
        bitmap: u64 = 0, // 64位位图
        last_sequence: u48 = 0,

        /// 检查序列号是否已接收（重放检测）
        pub fn checkReplay(self: *ReplayWindow, sequence: u48) bool {
            // 如果序列号太旧（超出窗口），拒绝
            if (sequence < self.last_sequence) {
                const diff = self.last_sequence - sequence;
                if (diff > 64) return true; // 超出窗口范围

                // 检查位图
                const bit_pos = @as(u6, @intCast(diff - 1));
                if (self.bitmap & (@as(u64, 1) << bit_pos) != 0) {
                    return true; // 已接收，重放
                }

                // 标记为已接收
                self.bitmap |= @as(u64, 1) << bit_pos;
                return false;
            } else {
                // 新序列号，更新窗口
                const diff = sequence - self.last_sequence;
                if (diff > 64) {
                    // 序列号跳跃太大，重置窗口
                    self.bitmap = 1; // 标记当前序列号
                    self.last_sequence = sequence;
                    return false;
                }

                // 更新位图
                self.bitmap <<= @intCast(diff);
                self.bitmap |= 1; // 标记当前序列号
                self.last_sequence = sequence;
                return false;
            }
        }
    };

    /// 初始化 DTLS 记录层
    pub fn init(allocator: std.mem.Allocator, schedule: *zco.Schedule) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .schedule = schedule,
            .udp = null,
        };
        return self;
    }

    /// 清理资源
    pub fn deinit(self: *Self) void {
        if (self.udp) |udp| {
            udp.deinit();
        }
        self.allocator.destroy(self);
    }

    /// 设置 UDP socket
    pub fn setUdp(self: *Self, udp: *nets.Udp) void {
        std.log.debug("DTLS Record.setUdp: 关联 UDP socket", .{});
        self.udp = udp;
        std.log.debug("DTLS Record.setUdp: UDP socket 已关联", .{});
    }

    /// 设置读取加密状态
    pub fn setReadCipher(self: *Self, key: [16]u8, iv: [12]u8, epoch: u16) void {
        self.read_cipher = Cipher.init(key, iv);
        self.read_epoch = epoch;
        self.read_sequence_number = 0;
    }

    /// 设置写入加密状态
    pub fn setWriteCipher(self: *Self, key: [16]u8, iv: [12]u8, epoch: u16) void {
        self.write_cipher = Cipher.init(key, iv);
        self.write_epoch = epoch;
        self.write_sequence_number = 0;
    }

    /// 发送 DTLS 记录
    pub fn send(self: *Self, content_type: ContentType, data: []const u8, address: std.net.Address) !void {
        if (self.udp == null) return error.NoUdpSocket;

        std.log.debug("DTLS Record.send: 发送 {} 类型记录 ({} 字节) 到 {}", .{ content_type, data.len, address });

        // 加密数据（如果有写加密）
        var payload: []const u8 = data;
        var encrypted_payload: ?[]u8 = null;
        defer if (encrypted_payload) |p| self.allocator.free(p);

        if (self.write_cipher) |cipher| {
            encrypted_payload = try cipher.encrypt(data, self.allocator);
            payload = encrypted_payload.?;
            std.log.debug("DTLS Record.send: 数据已加密 ({} -> {} 字节)", .{ data.len, payload.len });
        } else {
            std.log.debug("DTLS Record.send: 使用明文发送（未设置写加密）", .{});
        }

        // 构建记录头
        const header = RecordHeader{
            .content_type = content_type,
            .version = .dtls_1_2,
            .epoch = self.write_epoch,
            .sequence_number = self.write_sequence_number,
            .length = @as(u16, @intCast(payload.len)),
        };

        // 编码记录
        var record = std.ArrayList(u8).init(self.allocator);
        defer record.deinit();

        const header_bytes = header.encode();
        try record.appendSlice(&header_bytes);
        try record.appendSlice(payload);

        std.log.debug("DTLS Record.send: 发送 DTLS 记录 (总长度: {} 字节)", .{record.items.len});

        // 发送
        const sent = try self.udp.?.sendTo(record.items, address);
        std.log.debug("DTLS Record.send: 已通过 UDP 发送 {} 字节", .{sent});

        // 更新序列号
        self.write_sequence_number +%= 1;
    }

    /// 接收 DTLS 记录
    pub fn recv(self: *Self, buffer: []u8) !struct { content_type: ContentType, data: []u8, from: std.net.Address } {
        if (self.udp == null) return error.NoUdpSocket;

        std.log.debug("DTLS Record.recv: 等待接收 UDP 数据...", .{});
        var recv_buffer: [2048]u8 = undefined;

        // 检查 UDP socket 是否存在
        if (self.udp == null) {
            std.log.err("DTLS Record.recv: UDP socket 为 null", .{});
            return error.NoUdpSocket;
        }

        std.log.debug("DTLS Record.recv: 调用 UDP.recvFrom...", .{});
        const result = self.udp.?.recvFrom(&recv_buffer) catch |err| {
            std.log.err("DTLS Record.recv: UDP.recvFrom 失败: {}", .{err});
            return err;
        };

        std.log.debug("DTLS Record.recv: 收到 UDP 数据 ({} 字节) 来自 {}", .{ result.data.len, result.addr });

        if (result.data.len < 13) {
            std.log.debug("DTLS Record.recv: 数据太短 ({} 字节 < 13 字节)", .{result.data.len});
            return error.InvalidRecord;
        }

        // 解析记录头
        const header = try RecordHeader.parse(result.data);
        std.log.debug("DTLS Record.recv: 解析记录头 (类型: {}, epoch: {}, 序列号: {}, 长度: {})", .{ header.content_type, header.epoch, header.sequence_number, header.length });

        // 检查重放（如果已加密）
        if (self.read_cipher != null) {
            if (self.replay_window.checkReplay(header.sequence_number)) {
                std.log.debug("DTLS Record.recv: 检测到重放 (序列号: {})", .{header.sequence_number});
                return error.ReplayDetected;
            }
        }

        // 提取负载
        const payload_data = result.data[13..];
        if (payload_data.len < header.length) {
            std.log.debug("DTLS Record.recv: 数据不完整 (需要 {} 字节，实际 {} 字节)", .{ header.length, payload_data.len });
            return error.IncompleteRecord;
        }

        const encrypted_payload = payload_data[0..header.length];
        std.log.debug("DTLS Record.recv: 提取负载 ({} 字节)", .{encrypted_payload.len});

        // 解密数据（如果有读加密）
        var decrypted_data: ?[]u8 = null;
        defer if (decrypted_data) |d| self.allocator.free(d);

        const payload = if (self.read_cipher) |cipher| blk: {
            std.log.debug("DTLS Record.recv: 开始解密数据 ({} 字节)", .{encrypted_payload.len});
            decrypted_data = try cipher.decrypt(encrypted_payload, self.allocator);
            std.log.debug("DTLS Record.recv: 解密完成 ({} -> {} 字节)", .{ encrypted_payload.len, decrypted_data.?.len });
            break :blk decrypted_data.?;
        } else blk: {
            std.log.debug("DTLS Record.recv: 使用明文（未设置读加密）", .{});
            break :blk encrypted_payload;
        };

        // 复制到用户缓冲区
        if (payload.len > buffer.len) return error.BufferTooSmall;
        @memcpy(buffer[0..payload.len], payload);

        // 更新读取序列号（如果 epoch 匹配）
        if (header.epoch == self.read_epoch) {
            self.read_sequence_number = header.sequence_number;
        }

        return .{
            .content_type = header.content_type,
            .data = buffer[0..payload.len],
            .from = result.addr,
        };
    }

    pub const Error = error{
        InvalidRecordHeader,
        InvalidRecord,
        IncompleteRecord,
        InvalidCiphertext,
        ReplayDetected,
        NoUdpSocket,
        BufferTooSmall,
        OutOfMemory,
    };
};
