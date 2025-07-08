const std = @import("std");
const config = @import("config");

const zigimports = @import("zigimports.zig");
fn read_file(al: std.mem.Allocator, filepath: []const u8) ![:0]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const source = try file.readToEndAllocOptions(
        al,
        std.math.maxInt(usize),
        null,
        @alignOf(u8),
        0, // NULL terminated, needed for the zig parser
    );
    return source;
}

fn write_file(filepath: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(filepath, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind == .directory) {
        return error.IsDir;
    }

    try file.writeAll(content);
}

fn clean_content(al: std.mem.Allocator, imports: []zigimports.ImportSpan, source: [:0]const u8, unused_imports: []zigimports.ImportSpan, debug: bool) ![]u8 {
    var filtered_imports = try al.alloc(zigimports.ImportSpan, imports.len);
    defer al.free(filtered_imports);

    var filtered_count: usize = 0;
    for (imports) |import| {
        var is_unused = false;
        for (unused_imports) |unused| {
            if (std.mem.eql(u8, import.full_import, unused.full_import)) {
                is_unused = true;
                break;
            }
        }
        if (!is_unused) {
            filtered_imports[filtered_count] = import;
            filtered_count += 1;
        }
    }

    const final_filtered_imports = filtered_imports[0..filtered_count];

    var new_content = std.ArrayList(u8).init(al);

    // Add sorted imports to the top of the new content
    var current_kind: ?zigimports.ImportKind = null;
    var last_import_line: usize = 0;
    for (final_filtered_imports) |imp| {
        if (debug) std.debug.print("imp: {s}\n", .{imp.full_import});
        if (current_kind != imp.kind) {
            if (current_kind != null) {
                // Ensure a newline between different import groups
                try new_content.appendSlice(&[_]u8{'\n'});
            }
            current_kind = imp.kind;
        }
        if (debug) std.debug.print("appending: {s} {d}\n", .{ source[imp.start_index..imp.end_index], imp.start_line });
        try new_content.appendSlice(source[imp.start_index..imp.end_index]);
        last_import_line = new_content.items.len;
    }

    if (debug) std.debug.print("new_content:\n{s}\n---------\n", .{new_content.items});

    // Set line_start to the end of the import block to start copying the rest of the file
    // var line_start: usize = final_filtered_imports[final_filtered_imports.len - 1].end_index;
    var line_start: usize = 0;

    // Copy the rest of the file, excluding the original import lines
    while (line_start < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, line_start, '\n');
        const actual_line_end = if (line_end == null) source.len else line_end.? + 1;

        const line = source[line_start..actual_line_end];

        // skip newlines already handled in imports lines
        if (line_start <= last_import_line and std.mem.eql(u8, line, "\n")) {
            line_start = actual_line_end;
            continue;
        }

        var is_import_line = false;
        for (imports) |imp| {
            if (line_start == imp.start_index) {
                is_import_line = true;
                break;
            }
        }

        if (!is_import_line) {
            if (debug) std.debug.print("appending: {s}", .{line});
            try new_content.appendSlice(line);
        }

        line_start = actual_line_end;
    }

    return new_content.toOwnedSlice();
}

