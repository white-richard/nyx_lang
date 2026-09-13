const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ----- Parser and lexer generation (outputs go to the build cache) -----
    const bison = b.addSystemCommand(&.{ "bison", "-Wnone", "-o" });
    const parser_c = bison.addOutputFileArg("c11.tab.c");
    const parser_h = bison.addPrefixedOutputFileArg("--defines=", "c11.tab.h");
    bison.addFileArg(b.path("src/c11.y"));
    const generated_include_dir = parser_h.dirname();

    const flex = b.addSystemCommand(&.{ "flex", "-o" });
    const lexer_c = flex.addOutputFileArg("lex.yy.c");
    flex.addFileArg(b.path("src/c11.l"));

    // ----- Compiler executable -----
    const exe = b.addExecutable(.{
        .name = "NyxLang",
        .version = .{ .major = 0, .minor = 2, .patch = 0 },
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.addCSourceFile(.{ .file = parser_c, .flags = &.{} });
    exe.addCSourceFile(.{ .file = lexer_c, .flags = &.{} });
    exe.addIncludePath(generated_include_dir);
    exe.linkLibC();
    b.installArtifact(exe);

    // ----- zig build run -- <source-file> [flags] -----
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the compiler");
    run_step.dependOn(&run_cmd.step);

    // ----- zig build test: unit tests -----
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_scope.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // ast.zig imports the Bison-generated token header.
    unit_tests.addIncludePath(generated_include_dir);
    unit_tests.linkLibC();

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // ----- zig build smoke: run the compiler against tests/fixtures -----
    const smoke_config = b.addOptions();
    smoke_config.addOptionPath("compiler", exe.getEmittedBin());
    smoke_config.addOptionPath("fixtures_dir", b.path("tests/fixtures"));

    const smoke_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "smoke_config", .module = smoke_config.createModule() }},
        }),
    });
    const run_smoke = b.addRunArtifact(smoke_tests);
    // Fixture edits do not change the test binary, so always rerun.
    run_smoke.has_side_effects = true;

    const smoke_step = b.step("smoke", "Run compiler smoke tests against tests/fixtures");
    smoke_step.dependOn(&run_smoke.step);
}
