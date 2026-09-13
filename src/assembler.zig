const std = @import("std");
const nya = @import("3ac.zig");
const ast = @import("ast.zig");

// Not sure what to think about this yet:
// zig cc -target riscv64-freestanding -c ass.s -o ass.o
// llvm-objdump -d ass.o

// This is more of a full emulator though, is it a better option?
// qemu-riscv64
// sudo pacman -S qemu-user
// zig cc -target riscv64-linux-musl -static -O0 ass.s -o a.out
// qemu-riscv64 ./a.out
// echo $?
// should return 5

// TODO Need to move return values to a0
// TODO we are using x1/s1 but this should be a callee saved register. We need the prelonngs and prolouge and stuff

// TODO need .globl



// What was the reasoning behind 32 instead of 64 again?

pub fn assemble(
    alloc: std.mem.Allocator,
    nyac: []const nya.NYAC,
) !void {
    // 1. Allocate registers
    const allocated = try allocate_registers(alloc, nyac);
    defer alloc.free(allocated);

    // 2. Lower to RISC-V instructions
    var riscv = try lower_to_riscv(alloc, allocated);
    defer riscv.deinit(alloc);

    // 3. Emit assembly to file
    try emit_assembly(alloc, riscv, "ass.s");
}

// These are the actual physical regiesters that we are assign
const PHYS_REGS = [_]u8{
    // Avoid x0 (zero), x1 (ra), x2 (sp)
    5, 6, 7, // t0–t2
    28, 29, 30, 31, // t3–t6
    10, 11, 12, 13, 14, 15, 16, 17, // a0–a7 (optional)
    8, 9, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, // s0–s11 (optional)
};

fn allocate_registers(
    alloc: std.mem.Allocator,
    nyac: []const nya.NYAC,
) ![]nya.NYAC {
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

    // 3. Graph coloring
    const coloring = try color_graph(alloc, graph);
    defer alloc.free(coloring);

    // 4. Rewrite NYAC with physical registers
    return try rewrite_registers(alloc, nyac, coloring);
}

fn analyze_lifetimes(
    alloc: std.mem.Allocator,
    nyac: []const nya.NYAC,
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

        // Defs kill liveness
        if (inst.return_addr != nya.Unused) {
            live_now.unset(inst.return_addr);
        }

        // Uses add liveness
        if (inst.op1 == .Register) {
            live_now.set(inst.op1.Register);
        }
        if (inst.op2 == .Register) { // Fixed: was op2_addr
            live_now.set(inst.op2.Register);
        }
    }

    return live_list;
}

