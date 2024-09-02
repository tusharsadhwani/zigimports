# zigimports

Automatically remove unused imports and global variables from Zig files.

Zig currently entirely ignores unused globals, which means unused imports aren't errors.
They aren't even warnings.

In fact, you can have an import importing a module/file that *doesn't even exist*, and
the Zig compiler will simply ignore it.

`zigimports` helps you avoid that by cleaning up unused imports.

## Installation

Requires Zig 0.13.0 or newer:

```bash
zig build --release=safe
```

You should have the `./zig-out/bin/zigimports` binary now.

## Usage

```console
$ zigimports path/to/file.zig
path/to/file.zig:1:0: std is unused
path/to/file.zig:2:0: otherfile is unused
path/to/file.zig:9:0: MyStruct is unused

$ zigimports path/to/file.zig --fix
path/to/file.zig - Removed 3 unused imports
```
