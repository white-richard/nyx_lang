const std = @import("std");
const ast = @import("ast.zig");

pub fn built_in_types(
    allocator: std.mem.Allocator,
    root: *ast.Node,
) !?*ast.Node {
    // upstream = upstream;
    // const arena = std.heap.ArenaAllocator.init(upstream);
    // const allocator = arena.allocator();

    const int32 = try allocator.create(ast.TypeNode);
    int32.* = ast.TypeNode{
        .is_unsigned = false,
        .is_const = false,
        .qualifier = 0, // 0 none, 1 long, 2 long long
        .type_name = "int",
        .size = @sizeOf(i32),
        .alignment = @alignOf(i32),
    };
    const int32_Node = try allocator.create(ast.Node);
    int32_Node.* = .{ .Type = int32 };

    const int64 = try allocator.create(ast.TypeNode);
    int64.* = ast.TypeNode{
        .is_unsigned = false,
        .is_const = false,
        .qualifier = 1, // 0 none, 1 long, 2 long long
        .type_name = "long",
        .size = @sizeOf(i64),
        .alignment = @alignOf(i64),
    };
    const int64_node = try allocator.create(ast.Node);
    int64_node.* = .{ .Type = int64 };

    const int128 = try allocator.create(ast.TypeNode);
    int128.* = ast.TypeNode{
        .is_unsigned = false,
        .is_const = false,
        .qualifier = 2, // 0 none, 1 long, 2 long long
        .type_name = "long long",
        .size = @sizeOf(i64),
        .alignment = @alignOf(i64),
    };
    const int128_node = try allocator.create(ast.Node);
    int128_node.* = .{ .Type = int128 };

    const uint32 = try allocator.create(ast.TypeNode);
    uint32.* = ast.TypeNode{
        .is_unsigned = true,
        .is_const = false,
        .qualifier = 0, // 0 none, 1 long, 2 long long
        .type_name = "uint",
        .size = @sizeOf(u32),
        .alignment = @alignOf(u32),
    };
    const uint32_node = try allocator.create(ast.Node);
    uint32_node.* = .{ .Type = uint32 };

    const uint64 = try allocator.create(ast.TypeNode);
    uint64.* = ast.TypeNode{
        .is_unsigned = true,
        .is_const = false,
        .qualifier = 1, // 0 none, 1 long, 2 long long
        .type_name = "ulong",
        .size = @sizeOf(u64),
        .alignment = @alignOf(u64),
    };
    const uint64_node = try allocator.create(ast.Node);
    uint64_node.* = .{ .Type = uint64 };

    const uint128 = try allocator.create(ast.TypeNode);
    uint128.* = ast.TypeNode{
        .is_unsigned = true,
        .is_const = false,
        .qualifier = 2, // 0 none, 1 long, 2
        .type_name = "ulong long",
        .size = @sizeOf(u128),
        .alignment = @alignOf(u128),
    };
    const uint128_node = try allocator.create(ast.Node);
    uint128_node.* = .{ .Type = uint128 };

    const float32 = try allocator.create(ast.TypeNode);
    float32.* = ast.TypeNode{
        .is_unsigned = false,
        .is_floating = true,
        .is_const = false,
        .qualifier = 0, // 0 none, 1 long, 2 long long
        .type_name = "float",
        .size = @sizeOf(f32),
        .alignment = @alignOf(f32),
    };
    const float32_node = try allocator.create(ast.Node);
    float32_node.* = .{ .Type = float32 };

    const float64 = try allocator.create(ast.TypeNode);
    float64.* = ast.TypeNode{
        .is_unsigned = false,
        .is_floating = true,
        .is_const = false,
        .qualifier = 1, // 0 none, 1 long, 2
        .type_name = "double",
        .size = @sizeOf(f64),
        .alignment = @alignOf(f64),
    };
    const float64_node = try allocator.create(ast.Node);
    float64_node.* = .{ .Type = float64 };

    const charu8 = try allocator.create(ast.TypeNode);
    charu8.* = ast.TypeNode{
        .is_unsigned = false,
        .is_const = false,
        .qualifier = 0, // 0 none, 1 long, 2 long long
        .type_name = "char",
        .size = @sizeOf(u8),
        .alignment = @alignOf(u8),
    };
    const charu8_node = try allocator.create(ast.Node);
    charu8_node.* = .{ .Type = charu8 };

    const VOID = try allocator.create(ast.TypeNode);
    VOID.* = ast.TypeNode{
        .is_unsigned = false,
        .is_const = false,
        .qualifier = 0, // 0 none, 1 long, 2 long long
        .type_name = "void",
        .size = 0,
        .alignment = 1,
    };
    const VOID_node = try allocator.create(ast.Node);
    VOID_node.* = .{ .Type = VOID };

    const bool_type = try allocator.create(ast.TypeNode);
    bool_type.* = ast.TypeNode{
        .is_unsigned = false,
        .is_const = false,
        .qualifier = 0, // 0 none, 1 long, 2 long long
        .type_name = "bool",
        .size = @sizeOf(bool),
        .alignment = @alignOf(bool),
    };
    const bool_type_node = try allocator.create(ast.Node);
    bool_type_node.* = .{ .Type = bool_type };

    const printf_node = try allocator.create(ast.FunctionNode);
    const nameparm = try allocator.create(ast.NameParameterNode);
    const p_ident = try allocator.create(ast.IdentifierNode);
    const body_node = try allocator.create(ast.Node);
    const ident_node = try allocator.create(ast.Node);
    p_ident.* = ast.IdentifierNode{ .name = "printf" };
    body_node.* = ast.Node{ .BlockItems = @constCast(&ast.BlockItemsNode{ .items = &[_]*ast.Node{} }) };
    ident_node.* = ast.Node{ .Identifier = p_ident };
    nameparm.* = ast.NameParameterNode{ .parameterList = null, .name = ident_node };
    const nameparm_node = try allocator.create(ast.Node);
    nameparm_node.* = ast.Node{ .NameParameterNode = nameparm };
    printf_node.* = ast.FunctionNode{ .retType = VOID, .nameParam = nameparm_node, .body = body_node, .arity = 1000 };
    const ret_node = try allocator.create(ast.Node);
    ret_node.* = ast.Node{ .Function = printf_node };

    const block_node = try allocator.create(ast.Node);
    const builtin_block = try allocator.create(ast.BlockItemsNode);
    var bl_items: std.ArrayList(*ast.Node) = .empty;
    try bl_items.appendSlice(allocator, &[_]*ast.Node{ int32_Node, int64_node, int128_node, uint32_node, uint64_node, uint128_node, float32_node, float64_node, charu8_node, VOID_node, bool_type_node, ret_node, root });
    builtin_block.* = ast.BlockItemsNode{ .items = try bl_items.toOwnedSlice(allocator) };
    block_node.* = ast.Node{ .BlockItems = builtin_block };

    return block_node;
}
