//! Tagged heap allocator

pub const Config = struct {
    /// Maximum number of supported threads.
    num_threads: u16,
    /// Size of the blocks reserved by per-thread allocators
    block_size: comptime_int = 2 * 1024 * 1024,
    /// Whether or not to track unreachable memory
    track_fragmentation: bool = builtin.mode == .Debug,
};

const FreeBlock = struct {
    // The number of directly contiguous blocks in the free list following this one
    contiguous_length: usize,
    // Index of the next non-contiguous free block in the free list.
    next_free: ?usize,
};

pub fn TaggedAllocator(comptime TagE: type, comptime config: Config) type {
    const tag_info = @typeInfo(TagE).@"enum";
    if (!tag_info.is_exhaustive)
        @compileError("`TagE` must be an exhaustive enum");

    const tag_bits = 7;
    const TagInt = std.meta.Int(.unsigned, tag_bits);

    if (@typeInfo(tag_info.tag_type).int.bits > tag_bits)
        @compileError("`TagE` must be be backed by a u7 or smaller");
    if (!std.math.isPowerOfTwo(config.block_size))
        @compileError("`block_size` must be a power of two");
    if (config.block_size < 64 * 1024)
        @compileError("`block_size` must be at least 64KB");

    const Block = struct {
        allocator: std.heap.FixedBufferAllocator,
    };

    const Indexer = std.enums.EnumIndexer(TagE);
    const IndexMultiBitSet = MultiBitSet(Indexer.count + 1);

    return struct {
        heap: []u8,

        // The lanes in the set are indexed as follows:
        //  - [0 - Indexer.count): Lane index is @intFromEnum(TagE). Set bits indicate that block belongs to that tag
        //  - [Indexer.count]: Set bits indicate that block is allocated to some tag
        index: IndexMultiBitSet,
        // Index of the first free block. This is the minimum free index in `index[Indexer.count]`.
        next_free: ?usize,
        // Guards the non-PerThread state (the above fields and metadata inside free blocks)
        lock: std.Thread.Mutex = .{},
        // When a per-thread block is replaced because it can't fit the required allocation size,
        // the number of bytes that were unallocated in that block are added here
        fragmented_bytes: if (config.track_fragmentation) std.EnumArray(TagE, usize) else void,
        // Per-thread state. Does not need to be locked when accessed.
        threads: [config.num_threads]PerThread,

        const Self = @This();

        /// Initialize the allocator with a maximum capacity of `max_capacity`,
        /// which will be rounded up to the nearest block size.
        pub fn init(backing_allocator: std.mem.Allocator, max_capacity: usize) !Self {
            const block_capacity = std.mem.alignForward(usize, max_capacity, config.block_size);
            const num_blocks = @divExact(block_capacity, config.block_size);
            const self_size = @sizeOf(IndexMultiBitSet.MaskInt) * IndexMultiBitSet.totalMasks(num_blocks);

            const heap = try backing_allocator.alloc(u8, block_capacity + self_size);
            errdefer backing_allocator.free(heap);

            var self_buf: std.heap.FixedBufferAllocator = .init(heap[block_capacity..]);
            const self_allocator = self_buf.allocator();

            const free_block = asFreeBlock(heap, 0);
            free_block.* = .{
                .contiguous_length = num_blocks - 1,
                .next_free = null,
            };

            var self = Self{
                .heap = heap,
                .index = try .init(self_allocator, num_blocks),
                .next_free = 0,
                .threads = undefined,
                .fragmented_bytes = undefined,
            };

            for (&self.threads, 0..) |*per_thread, ix| {
                per_thread.* = .{
                    .ix = @intCast(ix),
                };
            }

            if (config.track_fragmentation) {
                self.fragmented_bytes = .initFill(0);
            }

            return self;
        }

        pub fn deinit(self: Self, backing_allocator: std.mem.Allocator) void {
            backing_allocator.free(self.heap);
        }

        /// The returned allocator is valid until this tag is freed
        pub fn allocator(self: *Self, tag: TagE, thread_ix: u8) std.mem.Allocator {
            return self.threads[thread_ix].allocator(tag);
        }

        pub fn freeTag(self: *Self, tag: TagE) void {
            self.lock.lock();
            defer self.lock.unlock();

            self.index.toggleLane(Indexer.count, @intFromEnum(tag));

            // Rebuild the linked-list of contiguous free blocks
            var iter = self.index.iterator(Indexer.count, .{ .kind = .unset });
            self.next_free = iter.next();

            var prev_ix = self.next_free orelse return;
            var free_block = asFreeBlock(self.heap, prev_ix);
            free_block.contiguous_length = 0;

            while (iter.next()) |ix| {
                if (ix == prev_ix + 1) {
                    // Continue the run of contiguous blocks
                    free_block.contiguous_length += 1;
                } else {
                    // Start a new run, link the last block to this one
                    free_block.next_free = ix;
                    free_block = asFreeBlock(self.heap, ix);
                    free_block.contiguous_length = 0;
                }

                prev_ix = ix;
            }

            free_block.next_free = null;
            self.index.unsetAll(@intFromEnum(tag));

            for (&self.threads) |*per_thread|
                per_thread.current_block.remove(tag);
        }

        fn asBlock(heap: []u8, index: usize, num_blocks: usize) Block {
            return .{
                .allocator = .init(heap[index * config.block_size ..][0 .. num_blocks * config.block_size]),
            };
        }

        fn asFreeBlock(heap: []u8, index: usize) *FreeBlock {
            return @alignCast(std.mem.bytesAsValue(FreeBlock, &heap[index * config.block_size]));
        }

        fn acquire(self: *Self, tag: TagE, num_blocks: usize) ?Block {
            assert(num_blocks > 0);

            self.lock.lock();
            defer self.lock.unlock();

            var next_free = self.next_free orelse return null;
            var free_block = asFreeBlock(self.heap, next_free);
            var prev_free_block: ?*FreeBlock = null;
            if (num_blocks > 1) {
                const min_num_trailing_blocks = num_blocks - 1;
                while (free_block.contiguous_length < min_num_trailing_blocks) {
                    next_free = free_block.next_free orelse return null;
                    prev_free_block = free_block;
                    free_block = asFreeBlock(self.heap, next_free);
                }

                const start_index = if (free_block.contiguous_length == min_num_trailing_blocks) index: {
                    // Take the entire run, including this block
                    if (prev_free_block) |prev| {
                        prev.next_free = free_block.next_free;
                    } else {
                        self.next_free = free_block.next_free;
                    }

                    break :index next_free;
                } else index: {
                    // Take the blocks from the end of this block's run
                    const index = next_free + free_block.contiguous_length - min_num_trailing_blocks;
                    free_block.contiguous_length -= num_blocks;

                    break :index index;
                };

                const range: std.bit_set.Range = .{ .start = start_index, .end = start_index + num_blocks };
                self.index.setRangeValue(@intFromEnum(tag), range, true);
                self.index.setRangeValue(Indexer.count, range, true);

                return asBlock(self.heap, start_index, num_blocks);
            } else {
                if (free_block.contiguous_length > 0) {
                    // Take the last block of this run
                    const index = next_free + free_block.contiguous_length;
                    free_block.contiguous_length -= 1;
                    self.index.set(@intFromEnum(tag), index);
                    self.index.set(Indexer.count, index);
                    return asBlock(self.heap, index, 1);
                } else {
                    // Take this block
                    self.index.set(@intFromEnum(tag), next_free);
                    self.index.set(Indexer.count, next_free);
                    self.next_free = free_block.next_free;
                    return asBlock(self.heap, next_free, 1);
                }
            }

            return null;
        }

        const PerThread = struct {
            // The alignment serves two purposes:
            // - Guarantees no false sharing between threads
            // - Leaves the lower bits free to store the tag in the context pointer
            _: void align(@max(std.math.maxInt(TagInt) + 1, std.atomic.cache_line)) = {},

            // Per-tag block that will be used for the next allocation
            current_block: std.EnumMap(TagE, Block) = .init(.{}),
            // Index into `per_thread`. Used with @fieldParentPtr to recover Self
            ix: u16,

            pub fn asContext(self: *@This(), tag: TagE) *anyopaque {
                return @ptrFromInt(@as(usize, @bitCast(@intFromPtr(self) | @intFromEnum(tag))));
            }

            pub fn fromContext(ctx: *anyopaque) struct { *@This(), TagE } {
                return .{
                    @ptrFromInt(@intFromPtr(ctx) & ~@as(u64, std.math.maxInt(TagInt))),
                    @enumFromInt(@intFromPtr(ctx) & std.math.maxInt(TagInt)),
                };
            }

            pub fn allocator(self: *@This(), tag: TagE) std.mem.Allocator {
                return .{
                    .ptr = asContext(self, tag),
                    .vtable = &.{
                        .alloc = alloc,
                        .resize = resize,
                        .remap = remap,
                        .free = free,
                    },
                };
            }

            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                const thread, const tag = fromContext(ctx);
                if (thread.current_block.getPtr(tag)) |block|
                    if (std.heap.FixedBufferAllocator.alloc(&block.allocator, len, alignment, ret_addr)) |r|
                        return r;

                const self: *Self = @fieldParentPtr(
                    "threads",
                    @as(*[config.num_threads]PerThread, @ptrCast(@as([*]PerThread, @ptrCast(thread)) - thread.ix)),
                );

                const num_blocks = std.math.divCeil(usize, len, config.block_size) catch unreachable;
                const new_block = self.acquire(tag, num_blocks) orelse return null;
                const block = thread.current_block.putUninitialized(tag);
                block.* = new_block;

                return std.heap.FixedBufferAllocator.alloc(&block.allocator, len, alignment, ret_addr);
            }

            pub fn resize(
                ctx: *anyopaque,
                buf: []u8,
                alignment: std.mem.Alignment,
                new_size: usize,
                return_address: usize,
            ) bool {
                const thread, const tag = fromContext(ctx);
                const block = thread.current_block.getPtr(tag) orelse return false;
                return std.heap.FixedBufferAllocator.resize(&block.allocator, buf, alignment, new_size, return_address);
            }

            fn remap(
                context: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                return_address: usize,
            ) ?[*]u8 {
                return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
            }

            fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, return_address: usize) void {
                const thread, const tag = fromContext(ctx);
                if (thread.current_block.getPtr(tag)) |block|
                    std.heap.FixedBufferAllocator.free(&block.allocator, buf, alignment, return_address);
            }
        };
    };
}

