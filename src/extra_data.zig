//! # ExtraData
//!
//! ExtraData is a wrapper around the concept of a struct + variable length arrays that directly trails the struct.
//!
//! The memory layout of this scheme looks like this:
//!   [Header struct (includes a generated struct field that contains length fields for all trailing arrays)]
//!   [Padding to align to the largest trailing data type]
//!   [Array 0]
//!   [Array 1]
//!   ...
//!   [Array N]
//!
//! The trailing arrays are sorted by descending alignment so that no padding is required between them. This
//! can be disabled by setting `sort_by_alignment` to false, if you want to preserve a specific ordering.
//!
//! The alignment of the header struct must be >= the maximum alignment of the extra data fields. Without this
//! constraint, the offsets to the extra data fields would change based on the address of the header. There is
//! a compiler error that will alert you to this, and a simple fix is to add an `align(N)` to your extra data field
//! in the header definition.
//!
//! ## Usage:
//!
//! ```zig
//! const RenderData = struct {
//!    index_buffer: IndexBufferHandle,
//!    extra: Extra.Lengths = .{},
//!
//!    const Extra = ExtraData(@This(), .{
//!         .vertex_buffers = .{ VertexBufferHandle, u3 },
//!         .textures = .{ TextureBufferHandle, u2 },
//!    }, .{});
//! }
//!
//! const render_data = RenderData.Extra.create(allocator, .{
//!     .num_vertex_buffers = 2,
//!     .num_textures = 4,
//! });
//!
//! render_data.* = .{ .index_buffer = ... };
//!
//! const accessor = RenderData.Extra.accessor(render_data);
//! accessor.vertex_buffers[0] = ... ;
//! accessor.textures[2] = ... ;
//! ```
//!
//! `RenderData.extra` is generated based on the definition, and looks like:
//!
//! ```zig
//! packed struct {
//!     num_vertex_buffers: u3 = 0,
//!     num_vertex_offsets: u2 = 0,
//! }
//! ```
//!
//! A `total_size` field can be included in the lengths struct by setting `include_total_size` in the config.
//!
//! If you are serializing the result to disk, or some other reason where you don't need the trailing
//! fields to be aligned, set `include_padding` to false.
//!
//! To support mappable serialization (where the header is `extern struct`), set `abi_sized_length` to
//! size the lengths struct to an ABI-sized integer.
//!
//! Access the variable length data with `accessor()`, which returns a struct with a slice  backed by each array.
//!

pub const Config = struct {
    // Includes a `total_size` field in the generated length struct
    include_total_size: bool = false,

    // Includes padding so that trailing arrays are aligned. Setting this to false only
    // makes sense in advanced used cases (ie. packed serialization), as alignment errors will
    // occur when accessing unaligned data.
    include_padding: bool = true,

    // Set to true to sort the trailing arrays by alignment, which results in the least amount of padding.
    // If you plan on creating ExtraData and then appending to it (ie. copying a base template, but
    // with a new set of lengths, where fields at the end now have non-zero lengths) you will need to
    // set this false so that the order of fields is stable.
    sort_by_alignment: bool = true,

    // Set to size the length struct to an ABI sized integer, so it can be included in extern and packed structs.
    abi_sized_length: bool = false,
};

pub const FieldDefinition = struct {
    type: type,
    length_type: type,
    alignment: ?comptime_int = null,
};

const std = @import("std");
const builtin = @import("builtin");
const Type = std.builtin.Type;

