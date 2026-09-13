const std = @import("std");
const log = @import("Log.zig");
const parse = @cImport(@cInclude("c11.tab.h"));
const scope = @import("scope.zig");
const ast = @import("ast.zig");
const analyzer = @import("semanticAnalyzer.zig");
const c = @cImport(@cInclude("c11.tab.h"));
const bi = @import("builtin.zig");
const ir = @import("3ac.zig");
const asmb = @import("assembler.zig");

pub const YY_BUFFER_STATE = *opaque {};
extern fn yylex() c_int; // from your lexer
extern fn yy_scan_bytes(bytes: [*c]const u8, len: c_int) YY_BUFFER_STATE;
extern fn yyparse() c_int;
export var root: ?*ast.Node = null;
pub export var column: c_int = 1;
pub export var line: c_int = 1;
pub const parse_alloc = std.heap.c_allocator;
var source_code: []const u8 = undefined;
var assemble_flag: bool = false;

pub fn main() !void {
    _main() catch |err| {
        if (ast.debug_mode) {
            return err;
        }
        std.debug.print("NyxLang encountered an internal error.\n", .{});
        std.process.exit(1);
    };
}

fn _main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len == 1 or args.len > 3) {
        std.debug.print("Usage: {s} <filename>. Found {d} args\n", .{ args[0], args.len });
        std.debug.print("Usage: {s} <filename> <flags>. Found {d} args\n", .{ args[0], args.len });
        return;
    }
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    if (ast.debug_mode) std.debug.print("CWD: {s}\n", .{cwd});
    defer allocator.free(cwd);
    const filename = args[1];
    if (args.len > 2) {
        const flags = args[2];
        // Check for 'd' flag
        if (std.mem.indexOf(u8, flags, "d") != null) {
            ast.debug_mode = true;
        }
        // Check for 'a' flag
        if (std.mem.indexOf(u8, flags, "a") != null) {
            assemble_flag = true;
        }
    }
    if (ast.debug_mode) std.debug.print("\n\nFILENAME: {s}\n\n", .{filename});
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    source_code = contents;
    defer allocator.free(contents);

    const length: c_int = @intCast(contents.len);
    _ = yy_scan_bytes(contents.ptr, length);

    const result = yyparse();

    const symbol_table = scope.SymbolTable.create(parse_alloc, null) catch {
        log.Error(0, 0, "Failed to create symbol table", "", "Symbol Table Initialization Error");
        return;
    };

    analyzer.setSymbolTable(symbol_table);

    const new_root = try bi.built_in_types(parse_alloc, root.?);

    if (ast.debug_mode) {
        std.debug.print("\n\n\n\x1b[1;33mPARSE/AST PRINTOUT\x1b[0m DEBUG MODE ENABLED\n", .{});
        try ast.printNode(new_root, 0);
    }
    if (new_root) |r| {
        analyzer.semantic_analyze_node(r) catch |err| {
            std.debug.print("Semantic analysis failed: {s}\n", .{@errorName(err)});
            return;
        };

        if (ast.debug_mode) std.debug.print("\n\x1b[1;33m3AC COMPILATION PRINTOUT\x1b[0m\n", .{});
        const compiler: *ir.Compiler = ir.Compiler.init(parse_alloc, r) catch |err| {
            std.debug.print("3AC compilation failed: {s}\n", .{@errorName(err)});
            return;
        };

        const nyac_list: *std.ArrayList(ir.NYAC) = try compiler.compile();
        // Assembler
        if (assemble_flag) try asmb.assemble(parse_alloc, nyac_list.items);

        std.debug.print("\nParse {s} with \x1b[1;31m{d} errors\x1b[0m.\n", .{ if (result == 1) "failed." else "successful", log.err_count });
    }
}

export fn yyerror(msg: [*c]const u8) void {
    const line_u: usize = @intCast(line);
    const col_u: usize = @intCast(column);
    log.C_Error(col_u, line_u, msg, get_src(), "Parsing error");
}

pub fn diagnostic_source(line_no: usize) []const u8 {
    // Find the byte offsets for: start_of_line and end_of_line
    if (line_no == 0) return "";
    var current_line: usize = 1;
    var start: usize = 0;
    var i: usize = 0;

    // Seek to the beginning of the requested line
    while (i < source_code.len and current_line < line_no) {
        if (source_code[i] == '\n') {
            current_line += 1;
            start = i + 1; // Start at the char AFTER newline
        }
        i += 1;
    }

    // If requested line > total lines → return empty slice rather than panic
    if (current_line != line_no)
        return "";

    while (start < source_code.len and (source_code[start] == ' ' or source_code[start] == '\t')) {
        start += 1;
    }

    // Find the end of the line or EOF
    var end = start;
    while (end < source_code.len and source_code[end] != '\n') {
        end += 1;
    }

    // Guarantee we produce a valid slice
    return source_code[start..end];
}

fn get_src() []const u8 {
    var current_line: usize = 0;
    var idx: usize = 0;
    var line_length: usize = 0;
    while (idx < source_code.len and current_line < line) {
        if (source_code[idx] == '\n') {
            current_line += 1;
            if (current_line < line) line_length = idx;
        }
        idx += 1;
    }
    // idx is now just past the newline that ends the current line.
    return source_code[line_length .. idx - 1];
}

export fn zig_error(hint: [*c]const u8, msg: [*c]const u8) void {
    const line_u: usize = @intCast(line);
    const col_u: usize = @intCast(column);
    log.C_Error(col_u, line_u, msg, get_src(), hint);
}
