# zigimports

Automatically remove unused imports and global variables from Zig files.

Zig currently entirely ignores unused globals, which means unused imports aren't errors.
They aren't even warnings.

In fact, you can have an import importing a module/file that *doesn't even exist*, and
the Zig compiler will simply ignore it.

`zigimports` helps you avoid that by cleaning up unused imports.

> [!NOTE]
> Zig plans to eventually address this issue in the compiler directly:
> https://github.com/ziglang/zig/issues/335

## Installation

Requires Zig 0.13.0 or newer:

```bash
zig build --release=safe
```

You should have the `./zig-out/bin/zigimports` binary now.

## Usage

Basic usage:

```console
$ zigimports path/to/file.zig
path/to/file.zig:1:0: std is unused
path/to/file.zig:2:0: otherfile is unused
path/to/file.zig:9:0: MyStruct is unused

$ zigimports path/to/file.zig --fix
path/to/file.zig - Removed 3 unused imports
```

To tidy up your entire codebase, use:

```bash
zigimports --fix .
```

Inspired by `go fmt`, imports are sorted as follows:
- Standard library libraries
- Third-party modules
- Local imports

A newline is placed in between each group.

```zig
# Before
const zig = @import("std").zig;
const root = @import("root");
const foo = @import("foo");
const Two = @import("baz.zig").Two;
const debug = @import("std").debug;
const print = @import("std").debug.print;
const bar = @import("bar");
const One = @import("baz.zig").One;
const builtin = @import("builtin");
const std = @import("std");

pub fn hi() void {
  print("hi");
  One.add;
  foo.bar();
}

pub fn bye() void {
  print("bye");
  builtin.is_test;
}
----------------------------------------
# After
const builtin = @import("builtin");
const print = @import("std").debug.print;

const foo = @import("foo");

const One = @import("baz.zig").One;

pub fn hi() void {
  print("hi");
  One.add;
  foo.bar();
}

pub fn bye() void {
  print("bye");
  builtin.is_test;
}
```
## Development
There is an optional [Dev Container](https://containers.dev/) configuration and Dockerfile to help setup Zig.