pub fn ExtraData(comptime THeader: type, comptime definition: anytype, comptime config: Config) type {
    const definition_type = @typeInfo(@TypeOf(definition));
    if (definition_type != .@"struct") {
        @compileError("definition must be a struct");
    }

    const definition_len = definition_type.@"struct".fields.len;
    const ExtraDataField = struct {
        value_type: type,
        value_alignment: comptime_int,
        length_field: Type.StructField,
        accessor_field: Type.StructField,
    };

    comptime var length_bits: u16 = 0;
    comptime var extra_fields: [definition_len]ExtraDataField = undefined;
    inline for (definition_type.@"struct".fields, &extra_fields) |field, *extra_field| {
        comptime var length_type: type = undefined;
        if (field.type == FieldDefinition) {
            extra_field.value_type = @field(definition, field.name).type;
            if (@field(definition, field.name).alignment) |a| {
                extra_field.value_alignment = a;
            } else {
                extra_field.value_alignment = @alignOf(extra_field.value_type);
            }
            length_type = @field(definition, field.name).length_type;
        } else {
            const field_type = @typeInfo(field.type);
            if (field_type != .@"struct" or
                !field_type.@"struct".is_tuple or
                field_type.@"struct".fields.len != 2 or
                @typeInfo(field_type.@"struct".fields[0].type) != .type or
                @typeInfo(field_type.@"struct".fields[1].type) != .type or
                @typeInfo(@field(definition, field.name)[1]) != .int)
            {
                @compileError("each field in the definition struct must be a tuple of {type, type} or FieldDefinition");
            }

            extra_field.value_type = @field(definition, field.name)[0];
            extra_field.value_alignment = @alignOf(extra_field.value_type);
            length_type = @field(definition, field.name)[1];
        }

        length_bits += @typeInfo(length_type).int.bits;
        extra_field.length_field = .{
            .name = "num_" ++ field.name,
            .type = length_type,
            .default_value_ptr = &@as(length_type, 0),
            .is_comptime = false,
            .alignment = 0,
        };

        const slice_info: std.builtin.Type = .{
            .pointer = .{
                .size = .slice,
                .is_const = false,
                .is_volatile = false,
                .alignment = extra_field.value_alignment,
                .address_space = .generic,
                .child = extra_field.value_type,
                .is_allowzero = false,
                .sentinel_ptr = null,
            },
        };

        const slice_type = @Type(slice_info);
        extra_field.accessor_field = .{
            .name = field.name,
            .type = slice_type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(slice_type),
        };
    }

    if (config.sort_by_alignment) {
        const Context = struct {
            extra_fields: []ExtraDataField,

            pub fn lessThan(comptime ctx: @This(), comptime a: usize, comptime b: usize) bool {
                return ctx.extra_fields[a].value_alignment > ctx.extra_fields[b].value_alignment;
            }

            pub fn swap(comptime ctx: @This(), comptime a: usize, comptime b: usize) void {
                std.mem.swap(ExtraDataField, &ctx.extra_fields[a], &ctx.extra_fields[b]);
            }
        };

        std.sort.insertionContext(0, extra_fields.len, Context{ .extra_fields = &extra_fields });
    }

    comptime var max_alignment = 0;
    comptime var value_types: [definition_len]type = undefined;
    comptime var value_alignments: [definition_len]comptime_int = undefined;
    comptime var length_fields: [definition_len + 1 + (if (config.include_total_size) 1 else 0)]Type.StructField = undefined;
    comptime var accessor_fields: [definition_len]Type.StructField = undefined;
    for (extra_fields, 0..) |extra_field, ix| {
        value_types[ix] = extra_field.value_type;
        value_alignments[ix] = extra_field.value_alignment;
        length_fields[ix] = extra_field.length_field;
        accessor_fields[ix] = extra_field.accessor_field;
        max_alignment = @max(max_alignment, extra_field.value_alignment);
    }

    if (config.include_total_size) {
        length_bits += @sizeOf(usize);
        length_fields[definition_len] = .{
            .name = "total_size",
            .type = usize,
            .default_value_ptr = &@as(usize, 0),
            .is_comptime = false,
            .alignment = 0,
        };
    }

    const needs_padding_field = if (config.abi_sized_length) blk: {
        const abi_bits = try std.math.ceilPowerOfTwo(u16, length_bits);
        const padding_bits = abi_bits - length_bits;
        if (padding_bits > 0) {
            const Int = std.meta.Int(.unsigned, padding_bits);
            length_fields[length_fields.len - 1] = .{
                .name = "_",
                .type = Int,
                .default_value_ptr = &@as(Int, 0),
                .is_comptime = false,
                .alignment = 0,
            };

            break :blk true;
        }

        break :blk false;
    } else false;

    const LengthsT = @Type(.{
        .@"struct" = .{
            .layout = std.builtin.Type.ContainerLayout.@"packed",
            .fields = length_fields[0 .. length_fields.len - if (needs_padding_field) 0 else 1],
            .decls = &.{},
            .is_tuple = false,
        },
    });

    const AccessorT = @Type(.{
        .@"struct" = .{
            .layout = std.builtin.Type.ContainerLayout.auto,
            .fields = &accessor_fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });

    return struct {
        pub const alignment: std.mem.Alignment = .fromByteUnits(max_alignment);
        pub const Lengths = LengthsT;
        pub const Accessor = AccessorT;

        const BufSlice = []align(@alignOf(THeader)) u8;
        const BufPtr = [*]align(@alignOf(THeader)) u8;

        fn getLengthsPtr(header: *THeader) *Lengths {
            const header_type = @typeInfo(THeader);
            switch (header_type) {
                .@"struct" => {},
                .void => @compileError("getLengths can't be used when THeader is void"),
                else => @compileError("THeader must be either be void, or a struct"),
            }

            // Find the length struct field on THeader
            const header_length_field = inline for (header_type.@"struct".fields) |field| {
                if (field.type == Lengths) break field;
            } else {
                @compileError("THeader must have a field of type " ++ @typeName(Lengths));
            };

            return &@field(header, header_length_field.name);
        }

        fn getLengths(header: *const THeader) Lengths {
            return getLengthsPtr(@constCast(header)).*;
        }

        fn validateCreateArgs() void {
            if (THeader == void) @compileError("create can't be used with a void header, use createExtraData instead");

            // Since alignForward is used, the base container must have an alignment >= the largest field
            if (config.include_padding and THeader != void and max_alignment > @alignOf(THeader)) {
                @compileError("Alignment of " ++ @typeName(THeader) ++ " must be >= " ++
                    std.fmt.comptimePrint("{d}", .{max_alignment}));
            }
        }

        /// Allocate THeader + enough memory for the extra data, including padding for alignment
        pub fn create(allocator: std.mem.Allocator, lengths: Lengths) !*THeader {
            validateCreateArgs();

            const buf = try alloc(allocator, lengths);
            const header = @as(*THeader, @ptrCast(buf.ptr));
            const lengths_ptr = getLengthsPtr(header);

            lengths_ptr.* = lengths;
            if (config.include_total_size) {
                lengths_ptr.total_size = buf.len;
            }

            return header;
        }

        pub fn dupe(allocator: std.mem.Allocator, lengths: Lengths, existing: *const THeader) !*THeader {
            validateCreateArgs();

            const existing_lengths = getLengths(existing);
            const existing_size = totalSize(existing_lengths);

            const buf = try alloc(allocator, lengths);
            const header = @as(*THeader, @ptrCast(buf.ptr));
            const lengths_ptr = getLengthsPtr(header);

            // See if we use a simply memcpy or if we need to copy each extra data slice separately
            // If only the last field (after alignment sorting) was modified we can use a simple memcpy;

            const use_trivial_copy = if (!config.sort_by_alignment) blk: {
                inline for (@typeInfo(Lengths).@"struct".fields, 0..) |field_info, ix| {
                    if (@field(existing_lengths, field_info.name) != @field(lengths, field_info.name)) {
                        break :blk ix == length_fields.len - 1;
                    }
                }

                break :blk true;
            } else false;

            if (use_trivial_copy) {
                const copy_size = @min(existing_size, buf.len);
                @memcpy(buf[0..copy_size], @as([*]const u8, @ptrCast(existing))[0..copy_size]);
                lengths_ptr.* = lengths;
            } else {
                header.* = existing.*;
                lengths_ptr.* = lengths;

                const existing_accessor = accessor(@constCast(existing));
                const dupe_accessor = accessor(header);
                inline for (@typeInfo(Accessor).@"struct".fields) |field_info| {
                    const existing_slice = @field(existing_accessor, field_info.name);
                    const dupe_slice = @field(dupe_accessor, field_info.name);
                    const len = @min(existing_slice.len, dupe_slice.len);
                    @memcpy(dupe_slice[0..len], existing_slice[0..len]);
                }
            }

            if (config.include_total_size) {
                lengths_ptr.total_size = buf.len;
            }

            return header;
        }

        /// Allocates the backing storage for THeader and all variable length fields
        pub fn alloc(allocator: std.mem.Allocator, lengths: Lengths) !BufSlice {
            return try allocator.allocWithOptions(
                u8,
                totalSize(lengths),
                .of(THeader),
                null,
            );
        }

        pub fn deinit(allocator: std.mem.Allocator, header: *THeader) void {
            allocator.free(allocation(header));
        }

        /// Returns the original backing byte slice allocation
        pub fn allocation(header: *THeader) []align(@alignOf(THeader)) u8 {
            const lengths = getLengthsPtr(header);
            var slice = std.mem.sliceAsBytes(header[0..1]);
            slice.len = totalSize(lengths.*);
            return slice;
        }

        /// Returns the size in bytes of header + variable length data, including padding for alignment
        pub fn totalSize(lengths: Lengths) usize {
            var total: usize = @sizeOf(THeader);
            inline for (value_types, value_alignments, 0..) |value_type, value_alignment, ix| {
                if (config.include_padding) {
                    total = std.mem.alignForward(usize, total, value_alignment);
                }

                total += @sizeOf(value_type) * @as(usize, @intCast(@field(lengths, length_fields[ix].name)));
            }
            return total;
        }

        /// Returns an accessor struct containing a slice field for each backing array
        pub fn accessor(header: *THeader) Accessor {
            if (THeader == void) @compileError("When using a void header, accessorFromDataPtr must be used instead of accessor");

            const iter_ptr: BufPtr = @as(BufPtr, @ptrCast(@alignCast(header))) + @as(usize, @intCast(@sizeOf(THeader)));
            return accessorFromDataPtr(getLengthsPtr(header), iter_ptr);
        }

        pub fn accessorFromDataPtr(lengths: *const Lengths, data_ptr: BufPtr) Accessor {
            @setRuntimeSafety(builtin.mode == .Debug);

            var result: Accessor = undefined;
            var iter_ptr: [*]u8 = data_ptr;
            inline for (value_types, value_alignments, accessor_fields, 0..) |value_type, value_alignment, accessor_field, ix| {
                const byte_len = @sizeOf(value_type) * @as(usize, @intCast(@field(lengths, length_fields[ix].name)));

                if (config.include_padding) {
                    iter_ptr = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(iter_ptr), value_alignment));
                } else {
                    iter_ptr = @ptrFromInt(@intFromPtr(iter_ptr));
                }

                @field(result, accessor_field.name) = @alignCast(std.mem.bytesAsSlice(value_type, iter_ptr[0..byte_len]));
                iter_ptr += byte_len;
            }

            return result;
        }

        /// Intended to be called in `serializeMappable` implementations of structs containing ExtraData
        pub fn serializeMappable(header: *const THeader, out_header: ?*THeader, serializer: anytype) !usize {
            _ = out_header;
            if (!config.include_padding)
                @compileError("data has to be aligned in order to compatible with mappable serialization");

            var required_size: usize = 0;
            const a = accessor(@constCast(header));
            inline for (extra_fields, accessor_fields) |extra_field, accessor_field| {
                if (extra_field.value_alignment != @alignOf(extra_field.value_type))
                    @compileError("custom trailing data alignments are not supported with mappable serialization");

                const result = try serializer.serializeTrailing(extra_field.value_type, @field(a, accessor_field.name)[0..]);
                required_size += result.required_size;
            }

            std.debug.assert(required_size == totalSize(getLengths(header)) - @sizeOf(THeader));
            return required_size;
        }
    };
}

