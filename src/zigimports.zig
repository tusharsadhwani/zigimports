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

pub const BlockSpan = struct {
    start_index: usize,
    end_index: usize,
};

/// Resolve file and directory paths recursively, and return a list of Zig files
/// present in the given paths.
pub fn get_zig_files(al: std.mem.Allocator, path: []u8, debug: bool) !std.ArrayList([]u8) {
    var files: std.ArrayList([]u8) = .empty;
    errdefer files.deinit(al);
    try _get_zig_files(al, &files, path, debug);
    return files;
}
fn _get_zig_files(al: std.mem.Allocator, files: *std.ArrayList([]u8), path: []u8, debug: bool) !void {
    // openFile fails on symlinks that point to paths that don't exist, skip those
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == std.fs.File.OpenError.ProcessFdQuotaExceeded) return err;
        if (debug) std.debug.print("Failed to open {s}: {s}\n", .{ path, @errorName(err) });
        return;
    };
    defer file.close();

    const stat = try file.stat();
    if (debug) std.debug.print("Path {s} is a {s}\n", .{ path, @tagName(stat.kind) });
    switch (stat.kind) {
        .file => {
            if (std.mem.eql(u8, std.fs.path.extension(path), ".zig")) {
                if (debug) std.debug.print("Storing zig file {s}\n", .{path});
                try files.append(al, try al.dupe(u8, path));
            }
        },
        .directory => {
            // openDir fails on symlinks when .no_follow is given, skip those
            var dir = std.fs.cwd().openDir(
                path,
                .{ .iterate = true, .no_follow = true },
            ) catch |err| {
                if (debug) std.debug.print("Failed to open {s}: {s}\n", .{ path, @errorName(err) });
                return;
            };
            defer dir.close();

            var entries = dir.iterate();
            while (try entries.next()) |entry| {
                // Ignore dotted files / folders
                if (entry.name[0] == '.') {
                    if (debug) std.debug.print("Skipping hidden path {s}\n", .{entry.name});
                    continue;
                }
                const child_path = try std.fs.path.join(al, &.{ path, entry.name });
                defer al.free(child_path);
                try _get_zig_files(al, files, child_path, debug);
            }
        },
        else => {},
    }
}

/// Returns if the given source position is inside a block or not.
/// `true` means that statement it NOT global, `false` means the statement is global.
fn is_inside_block(blocks: []BlockSpan, source_pos: usize) bool {
    for (blocks) |block| {
        // TODO: maybe it should be `>` not `>=` for end_index
        if (block.start_index <= source_pos and block.end_index >= source_pos)
            return true;
    }
    return false;
}

