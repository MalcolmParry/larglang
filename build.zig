const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "largc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addArgs(b.args orelse &.{});
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const comp_test_step = b.step("comp-test", "");
    const comp_test_asm_emit = b.addRunArtifact(exe);
    comp_test_asm_emit.addArgs(&.{ "test.larg", "-o" });
    const asm_file = comp_test_asm_emit.addOutputFileArg("test.s");

    const comp_test = b.addExecutable(.{
        .name = "test",
        .root_module = b.addModule("test", .{
            .target = target,
            .optimize = .ReleaseFast,
            .pic = false,
        }),
    });
    comp_test.step.dependOn(&comp_test_asm_emit.step);
    comp_test.root_module.addAssemblyFile(asm_file);

    const comp_test_install = b.addInstallArtifact(comp_test, .{});
    comp_test_install.step.dependOn(&comp_test.step);
    comp_test_step.dependOn(&comp_test_install.step);
}