fn run(al: std.mem.Allocator, filepath: []const u8, fix_mode: bool, debug: bool) !bool {
    if (debug)
        std.debug.print("-------- Running on file: {s} --------\n", .{filepath});

    const source = try read_file(al, filepath);
    defer al.free(source);

    const imports = try zigimports.find_imports(al, source, debug);
    defer al.free(imports);

    std.sort.insertion(zigimports.ImportSpan, imports, {}, zigimports.compareImports);

    const unused_imports = try zigimports.identifyUnusedImports(al, imports, source, debug);
    defer unused_imports.deinit();

    if (debug)
        std.debug.print("Found {} unused imports in {s}\n", .{ unused_imports.items.len, filepath });

    if (fix_mode) {
        const cleaned_content = try clean_content(al, imports, source, unused_imports.items, debug);
        defer al.free(cleaned_content);

        try write_file(filepath, cleaned_content);

        if (unused_imports.items.len > 0) {
            std.debug.print("{s} - Removed {} unused import{s}\n", .{
                filepath,
                unused_imports.items.len,
                if (unused_imports.items.len == 1) "" else "s",
            });
            return true;
        } else {
            return false;
        }
    } else {
        for (unused_imports.items) |import| {
            std.debug.print("{s}:{}:{}: {s} is unused\n", .{
                filepath,
                import.start_line,
                import.start_column,
                import.import_name,
            });
        }
    }
    return false;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };
    const al = gpa.allocator();

    var args = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, args);

    var paths = std.ArrayList([]u8).init(al);
    defer paths.deinit();

    var fix_mode = false;
    var debug = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("{s}\n", .{config.version});
            return 0;
        } else if (std.mem.eql(u8, arg, "--fix"))
            fix_mode = true
        else if (std.mem.eql(u8, arg, "--debug"))
            debug = true
        else
            try paths.append(arg);
    }

    if (paths.items.len == 0) {
        std.debug.print("Usage: zigimports [--fix] [paths...]\n", .{});
        return 2;
    }

    var failed = false;
    for (paths.items) |path| {
        const files = try zigimports.get_zig_files(al, path, debug);
        defer files.deinit();
        defer for (files.items) |file| al.free(file);

        for (files.items) |filepath| {
            if (fix_mode) {
                // In `--fix` mode, we keep linting and fixing until no lint
                // issues are found in any file.
                // FIXME: This is inefficient, as we're linting every single
                // file at least twice, even if most files didn't even have
                // unused globals.
                // Would be better to keep track of which files had to be edited
                // and only re-check those the next time.
                while (true) {
                    const unused_imports_found = try run(al, filepath, fix_mode, debug);
                    if (!unused_imports_found) break;
                }
            } else {
                const unused_imports_found = try run(al, filepath, fix_mode, debug);
                if (unused_imports_found) failed = true;
            }
        }
    }

    return if (failed) 1 else 0;
}

test "basic" {
    const allocator = std.testing.allocator;

    const input =
        \\const zig = @import("std").zig;
        \\const root = @import("root");
        \\const foo = @import("foo");
        \\const Two = @import("baz.zig").Two;
        \\const debug = @import("std").debug;
        \\const print = @import("std").debug.print;
        \\const bar = @import("bar");
        \\const One = @import("baz.zig").One;
        \\const builtin = @import("builtin");
        \\const std = @import("std");
        \\
        \\pub fn hi() void {
        \\  print("hi");
        \\  One.add;
        \\  foo.bar();
        \\}
        \\
        \\pub fn bye() void {
        \\  print("bye");
        \\  builtin.is_test;
        \\}
    ;

    const expected_output =
        \\const builtin = @import("builtin");
        \\const print = @import("std").debug.print;
        \\
        \\const foo = @import("foo");
        \\
        \\const One = @import("baz.zig").One;
        \\
        \\pub fn hi() void {
        \\  print("hi");
        \\  One.add;
        \\  foo.bar();
        \\}
        \\
        \\pub fn bye() void {
        \\  print("bye");
        \\  builtin.is_test;
        \\}
    ;

    const imports = try zigimports.find_imports(allocator, input, false);
    defer allocator.free(imports);

    std.sort.insertion(zigimports.ImportSpan, imports, {}, zigimports.compareImports);

    const unused_imports = try zigimports.identifyUnusedImports(allocator, imports, input, false);
    defer unused_imports.deinit();

    const new_content = try clean_content(allocator, imports, input, unused_imports.items);
    defer allocator.free(new_content);

    try std.testing.expectEqualStrings(expected_output, new_content);
}

test "global assignment between imports" {
    const allocator = std.testing.allocator;

    const input =
        \\const std = @import("std");
        \\const print = std.debug.print;
        \\const config = @import("config");
        \\pub fn foo() void {
        \\  std.fake;
        \\  print("test");
        \\  config.import;
        \\}
    ;

    const expected_output =
        \\const std = @import("std");
        \\
        \\const config = @import("config");
        \\const print = std.debug.print;
        \\pub fn foo() void {
        \\  std.fake;
        \\  print("test");
        \\  config.import;
        \\}
    ;

    const imports = try zigimports.find_imports(allocator, input, false);
    defer allocator.free(imports);

    std.sort.insertion(zigimports.ImportSpan, imports, {}, zigimports.compareImports);

    const unused_imports = try zigimports.identifyUnusedImports(allocator, imports, input, false);
    defer unused_imports.deinit();

    const new_content = try clean_content(allocator, imports, input, unused_imports.items);
    defer allocator.free(new_content);

    try std.testing.expectEqualStrings(expected_output, new_content);
}
