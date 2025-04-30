//! Data structures that point to data relative to their own storage

pub fn Slice(comptime T: type, comptime TLength: type) type {
    return extern struct {
        const Self = @This();
        const _T = T;
        const _TLength = TLength;

        offset: u32 = 0,
        len: TLength = 0,

        pub fn set(self: *Self, data: []const T) void {
            self.offset = @intCast(@intFromPtr(data.ptr) - @intFromPtr(self));
            self.len = @intCast(data.len);
        }

        /// Returns a slice backed by the trailing data.
        ///
        /// When iterating this slice, it's important to capture the values as pointers if they
        /// contain other relative data structures. If they are captured by value, the offsets
        /// will point into stack memory, not to the trailing data.
        pub fn slice(self: anytype) if (@typeInfo(@TypeOf(self)).pointer.is_const) []const T else []T {
            if (self.offset == 0) return &.{};
            return @as(
                if (@typeInfo(@TypeOf(self)).pointer.is_const) [*]const T else [*]T,
                @ptrFromInt(@intFromPtr(self) + self.offset),
            )[0..self.len];
        }

        pub fn sliceZ(self: anytype) if (@typeInfo(@TypeOf(self)).pointer.is_const) [:0]const T else [:0]T {
            const s = self.slice();
            return s[0 .. s.len - 1 :0];
        }

        pub fn serializeMappable(self: *const Self, out: ?*Self, serializer: anytype) !usize {
            // Checking the length here and not offset as we want to allow reserving space regardless
            // of if there is data set. `slice()` will have a length of zero if there is no data.
            if (self.len > 0) {
                const result = try serializer.serializeTrailing(T, self.slice());
                if (result.trailing) |trailing| out.?.set(trailing);
                return result.required_size;
            }

            return 0;
        }
    };
}

pub fn Pointer(comptime T: type) type {
    return extern struct {
        const Self = @This();
        const _T = T;

        offset: u32 = 0,

        pub fn set(self: *Self, pointer: ?*const T) void {
            if (pointer) |p| {
                self.offset = @intCast(@intFromPtr(p) - @intFromPtr(self));
            } else {
                self.offset = 0;
            }
        }

        pub fn ptr(self: anytype) if (@typeInfo(@TypeOf(self)).pointer.is_const) ?*const T else ?*T {
            if (self.offset == 0) return null;
            return @ptrFromInt(@intFromPtr(self) + self.offset);
        }

        pub fn serializeMappable(self: *const Self, out: ?*Self, serializer: anytype) !usize {
            if (self.ptr()) |p| {
                const result = try serializer.serializeTrailing(T, p[0..1]);
                if (result.trailing) |trailing| out.?.set(&trailing[0]);
                return result.required_size;
            }

            return 0;
        }
    };
}

/// Given an instance of a container that contains Pointer and Slice fields, returns the
/// total size of the allocation required to hold everything contiguously, including padding.
///
/// Only the fields on relative data structures need to be defined (ie. `len` and `offset`), other
/// fields can be undefined.
///
/// `offset` fields can be zero, indicating there is no trailing data for that field.
///
/// If `offset` is set, then this process works recursively, and trailing data can contain
/// other relative data structures which themselves have trailing data.
pub fn requiredSize(comptime TRoot: type, root: *const TRoot) !usize {
    validateRoot(TRoot);
    var pos: usize = @sizeOf(TRoot);
    try innerRequiredSize(TRoot, false, TRoot, root, &pos, {}, null, false);
    return pos;
}

/// The same as `requiredSize`, except lengths for Slices nested within fields in TRoot are provided.
///
/// In this version, only the lengths of Slices directly on `root` are read, the rest of the lengths
/// come from `external_lengths`.
pub fn requiredSizeExternalLengths(comptime TRoot: type, root: *const TRoot, external_lengths: []const usize) !usize {
    validateRoot(TRoot);
    var pos: usize = @sizeOf(TRoot);
    var lengths = external_lengths;
    try innerRequiredSize(TRoot, false, TRoot, root, &pos, {}, &lengths, false);
    return pos;
}

fn validateRoot(comptime TRoot: type) void {
    const root_info = @typeInfo(TRoot);
    if (root_info != .@"struct" or root_info.@"struct".layout == .auto)
        @compileError("requiresSize expects an extern struct");
}

