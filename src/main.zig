const std = @import("std");

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

fn write_file(filepath: []const u8, chunks: [][]u8) !void {
    const file = try std.fs.cwd().createFile(filepath, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind == .directory) {
        return error.IsDir;
    }

    for (chunks) |chunk| try file.writeAll(chunk);
}

fn run(al: std.mem.Allocator, filepath: []const u8, fix_mode: bool) !bool {
    const source = try read_file(al, filepath);
    defer al.free(source);

    const unused_imports = try zigimports.find_unused_imports(al, source);
    defer unused_imports.deinit();

    if (fix_mode) {
        const fix_count = unused_imports.items.len;
        if (fix_count > 0) {
            const cleaned_sources = try zigimports.remove_imports(al, source, unused_imports.items);
            defer cleaned_sources.deinit();
            try write_file(filepath, cleaned_sources.items);

            std.debug.print("{s} - Removed {} unused import{s}\n", .{
                filepath,
                fix_count,
                if (fix_count == 1) "" else "s",
            });
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
        if (unused_imports.items.len > 0) return true; // Non-zero exit case
    }
    return false;
}

fn get_zig_files(al: std.mem.Allocator, path: []u8) !std.ArrayList([]u8) {
    var files = std.ArrayList([]u8).init(al);
    try _get_zig_files(al, &files, path);
    return files;
}
fn _get_zig_files(al: std.mem.Allocator, files: *std.ArrayList([]u8), path: []u8) !void {
    const file = std.fs.cwd().openFile(path, .{}) catch return;
    defer file.close();

    const stat = try file.stat();
    switch (stat.kind) {
        .file => {
            if (std.mem.eql(u8, std.fs.path.extension(path), ".zig")) {
                try files.append(try al.dupe(u8, path));
            }
        },
        .directory => {
            const dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
            var entries = dir.iterate();
            while (try entries.next()) |entry| {
                // Ignore dotted files / folders
                if (entry.name[0] == '.') continue;
                const child_path = try std.fs.path.join(al, &.{ path, entry.name });
                defer al.free(child_path);
                try _get_zig_files(al, files, child_path);
            }
        },
        else => {}, // TODO: symlinks etc. aren't handled
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer if (gpa.deinit() == .leak) {
    //     std.process.exit(1);
    // };
    const al = gpa.allocator();

    var args = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, args);

    var paths = std.ArrayList([]u8).init(al);
    defer paths.deinit();

    var fix_mode = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--fix"))
            fix_mode = true
        else
            try paths.append(arg);
    }

    var failed = false;
    for (paths.items) |path| {
        const files = try get_zig_files(al, path);
        defer files.deinit();
        defer for (files.items) |file| al.free(file);

        for (files.items) |filepath| {
            const unused_imports_found = try run(al, filepath, fix_mode);
            if (unused_imports_found) failed = true;
        }
    }

    return if (failed) 1 else 0;
}
