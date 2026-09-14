const std = @import("std");
const ir = @import("3ac.zig");
const ast = @import("ast.zig");

// Inspecting the generated assembly:
//   zig cc -target riscv64-freestanding -c a.s -o a.o
//   llvm-objdump -d a.o
//
// Running it under user-mode emulation (requires qemu-riscv64):
//   zig cc -target riscv64-linux-musl -static -O0 a.s -o a.out
//   qemu-riscv64 ./a.out; echo $?

// Calling convention:
//   - arguments go in a0-a7, the return value comes back in a0
//   - the allocator only hands out s0-s11, and every function saves all of
//     them plus ra in its prologue
//   - every variable lives in an 8 byte stack slot (ld/sd), globals live in .data

pub fn assemble(
    alloc: std.mem.Allocator,
    nyac: []const ir.NYAC,
) !void {
    // 1. Allocate registers
    const allocated = try allocate_registers(alloc, nyac);
    defer alloc.free(allocated);

    // 2. Lower to RISC-V instructions
    var riscv = try lower_to_riscv(alloc, allocated);
    defer riscv.deinit(alloc);

    // 3. Emit assembly to file
    try emit_assembly(alloc, riscv, "a.s");
}

// Physical registers available to the allocator.
// Only the callee-saved s registers, t0/t1 are left free as scratch and a0-a7 for calls.
const PHYS_REGS = [_]u8{
    8, 9, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, // s0–s11
};
const SAVED_REGS = PHYS_REGS;

// After allocation they are renumbered to SLOT_BASE + id so the lowering pass can tell them apart
const SLOT_BASE: usize = 1000;
const T0: usize = 5;
const T1: usize = 6;
const A0: usize = 10;

fn allocate_registers(
    alloc: std.mem.Allocator,
    nyac: []const ir.NYAC,
) ![]ir.NYAC {
    const temp_count = find_max_temp(nyac) + 1;

    // 1. Liveness analysis
    const live_list = try analyze_lifetimes(alloc, nyac, temp_count);
    defer {
        for (live_list) |*bs| bs.deinit();
        alloc.free(live_list);
    }

    // 2. Build interference graph
    const graph = try build_interference_graph(alloc, nyac, live_list, temp_count);
    defer free_graph(alloc, graph);

    // Which virtual registers are really stack slots
    var is_slot = try alloc.alloc(bool, temp_count);
    defer alloc.free(is_slot);
    @memset(is_slot, false);
    for (nyac) |inst| {
        if (inst.instruction == .ImbueRegister and inst.return_addr != ir.Unused) {
            is_slot[inst.return_addr] = true;
        }
    }

    // 3. Graph coloring
    const coloring = try color_graph(alloc, graph, is_slot);
    defer alloc.free(coloring);

    // 4. Rewrite NYAC with physical registers
    return try rewrite_registers(alloc, nyac, coloring, is_slot);
}

fn analyze_lifetimes(
    alloc: std.mem.Allocator,
    nyac: []const ir.NYAC,
    temp_count: usize,
) ![]std.bit_set.DynamicBitSet {
    var live_now = try std.bit_set.DynamicBitSet.initEmpty(alloc, temp_count);
    defer live_now.deinit();

    var live_list = try alloc.alloc(std.bit_set.DynamicBitSet, nyac.len);
    errdefer {
        for (live_list) |*bs| bs.deinit();
        alloc.free(live_list);
    }

    var i: usize = nyac.len;
    while (i > 0) {
        i -= 1;
        const inst = nyac[i];

        // Snapshot live-after for this instruction
        live_list[i] = try live_now.clone(alloc);

        // Defs kill liveness (SR is the exception, its return_addr is the address it writes to)
        if (inst.return_addr != ir.Unused and inst.instruction != .StoreRegister) {
            live_now.unset(inst.return_addr);
        }

        // Uses add liveness
        if (inst.instruction == .StoreRegister and inst.return_addr != ir.Unused) {
            live_now.set(inst.return_addr);
        }
        if (inst.op1 == .Register and inst.op1.Register != ir.Unused) {
            live_now.set(inst.op1.Register);
        }
        if (inst.op2 == .Register and inst.op2.Register != ir.Unused) { // Fixed: was op2_addr
            live_now.set(inst.op2.Register);
        }
    }

    return live_list;
}

