//! A bit set with a compile-time known number of lanes, and runtime-known lane length.
//!
//! This is essentially a simplified std.bit_set.DynamicBitSetUnmanaged, but with
//! multiple lanes, and no ability to resize.

pub fn MultiBitSet(num_lanes: comptime_int) type {
    const LaneIndex = std.math.IntFittingRange(0, num_lanes);

    return struct {
        /// The integer type used to represent a mask in this bit set
        pub const MaskInt = usize;

        /// The integer type used to shift a mask in this bit set
        pub const ShiftInt = std.math.Log2Int(MaskInt);

        bit_length: usize = 0,
        masks: [*]MaskInt,

        const Self = @This();
        pub fn init(allocator: std.mem.Allocator, bit_length: usize) !Self {
            const buf = try allocator.alloc(MaskInt, totalMasks(bit_length));
            @memset(buf, 0);
            return .{
                .bit_length = bit_length,
                .masks = buf.ptr,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.masks[0..totalMasks(self.bit_length)]);
        }

        pub fn totalMasks(bit_length: usize) usize {
            return num_lanes * numMasks(bit_length);
        }

        pub fn set(self: *Self, lane: LaneIndex, index: usize) void {
            assert(index < self.bit_length);
            self.laneSlice(lane)[maskIndex(index)] |= maskBit(index);
        }

        pub fn isSet(self: *const Self, lane: LaneIndex, index: usize) bool {
            assert(index < self.bit_length);
            return (self.laneSliceConst(lane)[maskIndex(index)] & maskBit(index)) != 0;
        }

        pub fn unset(self: *Self, lane: LaneIndex, index: usize) void {
            assert(index < self.bit_length);
            self.laneSlice(lane)[maskIndex(index)] &= ~maskBit(index);
        }

        pub fn unsetAll(self: *Self, lane: LaneIndex) void {
            @memset(self.laneSlice(lane), 0);
        }

        pub fn setAll(self: *Self, lane: LaneIndex) void {
            const masks = self.laneSlice(lane);
            @memset(masks, std.math.maxInt(MaskInt));
            masks[masks.len - 1] &= paddingMask(self.bit_length, masks.len);
        }

        /// Count number of set bits
        pub fn count(self: *const Self, lane: LaneIndex) usize {
            var total: usize = 0;
            for (self.laneSliceConst(lane)) |mask| {
                total += @popCount(mask);
            }
            return total;
        }

        pub fn setRangeValue(
            self: *Self,
            lane: LaneIndex,
            range: std.bit_set.Range,
            value: bool,
        ) void {
            var bit_set: std.bit_set.DynamicBitSetUnmanaged = .{
                .bit_length = self.bit_length,
                .masks = self.laneSlice(lane).ptr,
            };

            bit_set.setRangeValue(range, value);
        }

        /// Returns the index of the first set bit, starting at `start`,
        /// or null if there are no set bits.
        pub fn findFirstSet(
            self: *const Self,
            lane: LaneIndex,
            start: usize,
        ) ?usize {
            var offset: usize = 0;
            var mask = self.laneSliceConst(lane).ptr;
            if (start > 0) {
                const skipped_masks = @divFloor(start, @bitSizeOf(MaskInt));
                mask += skipped_masks;
                const rem: ShiftInt = @intCast(@rem(start, @bitSizeOf(MaskInt)));
                if (rem > 0) {
                    const masked = mask[0] & ((~@as(MaskInt, 0)) >> rem);
                    if (masked != 0)
                        return offset + @ctz(masked);
                }

                offset += skipped_masks * @bitSizeOf(MaskInt);
            }

            while (offset < self.bit_length) {
                if (mask[0] != 0) break;
                mask += 1;
                offset += @bitSizeOf(MaskInt);
            } else return null;
            return offset + @ctz(mask[0]);
        }

        /// Toggles all bits in `a` if they are set in lane `b`
        pub fn toggleLane(self: *Self, a: LaneIndex, b: LaneIndex) void {
            for (self.laneSlice(a), self.laneSlice(b)) |*maskA, maskB| {
                maskA.* ^= maskB;
            }
        }

        pub const Iterator = std.bit_set.DynamicBitSetUnmanaged.Iterator;

        pub fn iterator(
            self: *Self,
            lane: LaneIndex,
            comptime options: std.bit_set.IteratorOptions,
        ) Iterator(options) {
            var bit_set: std.bit_set.DynamicBitSetUnmanaged = .{
                .bit_length = self.bit_length,
                .masks = self.laneSlice(lane).ptr,
            };

            return bit_set.iterator(options);

            // bit_set.setRangeValue(range, value);
            // const masks = self.laneSlice(lane);
            // return Iterator(options).init(masks, paddingMask(self.bit_length, masks.len));
        }

        fn laneSlice(self: *Self, lane: LaneIndex) []MaskInt {
            const masks_len = numMasks(self.bit_length);
            return self.masks[lane * masks_len ..][0..masks_len];
        }

        fn laneSliceConst(self: *const Self, lane: LaneIndex) []const MaskInt {
            return @constCast(self).laneSlice(lane);
        }

        fn maskBit(index: usize) MaskInt {
            return @as(MaskInt, 1) << @as(ShiftInt, @truncate(index));
        }

        fn maskIndex(index: usize) usize {
            return index >> @bitSizeOf(ShiftInt);
        }

        fn numMasks(bit_length: usize) usize {
            return (bit_length + (@bitSizeOf(MaskInt) - 1)) / @bitSizeOf(MaskInt);
        }

        fn paddingMask(bit_length: usize, num_masks: usize) MaskInt {
            const padding_bits: ShiftInt = @intCast(num_masks * @bitSizeOf(MaskInt) - bit_length);
            return (~@as(MaskInt, 0)) >> padding_bits;
        }
    };
}

