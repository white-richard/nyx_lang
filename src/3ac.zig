const std = @import("std");
const m = @import("main.zig");
const ast = @import("ast.zig");
const log = @import("Log.zig");

pub const CompileError = error{
    OutOfMemory,
    UnsupportedNode,
    UnsupportedBinaryOp,
    UndefinedVariable,
    Invalid,
    todo,
};

pub const Instruction = enum {
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    And,
    Or,
    Equals,
    NotEquals,
    LessThan,
    GreaterThan,
    LessEquals,
    GreaterEquals,
    Constant,
    LoadByte,
    StoreByte,
    StoreDouble,
    LoadDouble,
    Label,
    Goto,
    If,
    Jump,
    JumpFalse,
    ImbueFrame,
    ImbueRegister,
    ImbueLabel,
    StoreRegister,
    LoadRegister,
    Return,
};
pub const Value = union(enum) {
    Number: i32,
    Float: f32,
    String: []const u8,
    Char: u8,
    Void: void,
};

// Reserved Register Allocation
pub const Register = usize;
pub const Unused: Register = 0;
pub const NYACOperand = union(enum) {
    Label: []const u8,
    Value: Value,
    Register: Register,
};

pub const NYAC = struct { return_addr: Register, instruction: Instruction, op1: NYACOperand, op2: NYACOperand };

// Storage for registers, and the outputted nyac_list
var registers: std.ArrayList(Value) = .empty;
var nyac_list: std.ArrayList(NYAC) = .empty;

