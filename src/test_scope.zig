const std = @import("std");
const testing = std.testing;
const SymbolTable = @import("scope.zig").SymbolTable;

test "SymbolTable: create/destroy root" {
    const root = try SymbolTable.create(testing.allocator, null);
    defer root.destroy();

    try testing.expect(root.parent == null);
}

test "SymbolTable: push/pop table" {
    var root = try SymbolTable.create(testing.allocator, null);
    defer root.destroy();

    const child = try root.push();
    try testing.expect(child.parent == root);

    const back = child.pop();
    try testing.expect(back == root);
}

test "SymbolTable: current depth of table" {
    var root = try SymbolTable.create(testing.allocator, null);
    defer root.destroy();

    try testing.expect(root.current_depth() == 0);

    const child1 = try root.push();
    defer child1.destroy();
    try testing.expect(child1.current_depth() == 1);

    const child2 = try child1.push();
    defer child2.destroy();
    try testing.expect(child2.current_depth() == 2);
}

// test "print_sym_tables crash test" {
//     var st = try SymbolTable.create(testing.allocator, null);
//     defer st.destroy();
//
//     // Should print the contents of the three maps; at least the builtin
//     // types exist in type_map for the root table.
//     st.print_sym_tables();
// }

// Uncomment for debugging the tester
// test "should fail" {
//     try std.testing.expect(false);
// }