fn build_interference_graph(
    alloc: std.mem.Allocator,
    nyac: []const nya.NYAC,
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
        if (inst.return_addr == nya.Unused) continue;

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
) ![]usize {
    const num_colors = PHYS_REGS.len;
    var coloring = try alloc.alloc(usize, graph.len);
    @memset(coloring, std.math.maxInt(usize)); // uncolored

    // Simple greedy coloring
    for (graph, 0..) |neighbors, node| {
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
    nyac: []const nya.NYAC,
    coloring: []const usize,
) ![]nya.NYAC {
    var result = try alloc.alloc(nya.NYAC, nyac.len);
    var is_slot = try alloc.alloc(bool, coloring.len);
    defer alloc.free(is_slot);
    @memset(is_slot, false);

    for (nyac) |inst| {
        if (inst.instruction == .ImbueRegister and inst.return_addr != nya.Unused) {
            is_slot[inst.return_addr] = true;
        }
    }

    for (nyac, 0..) |inst, i| {
        result[i] = inst;

        // Map virtual register to physical register
        if (inst.return_addr != nya.Unused and !is_slot[inst.return_addr]) {
            const c = coloring[inst.return_addr];
            result[i].return_addr = PHYS_REGS[c];
        }
        if (inst.op1 == .Register and !is_slot[inst.op1.Register]) {
            const c = coloring[inst.op1.Register];
            result[i].op1 = .{ .Register = PHYS_REGS[c] };
        }
        if (inst.op2 == .Register and !is_slot[inst.op2.Register]) {
            const c = coloring[inst.op2.Register];
            result[i].op2 = .{ .Register = PHYS_REGS[c] };
        }
    }

    return result;
}

fn find_max_temp(nyac: []const nya.NYAC) usize {
    var max: usize = 0;

    for (nyac) |inst| {
        if (inst.return_addr != nya.Unused and inst.return_addr > max) {
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

    // pseudo
    label,
};

fn lower_to_riscv(
    alloc: std.mem.Allocator,
    nyac: []const nya.NYAC,
) !std.ArrayList(RiscVInst) {
    var out = std.ArrayList(RiscVInst).empty;

    // slot id (virtual temp number) -> stack offset
    var slot_off = std.AutoHashMap(usize, i32).init(alloc);

    var frame_size: i32 = 0;

    // PASS 1: assign each IMBUE_REGISTER a stack slot
    for (nyac) |inst| {
        if (inst.instruction == .ImbueRegister) {
            const slot_id = inst.return_addr;
            const bytes: i32 = inst.op1.Value.Number;

            if (!slot_off.contains(slot_id)) {
                slot_off.put(slot_id, frame_size) catch return error.OutOfMemory;
                frame_size += bytes;
            }
        }
    }

    const fs = align16(frame_size);
    // PASS 2:

    for (nyac) |inst| {
        switch (inst.instruction) {
            //////////////////////////////
            // Arethmetic Operations ////
            /////////////////////////////
            .Add => {
                if (inst.op1 == .Register and inst.op2 == .Register) {
                    try out.append(alloc, .{
                        .op = .add,
                        .rd = inst.return_addr,
                        .rs1 = inst.op1.Register,
                        .rs2 = inst.op2.Register,
                    });
                } else if (inst.op1 == .Register and inst.op2 == .Value) {
                    try out.append(alloc, .{
                        .op = .addi,
                        .rd = inst.return_addr,
                        .rs1 = inst.op1.Register,
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
                try out.append(alloc, .{
                    .op = .li,
                    .rd = inst.return_addr,
                    .imm = inst.op1.Value.Number,
                });
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
                try out.append(alloc, .{ .op = .xori, .rd = inst.return_addr, .rs1 = inst.op1.Register, .rs2 = inst.op2.Register });
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

                // Function prologue for main (you can generalize later)
                if (std.mem.eql(u8, name, "main") and fs != 0) {
                    try out.append(alloc, .{
                        .op = .addi,
                        .rd = 2, // sp
                        .rs1 = 2, // sp
                        .imm = -fs,
                    });
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
                const slot_id = inst.return_addr;
                const off = slot_off.get(slot_id) orelse return error.UnknownSlot;

                // slot register holds an ADDRESS (pointer to its stack space)
                try out.append(alloc, .{
                    .op = .addi,
                    .rd = slot_id,
                    .rs1 = 2, // sp
                    .imm = off,
                });
            },

            .LoadRegister => {
                // LR dst, addr
                const dst = inst.return_addr;
                const addr = inst.op1.Register;

                try out.append(alloc, .{
                    .op = .lw,
                    .rd = dst,
                    .rs1 = addr,
                    .offset = 0,
                });
            },
            .StoreRegister => {
                // SR addr, value
                const addr = inst.return_addr;
                const value = inst.op1.Register;

                try out.append(alloc, .{
                    .op = .sw,
                    .rs1 = addr,
                    .rs2 = value,
                    .offset = 0,
                });
            },

            .Return => {
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

    return out;
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
                // if (ast.debug_mode) try std.debug.print("{s}:\n", .{inst.label});
            },

            .li => {
                try writer.print("    li x{d}, {d}\n", .{ inst.rd, inst.imm });
                // if (ast.debug_mode) try std.debug.print("    li x{d}, {d}\n", .{ inst.rd, inst.imm });
            },

            // 3-register ALU ops
            .add, .sub, .mul, .div, .rem, .band, .bor, .bxor, .slt, .sltu => {
                try writer.print(
                    "    {s} x{d}, x{d}, x{d}\n",
                    .{ @tagName(inst.op), inst.rd, inst.rs1, inst.rs2 },
                );
                // if (ast.debug_mode) try std.debug.print(
                //     "    {s} x{d}, x{d}, x{d}\n",
                //     .{ @tagName(inst.op), inst.rd, inst.rs1, inst.rs2 },
                // );
            },

            // branches
            .beq, .bne, .blt, .bge => {
                try writer.print(
                    "    {s} x{d}, x{d}, {s}\n",
                    .{ @tagName(inst.op), inst.rs1, inst.rs2, inst.label },
                );
                // if (ast.debug_mode) try std.debug.print(
                //     "    {s} x{d}, x{d}, {s}\n",
                //     .{ @tagName(inst.op), inst.rs1, inst.rs2, inst.label },
                // );
            },

            // jumps
            .jal => {
                try writer.print(
                    "    jal x{d}, {s}\n",
                    .{ inst.rd, inst.label },
                );
                // if (ast.debug_mode) try std.debug.print(
                //     "    jal x{d}, {s}\n",
                //     .{ inst.rd, inst.label },
                // );
            },

            // loads
            .lw => {
                try writer.print(
                    "    lw x{d}, {d}(x{d})\n",
                    .{ inst.rd, inst.offset, inst.rs1 },
                );
                // if (ast.debug_mode) try std.debug.print(
                //     "    lw x{d}, {d}(x{d})\n",
                //     .{ inst.rd, inst.offset, inst.rs1 },
                // );
            },

            // stores
            .sw => {
                try writer.print(
                    "    sw x{d}, {d}(x{d})\n",
                    .{ inst.rs2, inst.offset, inst.rs1 },
                );
                // if (ast.debug_mode) try std.debug.print(
                //     "    sw x{d}, {d}(x{d})\n",
                //     .{ inst.rs2, inst.offset, inst.rs1 },
                // );
            },

            .addi => {
                try writer.print("    addi x{d},x{d}, {d}\n", .{ inst.rd, inst.rs1, inst.imm });
                // if (ast.debug_mode) try std.debug.print("    addi x{d},x{d}, {d}\n", .{ inst.rd, inst.rs1, inst.imm });
            },

            .ret => {
                try writer.print("    ret\n", .{});
                // if (ast.debug_mode) try std.debug.print("    ret\n", .{});
            },

            else => {
                try writer.print(
                    "    # UNEMITTED OP: {s}\n",
                    .{@tagName(inst.op)},
                );
                // if (ast.debug_mode) try std.debug.print(
                //     "    # UNEMITTED OP: {s}\n",
                //     .{@tagName(inst.op)},
                // );
            },
        }
    }

    try writer.flush();
}

fn align16(n: i32) i32 {
    return (n + 15) & ~@as(i32, 15);
}