const testing = std.testing;
test ExtraData {
    const Foo = struct {
        unaligned_data: bool = false,
        extra: Extra.Lengths align(8) = .{},

        const Extra = ExtraData(@This(), .{
            .shorts = .{ u16, u3 },
            .words = .{ u32, u4 },
            .doublewords = .{ u64, u8 },
        }, .{
            .include_total_size = false,
            .include_padding = true,
        });
    };

    const FooUnaligned = struct {
        unaligned_data: bool = false,
        extra: Extra.Lengths = .{},

        const Extra = ExtraData(@This(), .{
            .shorts = .{ u16, u3 },
            .words = .{ u32, u4 },
            .doublewords = .{ u64, u8 },
        }, .{
            .include_total_size = false,
            .include_padding = false,
        });
    };

    const FooExplicitAlignment = struct {
        unaligned_data: bool = false,
        extra: Extra.Lengths align(16) = .{},

        const Extra = ExtraData(@This(), .{
            .shorts = .{ u16, u8 },
            .aligned_bytes = FieldDefinition{
                .type = u8,
                .length_type = u16,
                .alignment = 16,
            },
        }, .{
            .include_total_size = false,
            .include_padding = true,
            .sort_by_alignment = false,
        });
    };

    const foo_default: Foo = .{};

    // Length types
    try testing.expectEqual(u3, @TypeOf(foo_default.extra.num_shorts));
    try testing.expectEqual(u4, @TypeOf(foo_default.extra.num_words));
    try testing.expectEqual(u8, @TypeOf(foo_default.extra.num_doublewords));

    // Default lengths
    try testing.expectEqual(@as(u3, 0), foo_default.extra.num_shorts);
    try testing.expectEqual(@as(u4, 0), foo_default.extra.num_words);
    try testing.expectEqual(@as(u8, 0), foo_default.extra.num_doublewords);

    // Allocation
    const foo = try Foo.Extra.create(testing.allocator, .{
        .num_shorts = 5,
        .num_words = 7,
        .num_doublewords = 2,
    });
    defer Foo.Extra.deinit(testing.allocator, foo);

    const foo_unaligned = try FooUnaligned.Extra.create(testing.allocator, .{
        .num_shorts = 5,
        .num_words = 7,
        .num_doublewords = 2,
    });
    defer FooUnaligned.Extra.deinit(testing.allocator, foo_unaligned);

    try testing.expectEqual(@as(u3, 5), foo.extra.num_shorts);
    try testing.expectEqual(@as(u4, 7), foo.extra.num_words);
    try testing.expectEqual(@as(u8, 2), foo.extra.num_doublewords);

    // 5 x u16 = 10
    // 7 x u32 = 28
    // 2 x u64 = 16
    try testing.expectEqual(@as(usize, @sizeOf(Foo) + 54), Foo.Extra.totalSize(foo.extra));
    try testing.expectEqual(@as(usize, @sizeOf(FooUnaligned) + 54), FooUnaligned.Extra.totalSize(foo_unaligned.extra));

    const foo_explicit_alignment = try FooExplicitAlignment.Extra.create(testing.allocator, .{
        .num_aligned_bytes = 8,
        .num_shorts = 2,
    });
    defer FooExplicitAlignment.Extra.deinit(testing.allocator, foo_explicit_alignment);

    try testing.expectEqual(u16, @TypeOf(foo_explicit_alignment.extra.num_aligned_bytes));

    // 2 x u16 = 4
    // + 12 bytes padding (not sorted)
    // 8 x u8 = 8
    try testing.expectEqual(
        @as(usize, @sizeOf(FooExplicitAlignment) + 24),
        FooExplicitAlignment.Extra.totalSize(foo_explicit_alignment.extra),
    );

    const allocation = Foo.Extra.allocation(foo);
    try testing.expectEqual(@as([*]u8, @ptrCast(foo)), allocation.ptr);
    try testing.expectEqual(Foo.Extra.totalSize(foo.extra), allocation.len);
    try testing.expectEqual(@alignOf(Foo), @typeInfo(@TypeOf(allocation.ptr)).pointer.alignment);

    const accessor = Foo.Extra.accessor(foo);
    try testing.expectEqual([]u16, @TypeOf(accessor.shorts));
    try testing.expectEqual([]u32, @TypeOf(accessor.words));
    try testing.expectEqual([]u64, @TypeOf(accessor.doublewords));
    try testing.expectEqual(@as(usize, 5), accessor.shorts.len);
    try testing.expectEqual(@as(usize, 7), accessor.words.len);
    try testing.expectEqual(@as(usize, 2), accessor.doublewords.len);

    // Verify aligned access (safety checks)
    for (accessor.shorts, 0..) |*v, ix| {
        v.* = @as(u16, @intCast(ix));
    }
    for (accessor.words, 0..) |*v, ix| {
        v.* = @as(u32, @intCast(ix));
    }
    for (accessor.doublewords, 0..) |*v, ix| {
        v.* = @as(u64, @intCast(ix));
    }

    for (accessor.shorts, 0..) |v, ix| {
        try testing.expectEqual(@as(u16, @intCast(ix)), v);
    }
    for (accessor.words, 0..) |v, ix| {
        try testing.expectEqual(@as(u32, @intCast(ix)), v);
    }
    for (accessor.doublewords, 0..) |v, ix| {
        try testing.expectEqual(@as(u64, @intCast(ix)), v);
    }

    // Total size field
    const Bar = struct {
        unaligned_data: bool = false,
        extra: Extra.Lengths = .{},

        const Extra = ExtraData(@This(), .{
            .shorts = .{ u16, u3 },
            .words = .{ u32, u4 },
            .doublewords = .{ u64, u8 },
        }, .{
            .include_total_size = true,
            .include_padding = true,
        });
    };

    const bar_default: Bar = .{};
    try testing.expectEqual(usize, @TypeOf(bar_default.extra.total_size));
    try testing.expectEqual(@as(usize, 0), bar_default.extra.total_size);

    const bar = try Bar.Extra.create(testing.allocator, .{
        .num_shorts = 5,
        .num_words = 7,
        .num_doublewords = 2,
    });
    defer Bar.Extra.deinit(testing.allocator, bar);

    try testing.expectEqual(@as(usize, @sizeOf(Bar) + 54), bar.extra.total_size);
}

