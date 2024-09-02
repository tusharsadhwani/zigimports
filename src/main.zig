const std = @import("std");

const zigimports = @import("zigimports.zig");

fn read_file(al: std.mem.Allocator, filepath: []const u8) ![:0]u8 {
    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();
    const stat = try file.stat();
    if (stat.kind == .directory) {
        return error.IsDir;
    }

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

fn run(al: std.mem.Allocator, filepath: []const u8, fix_mode: bool) !void {
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
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };
    const al = gpa.allocator();

    var args = try std.process.argsAlloc(al);
    defer std.process.argsFree(al, args);

    var filepaths = std.ArrayList([]u8).init(al);
    defer filepaths.deinit();

    var fix_mode = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--fix"))
            fix_mode = true
        else
            try filepaths.append(arg);
    }
    for (filepaths.items) |filepath| try run(al, filepath, fix_mode);
}
