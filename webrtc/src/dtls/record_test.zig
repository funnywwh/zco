const std = @import("std");
const testing = std.testing;
const zco = @import("zco");
// 通过 webrtc 模块访问，避免相对路径导入问题
const webrtc = @import("webrtc");
const Record = webrtc.dtls.record.Record;

test "DTLS RecordHeader encode and parse" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    const header = Record.RecordHeader{
        .content_type = .handshake,
        .version = .dtls_1_2,
        .epoch = 1,
        .sequence_number = 0x123456789ABC,
        .length = 100,
    };

    const encoded = header.encode();
    const parsed = try Record.RecordHeader.parse(&encoded);

    try testing.expect(parsed.content_type == .handshake);
    try testing.expect(parsed.version == .dtls_1_2);
    try testing.expect(parsed.epoch == 1);
    try testing.expect(parsed.sequence_number == 0x123456789ABC);
    try testing.expect(parsed.length == 100);
}

test "DTLS RecordHeader parse invalid header" {
    var buffer: [10]u8 = undefined; // 小于 13 字节
    const result = Record.RecordHeader.parse(&buffer);
    try testing.expectError(error.InvalidRecordHeader, result);
}

test "DTLS ReplayWindow checkReplay new sequence" {
    var window = Record.ReplayWindow{};

    // 新序列号应该通过
    try testing.expect(window.checkReplay(100) == false);
    try testing.expect(window.last_sequence == 100);
    try testing.expect(window.bitmap == 1);
}

test "DTLS ReplayWindow checkReplay duplicate sequence" {
    var window = Record.ReplayWindow{};
    window.last_sequence = 100;
    window.bitmap = 1;

    // 重复的序列号应该被检测为重放
    try testing.expect(window.checkReplay(99) == true);
}

test "DTLS ReplayWindow checkReplay future sequence" {
    var window = Record.ReplayWindow{};
    window.last_sequence = 100;

    // 未来的序列号应该通过并更新窗口
    try testing.expect(window.checkReplay(150) == false);
    try testing.expect(window.last_sequence == 150);
}

test "DTLS Cipher encrypt and decrypt" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 使用固定的密钥和 IV（仅用于测试）
    var key: [16]u8 = undefined;
    @memset(&key, 0x42);

    var iv: [12]u8 = undefined;
    @memset(&iv, 0x24);

    var cipher = Record.Cipher.init(key, iv);

    const plaintext = "Hello, DTLS!";
    const ciphertext = try cipher.encrypt(plaintext, allocator);
    defer allocator.free(ciphertext);

    // 密文应该比明文长（包含 16 字节 tag）
    try testing.expect(ciphertext.len == plaintext.len + 16);

    const decrypted = try cipher.decrypt(ciphertext, allocator);
    defer allocator.free(decrypted);

    try testing.expectEqualStrings(plaintext, decrypted);
}

test "DTLS Cipher decrypt invalid ciphertext" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const key = [_]u8{0} ** 16;
    const iv = [_]u8{0} ** 12;
    var cipher = Record.Cipher.init(key, iv);

    const invalid_ciphertext = &[_]u8{0} ** 10; // 小于 16 字节
    const result = cipher.decrypt(invalid_ciphertext, allocator);
    try testing.expectError(error.InvalidCiphertext, result);
}

test "DTLS Record init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    const record = try Record.init(allocator, schedule);
    defer record.deinit();

    try testing.expect(record.read_epoch == 0);
    try testing.expect(record.write_epoch == 0);
    try testing.expect(record.read_sequence_number == 0);
    try testing.expect(record.write_sequence_number == 0);
}

test "DTLS Record setReadCipher and setWriteCipher" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    const record = try Record.init(allocator, schedule);
    defer record.deinit();

    const key = [_]u8{0} ** 16;
    const iv = [_]u8{0} ** 12;

    record.setReadCipher(key, iv, 1);
    record.setWriteCipher(key, iv, 2);

    try testing.expect(record.read_epoch == 1);
    try testing.expect(record.write_epoch == 2);
    try testing.expect(record.read_cipher != null);
    try testing.expect(record.write_cipher != null);
}

test "DTLS Record send without UDP" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    const record = try Record.init(allocator, schedule);
    defer record.deinit();

    const address = try std.net.Address.parseIp4("127.0.0.1", 12345);
    const data = "test";
    const result = record.send(.application_data, data, address);
    try testing.expectError(error.NoUdpSocket, result);
}

test "DTLS Record recv without UDP" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try zco.init(allocator);
    defer zco.deinit();

    var schedule = try zco.newSchedule();
    defer schedule.deinit();

    const record = try Record.init(allocator, schedule);
    defer record.deinit();

    var buffer: [1024]u8 = undefined;
    const result = record.recv(&buffer);
    try testing.expectError(error.NoUdpSocket, result);
}

test "DTLS RecordHeader sequence number encoding" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // 测试 48 位序列号的编码和解析
    const test_cases = [_]u48{
        0,
        1,
        0xFF,
        0xFFFF,
        0xFFFFFF,
        0xFFFFFFFF,
        0xFFFFFFFFFF,
        0xFFFFFFFFFFFF,
    };

    for (test_cases) |seq_num| {
        const header = Record.RecordHeader{
            .content_type = .handshake,
            .version = .dtls_1_2,
            .epoch = 0,
            .sequence_number = seq_num,
            .length = 0,
        };

        const encoded = header.encode();
        const parsed = try Record.RecordHeader.parse(&encoded);

        try testing.expect(parsed.sequence_number == seq_num);
    }
}

test "DTLS RecordHeader version encoding" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const versions = [_]Record.ProtocolVersion{
        .dtls_1_0,
        .dtls_1_2,
        .dtls_1_3,
    };

    for (versions) |version| {
        const header = Record.RecordHeader{
            .content_type = .handshake,
            .version = version,
            .epoch = 0,
            .sequence_number = 0,
            .length = 0,
        };

        const encoded = header.encode();
        const parsed = try Record.RecordHeader.parse(&encoded);

        try testing.expect(parsed.version == version);
    }
}

test "DTLS RecordHeader content type encoding" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const content_types = [_]Record.ContentType{
        .change_cipher_spec,
        .alert,
        .handshake,
        .application_data,
    };

    for (content_types) |content_type| {
        const header = Record.RecordHeader{
            .content_type = content_type,
            .version = .dtls_1_2,
            .epoch = 0,
            .sequence_number = 0,
            .length = 0,
        };

        const encoded = header.encode();
        const parsed = try Record.RecordHeader.parse(&encoded);

        try testing.expect(parsed.content_type == content_type);
    }
}
