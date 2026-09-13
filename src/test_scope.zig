const std = @import("std");
const testing = std.testing;
const SymbolTable = @import("scope.zig").SymbolTable;

test "SymbolTable: create/destroy root" {
    const root = try SymbolTable.create(testing.allocator, null);
    defer root.destroy();

    try testing.expect(root.parent == null);
}

test "SymbolTable: push/pop table" {
    const root = try SymbolTable.create(testing.allocator, null);
    defer root.destroy();

    const child = root.push() orelse return error.PushFailed;
    try testing.expect(child.parent == root);

    const back = child.pop();
    try testing.expect(back == root);
}

test "SymbolTable: current depth of table" {
    const root = try SymbolTable.create(testing.allocator, null);
    defer root.destroy();

    try testing.expect(root.current_depth() == 0);

    const child1 = root.push() orelse return error.PushFailed;
    defer child1.destroy();
    try testing.expect(child1.current_depth() == 1);

    const child2 = child1.push() orelse return error.PushFailed;
    defer child2.destroy();
    try testing.expect(child2.current_depth() == 2);
}
