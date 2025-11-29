const std = @import("std");
const build_config = @import("build_config");

const zigimports = @import("zigimports.zig");

fn read_file(al: std.mem.Allocator, filepath: []const u8) ![:0]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    const stat = try file.stat();
    const buffer = try al.allocSentinel(u8, stat.size, 0);
    errdefer al.free(buffer);

    _ = try file.read(buffer);
    return buffer;
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

fn run(al: std.mem.Allocator, filepath: []const u8, fix_mode: bool, debug: bool) !bool {
    if (debug)
        std.debug.print("-------- Running on file: {s} --------\n", .{filepath});

    const source = try read_file(al, filepath);
    defer al.free(source);

    var unused_imports = try zigimports.find_unused_imports(al, source, debug);
    defer unused_imports.deinit(al);
    if (debug)
        std.debug.print("Found {} unused imports in {s}\n", .{ unused_imports.items.len, filepath });

    if (fix_mode) {
        const fix_count = unused_imports.items.len;
        if (fix_count > 0) {
            var cleaned_sources = try zigimports.remove_imports(al, source, unused_imports.items, debug);
            defer cleaned_sources.deinit(al);
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
    }
    return unused_imports.items.len > 0;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };
    const al = gpa.allocator();

    var args = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, args);

    var paths: std.ArrayList([]u8) = .empty;
    defer paths.deinit(al);

    var fix_mode = false;
    var debug = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("{s}\n", .{build_config.version});
            return 0;
        } else if (std.mem.eql(u8, arg, "--fix"))
            fix_mode = true
        else if (std.mem.eql(u8, arg, "--debug"))
            debug = true
        else
            try paths.append(al, arg);
    }

    if (paths.items.len == 0) {
        std.debug.print("Usage: zigimports [--fix] [paths...]\n", .{});
        return 2;
    }

    var failed = false;
    for (paths.items) |path| {
        var files = try zigimports.get_zig_files(al, path, debug);
        defer files.deinit(al);
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
