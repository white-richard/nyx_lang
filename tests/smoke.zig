const std = @import("std");
const testing = std.testing;
const config = @import("smoke_config");

const Output = struct {
    term: std.process.Child.Term,
    stderr: []const u8,
    /// Contents of a.nyac, or null if the compiler did not write it.
    nyac: ?[]const u8,
    /// Contents of ass.s, or null if the compiler did not write it.
    assembly: ?[]const u8,
};

/// Runs the compiler on `fixture` inside `dir`, which receives the
/// generated a.nyac and ass.s files.
fn compile(alloc: std.mem.Allocator, dir: std.fs.Dir, fixture: []const u8, flags: ?[]const u8) !Output {
    // Build-option paths may be relative to the build root, but the compiler
    // runs inside `dir`, so resolve them first.
    const cwd = std.fs.cwd();
    const compiler = try cwd.realpathAlloc(alloc, config.compiler);
    const fixtures_dir = try cwd.realpathAlloc(alloc, config.fixtures_dir);
    const path = try std.fs.path.join(alloc, &.{ fixtures_dir, fixture });

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ compiler, path });
    if (flags) |f| try argv.append(alloc, f);

    const result = try std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .cwd_dir = dir,
        .max_output_bytes = 1024 * 1024,
    });

    return .{
        .term = result.term,
        .stderr = result.stderr,
        .nyac = try readOptional(alloc, dir, "a.nyac"),
        .assembly = try readOptional(alloc, dir, "ass.s"),
    };
}

fn readOptional(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !?[]const u8 {
    return dir.readFileAlloc(alloc, name, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

fn expectSuccess(out: Output) !void {
    testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, out.term) catch |err| {
        std.debug.print("compiler stderr:\n{s}\n", .{out.stderr});
        return err;
    };
}

fn expectContains(haystack: ?[]const u8, needle: []const u8) !void {
    const text = haystack orelse return error.OutputFileMissing;
    if (std.mem.indexOf(u8, text, needle) == null) {
        std.debug.print("expected to find \"{s}\" in:\n{s}\n", .{ needle, text });
        return error.TestExpectedSubstring;
    }
}

test "simple program parses and emits NYAC" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try compile(arena.allocator(), tmp.dir, "array_initializer.nyx", null);
    try expectSuccess(out);
    try expectContains(out.nyac, "IR LABEL - \"main\" -");
    try expectContains(out.nyac, "IR IMBUE_REGISTER");
    try expectContains(out.nyac, "IR RETURN");
    try testing.expect(out.assembly == null);
}

test "symbol lookup resolves globals from function scope" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try compile(arena.allocator(), tmp.dir, "global_variables.nyx", null);
    try expectSuccess(out);
    const nyac = out.nyac orelse return error.OutputFileMissing;

    // The global `x` is given a stack slot by the first IMBUE_REGISTER.
    const slot_line = lineAfter(nyac, "SRC int x = 100;") orelse return error.MissingSource;
    try testing.expectEqualStrings("IMBUE_REGISTER", operand(slot_line, 1));
    const global_slot = operand(slot_line, 2);

    // `int z = x;` inside main must load from that same slot.
    const z_start = std.mem.indexOf(u8, nyac, "SRC int z = x;") orelse return error.MissingSource;
    var lines = std.mem.splitScalar(u8, nyac[z_start..], '\n');
    _ = lines.next();
    var found = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "SRC ")) break;
        if (std.mem.eql(u8, operand(line, 1), "LR")) {
            try testing.expectEqualStrings(global_slot, operand(line, 3));
            found = true;
        }
    }
    try testing.expect(found);
}

/// Returns the line following the first occurrence of `marker`.
fn lineAfter(text: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    var lines = std.mem.splitScalar(u8, text[start..], '\n');
    _ = lines.next();
    return lines.next();
}

/// Returns the space-separated field at `index` of a NYAC line, or "".
fn operand(line: []const u8, index: usize) []const u8 {
    var fields = std.mem.tokenizeScalar(u8, line, ' ');
    var i: usize = 0;
    while (fields.next()) |field| : (i += 1) {
        if (i == index) return field;
    }
    return "";
}

test "semantic analysis reports assignment to a const variable" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try compile(arena.allocator(), tmp.dir, "const_reassignment.nyx", null);
    try expectContains(out.stderr, "Cannot reassign to constant");
}

test "functions, loops, and comparisons lower to several IR operations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try compile(arena.allocator(), tmp.dir, "factorial.nyx", null);
    try expectSuccess(out);
    for ([_][]const u8{
        "IR LABEL - \"factorial\" -",
        "IR LABEL - \"main\" -",
        "IR CONST ",
        "IR LR ",
        "IR SR ",
        "IR LT ",
        "IR LTE ",
        "IR JUMPFALSE ",
        "IR JUMP ",
        "IR RETURN ",
    }) |needle| try expectContains(out.nyac, needle);
}

test "RISC-V lowering emits assembly for a small program" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const out = try compile(arena.allocator(), tmp.dir, "array_initializer.nyx", "-a");
    try expectSuccess(out);
    try expectContains(out.assembly, "main:\n");
    try expectContains(out.assembly, "    .globl main\n");
    try expectContains(out.assembly, "    sd ");
    try expectContains(out.assembly, "    ret\n");
}
