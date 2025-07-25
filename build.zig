const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("root", .{
        .root_source_file = b.path("src/main.zig"),
    });

    const test_step = b.step("test", "Run tests");
    const tests = b.addTest(.{
        .name = "ion-extras-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    test_step.dependOn(&b.addRunArtifact(tests).step);
}