test "ExtraData with no header" {
    const Extra = ExtraData(
        void,
        .{
            .shorts = .{ u16, u3 },
            .words = .{ u32, u4 },
            .doublewords = .{ u64, u8 },
        },
        .{},
    );

    const lengths: Extra.Lengths = .{
        .num_shorts = 5,
        .num_words = 7,
        .num_doublewords = 2,
    };
    const extra = try Extra.alloc(testing.allocator, lengths);
    defer testing.allocator.free(extra);

    const accessor = Extra.accessorFromDataPtr(&lengths, extra.ptr);

    for (accessor.shorts, 0..) |*v, ix| {
        v.* = @as(u16, @intCast(ix));
    }
    for (accessor.words, 0..) |*v, ix| {
        v.* = @as(u32, @intCast(ix));
    }
    for (accessor.doublewords, 0..) |*v, ix| {
        v.* = @as(u64, @intCast(ix));
    }

    for (accessor.shorts, 0..) |v, ix| {
        try testing.expectEqual(@as(u16, @intCast(ix)), v);
    }
    for (accessor.words, 0..) |v, ix| {
        try testing.expectEqual(@as(u32, @intCast(ix)), v);
    }
    for (accessor.doublewords, 0..) |v, ix| {
        try testing.expectEqual(@as(u64, @intCast(ix)), v);
    }
}

