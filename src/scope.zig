const std = @import("std");
const ast = @import("ast.zig");
const log = @import("Log.zig");
const m = @import("main.zig");

pub const SymbolTable = struct {

    // Allocators
    upstream: std.mem.Allocator, // allocator that created this SymbolTable
    arena: std.heap.ArenaAllocator, // This SymbolTable's local allocator
    allocator: std.mem.Allocator, // derived from arena

    // Maps to hold types, variables, and functions

    type_map: std.StringHashMap(*ast.TypeNode),
    variable_map: std.StringHashMap(*ast.DeclarationNode),
    function_map: std.StringHashMap(*ast.FunctionNode),

    // To support nested scopes, we keep a reference to the parent symbol table
    parent: ?*SymbolTable,

    pub fn create(upstream: std.mem.Allocator, parent: ?*SymbolTable) !*SymbolTable {
        // Allocate the struct from its upstream heap
        const self = try upstream.create(SymbolTable);
        self.* = .{
            .upstream = upstream,
            .arena = std.heap.ArenaAllocator.init(upstream),
            .allocator = undefined,
            .type_map = undefined,
            .variable_map = undefined,
            .function_map = undefined,
            .parent = parent,
        };
        // build our allocator
        self.allocator = self.arena.allocator();
        // initialize and allocate
        self.type_map = std.StringHashMap(*ast.TypeNode).init(self.allocator);
        self.variable_map = std.StringHashMap(*ast.DeclarationNode).init(self.allocator);
        self.function_map = std.StringHashMap(*ast.FunctionNode).init(self.allocator);

        return self;
    }
    pub fn root(self: *SymbolTable) *SymbolTable {
        var tbl = self;
        while (tbl.parent) |p| {
            tbl = p;
        }
        return tbl;
    }

    // We now want to use this allocator for all type allocations
    // This is because types should be global to the entire compilation
    pub fn typeAllocator(self: *SymbolTable) std.mem.Allocator {
        return self.root().allocator;
    }

    // Full deinit of maps, local arena and
    // the SymbolTable using its upstream allocator
    pub fn destroy(self: *SymbolTable) void {
        self.type_map.deinit();
        self.variable_map.deinit();
        self.function_map.deinit();
        self.arena.deinit(); // frees everything allocated by self.allocator
        self.upstream.destroy(self);
    }

    pub fn push(self: *SymbolTable) ?*SymbolTable {
        return SymbolTable.create(self.upstream, self) catch return null;
    }

    // Destroys this table and returns the parent
    pub fn pop(self: *SymbolTable) ?*SymbolTable {
        const parent = self.parent;
        self.destroy();
        return parent; // returns null if this is the root
    }

    pub fn current_depth(self: *SymbolTable) usize {
        var idx: usize = 0;
        var current_table = self.parent;
        while (current_table) |ct| {
            current_table = ct.parent;
            idx += 1;
        }
        return idx;
    }

    // We need 3  Assign functions to add types, variables and functions to our symbol table
    // Param: string name, Node* node
    // we will use the Node* to grab all the relevant information to create our type, variable, and function structs then assign them to a key in the respective symbol table
    pub fn assign_type(self: *SymbolTable, type_node: *ast.TypeNode) !void {
        const root_tbl = self.root();
        const type_string: []const u8 = std.mem.span(type_node.type_name);
        const key = try root_tbl.allocator.dupe(u8, type_string);
        try root_tbl.type_map.put(key, type_node);

        if (ast.debug_mode) {
            std.debug.print(
                "assign_type: '{s}' -> {*}, size={d}\n",
                .{ type_string, type_node, type_node.size },
            );
        }
    }

    pub fn assign_variable(self: *SymbolTable, decl_node: *ast.DeclarationNode) !void {
        if (decl_node.declaration_specifier) |node| {
            const type_ptr = node.Type;
            const type_name_slice: []const u8 = std.mem.span(type_ptr.type_name);

            const test_key = decl_node.assign_node.?.Assignment.declarator;
            const key = switch (test_key.*) {
                .Identifier => |id| id.name,
                .IdPointer => |id| id.identifier.Identifier.name,

                // Handle array declarations like `int x[5];`
                .Array => |arr| blk: {
                    // e.g., maybe arr.identifier or arr.declarator instead of arr.id
                    if (arr.identifier) |id_node| {
                        break :blk id_node.Identifier.name;
                    } else {
                        if (ast.debug_mode)
                            std.debug.print("assign_variable: array declarator missing identifier\n", .{});
                        break :blk "<?>"; // fallback name
                    }
                },

                else => "<?>",
            };

            if (ast.debug_mode) std.debug.print("Assigning variable {s} of type {s}\n", .{ key, type_name_slice });
            try self.variable_map.put(key, decl_node);
            if (ast.debug_mode) std.debug.print("Variable {s} inserted into variable_map.\n", .{key});
        }
    }

    pub fn assign_function(self: *SymbolTable, func_node: *ast.FunctionNode) !void {
        const key = func_node.nameParam.NameParameterNode.name.Identifier.name;
        try self.function_map.put(key, func_node);
    }

    // We need 3 Get functions to retrieve types, variables and functions from our symbol table
    // Param: string name
    // return the struct pointer if found, else return null

    pub fn get_type(self: *SymbolTable, name: []const u8) ?*ast.TypeNode {
        var current_table: ?*SymbolTable = self;
        while (current_table) |tbl| : (current_table = tbl.parent) {
            if (tbl.type_map.get(name)) |ptr| return ptr;
        }
        // create and error message here
        if (ast.debug_mode) std.debug.print("Type {s} not found in symbol table.\n", .{name});
        return null;
    }

    pub fn get_variable(self: *SymbolTable, name: []const u8) ?*ast.DeclarationNode {
        var current_table: ?*SymbolTable = self;
        while (current_table) |table| : (current_table = table.parent) {
            if (table.variable_map.get(name)) |var_ptr| return var_ptr;
        }

        return null;
    }

    pub fn get_function(self: *SymbolTable, name: []const u8) ?*ast.FunctionNode {
        var current_table: ?*SymbolTable = self;
        while (current_table) |table| : (current_table = table.parent) {
            if (table.function_map.get(name)) |func_ptr| {
                return func_ptr;
            }
        }
        return null;
    }

    pub fn print_sym_tables(self: *SymbolTable) void {
        std.debug.print("\n\n--- Symbol Table ---\n", .{});
        dumpMap("types", self.type_map);
        dumpMap("variables", self.variable_map);
        dumpMap("functions", self.function_map);
        std.debug.print("--------------------\n\n", .{});
    }
    fn dumpMap(comptime label: []const u8, map: anytype) void {
        std.debug.print("{s}:\n", .{label});

        // find the longest key
        var max_key_len: usize = 0;
        {
            var it = map.iterator();
            while (it.next()) |e| {
                const key: []const u8 = e.key_ptr.*;
                if (key.len > max_key_len) max_key_len = key.len;
            }
        }

        // header + underline
        std.debug.print("  key", .{});
        var i: usize = "key".len;
        while (i < max_key_len) : (i += 1) std.debug.print(" ", .{});
        std.debug.print("  |  value\n", .{});

        std.debug.print("  ", .{});
        var j: usize = 0;
        while (j < max_key_len) : (j += 1) std.debug.print("-", .{});
        std.debug.print("-----\n", .{});

        // print rows with manual padding
        var it2 = map.iterator();
        while (it2.next()) |e| {
            const key = e.key_ptr.*; // []const u8
            const val = e.value_ptr.*; // pointer to your value

            // key column
            std.debug.print("  {s}", .{key});
            var pad: usize = key.len;
            while (pad < max_key_len) : (pad += 1) std.debug.print(" ", .{});

            // separator + pointer value
            std.debug.print("  |  {*}\n", .{val});
        }

        std.debug.print("\n", .{});
    }
};