test TaggedAllocator {
    const Tag = enum {
        level,
        game,
        render,
    };

    const block_size = 2 * 1024 * 1024;
    const num_blocks = 16;
    const num_threads = 8;

    var heap: TaggedAllocator(Tag, .{
        .num_threads = num_threads,
        .block_size = block_size,
        .track_fragmentation = true,
    }) = try .init(testing.allocator, block_size * num_blocks);
    defer heap.deinit(testing.allocator);

    // Free tags with 0 allocs
    heap.freeTag(.level);
    heap.freeTag(.game);
    heap.freeTag(.render);

    // Verify that every block can be allocated, freed, and allocated again
    for (0..2) |_| {
        for (0..num_threads) |thread_ix| {
            const level_allocator = heap.allocator(.level, @intCast(thread_ix));
            const buf = try level_allocator.alloc(u8, block_size);
            try testing.expectEqual(block_size, buf.len);
        }

        const level_allocator = heap.allocator(.level, 0);
        for (0..num_blocks - num_threads) |_| {
            const buf = try level_allocator.alloc(u8, block_size);
            try testing.expectEqual(block_size, buf.len);
        }

        // Memory should be exhausted
        const game_allocator = heap.allocator(.game, 0);
        const render_allocator = heap.allocator(.game, 0);
        try testing.expectError(error.OutOfMemory, level_allocator.alloc(u8, 1));
        try testing.expectError(error.OutOfMemory, game_allocator.alloc(u8, 1));
        try testing.expectError(error.OutOfMemory, render_allocator.alloc(u8, 1));

        heap.freeTag(.level);
    }

    // Verify that every block can be contiguously allocated in a single allocation
    for (0..2) |_| {
        const game_allocator = heap.allocator(.game, 0);
        _ = try game_allocator.alloc(u8, num_blocks * block_size);
        try testing.expectError(error.OutOfMemory, game_allocator.alloc(u8, 1));

        heap.freeTag(.game);
    }

    const Action = struct {
        tag: Tag,
        action: union(enum) {
            alloc: struct {
                thread_ix: std.math.IntFittingRange(0, num_threads - 1),
                size: usize,
                expect_oom: bool = false,
            },
            free: void,
        },

        fn apply(self: @This(), h: *@TypeOf(heap)) !void {
            switch (self.action) {
                .alloc => |alloc| {
                    const allocator = h.allocator(self.tag, alloc.thread_ix);
                    if (alloc.expect_oom) {
                        try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
                    } else {
                        const buf = try allocator.alloc(u8, alloc.size);
                        try testing.expectEqual(alloc.size, buf.len);
                    }
                },
                .free => {
                    h.freeTag(self.tag);
                },
            }
        }
    };

    // Allocating from the same contiguous block (single thread)
    {
        const allocs: []const Action = &.{
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size * 8 } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size / 2 } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size / 2 } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size * 3 } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = 1, .expect_oom = true } } },
            .{ .tag = .level, .action = .{ .free = {} } },
        };

        for (allocs) |alloc|
            try alloc.apply(&heap);
    }

    // Verifying that freed contiguous blocks can be allocated again contiguously
    {
        const allocs: []const Action = &.{
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size * 4 } } },
            .{ .tag = .game, .action = .{ .alloc = .{ .thread_ix = 0, .size = block_size * 4 } } },
            .{ .tag = .game, .action = .{ .alloc = .{ .thread_ix = 1, .size = block_size * 4 } } },
            .{ .tag = .render, .action = .{ .alloc = .{ .thread_ix = 2, .size = block_size * 4 } } },
            .{ .tag = .game, .action = .{ .free = {} } },
            .{ .tag = .game, .action = .{ .alloc = .{ .thread_ix = 1, .size = block_size * 8 } } },
            .{ .tag = .game, .action = .{ .alloc = .{ .thread_ix = 0, .size = 1, .expect_oom = true } } },
            .{ .tag = .render, .action = .{ .alloc = .{ .thread_ix = 0, .size = 1, .expect_oom = true } } },
            .{ .tag = .level, .action = .{ .alloc = .{ .thread_ix = 0, .size = 1, .expect_oom = true } } },
            .{ .tag = .render, .action = .{ .free = {} } },
            .{ .tag = .game, .action = .{ .free = {} } },
            .{ .tag = .level, .action = .{ .free = {} } },
        };

        for (allocs) |alloc|
            try alloc.apply(&heap);
    }

    // Verifying contiguous allocation failure when fully fragmented
    {
        const game_allocator = heap.allocator(.game, 0);
        const render_allocator = heap.allocator(.render, 0);
        for (0..num_blocks) |ix| {
            if ((ix & 0x01) == 0) {
                _ = try game_allocator.alloc(u8, block_size);
            } else {
                _ = try render_allocator.alloc(u8, block_size);
            }
        }

        heap.freeTag(.render);
        try testing.expectError(error.OutOfMemory, game_allocator.alloc(u8, block_size + 1));

        for (0..num_blocks) |ix| {
            if ((ix & 0x01) == 0) {
                _ = try game_allocator.alloc(u8, block_size);
            }
        }

        try testing.expectError(error.OutOfMemory, render_allocator.alloc(u8, 1));
        heap.freeTag(.game);
    }
}

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const main = @import("main.zig");
const FreeList = main.FreeList;
const MultiBitSet = main.MultiBitSet;