test "dupe" {
    const Foo = struct {
        bar: usize,
        extra: Extra.Lengths align(16),

        pub const Extra = ExtraData(@This(), .{
            .a = .{ u8, u3 },
            .b = .{ u16, u8 },
            .c = .{ u16, u16 },
        }, .{
            .sort_by_alignment = false,
        });
    };

    // Trivial copy path
    {
        const foo = try Foo.Extra.create(testing.allocator, .{
            .num_a = 2,
            .num_b = 8,
            .num_c = 2,
        });
        defer Foo.Extra.deinit(testing.allocator, foo);

        foo.* = .{
            .bar = 1234,
            .extra = foo.extra,
        };

        const accessor = Foo.Extra.accessor(foo);
        for (accessor.a, 0..) |*a, ix| {
            a.* = @intCast(ix);
        }

        for (accessor.b, 0..) |*b, ix| {
            b.* = @intCast(ix + 16);
        }

        for (accessor.c, 0..) |*c, ix| {
            c.* = @intCast(ix + 32);
        }

        var dupe_lengths = foo.extra;
        dupe_lengths.num_c = 6;

        const foo_dupe = try Foo.Extra.dupe(testing.allocator, dupe_lengths, foo);
        defer Foo.Extra.deinit(testing.allocator, foo_dupe);

        const dupe_accessor = Foo.Extra.accessor(foo_dupe);

        try testing.expectEqualSlices(u8, accessor.a, dupe_accessor.a);
        try testing.expectEqualSlices(u16, accessor.b[0..dupe_lengths.num_b], dupe_accessor.b);
        try testing.expectEqualSlices(u16, accessor.c, dupe_accessor.c[0..2]);
    }

    // Non-trivial copy path
    {
        const foo = try Foo.Extra.create(testing.allocator, .{
            .num_a = 2,
            .num_b = 8,
            .num_c = 2,
        });
        defer Foo.Extra.deinit(testing.allocator, foo);

        foo.* = .{
            .bar = 1234,
            .extra = foo.extra,
        };

        const accessor = Foo.Extra.accessor(foo);
        for (accessor.a, 0..) |*a, ix| {
            a.* = @intCast(ix);
        }

        for (accessor.b, 0..) |*b, ix| {
            b.* = @intCast(ix + 16);
        }

        for (accessor.c, 0..) |*c, ix| {
            c.* = @intCast(ix + 32);
        }

        var dupe_lengths = foo.extra;
        dupe_lengths.num_b = 6;

        const foo_dupe = try Foo.Extra.dupe(testing.allocator, dupe_lengths, foo);
        defer Foo.Extra.deinit(testing.allocator, foo_dupe);

        const dupe_accessor = Foo.Extra.accessor(foo_dupe);

        try testing.expectEqualSlices(u8, accessor.a, dupe_accessor.a);
        try testing.expectEqualSlices(u16, accessor.b[0..dupe_lengths.num_b], dupe_accessor.b);
        try testing.expectEqualSlices(u16, accessor.c, dupe_accessor.c);
    }
}

