const std = @import("std");
const config = @import("config");

const zigimports = @import("zigimports.zig");

fn read_file(gpa: std.mem.Allocator, io: std.Io, filepath: []const u8) ![:0]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, filepath, .{});
    defer file.close(io);
    var file_reader = file.reader(io, &.{});
    const source = try file_reader.interface.allocRemainingAlignedSentinel(
        gpa,
        .unlimited,
        .of(u8),
        0, // NULL terminated, needed for the zig parser
    );
    return source;
}

fn write_file(io: std.Io, filepath: []const u8, chunks: [][]u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, filepath, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind == .directory) {
        return error.IsDir;
    }

    for (chunks) |chunk| try file.writeStreamingAll(io, chunk);
}

fn run(gpa: std.mem.Allocator, io: std.Io, filepath: []const u8, fix_mode: bool, debug: bool) !bool {
    if (debug)
        std.debug.print("-------- Running on file: {s} --------\n", .{filepath});

    const source = try read_file(gpa, io, filepath);
    defer gpa.free(source);

    var unused_imports = try zigimports.find_unused_imports(gpa, source, debug);
    defer unused_imports.deinit(gpa);
    if (debug)
        std.debug.print("Found {} unused imports in {s}\n", .{ unused_imports.items.len, filepath });

    if (fix_mode) {
        const fix_count = unused_imports.items.len;
        if (fix_count > 0) {
            var cleaned_sources = try zigimports.remove_imports(gpa, source, unused_imports.items, debug);
            defer cleaned_sources.deinit(gpa);
            try write_file(io, filepath, cleaned_sources.items);

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

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    defer gpa.free(args);

    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);

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
            try paths.append(gpa, arg);
    }

    if (paths.items.len == 0) {
        std.debug.print("Usage: zigimports [--fix] [paths...]\n", .{});
        return 2;
    }

    var failed = false;
    for (paths.items) |path| {
        var files = try zigimports.get_zig_files(gpa, io, path, debug);
        defer files.deinit(gpa);
        defer for (files.items) |file| gpa.free(file);

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
                    const unused_imports_found = try run(gpa, io, filepath, fix_mode, debug);
                    if (!unused_imports_found) break;
                }
            } else {
                const unused_imports_found = try run(gpa, io, filepath, fix_mode, debug);
                if (unused_imports_found) failed = true;
            }
        }
    }

    return if (failed) 1 else 0;
}
