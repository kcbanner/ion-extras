//! This is a fixed-size list that grows from either end via `add(.front)` or `add(.back)`
//!
//! Useful for applications where you have a set number of elements and need to build
//! two subsets. For example, building two lists of physics bodies that you need to add
//! or remove from the scene in a batch - added bodies are added to the front, and removed
//! bodies are added to the end.
pub fn DoubleList(comptime T: type) type {
    return struct {
        elements: []T,
        front_ix: usize,
        back_ix: usize,

        pub const empty: Self = .{
            .elements = &.{},
            .front_ix = 0,
            .back_ix = 0,
        };

        pub const End = enum { front, back };

        const Self = @This();
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return .{
                .elements = try allocator.alloc(T, capacity),
                .front_ix = 0,
                .back_ix = capacity,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.elements);
        }

        pub fn reset(self: *Self) void {
            self.front_ix = 0;
            self.back_ix = self.elements.len;
        }

        pub fn front(self: *Self) []T {
            return self.elements[0..self.front_ix];
        }

        pub fn back(self: *Self) []T {
            return self.elements[self.back_ix..];
        }

        pub fn add(self: *Self, end: End) !*T {
            if (self.front_ix == self.back_ix) return error.Overflow;
            return self.addAssumeCapacity(end);
        }

        pub fn addAssumeCapacity(self: *Self, end: End) *T {
            switch (end) {
                .front => {
                    const ptr = &self.elements[self.front_ix];
                    self.front_ix += 1;
                    return ptr;
                },
                .back => {
                    self.back_ix -= 1;
                    return &self.elements[self.back_ix];
                },
            }
        }
    };
}

test DoubleList {
    var list: DoubleList(u16) = try .init(testing.allocator, 10);
    defer list.deinit(testing.allocator);

    try testing.expectEqual(0, list.front().len);
    try testing.expectEqual(0, list.back().len);

    const expected_front: []const u16 = &.{ 0, 1, 2, 3, 4, 5 };
    const expected_back: []const u16 = &.{ 6, 7, 8, 9 };
    for (expected_front) |v| list.addAssumeCapacity(.front).* = v;
    for (0..expected_back.len) |ix| list.addAssumeCapacity(.back).* = expected_back[expected_back.len - ix - 1];

    try testing.expectEqualSlices(u16, expected_front, list.front());
    try testing.expectEqualSlices(u16, expected_back, list.back());

    try testing.expectError(error.Overflow, list.add(.back));
    try testing.expectError(error.Overflow, list.add(.front));

    list.reset();
    try testing.expectEqual(0, list.front().len);
    try testing.expectEqual(0, list.back().len);
}

const std = @import("std");
const testing = std.testing;
