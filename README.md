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

## Development
There is an optional [Dev Container](https://containers.dev/) configuration and Dockerfile to help setup Zig.

## About this fork
After using Zig for a couple weeks, I began to miss how `go fmt` automatically sorted imports and deleted unused ones. I started to investigate such capabilities and found tusharsadhwani's project. This was great but it was missing my desired feature of sorting imports.

I was able to get a basic program for identifying and sorting imports that's heavily inspired by `go fmt`, then I I forked and integrated my changes in. The scope of the project was dramatically changed, so the refactor to get the changes in were too. I tried to do the commits in a sensible order.
