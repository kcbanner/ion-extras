pub fn FreeList(
    comptime V: type,
    comptime max_entries: comptime_int,
    comptime support_iteration: bool,
) type {
    const IndexT = std.math.IntFittingRange(0, max_entries - 1);
    const AcquiredBitSet = std.bit_set.DynamicBitSetUnmanaged;

    return struct {
        const Element = union {
            element: V,
            next_free: ?IndexT,
        };

        elements: std.ArrayList(Element) = .empty,
        next_free: ?IndexT = null,
        acquired: if (support_iteration) AcquiredBitSet else void = if (support_iteration) .{} else {},

        const Self = @This();

        pub fn acquire(self: *Self, allocator: std.mem.Allocator) !IndexT {
            if (self.next_free == null) {
                try self.elements.ensureUnusedCapacity(allocator, 1);
                if (support_iteration) self.acquired.resize(allocator, self.elements.capacity, false);
            }

            return self.acquireAssumeCapacity();
        }

        pub fn acquireAssumeCapacity(self: *Self) !IndexT {
            const acquired_ix: IndexT = if (self.next_free) |next_free| blk: {
                self.next_free = self.elements.items[next_free].next_free;
                // Update the active field for safety-checked builds
                self.elements.items[next_free] = .{ .element = undefined };
                if (support_iteration) self.acquired.set(next_free);
                break :blk next_free;
            } else blk: {
                const next_free = self.elements.items.len;
                if (next_free == max_entries) return error.Overflow;
                self.elements.addOneAssumeCapacity().* = .{ .element = undefined };
                break :blk @intCast(next_free);
            };

            if (support_iteration) self.acquired.set(acquired_ix);
            return acquired_ix;
        }

        pub fn release(self: *Self, i: IndexT) void {
            self.elements.items[i] = .{ .next_free = self.next_free };
            self.next_free = i;
            if (support_iteration) self.acquired.unset(i);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, new_capacity: usize) !void {
            try self.elements.ensureTotalCapacity(allocator, new_capacity);
            if (support_iteration) try self.acquired.resize(allocator, new_capacity, false);
        }

        /// Returns a pointer to the element at `index`
        pub fn ptr(self: Self, i: IndexT) *V {
            return &self.elements.items[i].element;
        }

        /// Returns the index for a given pointer
        pub fn index(self: Self, p: *const V) !IndexT {
            if (@intFromPtr(p) < @intFromPtr(self.elements.items.ptr)) return error.OutOfBounds;
            const e: *const Element = @ptrCast(@alignCast(p));
            const i = e - self.elements.items.ptr;
            if (i >= self.elements.items.len) return error.OutOfBounds;
            return @intCast(i);
        }

        pub const Iterator = if (support_iteration) struct {
            iterator: AcquiredBitSet.Iterator(.{}),
            last_element: IndexT,
            last_visited: ?IndexT = null,

            pub fn next(self: *@This(), free_list: *const Self) ?*V {
                if (self.last_visited == self.last_element) return null;
                const ix: IndexT = @intCast(self.iterator.next() orelse return null);
                self.last_visited = ix;
                return free_list.ptr(ix);
            }
        } else void;

        pub fn iterator(self: *const Self) Iterator {
            if (!support_iteration) @compileError("`support_iteration` must be set to call iterator()");
            return .{
                .iterator = self.acquired.iterator(.{}),
                .last_element = @intCast(self.elements.items.len - 1),
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.elements.deinit(allocator);
            if (support_iteration) self.acquired.deinit(allocator);
        }
    };
}

test FreeList {
    var list: FreeList(u16, std.math.maxInt(u32), false) = .{};
    defer list.deinit(testing.allocator);

    const a = try list.acquire(testing.allocator);
    const b = try list.acquire(testing.allocator);
    const c = try list.acquire(testing.allocator);
    list.ptr(a).* = 1;
    list.ptr(b).* = 2;
    list.ptr(c).* = 3;

    try testing.expectEqual(a, try list.index(list.ptr(a)));
    try testing.expectEqual(b, try list.index(list.ptr(b)));
    try testing.expectEqual(c, try list.index(list.ptr(c)));

    list.release(a);
    const a_new = try list.acquire(testing.allocator);
    try testing.expectEqual(a, a_new);

    list.release(c);
    list.release(b);
    const b_new = try list.acquire(testing.allocator);
    const c_new = try list.acquire(testing.allocator);
    try testing.expectEqual(b, b_new);
    try testing.expectEqual(c, c_new);
}

test "overflow" {
    const max_entries = 8;
    var list: FreeList(u16, max_entries, false) = .{};
    defer list.deinit(testing.allocator);

    for (0..max_entries) |_| _ = try list.acquire(testing.allocator);
    try testing.expectError(error.Overflow, list.acquire(testing.allocator));

    list.release(0);
    _ = try list.acquire(testing.allocator);
}

test "iterator" {
    const max_entries = 128;
    var list: FreeList(u16, max_entries, true) = .{};
    defer list.deinit(testing.allocator);

    try list.ensureTotalCapacity(testing.allocator, max_entries);
    for (0..max_entries) |_| {
        const ix = try list.acquireAssumeCapacity();
        list.ptr(ix).* = @intCast(ix);
    }

    for (16..max_entries - 16) |i| list.release(@intCast(i));

    var iter_ix: usize = 0;
    var iter = list.iterator();
    while (iter.next(&list)) |elem| {
        const expected = if (iter_ix < 16) iter_ix else iter_ix + max_entries - 32;
        try testing.expectEqual(expected, elem.*);
        iter_ix += 1;
    }

    try testing.expectEqual(32, iter_ix);
}

const std = @import("std");
const testing = std.testing;