fn innerRequiredSize(
    comptime TRoot: type,
    comptime set_offsets: bool,
    comptime T: type,
    ptr: if (set_offsets) ?*T else ?*const T,
    pos: *usize,
    offset: if (set_offsets) usize else void,
    external_lengths: ?*[]const usize,
    /// Indicates that any Slices within T should draw from `external_lengths`
    consume_external_length: bool,
) !void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |s| {
            inline for (s.fields) |field| {
                if (@typeInfo(field.type) != .@"struct") continue;

                const field_offset = if (set_offsets) offset + @offsetOf(T, field.name) else {};
                if (!@hasDecl(field.type, "_T")) {
                    if (ptr) |p| {
                        try innerRequiredSize(
                            TRoot,
                            set_offsets,
                            field.type,
                            &@field(p, field.name),
                            pos,
                            field_offset,
                            external_lengths,
                            consume_external_length,
                        );
                    }

                    continue;
                }

                const _T = @field(field.type, "_T");

                if (@alignOf(_T) > @alignOf(T))
                    @compileError("the alignment of " ++ @typeName(T) ++
                        " must be >= the alignment of all its relative field data types (" ++
                        std.fmt.comptimePrint("{}", .{@alignOf(_T)}) ++ ")");

                if (@hasDecl(field.type, "_TLength")) {
                    const _TLength = @field(field.type, "_TLength");
                    if (field.type == Slice(_T, _TLength)) {
                        // This means there is a relative data structure that contains a Slice, and its
                        // length field isn't available. This can happen when using `alloc`, since the
                        // `template` argument can only specify lengths on the root struct.
                        //
                        // Resolve this by using `allocExternal` to pass a set of lengths for the inner slices.
                        if (consume_external_length and (external_lengths == null or external_lengths.?.len == 0))
                            return error.InsufficientExternalLengths;

                        pos.* = std.mem.alignForward(usize, pos.*, @alignOf(_T));
                        const start_pos = pos.*;

                        var slice_offset, const slice_len = if (consume_external_length) blk: {
                            const len = external_lengths.?.*[0];
                            external_lengths.?.* = external_lengths.?.*[1..];
                            break :blk .{ 0, len };
                        } else blk: {
                            const slice = &@field(ptr.?, field.name);
                            break :blk .{ slice.offset, slice.len };
                        };

                        const size = slice_len * @sizeOf(_T);
                        if (set_offsets) {
                            const slice = &@field(ptr.?, field.name);
                            slice.offset = @intCast(pos.* - field_offset);
                            slice_offset = slice.offset;
                            // TODO: Should this be setting the offset if slice_len is 0?
                            if (consume_external_length) slice.len = @intCast(slice_len);
                        }
                        pos.* += size;

                        if (slice_offset == 0) {
                            // No data, only a length - children of this will consume from `external_lengths`
                            for (0..slice_len) |ix| {
                                try innerRequiredSize(
                                    TRoot,
                                    set_offsets,
                                    _T,
                                    null,
                                    pos,
                                    if (set_offsets) start_pos + ix * @sizeOf(_T) else {},
                                    external_lengths,
                                    true,
                                );
                            }
                        } else {
                            const slice = &@field(ptr.?, field.name);
                            for (slice.slice(), 0..) |*data, ix| {
                                try innerRequiredSize(
                                    TRoot,
                                    set_offsets,
                                    _T,
                                    data,
                                    pos,
                                    if (set_offsets) start_pos + ix * @sizeOf(_T) else {},
                                    external_lengths,
                                    set_offsets or external_lengths != null,
                                );
                            }
                        }
                    }
                } else if (field.type == Pointer(_T)) {
                    pos.* = std.mem.alignForward(usize, pos.*, @alignOf(_T));
                    const start_pos = pos.*;

                    var ptr_offset = if (consume_external_length) 0 else @field(ptr.?, field.name).offset;
                    if (set_offsets) {
                        const p = &@field(ptr.?, field.name);
                        p.offset = @intCast(start_pos - field_offset);
                        ptr_offset = p.offset;
                    }

                    pos.* += @sizeOf(_T);

                    if (ptr_offset == 0) {
                        // No data - children of this will consume from `external_lengths`
                        try innerRequiredSize(
                            TRoot,
                            set_offsets,
                            _T,
                            null,
                            pos,
                            if (set_offsets) start_pos else {},
                            external_lengths,
                            true,
                        );
                    } else {
                        const p = &@field(ptr.?, field.name);
                        if (p.ptr()) |data| {
                            try innerRequiredSize(
                                TRoot,
                                set_offsets,
                                _T,
                                data,
                                pos,
                                if (set_offsets) start_pos else {},
                                external_lengths,
                                set_offsets or external_lengths != null,
                            );
                        }
                    }
                }
            }
        },
        else => {},
    }
}