test MultiBitSet {
    const num_lanes = 8;
    const bit_length: usize = 193;
    const Set = MultiBitSet(num_lanes);

    var bit_set: Set = try .init(testing.allocator, bit_length);
    defer bit_set.deinit(testing.allocator);

    for (0..num_lanes) |l| {
        bit_set.set(@intCast(l), 0);
        try testing.expect(bit_set.isSet(@intCast(l), 0));
        bit_set.unset(@intCast(l), 0);
        try testing.expect(!bit_set.isSet(@intCast(l), 0));
    }

    bit_set.setAll(0);
    for (0..num_lanes) |l| {
        try testing.expectEqual(if (l == 0) bit_length else 0, bit_set.count(@intCast(l)));
    }

    bit_set.unsetAll(0);
    try testing.expectEqual(0, bit_set.count(0));

    bit_set.setRangeValue(0, .{ .start = 0, .end = bit_length }, true);
    try testing.expectEqual(bit_length, bit_set.count(0));

    bit_set.setRangeValue(0, .{ .start = 100, .end = bit_length }, false);
    try testing.expectEqual(100, bit_set.count(0));

    try testing.expectEqual(null, bit_set.findFirstSet(1, 0));
    for (0..bit_length) |ix| {
        const set_ix = bit_length - ix - 1;
        bit_set.set(1, set_ix);
        try testing.expectEqual(set_ix, bit_set.findFirstSet(1, 0));
    }

    bit_set.set(2, bit_length - 1);
    for (0..bit_length) |ix| {
        try testing.expectEqual(bit_length - 1, bit_set.findFirstSet(2, ix));
    }

    {
        for (0..bit_length) |ix|
            if ((ix & 0x01) == 1) bit_set.set(3, ix);

        var iter = bit_set.iterator(3, .{});
        var count: usize = 0;
        while (iter.next()) |ix| {
            try testing.expect((ix & 0x01) == 1);
            count += 1;
        }

        try testing.expectEqual(@divFloor(bit_length, 2), count);
    }
}

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
