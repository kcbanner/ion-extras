//! Serialization / deserialization to / from byte streams.
//!
//! There are two forms of serialization: mappable and non-mappable.
//!
//! Mappable serialization allows for the resulting buffer to be directly cast
//! to the type itself and used directly. Variable length fields place their
//! data directly after the root struct in memory, and relative data structures
//! are used to access it. Because layouts must match exactly for this
//! to work, this form of serialization doesn't support versioning.
//!
//! Non-mappable (packed) serialization serializes all fields in-order into a byte
//! stream in a more compact form (no padding, variable length integer encoding).
//! Variable length data is serialized in-line. This form requires a deserialization
//! step to access the data, as it can't be directly mapped.
//!
//! Non-mappable serialization supports versioning. The serializer can skip over
//! removed fields if they are present in an old data stream, or provide defaults
//! for added fields if they are missing from the data stream.

pub const Config = struct {
    /// Version of the serializer / deserializer
    serializer_version: u32 = 0,

    /// Version of the data in the byte stream being read / written
    /// Must be <= `serializer_version`.
    data_version: u32 = 0,

    /// Endianness of the serialized data
    endian: std.builtin.Endian = native_endian,
};

/// Serializes T into a packed bytes
pub fn serializePacked(writer: std.io.AnyWriter, comptime T: type, ptr: *const T, config: Config) !void {
    if (config.data_version > config.serializer_version) return error.UnknownFutureVersion;

    var serializer: Serializer(true) = .{
        .allocator = {},
        .config = config,
        .writer = writer,
        .reader = {},
    };

    try serializer.serialize(T, ptr);
}

/// Serializes T into a slice of packed bytes allocated by `allocator`.
pub fn serializeAlloc(allocator: std.mem.Allocator, comptime T: type, ptr: *const T, config: Config) ![]u8 {
    if (config.data_version > config.serializer_version) return error.UnknownFutureVersion;

    var buf: std.ArrayListUnmanaged(u8) = .{};
    var serializer: Serializer(true) = .{
        .allocator = {},
        .config = config,
        .writer = buf.writer(allocator).any(),
        .reader = {},
    };

    try serializer.serialize(T, ptr);
    return buf.toOwnedSlice(allocator);
}

/// Deserializes from a slice of packed bytes into ptr.
/// Variable length fields are allocated using `allocator`.
/// It's recommended to use a `std.heap.ArenaAllocator`.
pub fn deserializeFromSliceAlloc(
    allocator: std.mem.Allocator,
    comptime T: type,
    ptr: *T,
    s: []const u8,
    config: Config,
) !void {
    if (config.data_version > config.serializer_version) return error.UnknownFutureVersion;

    var stream = std.io.fixedBufferStream(s);
    var serializer: Serializer(false) = .{
        .allocator = allocator,
        .config = config,
        .writer = {},
        .reader = stream.reader().any(),
    };

    try serializer.serialize(T, ptr);
}

/// Serializes struct T in a form that the memory can be cast to *T and used directly.
///
/// For structs with no variable length fields (and matching endianess) this is equivalent to memcpy.
///
/// For types with supported variable length fields, the variable length data will trail T
/// in the resulting buffer. In order for a container to support serializing it's variable
/// length fields, it should implement:
///
///     `fn serializeMappable(self: *const T, out: ?*T, serializer: anytype) !usize`
///
/// This function will be called twice during serialization - once where `out` is null, when
/// the serializer is measuring the length of all the variable length fields, and then with
/// the real pointer value of the struct in the destination buffer. The return value of this
/// function is the total number of bytes required for serialization including all children.
///
/// This function should write any variable length data using `serializer.serializeTrailing`.
/// When `out` is non-null, it should be used to update any fields that require it (such
/// as relative offsets) in-place.
///
/// Typically, implementations will sum the results of all their calls to `serializer.serializeTrailing`
/// as their return value - that function handles adding padding to the stream so the length it returns
/// may be larger than the trailing data, depending on what preceded it.
///
/// It is valid for the types of the variable length fields to themselves contain variable length fields.
///
/// The memory layout looks like this (here variable length field 0 contains structs that also have variable length fields):
///
///   [T]
///   [?Padding]
///   [Data for variable length field 0]
///   [?Padding]
///   [Data for variable length field 0.0]
///   [?Padding]
///   [Data for variable length field 0.1]
///   ...
///   [Data for variable length field 0.N]
///   [?Padding]
///   [Data for variable length field 1]
///   ...
///   [?Padding]
///   [Data for variable length field N]
///
/// It's recommended to order your variable length fields in order of descending alignment, to minimize padding.
///
pub fn serializeMappableAlloc(
    allocator: std.mem.Allocator,
    comptime T: type,
    ptr: *const T,
    endian: std.builtin.Endian,
) ![]align(@alignOf(T)) u8 {
    const S = MappableSerializer(T);
    const size = S.requiredSize(ptr, endian);
    const buf = try allocator.alignedAlloc(u8, @alignOf(T), size);
    try S.serialize(ptr, buf, endian);
    return buf;
}