/// Allocates enough memory to hold TRoot and all it's trailing relative data,
/// copies `template` into the allocated memory, and sets all `offset` fields
/// to point to their storage.
///
/// This follows the same requirements as `requiredSize`:
///   - `len` and `offset` fields on Slice must be defined
///   - `offset` on Pointer must be defined
///   - other fields can be undefined
///
/// The caller should initialize the trailing data via `slice()` and `ptr`().
///
/// Storage for Pointer is always allocated, and points to undefined memory
/// in the buffer, so it's up to the caller to call `set(null)` as needed.
///
/// Since `template` is passed by value, only one layer of relative data structures can be allocated.
/// `error.ExternalLengthsRequired` will be returned if an attempt to allocate a Slice inside another
/// relative data structure.
///
/// If you need to allocate a structure that does use inner Slices, use `allocExternal`.
pub fn alloc(allocator: std.mem.Allocator, comptime TRoot: type, template: TRoot) ![]align(@alignOf(TRoot)) u8 {
    const size = try requiredSize(TRoot, &template);
    const buf = try allocator.alignedAlloc(u8, .of(TRoot), size);

    const ptr = std.mem.bytesAsValue(TRoot, buf);
    ptr.* = template;

    var pos: usize = @sizeOf(TRoot);
    _ = try innerRequiredSize(
        TRoot,
        true,
        TRoot,
        ptr,
        &pos,
        0,
        null,
        false,
    );

    return buf;
}

/// Similar to `alloc` but allows allocating storage for structs that nest Slices within Slices.
///
/// `external_lengths` provides the length fields for all Slice fields that are within other
/// relative fields, in the order the serializer will visit them. `external_lengths` does not
/// include lengths specified in the first layer (`template`).
pub fn allocExternalLengths(
    allocator: std.mem.Allocator,
    comptime TRoot: type,
    template: TRoot,
    external_lengths: []const usize,
) ![]align(@alignOf(TRoot)) u8 {
    const size = try requiredSizeExternalLengths(TRoot, &template, external_lengths);
    const buf = try allocator.alignedAlloc(u8, .of(TRoot), size);

    const ptr = std.mem.bytesAsValue(TRoot, buf);
    ptr.* = template;

    var pos: usize = @sizeOf(TRoot);
    var lengths = external_lengths;
    _ = try innerRequiredSize(
        TRoot,
        true,
        TRoot,
        ptr,
        &pos,
        0,
        &lengths,
        false,
    );

    return buf;
}

/// Recovers the original allocation given only the pointer of the buffer allocated by `alloc`.
/// The length fields on all the relative data structures must be unchanged from when `alloc` was called.
pub fn allocation(comptime TRoot: type, ptr: *TRoot) []align(@alignOf(TRoot)) u8 {
    const size = requiredSize(TRoot, ptr) catch unreachable;
    return @as([*]align(@alignOf(TRoot)) u8, @ptrCast(ptr))[0..size];
}

const std = @import("std");
const testing = std.testing;

