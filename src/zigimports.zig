const std = @import("std");

pub const ImportKind = enum(u8) {
    Builtin,
    ThirdParty,
    Local,
    Specific,
};

pub const ImportSpan = struct {
    import_name: []const u8,
    start_index: usize,
    end_index: usize,
    start_line: usize,
    start_column: usize,
    end_line: usize,
    end_column: usize,
    module_start: usize,
    module: []const u8,
    kind: ImportKind,
    full_import: []const u8,
};

pub const BlockSpan = struct {
    start_index: usize,
    end_index: usize,
};

/// Resolve file and directory paths recursively, and return a list of Zig files
/// present in the given paths.
pub fn get_zig_files(al: std.mem.Allocator, path: []u8, debug: bool) !std.ArrayList([]u8) {
    var files = std.ArrayList([]u8).init(al);
    errdefer files.deinit();
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
                try files.append(try al.dupe(u8, path));
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

pub fn find_imports(al: std.mem.Allocator, source: [:0]const u8, debug: bool) ![]ImportSpan {
    var tree = try std.zig.Ast.parse(al, source, .zig);
    defer tree.deinit(al);

    var block_spans = std.ArrayList(BlockSpan).init(al);
    defer block_spans.deinit();
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
                const lbrace = tree.firstToken(@intCast(index));
                const rbrace = tree.lastToken(@intCast(index));
                try block_spans.append(.{
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

    var imports = std.ArrayList(ImportSpan).init(al);
    errdefer imports.deinit();
    // Pass 2: Find all global variable declarations
    for (tree.nodes.items(.tag), 0..) |node_type, index| {
        if (node_type != .simple_var_decl) continue;
        const import_stmt = tree.simpleVarDecl(@intCast(index));
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

        var token_idx = import_name_idx;
        var module_start: usize = 0;
        var module: []const u8 = "";
        var kind: ImportKind = .ThirdParty;
        var full_import_start: usize = 0;
        var full_import_end: usize = 0;
        var found_import = false;

        while (token_idx < tree.tokens.len) {
            const token = tree.tokenSlice(token_idx);
            if (std.mem.eql(u8, token, "@import")) {
                full_import_start = tree.tokenToSpan(token_idx).start;
                const next_token_idx = token_idx + 2;
                if (next_token_idx < tree.tokens.len) {
                    module_start = tree.tokenToSpan(next_token_idx).start - full_import_start;
                    module = tree.tokenSlice(next_token_idx);
                    // remove quotes
                    module = module[1 .. module.len - 1];
                    found_import = true;
                }
            } else if (found_import and (std.mem.eql(u8, token, ";") or std.mem.eql(u8, token, "."))) {
                full_import_end = tree.tokenToSpan(token_idx + 1).end;
                break;
            }
            token_idx += 1;
        }

        if (!found_import) continue;

        // Determine kind
        const is_builtin = std.mem.eql(u8, module, "std") or
            std.mem.eql(u8, module, "root") or
            std.mem.eql(u8, module, "builtin");

        const is_local = std.mem.endsWith(u8, module, ".zig");

        const is_specific = std.mem.containsAtLeast(u8, module, 1, ".") and !is_local;

        kind = if (is_builtin) ImportKind.Builtin else if (is_local) ImportKind.Local else if (is_specific) ImportKind.Specific else ImportKind.ThirdParty;

        const first_token_idx = tree.firstToken(@intCast(index));
        const start_location = tree.tokenLocation(0, first_token_idx);
        const last_token = tree.lastToken(@intCast(index));

        const semicolon = last_token + 1;
        var end_location = tree.tokenLocation(0, semicolon);
        // If the semicolon is followed by newlines, include those too
        const start_index: usize = tree.tokenToSpan(first_token_idx).start;
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

        const span = ImportSpan{
            .import_name = import_name,
            .start_index = start_index,
            .end_index = end_index,
            .start_line = start_location.line + 1,
            .start_column = start_location.column,
            .end_line = end_location.line + 1,
            .end_column = end_location.column + tree.tokenSlice(semicolon).len,
            .module_start = module_start,
            .module = module,
            .kind = kind,
            .full_import = source[full_import_start .. end_index - 2],
        };
        try imports.append(span);
    }

    return imports.toOwnedSlice();
}

pub fn identifyUnusedImports(al: std.mem.Allocator, imports: []ImportSpan, source: [:0]const u8, debug: bool) !std.ArrayList(ImportSpan) {
    var tree = try std.zig.Ast.parse(al, source, .zig);
    defer tree.deinit(al);

    var import_index = std.StringHashMap(usize).init(al);
    var import_used = std.StringHashMap(bool).init(al);
    defer import_index.deinit();
    defer import_used.deinit();

    // Store all imports in the hashmap
    for (imports, 0..) |import_span, index| {
        try import_index.put(import_span.import_name, index);
        try import_used.put(import_span.import_name, false);
    }

    // Check if we use the variable anywhere in the file
    for (tree.nodes.items(.tag), 0..) |node_type, index| {
        if (node_type != .field_access and node_type != .identifier) continue;
        const identifier_idx = tree.firstToken(@intCast(index));
        const identifier = tree.tokenSlice(identifier_idx);
        if (import_used.getKey(identifier) != null) {
            // Mark import as used
            if (debug and import_used.get(identifier) == false)
                std.debug.print("Global {s} is being used\n", .{identifier});
            try import_used.put(identifier, true);
        }
    }

    var unused_imports = std.ArrayList(ImportSpan).init(al);
    errdefer unused_imports.deinit();
    var name_iterator = import_used.iterator();
    while (name_iterator.next()) |entry| {
        const import_variable = entry.key_ptr.*;
        const is_used = entry.value_ptr.*;
        if (!is_used) {
            if (debug) std.debug.print("Found unused identifier: {s}\n", .{import_variable});
            const node_index = import_index.get(import_variable).?;
            try unused_imports.append(imports[node_index]);
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

pub fn remove_imports(al: std.mem.Allocator, source: [:0]const u8, imports: []ImportSpan, debug: bool) !std.ArrayList([]const u8) {
    std.debug.assert(imports.len > 0);
    std.mem.sort(ImportSpan, imports, {}, compare_start);

    var new_spans = std.ArrayList([]const u8).init(al);
    errdefer new_spans.deinit();
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
    try new_spans.append(source[0..previous_import.start_index]);
    for (imports[1..]) |import| {
        try new_spans.append(source[previous_import.end_index..import.start_index]);
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
    try new_spans.append(source[previous_import.end_index..]);
    if (debug) std.debug.print("Keeping source from {} to the end.\n", .{previous_import.end_index});
    return new_spans;
}

fn convertChunksToString(al: std.mem.Allocator, chunks: [][]const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(al, 1024);
    defer result.deinit();

    for (chunks) |chunk| {
        try result.appendSlice(chunk);
    }

    return result.toOwnedSlice();
}

pub fn compareImports(_: void, lhs: ImportSpan, rhs: ImportSpan) bool {
    // Compare by kind
    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) {
        return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    }

    // Compare by module name
    const order = std.mem.order(u8, lhs.module, rhs.module);
    if (order == .lt) {
        return true;
    } else if (order == .gt) {
        return false;
    }

    // If modules are equal, compare by extra paths
    const lhs_extra = lhs.full_import[lhs.module_start + lhs.module.len .. lhs.full_import.len];
    const rhs_extra = rhs.full_import[rhs.module_start + rhs.module.len .. rhs.full_import.len];
    const extra_order = std.mem.order(u8, lhs_extra, rhs_extra);
    if (extra_order == .lt) {
        return true;
    } else if (extra_order == .gt) {
        return false;
    }

    // If equal, compare by the number of "." to sort by scope
    const lhs_scope = std.mem.count(u8, lhs.module, ".");
    const rhs_scope = std.mem.count(u8, rhs.module, ".");
    if (lhs_scope != rhs_scope) {
        return lhs_scope < rhs_scope;
    }
    // If the number of "." is the same, compare by length to sort by specificity
    if (lhs.module.len != rhs.module.len) {
        return lhs.module.len < rhs.module.len;
    }

    // If everything else is equal, compare by original line number
    return lhs.start_line < rhs.start_line;
}

const print = std.debug.print;

pub fn newSourceFromImports(allocator: std.mem.Allocator, source: [:0]const u8, imports: []ImportSpan) !std.ArrayList(u8) {
    var new_content = std.ArrayList(u8).init(allocator);

    // Add sorted imports to the top of the new content
    var current_kind: ?ImportKind = null;
    for (imports) |imp| {
        if (current_kind != imp.kind) {
            if (current_kind != null) {
                // Ensure a newline between different import groups
                try new_content.appendSlice(&[_]u8{'\n'});
            }
            current_kind = imp.kind;
        }
        try new_content.appendSlice(source[imp.start_index..imp.end_index]);
    }

    // Set line_start to the end of the import block to start copying the rest of the file
    var line_start: usize = imports[imports.len - 1].end_index;

    // Copy the rest of the file, excluding the original import lines
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n');
        const actual_line_end = if (line_end == null) source.len else line_end.? + 1;

        const line = source[line_start..actual_line_end];

        var is_import_line = false;
        for (imports) |imp| {
            if (line_start == imp.start_index) {
                is_import_line = true;
                break;
            }
        }

        if (!is_import_line) {
            try new_content.appendSlice(line);
        }

        line_start = actual_line_end;
    }

    print("{s}\n", .{new_content.items});

    return new_content;
}

test "base-delete" {
    const allocator = std.testing.allocator;

    const input =
        \\const std = @import("std");
        \\const unused = @import("unused");
        \\pub fn main() void {
        \\    std.debug.print("Hi", .{});
        \\}
        \\
    ;

    const expected_output =
        \\const std = @import("std");
        \\pub fn main() void {
        \\    std.debug.print("Hi", .{});
        \\}
        \\
    ;

    const imports = try find_imports(allocator, input, false);
    defer allocator.free(imports);

    const unused_imports = try identifyUnusedImports(allocator, imports, input, false);
    defer unused_imports.deinit();

    const new_chunks = try remove_imports(allocator, input, unused_imports.items, false);
    defer new_chunks.deinit();

    const new_content = try convertChunksToString(allocator, new_chunks.items);
    defer allocator.free(new_content);

    try std.testing.expectEqualStrings(expected_output, new_content);
}
