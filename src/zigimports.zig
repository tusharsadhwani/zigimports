const std = @import("std");

pub const ImportSpan = struct {
    import_name: []const u8,
    start_index: usize,
    end_index: usize,
    start_line: usize,
    start_column: usize,
    end_line: usize,
    end_column: usize,
};

pub fn find_unused_imports(al: std.mem.Allocator, source: [:0]u8) !std.ArrayList(ImportSpan) {
    var tree = try std.zig.Ast.parse(al, source, .zig);
    defer tree.deinit(al);

    var import_index = std.StringHashMap(u32).init(al);
    var import_used = std.StringHashMap(bool).init(al);
    defer import_index.deinit();
    defer import_used.deinit();
    for (tree.nodes.items(.tag), 0..) |node_type, index| {
        if (node_type == .simple_var_decl) {
            // I'll be optimistically calling the variables what I hope to find in the
            // LHS / RHS, and then validating and skipping if it's not what is expected.
            const import_stmt = tree.simpleVarDecl(@intCast(index));

            const import_call = import_stmt.ast.init_node;
            const import_token = tree.firstToken(import_call);
            if (!std.mem.eql(u8, tree.tokenSlice(import_token), "@import")) continue;

            const import_name_idx = import_stmt.ast.mut_token + 1;
            const import_name = tree.tokenSlice(import_name_idx);
            try import_index.put(import_name, @intCast(index));
            try import_used.put(import_name, false);
        } else if (node_type == .field_access or node_type == .identifier) {
            const identifier_idx = tree.firstToken(@intCast(index));
            const identifier = tree.tokenSlice(identifier_idx);
            if (import_used.getKey(identifier) != null) {
                // Mark import as used
                try import_used.put(identifier, true);
            }
            continue;
        }
    }

    var unused_imports = std.ArrayList(ImportSpan).init(al);
    var name_iterator = import_used.iterator();
    while (name_iterator.next()) |entry| {
        const import_variable = entry.key_ptr.*;
        const is_used = entry.value_ptr.*;
        if (!is_used) {
            const node_index = import_index.get(import_variable).?;

            const first_token = tree.firstToken(node_index);
            const start_location = tree.tokenLocation(0, first_token);
            const last_token = tree.lastToken(node_index);

            const semicolon = last_token + 1;
            const end_location = tree.tokenLocation(0, semicolon);

            const span = ImportSpan{
                .import_name = import_variable,
                .start_index = tree.tokenToSpan(first_token).start,
                .end_index = tree.tokenToSpan(semicolon).end,
                .start_line = start_location.line + 1,
                .start_column = start_location.column,
                .end_line = end_location.line + 1,
                .end_column = end_location.column + tree.tokenSlice(semicolon).len,
            };
            try unused_imports.append(span);
        }
    }

    return unused_imports;
}

pub fn remove_imports(source: [:0]u8, imports: []ImportSpan) []u8 {
    // TODO: --fix currently does nothing
    _ = imports;
    return source[0..source.len];
}