fn build_interference_graph(
    alloc: std.mem.Allocator,
    nyac: []const ir.NYAC,
    live_list: []const std.bit_set.DynamicBitSet,
    temp_count: usize,
) ![]std.ArrayList(usize) {
    // Adjacency list representation
    var graph = try alloc.alloc(std.ArrayList(usize), temp_count);
    for (graph) |*adj| {
        adj.* = std.ArrayList(usize).empty;
    }

    errdefer {
        for (graph) |*adj| adj.deinit(alloc);
        alloc.free(graph);
    }

    // For each instruction, the defined register interferes with all live registers
    for (nyac, 0..) |inst, i| {
        if (inst.return_addr == ir.Unused or inst.instruction == .StoreRegister) continue;

        const def = inst.return_addr;
        var iter = live_list[i].iterator(.{});

        while (iter.next()) |live_reg| {
            if (live_reg != def) {
                // Add edge: def <-> live_reg
                try add_edge(&graph[def], live_reg, alloc);
                try add_edge(&graph[live_reg], def, alloc);
            }
        }
    }

    return graph;
}

fn add_edge(adj_list: *std.ArrayList(usize), neighbor: usize, alloc: std.mem.Allocator) !void {
    // Avoid duplicates
    for (adj_list.items) |n| {
        if (n == neighbor) return;
    }
    try adj_list.append(alloc, neighbor);
}

fn color_graph(
    alloc: std.mem.Allocator,
    graph: []const std.ArrayList(usize),
    is_slot: []const bool,
) ![]usize {
    const num_colors = PHYS_REGS.len;
    var coloring = try alloc.alloc(usize, graph.len);
    @memset(coloring, std.math.maxInt(usize)); // uncolored

    // Simple greedy coloring
    for (graph, 0..) |neighbors, node| {
        // stack slots live in memory
        if (is_slot[node]) continue;

        var used_colors = try std.bit_set.DynamicBitSet.initEmpty(alloc, num_colors);
        defer used_colors.deinit();

        // Mark colors used by neighbors
        for (neighbors.items) |neighbor| {
            if (coloring[neighbor] != std.math.maxInt(usize)) {
                used_colors.set(coloring[neighbor]);
            }
        }

        // Find first available color
        var color: usize = 0;
        while (color < num_colors) : (color += 1) {
            if (!used_colors.isSet(color)) {
                coloring[node] = color;
                break;
            }
        }

        // If we run out of colors, we'd need to spill (not implemented)
        if (coloring[node] == std.math.maxInt(usize)) {
            return error.RegisterSpillNeeded;
        }
    }

    return coloring;
}

fn free_graph(alloc: std.mem.Allocator, graph: []std.ArrayList(usize)) void {
    for (graph) |*adj| adj.deinit(alloc);
    alloc.free(graph);
}

fn rewrite_registers(
    alloc: std.mem.Allocator,
    nyac: []const ir.NYAC,
    coloring: []const usize,
    is_slot: []const bool,
) ![]ir.NYAC {
    var result = try alloc.alloc(ir.NYAC, nyac.len);

    for (nyac, 0..) |inst, i| {
        result[i] = inst;

        // Map virtual register to physical register
        result[i].return_addr = map_register(inst.return_addr, coloring, is_slot);
        if (inst.op1 == .Register) {
            result[i].op1 = .{ .Register = map_register(inst.op1.Register, coloring, is_slot) };
        }
        if (inst.op2 == .Register) {
            result[i].op2 = .{ .Register = map_register(inst.op2.Register, coloring, is_slot) };
        }
    }

    return result;
}

fn map_register(reg: usize, coloring: []const usize, is_slot: []const bool) usize {
    if (reg == ir.Unused) return ir.Unused;
    if (is_slot[reg]) return SLOT_BASE + reg;
    return PHYS_REGS[coloring[reg]];
}

fn find_max_temp(nyac: []const ir.NYAC) usize {
    var max: usize = 0;

    for (nyac) |inst| {
        if (inst.return_addr != ir.Unused and inst.return_addr > max) {
            max = inst.return_addr;
        }
        if (inst.op1 == .Register and inst.op1.Register > max) {
            max = inst.op1.Register;
        }
        if (inst.op2 == .Register and inst.op2.Register > max) {
            max = inst.op2.Register;
        }
    }

    return max;
}

