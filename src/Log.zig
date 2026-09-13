const std = @import("std");
const ast = @import("ast.zig");
const LogType = enum { INFO, WARN, ERROR };
pub var err_count: usize = 0;
pub fn InfoLoc(loc: *ast.Location, msg: []const u8, source: []const u8, hint: []const u8) void {
    log(loc.col, loc.line, msg, source, hint, .INFO);
}

pub fn C_Info(this_column: usize, this_line: usize, msg: [*c]const u8, source: []const u8, hint: [*c]const u8) void {
    const new_msg = std.mem.span(msg);
    const new_hint = std.mem.span(hint);
    log(this_column, this_line, new_msg, source, new_hint, .INFO);
}

pub fn Info(this_column: usize, this_line: usize, msg: []const u8, source: []const u8, hint: []const u8) void {
    log(this_column, this_line, msg, source, hint, .INFO);
}

pub fn C_Warn(this_column: usize, this_line: usize, msg: [*c]const u8, source: []const u8, hint: [*c]const u8) void {
    const new_msg = std.mem.span(msg);
    const new_hint = std.mem.span(hint);
    log(this_column, this_line, new_msg, source, new_hint, .WARN);
}
pub fn WarnLoc(loc: *ast.Location, msg: []const u8, source: []const u8, hint: []const u8) void {
    log(loc.col, loc.line, msg, source, hint, .WARN);
}
pub fn Warn(this_column: usize, this_line: usize, msg: []const u8, source: []const u8, hint: []const u8) void {
    log(this_column, this_line, msg, source, hint, .WARN);
}

pub fn C_Error(this_column: usize, this_line: usize, msg: [*c]const u8, source: []const u8, hint: [*c]const u8) void {
    err_count += 1;
    const new_msg = std.mem.span(msg);
    const new_hint = std.mem.span(hint);
    log(this_column, this_line, new_msg, source, new_hint, .ERROR);
}
pub fn Error(this_column: usize, this_line: usize, msg: []const u8, source: []const u8, hint: []const u8) void {
    err_count += 1;
    log(this_column, this_line, msg, source, hint, .ERROR);
}
pub fn ErrorLoc(loc: *ast.Location, msg: []const u8, source: []const u8, hint: []const u8) void {
    err_count += 1;
    log(loc.col, loc.line, msg, source, hint, .ERROR);
}

fn log(this_column: usize, this_line: usize, msg: []const u8, source: []const u8, hint: []const u8, l_type: LogType) void {
    // HEADER
    switch (l_type) {
        .INFO => std.debug.print("\x1b[1;32mNyxLang | Info: \x1b[0m", .{}),
        .ERROR => std.debug.print("\x1b[1;33mNyxLang | Error: \x1b[0m", .{}),
        .WARN => std.debug.print("\x1b[1;34mNyxLang | Warning: \x1b[0m", .{}),
    }
    std.debug.print("{s} at location {d}:{d}\n", .{ msg, this_line, this_column });

    if (source.len == 0) {
        std.debug.print("(no source available)\n", .{});
        if (hint.len >= 1)
            std.debug.print("\x1b[1;36mHint: \x1b[0m{s}\n", .{hint});
        return;
    }

    // SOURCE LINE
    std.debug.print("{s}\n", .{source});

    // Pointer underline location
    var col: usize = this_column;
    if (col > source.len) col = source.len;
    if (col > 0) col -= 1;

    // Print ~~~~~~~^ marker
    var i: usize = col;
    while (i > 0 and source[i] != ' ') {
        std.debug.print("\x1b[1;35m~\x1b[0m", .{});
        i -= 1;
    }
    std.debug.print("\x1b[1;35m^\x1b[0m\n", .{});

    // HINT
    if (hint.len >= 1)
        std.debug.print("\x1b[1;36mHint: \x1b[0m{s}\n", .{hint});
}

pub fn log_basic(l_type: LogType, str: []const u8, args: anytype) void {
    const string = f_str(str, args);

    // HEADER
    switch (l_type) {
        .INFO => std.debug.print("\x1b[1;32mNyxLang | Info: \x1b[0m", .{}),
        .ERROR => std.debug.print("\x1b[1;33mNyxLang | Error: \x1b[0m", .{}),
        .WARN => std.debug.print("\x1b[1;34mNyxLang | Warning: \x1b[0m", .{}),
    }
    std.debug.print("{s}\n", .{string});
}

pub fn f_str(comptime str: []const u8, args: anytype) []const u8 {
    const alloc = std.heap.c_allocator;
    return std.fmt.allocPrint(alloc, str, args) catch {
        return "Null";
    };
}
