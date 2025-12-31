//! UUID v4 generation utilities.

const std = @import("std");

/// A UUID v4 represented as a 36-character string (with hyphens).
pub const Uuid = [36]u8;

/// Generate a UUID v4 string.
/// Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
/// where x is any hex digit and y is one of 8, 9, a, or b.
pub fn v4() Uuid {
    var buf: Uuid = undefined;
    v4WithRandom(&buf, std.crypto.random);
    return buf;
}

/// Generate a UUID v4 using a provided random source.
/// Useful for testing with deterministic random.
pub fn v4WithRandom(buf: *Uuid, random: anytype) void {
    var random_bytes: [16]u8 = undefined;
    random.bytes(&random_bytes);
    formatUuid(buf, &random_bytes);
}

/// Format 16 random bytes into a UUID string.
fn formatUuid(buf: *Uuid, random_bytes: *[16]u8) void {
    // Set version (4) and variant (RFC 4122)
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var i: usize = 0;
    var j: usize = 0;

    // Format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    while (j < 16) : (j += 1) {
        if (j == 4 or j == 6 or j == 8 or j == 10) {
            buf[i] = '-';
            i += 1;
        }
        buf[i] = hex[random_bytes[j] >> 4];
        buf[i + 1] = hex[random_bytes[j] & 0x0f];
        i += 2;
    }
}

/// Validate that a string is a valid UUID format.
pub fn isValid(str: []const u8) bool {
    if (str.len != 36) return false;

    for (str, 0..) |c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (c != '-') return false;
        } else {
            if (!std.ascii.isHex(c)) return false;
        }
    }
    return true;
}

// Tests
test "v4 generates valid UUID format" {
    const uuid = v4();
    try std.testing.expect(isValid(&uuid));
}

test "v4 generates different UUIDs" {
    const uuid1 = v4();
    const uuid2 = v4();
    try std.testing.expect(!std.mem.eql(u8, &uuid1, &uuid2));
}

test "v4 has correct version nibble" {
    const uuid = v4();
    // Position 14 should be '4' (version)
    try std.testing.expectEqual(@as(u8, '4'), uuid[14]);
}

test "v4 has correct variant nibble" {
    const uuid = v4();
    // Position 19 should be '8', '9', 'a', or 'b' (variant)
    const variant = uuid[19];
    try std.testing.expect(variant == '8' or variant == '9' or variant == 'a' or variant == 'b');
}

test "isValid accepts valid UUIDs" {
    try std.testing.expect(isValid("550e8400-e29b-41d4-a716-446655440000"));
    try std.testing.expect(isValid("00000000-0000-0000-0000-000000000000"));
    try std.testing.expect(isValid("ffffffff-ffff-ffff-ffff-ffffffffffff"));
}

test "isValid rejects invalid UUIDs" {
    try std.testing.expect(!isValid(""));
    try std.testing.expect(!isValid("550e8400-e29b-41d4-a716-44665544000")); // too short
    try std.testing.expect(!isValid("550e8400-e29b-41d4-a716-4466554400000")); // too long
    try std.testing.expect(!isValid("550e8400e29b-41d4-a716-446655440000")); // missing hyphen
    try std.testing.expect(!isValid("550e8400-e29b-41d4-a716_446655440000")); // wrong separator
    try std.testing.expect(!isValid("550e8400-e29b-41d4-a716-44665544000g")); // invalid hex
}

test "v4WithRandom is deterministic with fixed random" {
    const TestRandom = struct {
        pub fn bytes(self: *@This(), buf: []u8) void {
            _ = self;
            for (buf) |*b| {
                b.* = 0xab;
            }
        }
    };

    var random = TestRandom{};
    var uuid1: Uuid = undefined;
    var uuid2: Uuid = undefined;

    v4WithRandom(&uuid1, &random);
    v4WithRandom(&uuid2, &random);

    try std.testing.expectEqualStrings(&uuid1, &uuid2);
}