const RiscVInst = struct {
    op: Op,
    rd: usize = 0,
    rs1: usize = 0,
    rs2: usize = 0,
    imm: i32 = 0,
    offset: i32 = 0,
    label: []const u8 = "",
};

const Op = enum {
    // arithmetic
    addi,
    add,
    sub,
    mul,
    div,
    rem,

    // bitwise (avoid Zig keywords)
    band,
    bor,
    bxor,

    // comparisons
    slt,
    sltu,

    // immediates
    li,
    xori,
    sltiu,

    // control flow
    beq,
    bne,
    blt,
    bge,
    jal,
    ret,

    // memory
    lw,
    sw,
    ld,
    sd,
    la,

    // calls
    call,

    // pseudo
    label,
    globl,
    section,
    string,
    zero,
};

fn lower_to_riscv(
    alloc: std.mem.Allocator,
    nyac: []const ir.NYAC,
) !std.ArrayList(RiscVInst) {
    var out = std.ArrayList(RiscVInst).empty;

    // slot id (virtual temp number) -> stack offset
    var slot_off = std.AutoHashMap(usize, i32).init(alloc);

    var frame_size: i32 = 0;

    // globals (slot id + size) and string literals
    var globals: std.ArrayList([2]i32) = .empty;
    var strings: std.ArrayList([]const u8) = .empty;

    // PASS 1: assign each IMBUE_REGISTER a stack slot
    for (nyac) |inst| {
        if (inst.instruction == .ImbueRegister) {
            const slot_id = inst.return_addr - SLOT_BASE;
            // everything gets at least 8 bytes so ld/sd (and pointers) fit, rounded to 8
            var bytes: i32 = if (inst.op1 == .Value) @max(inst.op1.Value.Number, 8) else 8;
            bytes = (bytes + 7) & ~@as(i32, 7);

            if (inst.op2 == .Label) {
                // global variable, lives in .data instead of the stack
                try globals.append(alloc, .{ @intCast(slot_id), bytes });
            } else if (!slot_off.contains(slot_id)) {
                slot_off.put(slot_id, frame_size) catch return error.OutOfMemory;
                frame_size += bytes;
            }
        }
    }

    // every function uses the same frame: all slots + space to save ra and the s registers
    const save_area: i32 = (SAVED_REGS.len + 1) * 8;
    const fs = align16(frame_size + save_area);

    try out.append(alloc, .{ .op = .section, .label = ".text" });

    // PASS 2: lower each NYAC instruction
    for (nyac) |inst| {
        switch (inst.instruction) {
            //////////////////////////////
            // Arethmetic Operations ////
            /////////////////////////////
            .Add => {
                // adding to a slot means adding to its address (array/struct offsets)
                var rs1: usize = if (inst.op1 == .Register) inst.op1.Register else 0;
                if (rs1 >= SLOT_BASE) {
                    try slot_address(alloc, &out, T0, rs1, slot_off);
                    rs1 = T0;
                }

                if (inst.op1 == .Register and inst.op2 == .Register) {
                    try out.append(alloc, .{
                        .op = .add,
                        .rd = inst.return_addr,
                        .rs1 = rs1,
                        .rs2 = inst.op2.Register,
                    });
                } else if (inst.op1 == .Register and inst.op2 == .Value) {
                    try out.append(alloc, .{
                        .op = .addi,
                        .rd = inst.return_addr,
                        .rs1 = rs1,
                        .imm = inst.op2.Value.Number,
                    });
                } else if (inst.op1 == .Value and inst.op2 == .Register) {
                    // swap to use addi
                    try out.append(alloc, .{
                        .op = .addi,
                        .rd = inst.return_addr,
                        .rs1 = inst.op2.Register,
                        .imm = inst.op1.Value.Number,
                    });
                } else {
                    return error.UnsupportedAddOperands;
                }
            },
            .Subtract => {
                try out.append(alloc, .{
                    .op = .sub,
                    .rd = inst.return_addr,
                    .rs1 = inst.op1.Register,
                    .rs2 = inst.op2.Register,
                });
            },
            .Constant => {
                switch (inst.op1.Value) {
                    .Number => {
                        try out.append(alloc, .{
                            .op = .li,
                            .rd = inst.return_addr,
                            .imm = inst.op1.Value.Number,
                        });
                    },
                    .Char => |ch| {
                        try out.append(alloc, .{ .op = .li, .rd = inst.return_addr, .imm = ch });
                    },
                    .String => |str| {
                        // string literals go in .rodata, load their address
                        try out.append(alloc, .{ .op = .la, .rd = inst.return_addr, .label = try std.fmt.allocPrint(alloc, ".Lstr{d}", .{strings.items.len}) });
                        try strings.append(alloc, str);
                    },
                    // floats would need the floating point registers
                    else => return error.UnsupportedConstant,
                }
            },
            .Multiply => {
                try out.append(alloc, .{ .op = .mul, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
            },
            .Divide => {
                try out.append(alloc, .{ .op = .div, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
            },
            .Modulo => {
                try out.append(alloc, .{ .op = .rem, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
            },
            /////////////////////////
            ///// Conditionals //////
            /////////////////////////
            .Equals => {
                try out.append(alloc, .{ .op = .bxor, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
                try out.append(alloc, .{ .op = .sltiu, .rd = inst.return_addr, .rs1 = inst.return_addr, .imm = 1 });
            },
            .NotEquals => {
                try out.append(alloc, .{ .op = .bxor, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
                try out.append(alloc, .{ .op = .sltu, .rd = inst.return_addr, .rs1 = 0, .rs2 = inst.return_addr });
            },
            .LessThan => {
                try out.append(alloc, .{ .op = .slt, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
            },
            .GreaterThan => {
                try out.append(alloc, .{ .op = .slt, .rd = inst.return_addr, .rs1 = inst.op2.Register, .rs2 = inst.op1.Register });
            },
            .LessEquals => {
                try out.append(alloc, .{ .op = .slt, .rd = inst.return_addr, .rs1 = inst.op2.Register, .rs2 = inst.op1.Register }); // b < a
                try out.append(alloc, .{ .op = .xori, .rd = inst.return_addr, .rs1 = inst.return_addr, .imm = 1 }); // !(b < a)
            },
            .GreaterEquals => {
                try out.append(alloc, .{ .op = .slt, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register }); // a < b
                try out.append(alloc, .{ .op = .xori, .rd = inst.return_addr, .rs1 = inst.return_addr, .imm = 1 }); // !(a < b)
            },
            .And => {
                // turn both sides into 0/1 first so 2 && 1 is 1
                try out.append(alloc, .{ .op = .sltu, .rd = T0, .rs1 = 0, .rs2 = inst.op1.Register });
                try out.append(alloc, .{ .op = .sltu, .rd = T1, .rs1 = 0, .rs2 = inst.op2.Register });
                try out.append(alloc, .{ .op = .band, .rd = inst.return_addr, .rs1 = T0, .rs2 = T1 });
            },
            .Or => {
                try out.append(alloc, .{ .op = .bor, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
                try out.append(alloc, .{ .op = .sltu, .rd = inst.return_addr, .rs1 = 0, .rs2 = inst.return_addr });
            },
            //////////////////
            ///// JUMPS /////
            /////////////////
            .Label => {
                const name = inst.op1.Label;

                // Emit a label pseudo-instruction
                try out.append(alloc, .{
                    .op = .label,
                    .label = name,
                });
            },

            .ImbueFrame => {
                // function prologue: make the frame and save ra + every s register
                try out.append(alloc, .{ .op = .globl, .label = inst.op1.Label });
                try out.append(alloc, .{ .op = .addi, .rd = 2, .rs1 = 2, .imm = -fs });
                try out.append(alloc, .{ .op = .sd, .rs1 = 2, .rs2 = 1, .offset = fs - 8 });
                for (SAVED_REGS, 0..) |reg, k| {
                    try out.append(alloc, .{ .op = .sd, .rs1 = 2, .rs2 = reg, .offset = fs - 16 - @as(i32, @intCast(k)) * 8 });
                }
            },

            ///////////////////
            ///// Calls  //////
            ///////////////////
            .Arg => {
                // mv aN, value
                const n: usize = @intCast(inst.op2.Value.Number);
                try out.append(alloc, .{ .op = .addi, .rd = A0 + n, .rs1 = inst.op1.Register, .imm = 0 });
            },
            .Param => {
                // mv dst, aN
                const n: usize = @intCast(inst.op1.Value.Number);
                try out.append(alloc, .{ .op = .addi, .rd = inst.return_addr, .rs1 = A0 + n, .imm = 0 });
            },
            .Call => {
                try out.append(alloc, .{ .op = .call, .label = inst.op1.Label });
                // result comes back in a0
                if (inst.return_addr != ir.Unused) {
                    try out.append(alloc, .{ .op = .addi, .rd = inst.return_addr, .rs1 = A0, .imm = 0 });
                }
            },

            .Goto, .Jump => {
                // unconditional jump to label
                try out.append(alloc, .{ .op = .jal, .rd = 0, .label = inst.op1.Label }); // jal x0, label  (aka "j label")
            },

            .JumpFalse => {
                // if cond == 0 => branch
                try out.append(alloc, .{ .op = .beq, .rs1 = inst.op1.Register, .rs2 = 0, .label = inst.op2.Label });
            },
            //////////////////
            ///// Arrays /////
            /////////////////
            .ImbueRegister => {
                // nothing to emit, the slot was given a stack offset (or .data space) in pass 1
            },
            .AddressOf => {
                try slot_address(alloc, &out, inst.return_addr, inst.op1.Register, slot_off);
            },

            .LoadRegister => {
                // LR dst, addr
                const dst = inst.return_addr;
                var addr = inst.op1.Register;
                if (addr >= SLOT_BASE) {
                    // a variable, get the address of its slot first
                    try slot_address(alloc, &out, T0, addr, slot_off);
                    addr = T0;
                }

                try out.append(alloc, .{
                    .op = .ld,
                    .rd = dst,
                    .rs1 = addr,
                    .offset = 0,
                });
            },
            .StoreRegister => {
                // SR addr, value
                var addr = inst.return_addr;
                const value = inst.op1.Register;
                if (addr >= SLOT_BASE) {
                    try slot_address(alloc, &out, T0, addr, slot_off);
                    addr = T0;
                }

                try out.append(alloc, .{
                    .op = .sd,
                    .rs1 = addr,
                    .rs2 = value,
                    .offset = 0,
                });
            },

            .Return => {
                // return value goes in a0
                if (inst.op1 == .Register and inst.op1.Register != ir.Unused) {
                    try out.append(alloc, .{ .op = .addi, .rd = A0, .rs1 = inst.op1.Register, .imm = 0 });
                }

                // restore ra and the s registers
                try out.append(alloc, .{ .op = .ld, .rd = 1, .rs1 = 2, .offset = fs - 8 });
                for (SAVED_REGS, 0..) |reg, k| {
                    try out.append(alloc, .{ .op = .ld, .rd = reg, .rs1 = 2, .offset = fs - 16 - @as(i32, @intCast(k)) * 8 });
                }

                // restore stack pointer
                if (fs != 0) {
                    try out.append(alloc, .{
                        .op = .addi,
                        .rd = 2, // sp
                        .rs1 = 2, // sp
                        .imm = fs,
                    });
                }

                // return
                try out.append(alloc, .{
                    .op = .ret,
                });
            },
            else => {},
        }
    }

    // string literals
    try out.append(alloc, .{ .op = .section, .label = ".rodata" });
    for (strings.items, 0..) |str, n| {
        try out.append(alloc, .{ .op = .label, .label = try std.fmt.allocPrint(alloc, ".Lstr{d}", .{n}) });
        try out.append(alloc, .{ .op = .string, .label = str });
    }

    // global variables, their initial values get stored at the top of main
    try out.append(alloc, .{ .op = .section, .label = ".data" });
    for (globals.items) |g| {
        try out.append(alloc, .{ .op = .label, .label = try global_name(alloc, @intCast(g[0])) });
        try out.append(alloc, .{ .op = .zero, .imm = g[1] });
    }

    return out;
}

fn global_name(alloc: std.mem.Allocator, slot_id: usize) ![]const u8 {
    return try std.fmt.allocPrint(alloc, "nyx_global_{d}", .{slot_id});
}

// Puts the address of a stack slot (sp + offset) or a global (la) into rd
fn slot_address(alloc: std.mem.Allocator, out: *std.ArrayList(RiscVInst), rd: usize, slot: usize, slot_off: std.AutoHashMap(usize, i32)) !void {
    const slot_id = slot - SLOT_BASE;
    if (slot_off.get(slot_id)) |off| {
        try out.append(alloc, .{ .op = .addi, .rd = rd, .rs1 = 2, .imm = off });
    } else {
        try out.append(alloc, .{ .op = .la, .rd = rd, .label = try global_name(alloc, slot_id) });
    }
}

fn emit_assembly(alloc: std.mem.Allocator, riscv: std.ArrayList(RiscVInst), output_path: []const u8) !void {
    _ = alloc;
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();

    var file_buf: [8192]u8 = undefined;
    var file_writer_wrapper = file.writer(&file_buf);
    const writer: *std.Io.Writer = &file_writer_wrapper.interface;

    for (riscv.items) |inst| {
        switch (inst.op) {
            .label => {
                try writer.print("{s}:\n", .{inst.label});
            },

            .li => {
                try writer.print("    li x{d}, {d}\n", .{ inst.rd, inst.imm });
            },

            // bitwise ops are named band/bor/bxor because and/or are Zig keywords
            .band, .bor, .bxor => {
                try writer.print(
                    "    {s} x{d}, x{d}, x{d}\n",
                    .{ @tagName(inst.op)[1..], inst.rd, inst.rs1, inst.rs2 },
                );
            },

            // immediate ALU ops
            .xori, .sltiu => {
                try writer.print("    {s} x{d}, x{d}, {d}\n", .{ @tagName(inst.op), inst.rd, inst.rs1, inst.imm });
            },

            // 3-register ALU ops
            .add, .sub, .mul, .div, .rem, .slt, .sltu => {
                try writer.print(
                    "    {s} x{d}, x{d}, x{d}\n",
                    .{ @tagName(inst.op), inst.rd, inst.rs1, inst.rs2 },
                );
            },

            // branches
            .beq, .bne, .blt, .bge => {
                try writer.print(
                    "    {s} x{d}, x{d}, {s}\n",
                    .{ @tagName(inst.op), inst.rs1, inst.rs2, inst.label },
                );
            },

            // jumps
            .jal => {
                try writer.print(
                    "    jal x{d}, {s}\n",
                    .{ inst.rd, inst.label },
                );
            },

            // loads
            .lw => {
                try writer.print(
                    "    lw x{d}, {d}(x{d})\n",
                    .{ inst.rd, inst.offset, inst.rs1 },
                );
            },

            // stores
            .sw => {
                try writer.print(
                    "    sw x{d}, {d}(x{d})\n",
                    .{ inst.rs2, inst.offset, inst.rs1 },
                );
            },

            // 64 bit loads and stores
            .ld => {
                try writer.print("    ld x{d}, {d}(x{d})\n", .{ inst.rd, inst.offset, inst.rs1 });
            },
            .sd => {
                try writer.print("    sd x{d}, {d}(x{d})\n", .{ inst.rs2, inst.offset, inst.rs1 });
            },
            .la => {
                try writer.print("    la x{d}, {s}\n", .{ inst.rd, inst.label });
            },
            .call => {
                try writer.print("    call {s}\n", .{inst.label});
            },

            // assembler directives
            .globl => {
                try writer.print("    .globl {s}\n", .{inst.label});
            },
            .section => {
                try writer.print("    .section {s}\n", .{inst.label});
                if (std.mem.eql(u8, inst.label, ".data")) try writer.print("    .balign 8\n", .{});
            },
            .string => {
                try writer.print("    .string \"{s}\"\n", .{inst.label});
            },
            .zero => {
                try writer.print("    .zero {d}\n", .{inst.imm});
            },

            .addi => {
                try writer.print("    addi x{d},x{d}, {d}\n", .{ inst.rd, inst.rs1, inst.imm });
            },

            .ret => {
                try writer.print("    ret\n", .{});
            },
        }
    }

    try writer.flush();
}

fn align16(n: i32) i32 {
    return (n + 15) & ~@as(i32, 15);
}