pub fn find_unused_imports(al: std.mem.Allocator, source: [:0]u8, debug: bool) !std.ArrayList(ImportSpan) {
    var tree = try std.zig.Ast.parse(al, source, .zig);
    defer tree.deinit(al);

    var import_index: std.StringHashMapUnmanaged(std.zig.Ast.Node.Index) = .empty;
    var import_used: std.StringHashMapUnmanaged(bool) = .empty;
    var block_spans: std.ArrayListUnmanaged(BlockSpan) = .empty;
    defer import_index.deinit(al);
    defer import_used.deinit(al);
    defer block_spans.deinit(al);
    // Pass 1: Find the spans of all block scopes
    for (tree.nodes.items(.tag), 0..) |node_type, index| {
        switch (node_type) {
            .block,
            .block_two,
            .block_semicolon,
            .block_two_semicolon,
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                const lbrace = tree.firstToken(@enumFromInt(index));
                const rbrace = tree.lastToken(@enumFromInt(index));
                try block_spans.append(al, .{
                    .start_index = tree.tokenToSpan(lbrace).start,
                    .end_index = tree.tokenToSpan(rbrace).end,
                });
                if (debug) {
                    const lbrace_location = tree.tokenLocation(0, lbrace);
                    const rbrace_location = tree.tokenLocation(0, rbrace);
                    std.debug.print("Block statement from {}:{} ({}) to {}:{} ({})\n", .{
                        lbrace_location.line + 1,
                        lbrace_location.column,
                        tree.tokenToSpan(lbrace).start,
                        rbrace_location.line + 1,
                        rbrace_location.column + tree.tokenSlice(rbrace).len,
                        tree.tokenToSpan(rbrace).end + tree.tokenSlice(rbrace).len,
                    });
                }
            },
            else => {},
        }
    }

    // Pass 2: Find all global variable declarations
    for (tree.nodes.items(.tag), 0..) |node_type, index| {
        if (node_type != .simple_var_decl) continue;
        const import_stmt = tree.simpleVarDecl(@enumFromInt(index));
        // Skip non-global declarations
        const first_token = tree.tokens.get(import_stmt.firstToken());
        if (is_inside_block(block_spans.items, first_token.start)) {
            if (debug) {
                std.debug.print("Skipping global on line {}; it's inside a block\n", .{
                    tree.tokenLocation(0, import_stmt.firstToken()).line,
                });
            }
            continue;
        }

        // Don't try to delete `pub`, `extern` and `export` statements
        if (import_stmt.visib_token != null or import_stmt.extern_export_token != null) {
            if (debug) {
                std.debug.print("Skipping import on line {} as it's pub/extern/export\n", .{
                    tree.tokenLocation(0, import_stmt.firstToken()).line,
                });
            }
            continue;
        }

        const import_name_idx = import_stmt.ast.mut_token + 1;
        const import_name = tree.tokenSlice(import_name_idx);
        try import_index.put(al, import_name, @enumFromInt(index));
        if (debug and import_used.get(import_name) == null)
            std.debug.print("Found new global: {s}\n", .{import_name});
        try import_used.put(al, import_name, false);
    }

    // Pass 3: Check if we use the variable anywhere in the file
    for (tree.nodes.items(.tag), 0..) |node_type, index| {
        if (node_type != .field_access and node_type != .identifier) continue;
        const identifier_idx = tree.firstToken(@enumFromInt(index));
        const identifier = tree.tokenSlice(identifier_idx);
        if (import_used.getKey(identifier) != null) {
            // Mark import as used
            if (debug and import_used.get(identifier) == false)
                std.debug.print("Global {s} is being used\n", .{identifier});
            try import_used.put(al, identifier, true);
        }
    }

    var unused_imports: std.ArrayList(ImportSpan) = .empty;
    errdefer unused_imports.deinit(al);
    var name_iterator = import_used.iterator();
    while (name_iterator.next()) |entry| {
        const import_variable = entry.key_ptr.*;
        const is_used = entry.value_ptr.*;
        if (!is_used) {
            if (debug) std.debug.print("Found unused identifier: {s}\n", .{import_variable});
            const node_index = import_index.get(import_variable).?;

            const first_token = tree.firstToken(node_index);
            const start_location = tree.tokenLocation(0, first_token);
            const last_token = tree.lastToken(node_index);

            const semicolon = last_token + 1;
            var end_location = tree.tokenLocation(0, semicolon);
            // If the semicolon is followed by a newlines, delete those too
            const start_index = tree.tokenToSpan(first_token).start;
            var end_index = tree.tokenToSpan(semicolon).end;
            if (source.len > end_index and source[end_index] == '\n') {
                end_index += 1;
                end_location.line += 1;
                end_location.column = 0;

                // If the statement has at least two leading and at least two trailing
                // newlines, then remove two trailing newlines.
                // For well-formatted zig code, this will ensure that if the import was
                // on its own little section surrounded by empty lines, the whole
                // section is deleted.
                if (start_index > 1 and source[start_index - 1] == '\n' and source[start_index - 2] == '\n' and source.len > end_index and source[end_index] == '\n') {
                    end_index += 1;
                    end_location.line += 1;
                    end_location.column = 0;
                }
            }

            const span: ImportSpan = .{
                .import_name = import_variable,
                .start_index = start_index,
                .end_index = end_index,
                .start_line = start_location.line + 1,
                .start_column = start_location.column,
                .end_line = end_location.line + 1,
                .end_column = end_location.column + tree.tokenSlice(semicolon).len,
            };
            try unused_imports.append(al, span);
        }
    }

    return unused_imports;
}

/// Returns `true` when lhs shows up before rhs in the file, i.e. the start index of
/// lhs < start index of rhs. Also has checks to ensure the spans never overlap.
fn compare_start(_: void, lhs: ImportSpan, rhs: ImportSpan) bool {
    if (lhs.start_index < rhs.start_index) {
        std.debug.assert(lhs.end_index <= rhs.start_index);
        return true;
    }

    std.debug.assert(rhs.end_index <= lhs.start_index);
    return false;
}

pub fn remove_imports(al: std.mem.Allocator, source: [:0]u8, imports: []ImportSpan, debug: bool) !std.ArrayList([]u8) {
    std.debug.assert(imports.len > 0);
    std.mem.sort(ImportSpan, imports, {}, compare_start);

    var new_spans: std.ArrayList([]u8) = .empty;
    errdefer new_spans.deinit(al);
    var previous_import = imports[0];
    if (debug) {
        std.debug.print("Unused import statement from {}:{} ({}) to {}:{} ({})\n", .{
            previous_import.start_line,
            previous_import.start_column,
            previous_import.start_index,
            previous_import.end_line,
            previous_import.end_column,
            previous_import.end_index,
        });
        std.debug.print("Keeping source from 0 to {}\n", .{previous_import.start_index});
    }
    try new_spans.append(al, source[0..previous_import.start_index]);
    for (imports[1..]) |import| {
        try new_spans.append(al, source[previous_import.end_index..import.start_index]);
        if (debug) {
            std.debug.print("Unused import statement from {}:{} ({}) to {}:{} ({})\n", .{
                import.start_line,
                import.start_column,
                import.start_index,
                import.end_line,
                import.end_column,
                import.end_index,
            });
            std.debug.print("Keeping source from {} to {}\n", .{ previous_import.end_index, import.start_index });
        }
        previous_import = import;
    }
    try new_spans.append(al, source[previous_import.end_index..]);
    if (debug) std.debug.print("Keeping source from {} to the end.\n", .{previous_import.end_index});
    return new_spans;
}