test {

    // Pointer
    {
        const Foo = extern struct {
            a: u32 align(8),
            b: u32,
            c: Pointer(u64),
        };

        const foo: Foo = .{ .a = 1, .b = 2, .c = .{} };
        const expected = @sizeOf(Foo) + @sizeOf(u64);
        try testing.expectEqual(expected, requiredSize(Foo, &foo));

        const foo_dupe_buf = try alloc(testing.allocator, Foo, foo);
        defer testing.allocator.free(foo_dupe_buf);
        const foo_dupe = std.mem.bytesAsValue(Foo, foo_dupe_buf);

        const foo_dupe_buf_recovered = allocation(Foo, foo_dupe);
        try testing.expectEqual(foo_dupe_buf.ptr, foo_dupe_buf_recovered.ptr);
        try testing.expectEqual(foo_dupe_buf.len, foo_dupe_buf_recovered.len);

        try testing.expectEqual(foo.a, foo_dupe.a);
        try testing.expectEqual(foo.b, foo_dupe.b);
        try testing.expectEqual(8, foo_dupe.c.offset);

        foo_dupe.c.ptr().?.* = 3;
    }

    // Slice
    {
        const Foo = extern struct {
            a: u32 align(8),
            b: u32,
            c: Slice(u64, u32),
        };

        const foo: Foo = .{ .a = 1, .b = 2, .c = .{ .len = 32 } };
        try testing.expectEqual(@sizeOf(Foo) + @sizeOf(u64) * 32, requiredSize(Foo, &foo));

        const foo_dupe_buf = try alloc(testing.allocator, Foo, foo);
        defer testing.allocator.free(foo_dupe_buf);
        const foo_dupe = std.mem.bytesAsValue(Foo, foo_dupe_buf);

        try testing.expectEqual(foo.a, foo_dupe.a);
        try testing.expectEqual(foo.b, foo_dupe.b);
        try testing.expectEqual(8, foo_dupe.c.offset);
        try testing.expectEqual(32, foo_dupe.c.len);

        const slice = foo_dupe.c.slice();
        try testing.expectEqual(32, slice.len);
        for (slice) |*v| v.* = 3;
    }

    // Recursive relative data
    {
        const Bar = extern struct {
            x: u32 align(8),
            y: u32,
            z: Pointer(u64),
        };

        const Foo = extern struct {
            a: u32 align(8),
            b: u32,
            c: Slice(Bar, u32),
            d: Pointer(Bar),
        };

        const foo: Foo = .{
            .a = 1,
            .b = 2,
            .c = .{ .len = 16 },
            .d = .{},
        };

        const expected =
            @sizeOf(Foo) +
            @sizeOf(Bar) * 17 +
            @sizeOf(u64) * 17;

        try testing.expectEqual(expected, requiredSize(Foo, &foo));
    }

    // Invalid uninitialized nested slice, the length of Foo.d.z is unknown
    {
        const Bar = extern struct {
            x: u32 align(8),
            y: u32,
            z: Slice(u64, u32),
        };

        const Foo = extern struct {
            a: u32 align(8),
            b: u32,
            c: Slice(Bar, u32),
            d: Pointer(Bar),
        };

        const foo: Foo = .{
            .a = 1,
            .b = 2,
            .c = .{ .len = 16 },
            .d = .{},
        };

        try testing.expectError(
            error.InsufficientExternalLengths,
            requiredSize(Foo, &foo),
        );
    }

    // External length alloc
    {
        const Bar = extern struct {
            x: u32 align(8),
            y: u32,
            z: Slice(u64, u32),
        };

        const Foo = extern struct {
            a: u32 align(8),
            b: extern struct {
                x: Slice(u64, u32) align(8),
            },
            c: Slice(Bar, u32),
            d: Pointer(Bar),
        };

        const foo: Foo = .{
            .a = 1,
            .b = .{
                .x = .{ .len = 1 },
            },
            .c = .{ .len = 2 },
            .d = .{},
        };

        const external_lengths = [_]usize{ 3, 4, 5 };

        try testing.expectError(
            error.InsufficientExternalLengths,
            requiredSizeExternalLengths(Foo, &foo, external_lengths[0..2]),
        );

        const foo_dupe_buf = try allocExternalLengths(
            testing.allocator,
            Foo,
            foo,
            external_lengths[0..],
        );
        defer testing.allocator.free(foo_dupe_buf);
        const foo_dupe = std.mem.bytesAsValue(Foo, foo_dupe_buf);

        try testing.expectEqual(1, foo_dupe.b.x.slice().len);
        for (external_lengths[0..2], foo_dupe.c.slice()) |length, bar| {
            try testing.expectEqual(length, bar.z.len);
        }
        try testing.expectEqual(external_lengths[2], foo_dupe.d.ptr().?.z.slice().len);
    }
}
