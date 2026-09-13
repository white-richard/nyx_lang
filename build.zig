const std = @import("std");

const test_targets = [_]std.Target.Query{
    .{}, // native
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- generate parser/lexer into src/ explicitly ---
    const bison = b.addSystemCommand(&.{ "bison", "-d", "-Wnone", "-o" });
    bison.addFileArg(b.path("src/c11.tab.c"));  // -o <outfile>
    bison.addFileArg(b.path("src/c11.y"));

    const flex = b.addSystemCommand(&.{ "flex", "-o" });
    flex.addFileArg(b.path("src/lex.yy.c"));  // -o <outfile>
    flex.addFileArg(b.path("src/c11.l"));

    const exe = b.addExecutable(.{
        .name = "NyxLang",
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // compile generated C sources from src/
    exe.addCSourceFile(.{ .file = b.path("src/c11.tab.c"), .flags = &.{} });
    exe.addCSourceFile(.{ .file = b.path("src/lex.yy.c"), .flags = &.{} });
    exe.linkLibC();
    exe.addIncludePath(b.path("src"));

    // make exe depend on the generators
    exe.step.dependOn(&bison.step);
    exe.step.dependOn(&flex.step);

    b.installArtifact(exe);

    // ----- Run the app -----
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    // ----- Run Tests ----- // TODO not working
    // const test_step = b.step("test", "Run unit tests");
    //
    // for (test_targets) |tar| {
    //     const unit_tests = b.addTest(.{
    //         .root_module = b.createModule(.{
    //             .root_source_file = b.path("src/symbolTable_test.zig"),
    //             .target = b.resolveTargetQuery(tar),
    //             .optimize = optimize,
    //         }),
    //     });
    //
    //     unit_tests.addCSourceFile(.{ .file = b.path("src/c11.tab.c"), .flags = &.{} });
    //     unit_tests.addCSourceFile(.{ .file = b.path("src/lex.yy.c"), .flags = &.{} });
    //     unit_tests.linkLibC();
    //     unit_tests.addIncludePath(b.path("src"));
    //
    //     // Ensure C files are generated before compiling tests:
    //     unit_tests.step.dependOn(&bison.step);
    //     unit_tests.step.dependOn(&flex.step);
    //
    //     const run_unit_tests = b.addRunArtifact(unit_tests);
    //     run_unit_tests.skip_foreign_checks = true; // ?
    //     test_step.dependOn(&run_unit_tests.step);
    // }
}
