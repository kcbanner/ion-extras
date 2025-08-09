// Copyable array with a fixed bound
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        pub fn slice(self: *Self) []T {
            return self.buf[0..self.len];
        }

        pub fn constSlice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        pub fn addOne(self: *Self) !*T {
            if (self.len == capacity) return error.OutOfMemory;
            defer self.len += 1;
            return &self.buf[self.len];
        }

        pub fn addOneAssumeCapacity(self: *Self) *T {
            return self.addOne() catch unreachable;
        }

        pub fn append(self: *Self, value: T) !void {
            (try self.addOne()).* = value;
        }

        pub fn appendAssumeCapacity(self: *Self, value: T) void {
            (self.addOne() catch unreachable).* = value;
        }

        pub fn appendSlice(self: *Self, values: []const T) !void {
            var array: std.ArrayListUnmanaged(T) = .{
                .items = self.buf[0..self.len],
                .capacity = capacity,
            };

            try array.appendSliceBounded(values);
            self.len = array.items.len;
        }

        pub fn pop(self: *Self) T {
            assert(self.len > 0);
            self.len -= 1;
            return self.buf[self.len];
        }

        pub fn resize(self: *Self, len: usize) !void {
            if (len > capacity) return error.OutOfMemory;
            self.len = len;
        }
    };
}

test {
    var a: BoundedArray(u8, 8) = .{};

    if (a.addOne()) |x| x.* = 5 else |err| return err;
    try testing.expectEqual(5, a.constSlice()[0]);

    try a.append(6);
    try testing.expectEqual(6, a.slice()[1]);

    try a.resize(0);
    try testing.expectEqual(0, a.constSlice().len);

    const values: []const u8 = &.{ 0, 1, 2, 3, 4, 5, 6, 7 };
    try a.appendSlice(values);
    try testing.expectEqualSlices(u8, values, a.constSlice());

    try testing.expectEqual(7, a.pop());
}

const std = @import("std");
const testing = std.testing;
const assert = std.debug.assert;