const serialize = @import("serialize.zig");

test "serialization" {
    const Foo = extern struct {
        const Self = @This();
        x: u32,
        y: u64,
        extra: Extra.Lengths align(16),

        pub const Extra = ExtraData(Self, .{
            .a = .{ u8, u3 },
            .b = .{ u16, u8 },
            .c = .{ u16, u16 },
        }, .{
            .abi_sized_length = true,
        });

        pub fn serializeMappable(self: *const Self, out: ?*Self, serializer: anytype) !usize {
            return Extra.serializeMappable(self, out, serializer);
        }
    };

    const foo_in = try Foo.Extra.create(testing.allocator, .{
        .num_a = 5,
        .num_b = 3,
        .num_c = 7,
    });
    defer Foo.Extra.deinit(testing.allocator, foo_in);

    const expected_a = [5]u8{ 1, 2, 3, 4, 5 };
    const expected_b = [3]u16{ 6, 7, 8 };
    const expected_c = [7]u16{ 9, 10, 11, 12, 13, 14, 15 };

    foo_in.x = 32;
    foo_in.y = 64;

    {
        const accessor = Foo.Extra.accessor(foo_in);
        @memcpy(accessor.a, expected_a[0..]);
        @memcpy(accessor.b, expected_b[0..]);
        @memcpy(accessor.c, expected_c[0..]);
    }

    const serialized = try serialize.serializeMappableAlloc(testing.allocator, Foo, foo_in, builtin.cpu.arch.endian());
    defer testing.allocator.free(serialized);

    const foo_mapped = std.mem.bytesAsValue(Foo, serialized);
    try testing.expectEqualDeep(foo_in.*, foo_mapped.*);

    {
        const accessor = Foo.Extra.accessor(foo_mapped);
        try testing.expectEqualSlices(u8, &expected_a, accessor.a);
        try testing.expectEqualSlices(u16, &expected_b, accessor.b);
        try testing.expectEqualSlices(u16, &expected_c, accessor.c);
    }
}
