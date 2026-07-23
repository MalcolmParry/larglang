const std = @import("std");
const Build = std.Build;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const largc = b.addExecutable(.{
        .name = "largc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(largc);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(largc);
    run_cmd.addArgs(b.args orelse &.{});
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    const build_examples_step = b.step("examples", "build the examples");
    for (programs) |prog| {
        compileProgram(b, prog, build_examples_step, largc, target);
    }
}

fn compileProgram(b: *Build, program: Program, step: *Build.Step, largc: *Build.Step.Compile, target: Build.ResolvedTarget) void {
    const asm_emit = b.addRunArtifact(largc);
    asm_emit.addFileInput(b.path(program.src_file));
    asm_emit.addArgs(&.{ program.src_file, "-o" });
    const asm_file = asm_emit.addOutputFileArg(b.fmt("{s}.s", .{program.name}));

    const exe = b.addExecutable(.{
        .name = program.name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .pic = true,
            .link_libc = program.libc,
        }),
    });

    for (program.system_libs) |sys_lib| {
        exe.root_module.linkSystemLibrary(sys_lib, .{ .preferred_link_mode = .static });
    }

    exe.step.dependOn(&asm_emit.step);
    exe.root_module.addAssemblyFile(asm_file);

    const install = b.addInstallArtifact(exe, .{});
    install.step.dependOn(&exe.step);
    step.dependOn(&install.step);
}

const programs = [_]Program{
    .{
        .name = "test",
        .src_file = "tests/test.larg",
    },
    .{
        .name = "raylib",
        .src_file = "tests/raylib.larg",
        .libc = true,
        .system_libs = &.{
            "raylib",
            "GL",
            "X11",
        },
    },
};

const Program = struct {
    name: []const u8,
    src_file: []const u8,
    libc: bool = false,
    system_libs: []const []const u8 = &.{},
};