// =======================
// ==    3AC EMISSION   ==
// =======================
//  -- NOTES: --
//  Indices into registers[] list is reserved from 0-8
//  Please be mindful of which index you use. If you need
//  extra registers start from 9.
pub const Compiler = struct {
    alloc: std.mem.Allocator,
    root: *ast.Node,
    nyac_list: std.ArrayList(NYAC),
    file_text: std.ArrayList(u8),
    var_registers: std.StringHashMap(Register),
    var_locations: std.StringHashMap(usize),
    count: usize,
    label_counter: usize,
    fp_offset: usize,
    cur_line: usize,
    last_line: usize,

    pub fn init(alloc: std.mem.Allocator, root: *ast.Node) !*Compiler {
        const compiler = try alloc.create(Compiler);
        compiler.* = .{
            .alloc = alloc,
            .root = root,
            .nyac_list = .empty,
            .file_text = .empty,
            .var_registers = std.StringHashMap(Register).init(alloc),
            .var_locations = std.StringHashMap(usize).init(alloc),
            .count = 8,
            .fp_offset = 0,
            .cur_line = 0,
            .last_line = 0,
            .label_counter = 0,
        };
        return compiler;
    }
    pub fn deinit(self: *Compiler) void {
        //self.nyac_list.deinit(self.alloc);
        self.file_text.deinit(self.alloc);
        self.var_registers.deinit();
        self.var_locations.deinit();
        self.alloc.destroy(self);
    }

    pub fn compile(self: *Compiler) !*std.ArrayList(NYAC) {
        const old_root = self.root;
        self.cur_line = 0;
        switch (self.root.*) {
            .BlockItems => |bi| {
                for (bi.items) |b| {
                    if (ast.debug_mode) std.debug.print("Processing item: {s}\n", .{@tagName(b.*)});
                    try check_write(self);
                    self.root = b;
                    _ = try self.compile_node();
                }
            },
            else => {},
        }

        self.root = old_root;

        // try to open file_name to emit 3AC, if it doesn't exist, then create it
        const file_name = "a.nyac";
        const file = try std.fs.cwd().createFile(file_name, .{
            .truncate = true,
            .exclusive = false,
        });

        defer file.close();
        if (ast.debug_mode) std.debug.print("{s}", .{self.file_text.items});
        try file.writeAll(self.file_text.items);

        return &self.nyac_list;
    }

    pub fn compile_node(self: *Compiler) anyerror!Register {
        if (ast.debug_mode) std.debug.print("Compiling node: {s}\n", .{@tagName(self.root.*)});

        // Note: All of the diagnostic source prints need to be moved
        // to file writing, we will write the source line and then
        // write the associated 3ac with it below.
        return switch (self.root.*) {
            .Binary => |node| try self.handle_binary(node),
            .Identifier => |node| try self.handle_ident(node),
            .Constant => |node| try self.handle_constant(node),
            .Function => |node| try self.handle_function(node),
            .FunctionCall => |node| try self.handle_func_call(node),
            // .ArgumentList => |node| try self.handle_some_node(node),
            // .InitializerList => |node| try self.handle_init_list(node),
            // .ParameterList => |node| try self.handle_some_node(node),
            // .NameParameterNode => |node| try self.handle_some_node(node),
            .TranslationUnitList => |node| try self.handle_translation_units(node),
            .BlockItems => |node| try self.handle_block(node),
            .Unary => |node| try self.handle_unary(node),
            .PostFix => |node| try self.handle_postfix(node),
            .PreFix => |node| try self.handle_prefix(node),
            .ConditionalExpression => |node| try self.handle_cond_expr(node),
            // NOT USED? .Comp => |node| try self.handle_comp(node),
            // .Cast => |node| try self.handle_some_node(node),
            // .AssOp => |node| try self.handle_some_node(node),
            .Declaration => |node| try self.handle_decl(node),
            .Assignment => |node| try self.handle_assignment(node),
            .WhileStmt => |node| try self.handle_while(node),
            .IfStmt => |node| try self.handle_if(node),
            .ReturnStmt => |node| try self.handle_return(node),
            // .String => |node| try self.handle_some_node(node),
            // NOT USED? .Char => |node| try self.handle_some_node(node),
            // NOT USED? .Int => |node| try self.handle_some_node(node),
            // NOT USED? .Float => |node| try self.handle_some_node(node),
            .Type => |_| return Unused,
            .ExpressionStmt => |node| try self.handle_expr_stmt(node),
            .Pointer => |node| try self.handle_pointer(node),
            .IdPointer => |node| try self.handle_id_pointer(node),
            // .Array => |node| try self.handle_array(node),
            // .StructDeclaration => |node| try self.handle_some_node(node),
            // .StructDeclarationList => |node| try self.handle_some_node(node),
            // .StructDeclaratorList => |node| try self.handle_some_node(node),
            // .StructSpecifier => |node| try self.handle_some_node(node),
            // .StructOrUnion => |node| try self.handle_some_node(node),
            else => return Unused,
        };
    }

    pub fn handle_unary(self: *Compiler, root: *ast.UnaryNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;

        const op = root.un_op;

        // '&'  - address-of
        // '*'  - dereference
        // '+'  - unary plus (no-op)
        // '-'  - negation
        // '~'  - bitwise NOT
        // '!'  - logical NOT

        // for unary '+', just return the operand register
        if (op == '+') {
            return try self.compile_expr(root.val);
        }

        // compile operand expression
        const operand_reg = try self.compile_expr(root.val);

        self.count += 1;
        const dest = self.count;

        var nyac: NYAC = undefined;

        if (op == '-') {
            // negate Negation: 0 - operand_reg
            self.count += 1;
            const zero_reg = self.count;
            const const_zero = NYAC{
                .instruction = .Constant,
                .return_addr = zero_reg,
                .op1 = NYACOperand{ .Value = Value{ .Number = 0 } },
                .op2 = NYACOperand{ .Register = Unused },
            };
            try self.nyac_list.append(self.alloc, const_zero);
            try self.emit(const_zero);

            nyac = NYAC{
                .instruction = .Subtract,
                .return_addr = dest,
                .op1 = NYACOperand{ .Register = zero_reg },
                .op2 = NYACOperand{ .Register = operand_reg },
            };
        } else if (op == '!') {
            // nogical not with operand_reg == 0
            self.count += 1;
            const zero_reg = self.count;
            const const_zero = NYAC{
                .instruction = .Constant,
                .return_addr = zero_reg,
                .op1 = NYACOperand{ .Value = Value{ .Number = 0 } },
                .op2 = NYACOperand{ .Register = Unused },
            };
            try self.nyac_list.append(self.alloc, const_zero);
            try self.emit(const_zero);

            nyac = NYAC{
                .instruction = .Equals,
                .return_addr = dest,
                .op1 = NYACOperand{ .Register = operand_reg },
                .op2 = NYACOperand{ .Register = zero_reg },
            };
        } else if (op == '~') {
            // bitwise not and used -1 - oper_reg
            self.count += 1;
            const neg_one_reg = self.count;
            const const_neg_one = NYAC{
                .instruction = .Constant,
                .return_addr = neg_one_reg,
                .op1 = NYACOperand{ .Value = Value{ .Number = -1 } },
                .op2 = NYACOperand{ .Register = Unused },
            };
            try self.nyac_list.append(self.alloc, const_neg_one);
            try self.emit(const_neg_one);

            nyac = NYAC{
                .instruction = .Subtract,
                .return_addr = dest,
                .op1 = NYACOperand{ .Register = neg_one_reg },
                .op2 = NYACOperand{ .Register = operand_reg },
            };
        } else if (op == '*') {
            // dereference load from address in operand_reg
            nyac = NYAC{
                .instruction = .LoadRegister,
                .return_addr = dest,
                .op1 = NYACOperand{ .Register = operand_reg },
                .op2 = NYACOperand{ .Register = Unused },
            };
        } else if (op == '&') {
            // address of using Imbue Register
            nyac = NYAC{
                .instruction = .ImbueRegister,
                .return_addr = dest,
                .op1 = NYACOperand{ .Register = operand_reg },
                .op2 = NYACOperand{ .Register = Unused },
            };
        } else {
            if (ast.debug_mode) std.debug.print("Unsupported unary operator: {c}\n", .{root.un_op});
            return CompileError.UnsupportedNode;
        }

        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        if (ast.debug_mode) std.debug.print("Unary Node Emitted\n", .{});
        return dest;
    }

    pub fn handle_ident(self: *Compiler, root: *ast.IdentifierNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;

        const addr_reg = self.var_registers.get(root.name) orelse return CompileError.UndefinedVariable;

        // Load the value from the variable slot
        self.count += 1;
        const val_reg = self.count;

        const nyac = NYAC{
            .instruction = .LoadRegister, // LR
            .return_addr = val_reg,
            .op1 = .{ .Register = addr_reg },
            .op2 = .{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        if (ast.debug_mode) std.debug.print("Identifier ({s}) Node Emitted\n", .{root.name});
        return val_reg;
    }

    pub fn handle_while(self: *Compiler, root: *ast.WhileNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;

        // Handle for-loop initialization (if present)
        if (root.init) |init_node| {
            _ = try self.compile_expr(init_node);
        }

        // While Statements Top and Bottom Label
        const start_label = self.new_label();
        const end_label = self.new_label();
        try self.emit_label(start_label);

        // Get the condition register
        const cond_reg = try self.compile_expr(root.cond);

        // Jump to end if cond false
        try self.emit_jump_false(cond_reg, end_label);

        // Execute the loop body
        _ = try self.compile_expr(root.body);

        // Jump to start : Emit end label
        try self.emit_jump(start_label);
        try self.emit_label(end_label);

        if (ast.debug_mode) std.debug.print("While Node Emitted\n", .{});
        return Unused;
    }

    pub fn handle_decl(self: *Compiler, root: *ast.DeclarationNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        var name: []const u8 = "";
        var struct_size: usize = 0;

        if (root.declaration_specifier) |spec| {
            if (ast.debug_mode) std.debug.print("Declaration specifier type: {s}\n", .{@tagName(spec.*)});
            if (spec.* == .Type) {
                if (ast.debug_mode) std.debug.print("Type node size: {d}\n", .{spec.Type.size});
                // if size > 0 then probably a struct
                if (spec.Type.size > 0) {
                    struct_size = spec.Type.size;
                    if (ast.debug_mode) {
                        std.debug.print("Handling type with size: {d} bytes\n", .{struct_size});
                    }
                }
            }
            if (spec.* == .StructSpecifier) {
                const struct_spec = spec.StructSpecifier;

                if (struct_spec.typeNode) |tn| {
                    struct_size = tn.size;

                    // TODO: Track struct field offsets in the IR representation.

                    if (struct_spec.identifier) |id| {
                        const struct_name = id.Identifier.name;
                        if (ast.debug_mode) {
                            std.debug.print("Handling struct '{s}' with size: {d} bytes...\n", .{ struct_name, struct_size });
                        }
                    }
                }
            } else if (spec.* == .Type) {
                if (ast.debug_mode) {
                    std.debug.print("Handling Type node declaration\n", .{});
                }
            }
        }

        if (root.assign_node) |ar| {
            name = switch (ar.Assignment.declarator.*) {
                .Array => |array| blk: {
                    if (array.*.identifier) |id| {
                        switch (id.*) {
                            .Identifier => |ident| break :blk ident.name,
                            .IdPointer => |ip| {
                                // For struct member arrays like wa.values[0]
                                // Use the struct name as the base
                                if (ip.pointer.* == .Identifier) {
                                    break :blk ip.pointer.Identifier.name;
                                }
                            },
                            else => {},
                        }
                    }
                    return CompileError.Invalid;
                },
                .Identifier => |ident| ident.*.name,
                .Pointer => |ptr| blk: {
                    // Handle pointer declarations like int *p
                    if (ast.debug_mode) std.debug.print("Processing Pointer declarator\n", .{});
                    if (ptr.*.pointee) |pointee| {
                        if (ast.debug_mode) std.debug.print("Pointee type: {s}\n", .{@tagName(pointee.*)});
                        switch (pointee.*) {
                            .Identifier => |ident| break :blk ident.name,
                            else => {
                                if (ast.debug_mode) std.debug.print("Unsupported pointee type in Pointer declarator\n", .{});
                                return CompileError.Invalid;
                            },
                        }
                    }
                    if (ast.debug_mode) std.debug.print("Pointer has no pointee\n", .{});
                    return CompileError.Invalid;
                },
                .IdPointer => |ip| blk: {
                    // Handle IdPointer for things like function parameters or member pointers
                    if (ast.debug_mode) std.debug.print("Processing IdPointer declarator\n", .{});
                    switch (ip.identifier.*) {
                        .Identifier => |ident| break :blk ident.name,
                        else => {
                            if (ast.debug_mode) std.debug.print("Unsupported identifier type in IdPointer: {s}\n", .{@tagName(ip.identifier.*)});
                            return CompileError.Invalid;
                        },
                    }
                },
                .Type => blk: {
                    break :blk ""; // TODO: Type declarators currently get an empty name.
                },
                else => {
                    if (ast.debug_mode) std.debug.print("Unsupported declarator type: {s}\n", .{@tagName(ar.Assignment.declarator.*)});
                    return CompileError.Invalid;
                },
            };
        } else return Unused;

        // Allocate register slot for the new variable
        self.count += 1;
        const dest = self.count;

        // Track the variable and register
        try self.var_registers.put(name, dest);
        if (ast.debug_mode) std.debug.print("Identifier \"{s}\" assigned to register {d}\n", .{ name, dest });

        if (struct_size > 0) {
            try self.var_locations.put(name, struct_size);
            if (ast.debug_mode) {
                std.debug.print("Struct variable '{s}' allocated at register {d} with size {d}\n", .{ name, dest, struct_size });
            }
        }

        // Emit IMBUE_REGISTER to allocate space
        var imbue_nyac = NYAC{
            .instruction = .ImbueRegister,
            .return_addr = dest,
            .op1 = NYACOperand{ .Register = Unused },
            .op2 = NYACOperand{ .Register = Unused },
        };

        if (struct_size > 0) {
            const clamped_size = @min(struct_size, std.math.maxInt(i32));
            imbue_nyac.op1 = NYACOperand{ .Value = Value{ .Number = @intCast(clamped_size) } };
        }

        try self.nyac_list.append(self.alloc, imbue_nyac);
        try self.emit(imbue_nyac);

        // NOW compile the initializer/assignment if present
        if (root.assign_node) |an| {
            if (an.Assignment.initializer) |initializer| {
                // Compile the RHS expression (this will look up 'x' and return t9)
                const rhs_reg = switch (initializer.*) {
                    .InitializerList => |init_list| {
                        return create_init_list(self, init_list, @intCast(dest));
                    },
                    else => try self.compile_expr(initializer),
                };

                // Store the value from rhs_reg into our new variable
                const store_nyac = NYAC{
                    .instruction = .StoreRegister,
                    .return_addr = dest,
                    .op1 = NYACOperand{ .Register = rhs_reg },
                    .op2 = NYACOperand{ .Register = Unused },
                };

                try self.nyac_list.append(self.alloc, store_nyac);
                try self.emit(store_nyac);
            }
        }

        if (ast.debug_mode) std.debug.print("Decl Node Emitted\n", .{});
        return dest;
    }

    pub fn handle_pointer(self: *Compiler, root: *ast.PointerNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        var pointee_reg = Unused;
        if (root.pointee) |pte| {
            pointee_reg = try self.compile_expr(pte);
        }

        self.count += 1;
        const dest = self.count;
        const nyac = NYAC{
            .instruction = .LoadRegister,
            .return_addr = Unused,
            .op1 = .{ .Register = pointee_reg },
            .op2 = .{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);
        if (ast.debug_mode) std.debug.print("Pointer Node Emitted, depth {d}\n", .{root.depth});
        return dest;
    }

    pub fn handle_id_pointer(self: *Compiler, node: *ast.IdPointerNode) anyerror!Register {
        self.cur_line = if (node.location) |loc| loc.line else 0;

        // Compile the pointer
        const ptr_reg = try self.compile_expr(node.pointer);

        // Compile the identifier (could just be variable lookup)
        // const id_name = switch (node.identifier.*) {
        //     .Identifier => |id| id.name,
        //     else => return CompileError.UnsupportedNode,
        // };
        // const id_reg = self.var_registers.get(id_name) orelse return CompileError.UndefinedVariable;

        // Allocate a register for the loaded value
        self.count += 1;
        const dest = self.count;

        const nyac = NYAC{
            .instruction = .LoadRegister,
            .return_addr = dest,
            .op1 = NYACOperand{ .Register = ptr_reg },
            .op2 = NYACOperand{ .Register = Unused },
        };

        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        if (ast.debug_mode) std.debug.print("IdPointer Node Emitted\n", .{});
        return dest;
    }

    pub fn handle_assignment(self: *Compiler, root: *ast.AssignmentNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;

        if (root.declarator.* == .IdPointer) {
            const id_pointer = root.declarator.IdPointer;
            if (id_pointer.pointer.* == .Identifier) {
                // like p1.x = 10
                return try self.handle_struct_member_assignment(root);
            }
        }

        const var_name = switch (root.declarator.*) {
            .Array => |array| array.*.identifier.?.*.Identifier.name,
            .Identifier => |ident| ident.*.name,
            .Pointer => |ptr| blk: {
                if (ptr.*.pointee) |pointee| {
                    switch (pointee.*) {
                        .Identifier => |ident| break :blk ident.name,
                        else => return CompileError.Invalid,
                    }
                }
                return CompileError.Invalid;
            },
            .IdPointer => |ip| blk: {
                switch (ip.identifier.*) {
                    .Identifier => |ident| break :blk ident.name,
                    else => return CompileError.Invalid,
                }
            },
            .Unary => blk: {
                break :blk ""; // dereference assignment (*p = val) is handled below
            },
            .Type => blk: {
                break :blk ""; // TODO: Assignments to a Type declarator emit no IR.
            },
            else => {
                if (ast.debug_mode) std.debug.print("Unsupported declarator in assignment: {s}\n", .{@tagName(root.declarator.*)});
                return CompileError.Invalid;
            },
        };

        if (root.declarator.* == .Unary) {
            const unary = root.declarator.Unary;
            if (unary.un_op == '*') {
                const ptr_reg = try self.compile_expr(unary.val);

                if (root.initializer) |izer| {
                    const value_reg = try self.compile_expr(izer);

                    const nyac = NYAC{
                        .instruction = .StoreRegister,
                        .return_addr = ptr_reg,
                        .op1 = NYACOperand{ .Register = value_reg },
                        .op2 = NYACOperand{ .Register = Unused },
                    };
                    try self.nyac_list.append(self.alloc, nyac);
                    try self.emit(nyac);
                }

                if (ast.debug_mode) std.debug.print("Unary Dereference Assign Node Emitted\n", .{});
                return ptr_reg;
            }
            return CompileError.UnsupportedNode;
        }

        if (var_name.len == 0) {
            return Unused;
        }

        const lhs_reg = self.var_registers.get(var_name) orelse {
            if (ast.debug_mode) std.debug.print("Undefined variable in assignment: {s}\n", .{var_name});
            return CompileError.UndefinedVariable;
        };

        // separate logic required for initializer list for arrays
        if (root.initializer) |izer| {
            if (ast.debug_mode) std.debug.print("Compiling initializer for assignment\n", .{});
            const rhs_reg = switch (izer.*) {
                .InitializerList => |init_list| {
                    return create_init_list(self, init_list, @intCast(lhs_reg));
                },
                else => return try self.compile_expr(izer),
            };

            // TODO: Emit width-specific stores (byte, double word) based on the variable type.
            const nyac = NYAC{
                .instruction = .StoreRegister,
                .return_addr = lhs_reg,
                .op1 = NYACOperand{ .Register = rhs_reg },
                .op2 = NYACOperand{ .Register = Unused },
            };

            try self.nyac_list.append(self.alloc, nyac);
            try self.emit(nyac);
        }

        if (ast.debug_mode) std.debug.print("Assign Node Emitted\n", .{});
        return lhs_reg;
    }

    pub fn handle_struct_member_assignment(self: *Compiler, root: *ast.AssignmentNode) anyerror!Register {
        // Extract struct member access: struct_var.field or struct_var->field
        const id_pointer = root.declarator.IdPointer;

        // Get the base struct variable name
        const struct_name = blk: {
            switch (id_pointer.pointer.*) {
                .Identifier => |id| {
                    if (id.name.len == 0) return CompileError.Invalid;
                    break :blk id.name;
                },
                else => return CompileError.Invalid,
            }
        };

        // Get the field name
        const field_name = blk: {
            switch (id_pointer.identifier.*) {
                .Identifier => |id| {
                    if (id.name.len == 0) return CompileError.Invalid;
                    break :blk id.name;
                },
                else => return CompileError.Invalid,
            }
        };

        // Get the base struct register
        const base_reg = self.var_registers.get(struct_name) orelse return CompileError.UndefinedVariable;

        // Get struct size to determine if we need field offset calculation
        const struct_size = self.var_locations.get(struct_name) orelse 0;

        if (ast.debug_mode) {
            std.debug.print("Struct member assignment: {s}.{s} (base_reg={d}, struct_size={d})\n", .{ struct_name, field_name, base_reg, struct_size });
        }

        var field_offset: usize = 0;
        if (id_pointer.typeNode) |tn| {
            field_offset = tn.field_map.?.get(field_name).?.offset orelse return CompileError.Invalid;
        } else {
            return CompileError.Invalid;
        }

        if (ast.debug_mode) {
            std.debug.print("Field '{s}' offset within struct '{s}': {d}\n", .{ field_name, struct_name, field_offset });
        }

        // Calculate the address of the struct field
        self.count += 1;
        const field_addr_reg = self.count;

        const offset_nyac = NYAC{
            .instruction = .Add,
            .return_addr = field_addr_reg,
            .op1 = NYACOperand{ .Register = base_reg },
            .op2 = NYACOperand{ .Value = Value{ .Number = @intCast(field_offset) } },
        };
        try self.nyac_list.append(self.alloc, offset_nyac);
        try self.emit(offset_nyac);

        // Compile the right-hand side value
        if (root.initializer) |initializer| {
            const rhs_reg = try self.compile_expr(initializer);

            // Store the value at the calculated field address
            const store_nyac = NYAC{
                .instruction = .StoreRegister,
                .return_addr = field_addr_reg,
                .op1 = NYACOperand{ .Register = rhs_reg },
                .op2 = NYACOperand{ .Register = Unused },
            };
            try self.nyac_list.append(self.alloc, store_nyac);
            try self.emit(store_nyac);
        }

        if (ast.debug_mode) std.debug.print("Struct Member Assign Node Emitted\n", .{});
        return field_addr_reg;
    }

    pub fn handle_function(self: *Compiler, root: *ast.FunctionNode) anyerror!Register {
        const name = root.nameParam.NameParameterNode.name.Identifier.name;

        if (std.mem.eql(u8, name, "printf")) {
            // TODO: Represent printf as a dedicated external-call instruction so
            // register allocation can handle it separately.
            return Unused;
        }

        self.cur_line = if (root.nameParam.NameParameterNode.name.Identifier.location) |loc| loc.line else 0;
        const func_ident_node = root.nameParam.NameParameterNode.name.Identifier;

        const nyac = NYAC{ .instruction = .Label, .return_addr = Unused, .op1 = NYACOperand{ .Label = func_ident_node.name }, .op2 = .{ .Register = Unused } };

        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        // Should register parameters before compiling body
        if (root.nameParam.NameParameterNode.parameterList) |param_list| {
            const params = param_list.ParameterList.params;
            for (params) |param| {
                if (param.* == .Declaration) {
                    _ = try self.compile_expr(param);
                }
            }
        }

        _ = try self.compile_expr(root.body);

        return Unused;
    }

    pub fn handle_func_call(self: *Compiler, root: *ast.FunctionCallNode) !Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        const func_ident_node = root.name.Identifier;

        const nyac = NYAC{ .instruction = .Goto, .return_addr = Unused, .op1 = NYACOperand{ .Label = func_ident_node.name }, .op2 = .{ .Register = Unused } };

        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        return Unused;
    }

    pub fn create_init_list(self: *Compiler, root: *ast.InitializerListNode, base_reg: u32) !Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;

        for (root.inits, 0..) |initializer, index| {
            self.count += 1;
            const offset_reg = self.count;

            const offset_nyac = NYAC{
                .instruction = .Add,
                .return_addr = offset_reg,
                .op1 = NYACOperand{ .Register = base_reg },
                .op2 = NYACOperand{ .Value = Value{ .Number = @intCast(index) } },
            };
            try self.nyac_list.append(self.alloc, offset_nyac);
            try self.emit(offset_nyac);

            const value_reg = try self.compile_expr(initializer);

            // store value at the calculated offset
            const store_nyac = NYAC{
                .instruction = .StoreRegister, // TODO this might need to change for different types
                .return_addr = offset_reg,
                .op1 = NYACOperand{ .Register = value_reg },
                .op2 = NYACOperand{ .Register = Unused },
            };
            try self.nyac_list.append(self.alloc, store_nyac);
            try self.emit(store_nyac);
        }

        return base_reg;
    }

    pub fn handle_translation_units(self: *Compiler, root: *ast.TranslationUnitListNode) !Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        for (root.translationUnits) |unit| {
            _ = try self.compile_expr(unit);
        }

        return Unused;
    }

    pub fn handle_binary(self: *Compiler, node: *ast.BinaryNode) anyerror!Register {
        self.cur_line = if (node.location) |loc| loc.line else 0;
        // Compiling the left and right nodes into registers
        self.root = node.lhs;
        const left_reg = try self.compile_node();

        self.root = node.rhs;
        const right_reg = try self.compile_node();

        // Destination reg
        self.count += 1;
        const dest = self.count;

        // ENUM Instruction
        const instr = switch (node.op) {
            '+' => Instruction.Add,
            '-' => Instruction.Subtract,
            '*' => Instruction.Multiply,
            '/' => Instruction.Divide,
            '%' => Instruction.Modulo,
            '<' => Instruction.LessThan,
            '>' => Instruction.GreaterThan,
            else => {
                if (ast.debug_mode) std.debug.print("Binary Node Unexpected: {c}", .{node.op});
                return CompileError.UnsupportedBinaryOp;
            },
        };

        const nyac = NYAC{ .instruction = instr, .return_addr = dest, .op1 = NYACOperand{ .Register = left_reg }, .op2 = .{ .Register = right_reg } };

        // Append to NYAC list and emit to file
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        if (ast.debug_mode) std.debug.print("Binary Node Emitted\n", .{});
        return dest;
    }

    pub fn handle_prefix(self: *Compiler, root: *ast.PreFixNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        const val_reg = try self.compile_expr(root.val);

        // Determine the op
        const op = root.pre_op;
        const is_increment = std.mem.eql(u8, op, "++");
        const is_decrement = std.mem.eql(u8, op, "--");

        if (!is_increment and !is_decrement) {
            return CompileError.UnsupportedNode;
        }

        // Create constant
        self.count += 1;
        const one_reg = self.count;

        const one_nyac = NYAC{
            .instruction = if (is_increment) .Add else .Subtract,
            .op1 = .{ .Register = val_reg },
            .op2 = .{ .Register = Unused },
            .return_addr = one_reg,
        };
        try self.nyac_list.append(self.alloc, one_nyac);
        try self.emit(one_nyac);

        // Perform operation
        self.count += 1;
        const result_reg = self.count;
        const op_nyac = NYAC{
            .instruction = if (is_increment) .Add else .Subtract,
            .return_addr = result_reg,
            .op1 = NYACOperand{ .Register = val_reg },
            .op2 = NYACOperand{ .Register = one_reg },
        };
        try self.nyac_list.append(self.alloc, op_nyac);
        try self.emit(op_nyac);

        // Store back to the variable
        const store_nyac = NYAC{
            .instruction = .StoreRegister,
            .return_addr = val_reg,
            .op1 = NYACOperand{ .Register = result_reg },
            .op2 = NYACOperand{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, store_nyac);
        try self.emit(store_nyac);

        // PREFIX: Return the NEW value
        if (ast.debug_mode) std.debug.print("PreFix Node Emitted\n", .{});
        return result_reg;
    }

    pub fn handle_postfix(self: *Compiler, root: *ast.PostFixNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        // Get the variable being modified
        const val_reg = try self.compile_expr(root.val);

        // POSTFIX: Save the OLD value first
        self.count += 1;
        const old_val_reg = self.count;
        const save_nyac = NYAC{
            .instruction = .StoreRegister,
            .return_addr = old_val_reg,
            .op1 = NYACOperand{ .Register = val_reg },
            .op2 = NYACOperand{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, save_nyac);
        try self.emit(save_nyac);

        // Determine the operation
        const op = root.post_op;
        const is_increment = std.mem.eql(u8, op, "++");
        const is_decrement = std.mem.eql(u8, op, "--");

        if (!is_increment and !is_decrement) {
            return CompileError.UnsupportedNode;
        }

        // Create constant 1
        self.count += 1;
        const one_reg = self.count;
        const one_nyac = NYAC{
            .instruction = .Constant,
            .op1 = NYACOperand{ .Register = 1 },
            .return_addr = one_reg,
            .op2 = NYACOperand{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, one_nyac);
        try self.emit(one_nyac);

        // Perform operation
        self.count += 1;
        const result_reg = self.count;
        const op_nyac = NYAC{
            .instruction = if (is_increment) .Add else .Subtract,
            .return_addr = result_reg,
            .op1 = NYACOperand{ .Register = val_reg },
            .op2 = NYACOperand{ .Register = one_reg },
        };
        try self.nyac_list.append(self.alloc, op_nyac);
        try self.emit(op_nyac);

        // Store back to the variable
        const store_nyac = NYAC{
            .instruction = .StoreRegister,
            .return_addr = val_reg,
            .op1 = NYACOperand{ .Register = result_reg },
            .op2 = NYACOperand{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, store_nyac);
        try self.emit(store_nyac);

        // POSTFIX: Return the OLD value
        if (ast.debug_mode) std.debug.print("PostFix Node Emitted\n", .{});
        return old_val_reg;
    }

    pub fn handle_constant(self: *Compiler, root: *ast.ConstantNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        self.count += 1;
        const dest = self.count;

        // check type of constant node
        if (std.mem.eql(u8, std.mem.span(root.typeNode.type_name), "float")) {
            const val = try std.fmt.parseFloat(f32, root.value);
            const nyac = NYAC{
                .instruction = .Constant,
                .op1 = NYACOperand{ .Value = Value{ .Float = val } },
                .return_addr = dest,
                .op2 = NYACOperand{ .Register = Unused },
            };

            try self.nyac_list.append(self.alloc, nyac);
            try self.emit(nyac);
        } else if (root.value.len > 0 and root.value[0] == '\'') {
            // Characters like 'a'
            var char_val: u8 = 0;
            if (root.value.len >= 3 and root.value[1] != '\\') {
                char_val = root.value[1];
            } else if (root.value.len >= 4 and root.value[1] == '\\') {
                char_val = switch (root.value[2]) { // handles our escape sequences
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '0' => 0,
                    '\\' => '\\',
                    '\'' => '\'',
                    else => root.value[2],
                };
            }
            const nyac = NYAC{
                .instruction = .Constant,
                .op1 = NYACOperand{ .Value = Value{ .Char = char_val } },
                .return_addr = dest,
                .op2 = NYACOperand{ .Register = Unused },
            };
            try self.nyac_list.append(self.alloc, nyac);
            try self.emit(nyac);
        } else {
            const val = try std.fmt.parseInt(i32, root.value, 10);
            const nyac = NYAC{
                .instruction = .Constant,
                .op1 = NYACOperand{ .Value = Value{ .Number = val } },
                .return_addr = dest,
                .op2 = NYACOperand{ .Register = Unused },
            };

            try self.nyac_list.append(self.alloc, nyac);
            try self.emit(nyac);
        }

        if (ast.debug_mode) std.debug.print("Constant Node Emitted\n", .{});
        return dest;
    }

    pub fn handle_return(self: *Compiler, node: *ast.ReturnNode) anyerror!Register {
        self.cur_line = if (node.location) |nl| nl.line else 0;
        var return_reg = Unused;
        if (node.val) |nv| {
            return_reg = try self.compile_expr(nv);
        }
        // Actually emit a RETURN instruction
        const nyac = NYAC{
            .instruction = .Return,
            .return_addr = Unused,
            .op1 = NYACOperand{ .Register = return_reg },
            .op2 = NYACOperand{ .Register = Unused },
        };
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        if (ast.debug_mode) std.debug.print("Return Node Emitted\n", .{});
        return return_reg;
    }

    pub fn handle_if(self: *Compiler, node: *ast.IfNode) anyerror!Register {
        self.cur_line = if (node.location) |nl| nl.line else 0;
        const cond_reg = self.compile_expr(node.cond);

        const else_label = self.new_label();
        const end_label = self.new_label();

        // Jump False
        try self.emit_jump_false(try cond_reg, else_label);

        // THen branch
        _ = try self.compile_expr(node.if_branch);

        try self.emit_jump(end_label);
        try self.emit_label(else_label);

        if (node.el_branch) |eb| {
            _ = try self.compile_expr(eb);
        }

        try self.emit_label(end_label);
        return Unused;
    }

    pub fn emit_jump_false(self: *Compiler, cond: Register, label: usize) !void {
        if (ast.debug_mode) std.debug.print("Label: {d} to emit\n", .{label});
        const nyac = NYAC{ .instruction = .JumpFalse, .return_addr = Unused, .op1 = .{ .Register = cond }, .op2 = .{ .Label = "ElseBranch" } };
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);
    }

    pub fn emit_jump(self: *Compiler, label: usize) !void {
        if (ast.debug_mode) std.debug.print("Label: {d} to emit\n", .{label});
        const nyac = NYAC{ .instruction = .Jump, .return_addr = Unused, .op1 = .{ .Label = "ThenBranch" }, .op2 = .{ .Register = Unused } };
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);
    }

    pub fn emit_label(self: *Compiler, label: usize) !void {
        if (ast.debug_mode) std.debug.print("Label: {d} to emit\n", .{label});
        const nyac = NYAC{ .instruction = .Label, .return_addr = Unused, .op1 = .{ .Label = "End?Label" }, .op2 = .{ .Register = Unused } };
        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);
    }

    pub fn handle_expr_stmt(self: *Compiler, root: *ast.ExpressionStmtNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        if (root.expr) |re| {
            _ = try self.compile_expr(re);
        }
        return Unused;
    }

    pub fn handle_cond_expr(self: *Compiler, root: *ast.ConditionalExpressionNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        const left_reg = try self.compile_expr(root.expr1);
        const right_reg = try self.compile_expr(root.expr2);

        self.count += 1;
        const dest = self.count;

        const op_str: []const u8 = std.mem.span(root.logicalOperator);
        // Determine the instruction based on logical operator
        const instr = if (std.mem.eql(u8, op_str, "&&"))
            Instruction.And
        else if (std.mem.eql(u8, op_str, "||"))
            Instruction.Or
        else if (std.mem.eql(u8, op_str, "=="))
            Instruction.Equals
        else if (std.mem.eql(u8, op_str, "!="))
            Instruction.NotEquals
        else if (std.mem.eql(u8, op_str, "<"))
            Instruction.LessThan
        else if (std.mem.eql(u8, op_str, ">"))
            Instruction.GreaterThan
        else if (std.mem.eql(u8, op_str, "<="))
            Instruction.LessEquals
        else if (std.mem.eql(u8, op_str, ">="))
            Instruction.GreaterEquals
        else
            return CompileError.UnsupportedBinaryOp;

        const nyac = NYAC{
            .instruction = instr,
            .return_addr = dest,
            .op1 = NYACOperand{ .Register = left_reg },
            .op2 = .{ .Register = right_reg },
        };

        try self.nyac_list.append(self.alloc, nyac);
        try self.emit(nyac);

        if (ast.debug_mode) std.debug.print("ConditionalExpression Node Emitted\n", .{});
        return dest;
    }

    pub fn handle_block(self: *Compiler, root: *ast.BlockItemsNode) anyerror!Register {
        self.cur_line = if (root.location) |loc| loc.line else 0;
        for (root.items) |bi| {
            _ = try self.compile_expr(bi);
        }
        return Unused;
    }

    pub fn check_write(self: *Compiler) !void {
        const line = switch (self.root.*) {
            .Identifier => |id| id.location.?.line,
            .Declaration => |decl| decl.location.?.line,
            .Assignment => |as| as.location.?.line,
            // .Function => |fun| fun.location.?.line,
            .Constant => |c| c.location.?.line,
            .Binary => |bn| bn.location.?.line,
            // if any node type lacks a location, fallback:
            else => 0,
        };
        if (line == 0) return;
        if (ast.debug_mode) {
            try self.file_text.appendSlice(self.alloc, m.diagnostic_source(line));
            try self.file_text.append(self.alloc, '\n');
        }
    }

    pub fn compile_expr(self: *Compiler, node: *ast.Node) anyerror!Register {
        const original = self.root;
        self.root = node;
        const reg = try self.compile_node();
        self.root = original;
        return reg;
    }

    pub fn emit(self: *Compiler, inst: NYAC) !void {
        const writer = &self.file_text;
        if (ast.debug_mode) std.debug.print("Current: {d} <> Last: {d}\n", .{ self.cur_line, self.last_line });
        if (self.cur_line > 0 and self.last_line != self.cur_line) {
            const src = m.diagnostic_source(self.cur_line);
            try writer.appendSlice(self.alloc, "SRC ");
            try writer.appendSlice(self.alloc, src);
            try writer.append(self.alloc, '\n');
            self.last_line = self.cur_line;
        }
        try writer.appendSlice(self.alloc, "IR ");
        try writer.appendSlice(self.alloc, switch (inst.instruction) {
            .Add => "ADD",
            .Subtract => "SUB",
            .Multiply => "MUL",
            .Divide => "DIV",
            .Modulo => "MOD",
            .Constant => "CONST",
            .LoadByte => "LB",
            .StoreByte => "SB",
            .LoadDouble => "LD",
            .StoreDouble => "SD",
            .Label => "LABEL",
            .Goto => "GOTO",
            .If => "IF",
            .ImbueFrame => "IMBUE_FRAME",
            .ImbueRegister => "IMBUE_REGISTER",
            .ImbueLabel => "IMBUE_LABEL",
            .StoreRegister => "SR",
            .LoadRegister => "LR",
            .Jump => "JUMP",
            .JumpFalse => "JUMPFALSE",
            .And => "AND",
            .Or => "OR",
            .Equals => "EQ",
            .NotEquals => "NEQ",
            .LessThan => "LT",
            .GreaterThan => "GT",
            .GreaterEquals => "GTE",
            .LessEquals => "LTE",
            .Return => "RETURN",
            // else => "INVALID"
        });

        var tmp: []const u8 = "";
        if (inst.return_addr == 0) {
            tmp = try std.fmt.allocPrint(self.alloc, " -", .{});
            try writer.appendSlice(self.alloc, tmp);
            self.alloc.free(tmp);
        } else {
            tmp = try std.fmt.allocPrint(self.alloc, " t{d}", .{inst.return_addr});
            try writer.appendSlice(self.alloc, tmp);
            self.alloc.free(tmp);
        }

        switch (inst.op1) {
            .Register => |register| {
                if (register == 0) {
                    tmp = try std.fmt.allocPrint(self.alloc, " -", .{});
                } else tmp = try std.fmt.allocPrint(self.alloc, " t{d}", .{register});
            },
            .Label => |label| {
                tmp = try std.fmt.allocPrint(self.alloc, " \"{s}\"", .{label});
            },
            .Value => |label| {
                // TODO: Share operand formatting between op1 and op2.
                switch (label) {
                    .Float => |flt| {
                        tmp = try std.fmt.allocPrint(self.alloc, " {d}", .{flt});
                    },
                    .Number => |num| {
                        tmp = try std.fmt.allocPrint(self.alloc, " {d}", .{num});
                    },
                    .String => |str| {
                        tmp = try std.fmt.allocPrint(self.alloc, " \"{s}\"", .{str});
                    },
                    .Char => |character| {
                        tmp = try std.fmt.allocPrint(self.alloc, " {c}", .{character});
                    },
                    .Void => |_| {
                        tmp = try std.fmt.allocPrint(self.alloc, " void", .{});
                    },
                    // else => |c| {
                    //     tmp = try std.fmt.allocPrint(self.alloc, ", (value: {any})", .{c});
                    // }
                }
            },
        }
        try writer.appendSlice(self.alloc, tmp);

        switch (inst.op2) {
            .Register => |register| {
                if (register == 0) {
                    tmp = try std.fmt.allocPrint(self.alloc, " -", .{});
                } else tmp = try std.fmt.allocPrint(self.alloc, " t{d}", .{register});
            },
            .Label => |label| {
                tmp = try std.fmt.allocPrint(self.alloc, " \"{s}\")", .{label});
            },
            .Value => |label| {
                switch (label) {
                    .Float => |flt| {
                        tmp = try std.fmt.allocPrint(self.alloc, " {d}", .{flt});
                    },
                    .Number => |num| {
                        tmp = try std.fmt.allocPrint(self.alloc, " {d}", .{num});
                    },
                    .String => |str| {
                        tmp = try std.fmt.allocPrint(self.alloc, " \"{s}\")", .{str});
                    },
                    .Char => |character| {
                        tmp = try std.fmt.allocPrint(self.alloc, " {c}", .{character});
                    },
                    .Void => |_| {
                        tmp = try std.fmt.allocPrint(self.alloc, " void", .{});
                    },
                    // else => |c| {
                    //     tmp = try std.fmt.allocPrint(self.alloc, ", (value: {any})", .{c});
                    // }
                }
            },
        }
        try writer.appendSlice(self.alloc, tmp);
        self.alloc.free(tmp);
        try writer.append(self.alloc, '\n');
    }
    pub fn new_label(self: *Compiler) usize {
        const id = self.label_counter;
        self.label_counter += 1;
        return id;
    }
};