/// Same as the above but serializes directly into a buffer.
pub fn serializeMappable(
    comptime T: type,
    ptr: *const T,
    endian: std.builtin.Endian,
    buf: []align(@alignOf(T)) u8,
) !void {
    try MappableSerializer(T).serialize(ptr, buf, endian);
}

/// Returns true if serializing T by using memcpy is equivalent to Serializer.serialize(T)
fn isTriviallySerializable(T: type, endian: std.builtin.Endian) bool {
    if (builtin.cpu.arch.endian() != endian) return false;

    const info = @typeInfo(T);
    switch (info) {
        .bool => return true,
        .int => |i| {
            const tag_bits = i.bits;
            const remainder = @mod(tag_bits, 8);
            return remainder == 0;
        },
        .float => return true,
        .@"enum" => |e| return isTriviallySerializable(e.tag_type, endian),
        .array => |a| return isTriviallySerializable(a.child, endian),
        .pointer => return false,
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "serialize")) {
                return false;
            }

            if (s.backing_integer) |_| {
                return false;
            } else {
                inline for (s.fields) |field| {
                    if (!isTriviallySerializable(field.type, endian)) return false;
                }
            }

            return true;
        },
        .optional => return false,
        .@"union" => |u| {
            if (u.layout == .@"packed") return true;
            return false;
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

fn Serializer(comptime writing: bool) type {
    return struct {
        const Self = @This();
        comptime writing: bool = writing,

        config: Config,
        allocator: if (writing) void else std.mem.Allocator,
        writer: if (writing) std.io.AnyWriter else void,
        reader: if (writing) void else std.io.AnyReader,

        pub fn serialize(self: *Self, T: type, ptr: if (writing) *const T else *T) !void {
            const info = @typeInfo(T);
            switch (info) {
                .bool => {
                    if (writing) {
                        try self.writer.writeByte(@intFromBool(ptr.*));
                    } else {
                        ptr.* = (try self.reader.readByte()) > 0;
                    }
                },
                .int => |i| {
                    const remainder = @mod(i.bits, 8);
                    if (remainder == 0) {
                        if (writing) {
                            try self.writer.writeInt(T, ptr.*, self.config.endian);
                        } else {
                            ptr.* = try self.reader.readInt(T, self.config.endian);
                        }
                    } else {
                        const bits = i.bits + 8 - remainder;
                        const Int = std.meta.Int(i.signedness, bits);
                        if (writing) {
                            try self.writer.writeInt(Int, ptr.*, self.config.endian);
                        } else {
                            const tmp = try self.reader.readInt(Int, self.config.endian);
                            ptr.* = @intCast(tmp);
                        }
                    }
                },
                .float => |f| {
                    const Int = std.meta.Int(.unsigned, f.bits);
                    if (writing) {
                        try self.writer.writeInt(Int, @as(Int, @bitCast(ptr.*)), self.config.endian);
                    } else {
                        ptr.* = @bitCast(try self.reader.readInt(Int, self.config.endian));
                    }
                },
                .@"enum" => |e| {
                    var tmp: e.tag_type = undefined;
                    if (writing) {
                        tmp = @intFromEnum(ptr.*);
                        try self.serialize(e.tag_type, &tmp);
                    } else {
                        try self.serialize(e.tag_type, &tmp);
                        ptr.* = @enumFromInt(tmp);
                    }
                },
                .array => |a| try self.serializeSlice(a.child, ptr.*[0..]),
                .pointer => |p| {
                    switch (p.size) {
                        .Slice => {
                            if (writing) {
                                try std.leb.writeUleb128(self.writer, ptr.len);
                                try self.serializeSlice(p.child, ptr.*);
                            } else {
                                const len = try std.leb.readUleb128(usize, self.reader);
                                const slice = try self.allocator.alloc(p.child, len);
                                try self.serializeSlice(p.child, slice);
                                ptr.* = slice;
                            }
                        },
                        .One => {
                            if (writing) {
                                try self.serialize(p.child, ptr.*);
                            } else {
                                const item = try self.allocator.create(p.child);
                                try self.serialize(p.child, item);
                                ptr.* = item;
                            }
                        },
                        else => @compileError("serializing many pointers is not supported"),
                    }
                },
                .@"struct" => |s| {
                    if (std.meta.hasFn(T, "serialize")) {
                        return ptr.serialize(self);
                    }

                    if (s.backing_integer) |Int| {
                        const int_info = @typeInfo(Int).int;
                        if (int_info.signedness == .signed) {
                            if (writing) {
                                try std.leb.writeIleb128(self.writer, @as(Int, @bitCast(ptr.*)));
                            } else {
                                ptr.* = @bitCast(try std.leb.readIleb128(Int, self.reader));
                            }
                        } else {
                            if (writing) {
                                try std.leb.writeUleb128(self.writer, @as(Int, @bitCast(ptr.*)));
                            } else {
                                ptr.* = @bitCast(try std.leb.readUleb128(Int, self.reader));
                            }
                        }
                    } else {
                        inline for (s.fields) |field| {
                            try serialize(self, field.type, &@field(ptr, field.name));
                        }
                    }
                },
                .optional => |o| {
                    if (writing) {
                        if (ptr.*) |*v| {
                            try self.writer.writeByte(1);
                            try self.serialize(o.child, v);
                        } else {
                            try self.writer.writeByte(0);
                        }
                    } else {
                        const set = try self.reader.readByte();
                        if (set > 0) {
                            try self.serialize(o.child, &ptr.*.?);
                        } else {
                            ptr.* = null;
                        }
                    }
                },
                .@"union" => |u| {
                    if (u.layout == .@"packed") {
                        return self.serializeSlice(u8, std.mem.asBytes(ptr));
                    }

                    if (u.tag_type) |tag_type| {
                        if (writing) {
                            const active_tag = std.meta.activeTag(ptr.*);
                            try self.serialize(tag_type, &active_tag);
                            switch (active_tag) {
                                inline else => |tag| {
                                    try self.serialize(std.meta.TagPayload(T, tag), &@field(ptr, @tagName(tag)));
                                },
                            }
                        } else {
                            var active_tag: tag_type = undefined;
                            try self.serialize(tag_type, &active_tag);
                            switch (active_tag) {
                                inline else => |tag| {
                                    ptr.* = @unionInit(T, @tagName(tag), undefined);
                                    try self.serialize(std.meta.TagPayload(T, tag), &@field(ptr, @tagName(tag)));
                                },
                            }
                        }
                    } else @compileError("untagged unions can't be serialized");
                },
                else => @compileError("unsupported type " ++ @typeName(T)),
            }
        }

        pub fn serializeSlice(self: *Self, T: type, slice: if (writing) []const T else []T) !void {
            if (isTriviallySerializable(T, self.config.endian)) {
                const bytes = std.mem.sliceAsBytes(slice);
                if (writing) {
                    try self.writer.writeAll(bytes);
                } else {
                    try self.reader.readNoEof(bytes);
                }
            } else {
                for (slice) |*item| {
                    try serialize(self, T, item);
                }
            }
        }

        fn versionInt(v: anytype) u32 {
            return switch (@typeInfo(@TypeOf(v))) {
                .int => @intCast(v),
                .@"enum" => @intFromEnum(v),
                else => @compileError("versions must be either a integer or an enum"),
            };
        }

        /// Serialize a field that was added in a particular version.
        ///
        /// During writing, the field is always written.
        ///
        /// During reading, if the data version contains the value it is deserialized and true is returned.
        ///
        /// For data versions before the field was added, the field is skipped and false is returned. Calling
        /// code should then write a default value instead.
        pub fn serializeAdded(self: *Self, T: type, ptr: if (writing) *const T else *T, version_added: anytype) !bool {
            if (!writing and self.config.data_version < versionInt(version_added)) return false;
            try self.serialize(T, ptr);
            return true;
        }

        /// Serialize a removed field.
        ///
        /// Serialization functions should call this in place of serialize / serializedAdded after the
        /// field has been removed from the data structure.
        ///
        /// During writing, this is a no-op and null is returned.
        /// During reading, if the data stream contains the removed field then it is returned, otherwise null.
        pub fn serializeRemoved(self: *Self, T: type, version_added: anytype, version_removed: anytype) !?T {
            if (writing or self.config.data_version >= versionInt(version_removed)) return null;
            var value: T = undefined;
            if (try serializeAdded(self, T, &value, version_added)) return value;
            return null;
        }
    };
}

/// Returns true if the type can be serialized by MappableSerializer
fn verifyMappable(comptime T: type) void {
    const info = @typeInfo(T);
    switch (info) {
        .bool,
        .int,
        .float,
        .@"enum",
        => {},
        .array => |a| verifyMappable(a.child),
        .pointer => @compileError("pointers can't be serialized, use RelativeSlice, RelativePtr, or ExtraData"),
        .@"struct" => |s| if (s.layout == .auto) @compileError("struct " ++ @typeName(T) ++ " does not have a defined memory layout"),
        .vector => |v| verifyMappable(v.child),
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

/// Returns true if the type its children have any variable length fields
fn isVariableLength(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .bool,
        .int,
        .float,
        .@"enum",
        => return false,
        .array => |a| return isVariableLength(a.child),
        .pointer => unreachable,
        .@"struct" => |s| {
            if (std.meta.hasFn(T, "serializeMappable")) return true;
            inline for (s.fields) |field| {
                if (isVariableLength(field.type)) return true;
            }
            return false;
        },
        .vector => |v| return isVariableLength(v.child),
        else => unreachable,
    }
}

fn MappableSerializer(comptime TRoot: type) type {
    const root_info = @typeInfo(TRoot);
    if (root_info != .@"struct" or root_info.@"struct".layout == .auto)
        @compileError("MappableSerializer expects either an extern or packed struct");

    verifyMappable(TRoot);

    return struct {
        const Self = @This();
        const Buffer = []align(@alignOf(TRoot)) u8;

        buf: Buffer = &.{},
        pos: usize = 0,
        endian: std.builtin.Endian,

        pub fn requiredSize(ptr: *const TRoot, endian: std.builtin.Endian) usize {
            var size: usize = @sizeOf(TRoot);
            var self: Self = .{ .endian = endian, .pos = size };
            size += self.innerSerialize(TRoot, ptr, null) catch unreachable;
            return size;
        }

        pub fn serialize(
            ptr: *const TRoot,
            buf: Buffer,
            endian: std.builtin.Endian,
        ) !void {
            var self: Self = .{
                .buf = buf,
                .endian = endian,
            };

            const size = @sizeOf(TRoot);
            @memcpy(buf[0..size], std.mem.asBytes(ptr));
            self.pos += @sizeOf(TRoot);

            const out = std.mem.bytesAsValue(TRoot, buf);
            _ = try self.innerSerialize(TRoot, ptr, out);

            if (native_endian != endian) {
                std.mem.byteSwapAllFields(TRoot, out);
            }
        }

        pub fn serializeTrailing(self: *Self, comptime T: type, in: []const T) !struct {
            /// Required trailing bytes for all children, including padding
            required_size: usize,

            /// During serialization, the trailing data slice that `in` was copied into.
            trailing: ?[]T,
        } {
            verifyMappable(T);

            const aligned = std.mem.alignForward(usize, self.pos, @alignOf(T));
            const padding = aligned - self.pos;
            const size = in.len * @sizeOf(T);

            var required_size: usize = padding + size;
            const trailing = if (self.buf.len > 0) blk: {
                @memset(self.buf[self.pos..][0..padding], 0);
                self.pos += padding;

                const out_bytes: []align(@alignOf(T)) u8 = @alignCast(self.buf[self.pos..][0..size]);
                const out = std.mem.bytesAsSlice(T, out_bytes);
                @memcpy(out, in);
                self.pos += size;

                if (isVariableLength(T)) {
                    for (in, out) |*in_item, *out_item| {
                        required_size += try self.innerSerialize(T, in_item, out_item);
                    }
                }

                if (native_endian != self.endian) {
                    for (out) |*item| byteSwap(T, item);
                }

                break :blk out;
            } else blk: {
                self.pos += padding + size;

                if (isVariableLength(T)) {
                    for (in) |*in_item| {
                        required_size += try self.innerSerialize(T, in_item, null);
                    }
                }

                break :blk null;
            };

            return .{
                .required_size = required_size,
                .trailing = trailing,
            };
        }

        /// Return value is the number of trailing bytes required / written including padding
        fn innerSerialize(self: *Self, T: type, in: *const T, out: ?*T) !usize {
            if (!isVariableLength(T)) return 0;

            const info = @typeInfo(T);
            switch (info) {
                .@"struct" => |s| {
                    if (std.meta.hasFn(T, "serializeMappable")) {
                        return try in.serializeMappable(out, self);
                    }

                    var size: usize = 0;
                    if (s.layout != .@"packed") {
                        inline for (s.fields) |field| {
                            size += try innerSerialize(
                                self,
                                field.type,
                                &@field(in, field.name),
                                if (out) |o| &@field(o, field.name) else null,
                            );
                        }
                    }

                    return size;
                },
                else => {},
            }

            return 0;
        }
    };
}

pub fn byteSwap(comptime T: type, ptr: *T) void {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct", .array => std.mem.byteSwapAllFields(T, ptr),
        else => ptr.* = byteSwapScalar(T, ptr.*),
    }
}

pub inline fn byteSwapScalar(comptime T: type, value: T) T {
    const info = @typeInfo(T);
    return switch (info) {
        .float => |f| @bitCast(@byteSwap(@as(
            std.meta.Int(.unsigned, f.bits),
            @bitCast(value),
        ))),
        else => @byteSwap(value),
    };
}

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const native_endian = builtin.cpu.arch.endian();

test "basic types" {
    const I = packed struct(u64) {
        a: i16,
        b: i16,
        c: u32,
    };

    const J = enum(u4) {
        foo,
        bar,
    };

    const Foo = struct {
        a: u32,
        b: i16,
        c: usize = 1234,
        d: struct {
            x: i32,
            y: u32,
        },
        e: enum {
            foo,
            bar,
            baz,
        },
        f: enum(i32) {
            foo,
            bar,
            baz,
        },
        g: [8]u8,
        h: struct {
            x: u32,
            y: u32,

            pub fn serialize(self: anytype, serializer: anytype) !void {
                if (serializer.writing) {
                    const tmp: u32 = 2 * self.x;
                    try serializer.serialize(u32, &tmp);
                } else {
                    var tmp: u32 = undefined;
                    try serializer.serialize(u32, &tmp);
                    self.x = tmp / 2;
                }

                try serializer.serialize(u32, &self.y);
            }
        },
        i: I,
        j: [3]J,
        k: bool,
        l: bool,
        m: f16,
        n: f32,
        o: f64,
        p: ?u64,
        q: ?u64,
        r: union(enum) {
            x: u32,
            y: u64,
        },
        s: u4,
    };

    const foo_in: Foo = .{
        .a = 0xaabbccdd,
        .b = -1,
        .d = .{
            .x = 6,
            .y = 7,
        },
        .e = .bar,
        .f = .foo,
        .g = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .h = .{ .x = 5, .y = 6 },
        .i = .{
            .a = -100,
            .b = -200,
            .c = 300,
        },
        .j = .{ .bar, .bar, .foo },
        .k = true,
        .l = false,
        .m = 0.1234,
        .n = 1234,
        .o = 56789,
        .p = null,
        .q = 64,
        .r = .{
            .y = 128,
        },
        .s = 8,
    };

    {
        try testing.expect(!isTriviallySerializable(Foo, native_endian));

        const serialized = try serializeAlloc(testing.allocator, Foo, &foo_in, .{});
        defer testing.allocator.free(serialized);

        try testing.expectEqual(serialized.len, 88);
        try testing.expectEqual(foo_in.a, std.mem.bytesAsValue(u32, serialized[0..4]).*);
        try testing.expectEqual(foo_in.b, std.mem.bytesAsValue(i16, serialized[4..6]).*);
        try testing.expectEqual(@as(usize, 1234), std.mem.bytesAsValue(usize, serialized[6..14]).*);
        try testing.expectEqual(foo_in.d.x, std.mem.bytesAsValue(i32, serialized[14..18]).*);
        try testing.expectEqual(foo_in.d.y, std.mem.bytesAsValue(u32, serialized[18..22]).*);
        try testing.expectEqual(@as(u8, @intFromEnum(foo_in.e)), std.mem.bytesAsValue(u8, serialized[22..23]).*);
        try testing.expectEqual(@intFromEnum(foo_in.f), std.mem.bytesAsValue(i32, serialized[23..27]).*);
        try testing.expectEqualSlices(u8, foo_in.g[0..], serialized[27..35]);
        try testing.expectEqual(foo_in.h.x * 2, std.mem.bytesAsValue(u32, serialized[35..39]).*);
        try testing.expectEqual(foo_in.h.y, std.mem.bytesAsValue(u32, serialized[39..43]).*);
        try testing.expectEqualSlices(u8, &.{ 1, 1, 0 }, serialized[49..52]);

        var foo_out: Foo = undefined;
        try deserializeFromSliceAlloc(testing.allocator, Foo, &foo_out, serialized, .{});

        try testing.expectEqualDeep(foo_in, foo_out);
    }

    const Bar = struct {
        a: packed union {
            x: u32,
            y: u64,
            z: packed struct(u64) {
                a: u32,
                b: u32,
            },
        },
    };

    const bar_in: Bar = .{
        .a = .{
            .y = 0xaabbccdd,
        },
    };

    {
        try testing.expect(isTriviallySerializable(Bar, native_endian));

        const serialized = try serializeAlloc(testing.allocator, Bar, &bar_in, .{});
        defer testing.allocator.free(serialized);

        var bar_out: Bar = undefined;
        try deserializeFromSliceAlloc(testing.allocator, Bar, &bar_out, serialized, .{});

        try testing.expectEqual(bar_in.a.y, bar_out.a.y);
    }
}

test "mappable" {
    const Foo = extern struct {
        a: u32,
        b: i16,
        c: usize = 1234,
        d: extern struct {
            x: i32,
            y: u32,
        },
        e: enum(u8) {
            foo,
            bar,
            baz,
        },
        f: enum(i32) {
            foo,
            bar,
            baz,
        },
        g: [8]u8,
        h: extern struct {
            x: u32,
            y: u32,
        },
        i: packed struct(u64) {
            a: i16,
            b: bool,
            c: u32,
            _: u15 = 0,
        },
        k: bool,
        l: bool,
        m: f16,
        n: f32,
        o: f64,
    };

    const foo_in: Foo = .{
        .a = 0xaabbccdd,
        .b = -1,
        .d = .{
            .x = 6,
            .y = 7,
        },
        .e = .bar,
        .f = .foo,
        .g = .{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .h = .{ .x = 10, .y = 5 },
        .i = .{
            .a = -100,
            .b = true,
            .c = 300,
        },
        .k = true,
        .l = false,
        .m = 0.1234,
        .n = 1234,
        .o = 56789,
    };

    {
        const serialized = try serializeMappableAlloc(
            testing.allocator,
            Foo,
            &foo_in,
            native_endian,
        );
        defer testing.allocator.free(serialized);

        try testing.expectEqual(@sizeOf(Foo), serialized.len);

        const foo_mapped = std.mem.bytesAsValue(Foo, serialized);
        try testing.expectEqualDeep(foo_in, foo_mapped.*);
    }

    {
        const serialized = try serializeMappableAlloc(
            testing.allocator,
            Foo,
            &foo_in,
            if (native_endian == .little) .big else .little,
        );
        defer testing.allocator.free(serialized);

        try testing.expectEqual(@sizeOf(Foo), serialized.len);

        const foo_mapped = std.mem.bytesAsValue(Foo, serialized);
        std.mem.byteSwapAllFields(Foo, foo_mapped);
        try testing.expectEqualDeep(foo_in, foo_mapped.*);
    }
}

test "variable length fields (non-mappable)" {
    const Foo = struct {
        a: u32,
        b: i16,
        c: []const u32,
        d: u64,
        e: *const u64,
        f: []const struct {
            x: u32,
            y: u32,
            z: []const u32,
        },
    };

    const foo_in: Foo = .{
        .a = 0xaabbccdd,
        .b = -1,
        .c = &.{ 3, 4, 5 },
        .d = 6,
        .e = &7,
        .f = &.{
            .{ .x = 8, .y = 9, .z = &.{ 10, 11 } },
            .{ .x = 12, .y = 13, .z = &.{} },
        },
    };

    try testing.expect(!isTriviallySerializable(Foo, native_endian));

    const serialized = try serializeAlloc(testing.allocator, Foo, &foo_in, .{});
    defer testing.allocator.free(serialized);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var foo_out: Foo = undefined;
    try deserializeFromSliceAlloc(arena.allocator(), Foo, &foo_out, serialized, .{});

    try testing.expectEqualDeep(foo_in, foo_out);
}

const relative = @import("relative.zig");

test "variable length fields (mappable)" {
    const F = extern struct {
        x: u32 align(8),
        y: u32,
        z: relative.Pointer(u64),
    };

    const Foo = extern struct {
        a: u32,
        b: i16,
        c: relative.Slice(f32, u8),
        d: u64,
        e: relative.Pointer(u64),
        f: relative.Slice(F, u16),
    };

    const foo_in_buf = try relative.alloc(testing.allocator, Foo, .{
        .a = 0xaabbccdd,
        .b = -1,
        .c = .{ .len = 3 },
        .d = 6,
        .e = .{},
        .f = .{ .len = 2 },
    });
    defer testing.allocator.free(foo_in_buf);
    const foo_in = std.mem.bytesAsValue(Foo, foo_in_buf);

    const c_expected: [3]f32 = .{ 3.0, 4.0, 5.0 };
    const e_expected: u64 = 7;
    const f_expected: [2]F = .{
        .{ .x = 8, .y = 9, .z = .{} },
        .{ .x = 12, .y = 13, .z = .{} },
    };
    const f_expected_z_values: [2]?u64 = .{ 10, null };

    @memcpy(foo_in.c.slice(), c_expected[0..]);
    foo_in.e.ptr().?.* = e_expected;
    for (foo_in.f.slice(), f_expected[0..], f_expected_z_values[0..]) |*f, expected, expected_z| {
        f.x = expected.x;
        f.y = expected.y;
        if (expected_z) |v| {
            f.z.ptr().?.* = v;
        } else {
            f.z.set(null);
        }
    }

    {
        const serialized = try serializeMappableAlloc(testing.allocator, Foo, foo_in, native_endian);
        defer testing.allocator.free(serialized);

        const foo_mapped = std.mem.bytesAsValue(Foo, serialized);
        try testing.expectEqual(foo_in.a, foo_mapped.a);
        try testing.expectEqual(foo_in.b, foo_mapped.b);
        try testing.expectEqualSlices(f32, &c_expected, foo_mapped.c.slice());
        try testing.expectEqual(foo_in.d, foo_mapped.d);
        try testing.expectEqual(e_expected, foo_mapped.e.ptr().?.*);

        for (f_expected, f_expected_z_values, foo_mapped.f.slice()) |expected, expected_z, *actual| {
            try testing.expectEqual(expected.x, actual.x);
            try testing.expectEqual(expected.y, actual.y);

            const actual_z = if (actual.z.ptr()) |p| p.* else null;
            try testing.expectEqual(expected_z, actual_z);
        }
    }

    {
        const serialized = try serializeMappableAlloc(
            testing.allocator,
            Foo,
            foo_in,
            if (native_endian == .little) .big else .little,
        );
        defer testing.allocator.free(serialized);

        const foo_mapped = std.mem.bytesAsValue(Foo, serialized);
        std.mem.byteSwapAllFields(Foo, foo_mapped);

        try testing.expectEqual(foo_in.a, foo_mapped.a);
        try testing.expectEqual(foo_in.b, foo_mapped.b);
        for (c_expected, foo_mapped.c.slice()) |expected, actual| {
            try testing.expectEqual(expected, byteSwapScalar(f32, actual));
        }
        try testing.expectEqual(foo_in.d, foo_mapped.d);
        try testing.expectEqual(e_expected, @byteSwap(foo_mapped.e.ptr().?.*));

        for (f_expected, f_expected_z_values, foo_mapped.f.slice()) |expected, expected_z, *actual| {
            std.mem.byteSwapAllFields(F, actual);
            try testing.expectEqual(expected.x, actual.x);
            try testing.expectEqual(expected.y, actual.y);

            const actual_z = if (actual.z.ptr()) |p| @byteSwap(p.*) else null;
            try testing.expectEqual(expected_z, actual_z);
        }
    }
}

test "versioning" {
    const Version = enum {
        initial,
        added_c,
        removed_b,
    };

    const FooV1 = struct {
        a: u32,
        b: u32,
    };

    const FooV2 = struct {
        a: u32,
        b: u32,
        c: u64,

        pub fn serialize(self: anytype, serializer: anytype) !void {
            try serializer.serialize(u32, &self.a);
            try serializer.serialize(u32, &self.b);
            if (!try serializer.serializeAdded(u64, &self.c, Version.added_c) and !serializer.writing) {
                self.c = 3;
            }
        }
    };

    const FooV3_VerifyValue = struct {
        a: u32,
        c: u64,

        pub fn serialize(self: anytype, serializer: anytype) !void {
            try serializer.serialize(u32, &self.a);
            if (try serializer.serializeRemoved(u32, Version.initial, Version.removed_b)) |b| {
                try testing.expectEqual(2, b);
            }
            try serializer.serialize(u64, &self.c);
        }
    };

    const FooV3_VerifyNoValue = struct {
        a: u32,
        c: u64,

        pub fn serialize(self: anytype, serializer: anytype) !void {
            try serializer.serialize(u32, &self.a);
            try testing.expect(try serializer.serializeRemoved(u32, Version.initial, Version.removed_b) == null);
            try serializer.serialize(u64, &self.c);
        }
    };

    const foo_v1: FooV1 = .{
        .a = 1,
        .b = 2,
    };

    const foo_v1_serialized = try serializeAlloc(testing.allocator, FooV1, &foo_v1, .{
        .data_version = @intFromEnum(Version.initial),
        .serializer_version = @intFromEnum(Version.initial),
    });
    defer testing.allocator.free(foo_v1_serialized);

    const foo_v2_expected: FooV2 = .{
        .a = 1,
        .b = 2,
        .c = 3,
    };

    // Deserialize v1 as v2
    const foo_v2_serialized = blk: {
        var foo_v2_out: FooV2 = undefined;
        try deserializeFromSliceAlloc(testing.allocator, FooV2, &foo_v2_out, foo_v1_serialized, .{
            .data_version = @intFromEnum(Version.initial),
            .serializer_version = @intFromEnum(Version.added_c),
        });
        try testing.expectEqualDeep(foo_v2_expected, foo_v2_out);

        break :blk try serializeAlloc(testing.allocator, FooV2, &foo_v2_out, .{
            .data_version = @intFromEnum(Version.added_c),
            .serializer_version = @intFromEnum(Version.added_c),
        });
    };
    defer testing.allocator.free(foo_v2_serialized);

    // Deserialize v2 as v2
    {
        var foo_v2_out: FooV2 = undefined;
        try deserializeFromSliceAlloc(testing.allocator, FooV2, &foo_v2_out, foo_v2_serialized, .{
            .data_version = @intFromEnum(Version.added_c),
            .serializer_version = @intFromEnum(Version.added_c),
        });
        try testing.expectEqualDeep(foo_v2_expected, foo_v2_out);
    }

    // Deserialize v2 as v3
    const foo_v3_serialized = blk: {
        const foo_v3_expected: FooV3_VerifyValue = .{
            .a = 1,
            .c = 3,
        };

        var foo_v3_out: FooV3_VerifyValue = undefined;
        try deserializeFromSliceAlloc(testing.allocator, FooV3_VerifyValue, &foo_v3_out, foo_v2_serialized, .{
            .data_version = @intFromEnum(Version.added_c),
            .serializer_version = @intFromEnum(Version.removed_b),
        });
        try testing.expectEqualDeep(foo_v3_expected, foo_v3_out);

        break :blk try serializeAlloc(testing.allocator, FooV3_VerifyValue, &foo_v3_out, .{
            .data_version = @intFromEnum(Version.removed_b),
            .serializer_version = @intFromEnum(Version.removed_b),
        });
    };
    defer testing.allocator.free(foo_v3_serialized);

    // Deserialize v3 as v3
    {
        const foo_v3_expected: FooV3_VerifyNoValue = .{
            .a = 1,
            .c = 3,
        };

        var foo_v3_out: FooV3_VerifyNoValue = undefined;
        try deserializeFromSliceAlloc(testing.allocator, FooV3_VerifyNoValue, &foo_v3_out, foo_v3_serialized, .{
            .data_version = @intFromEnum(Version.removed_b),
            .serializer_version = @intFromEnum(Version.removed_b),
        });
        try testing.expectEqualDeep(foo_v3_expected, foo_v3_out);
    }
}
