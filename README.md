# kdl.zig

A [KDL Document Language](https://kdl.dev) v2 parser written in Zig.

## Features

- Full KDL v2 syntax support including:
  - Strings (quoted, raw, multiline)
  - Numbers (decimal, hex, octal, binary, scientific notation)
  - Booleans (`#true`, `#false`), null (`#null`), and special floats (`#inf`, `#-inf`, `#nan`)
  - Type annotations
  - Node children blocks
  - Comments (line, block, slashdash)
  - Line continuations
- Memory-efficient arena-based allocation
- Zero dependencies beyond Zig standard library

## Status

**Production Ready** - Passes all 336 official KDL v2 test cases.

## Installation

Add as a Zig dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .kdl = .{
        .url = "https://github.com/user/kdl.zig/archive/refs/heads/main.tar.gz",
        // .hash = "...",
    },
},
```

Or just copy `src/kdl.zig` into your project.

## Quick Start

```zig
const std = @import("std");
const kdl = @import("kdl");

pub fn main() !void {
    const source =
        \\name "Alice"
        \\age 30
        \\active #true
    ;

    var doc = try kdl.parse(std.heap.page_allocator, source);
    defer doc.deinit();

    // Access nodes
    if (doc.getNode("name")) |node| {
        std.debug.print("Name: {s}\n", .{node.arguments[0].value.asString().?});
    }
}
```

## Examples

### Parsing a Configuration File

```zig
const source =
    \\// Database configuration
    \\database {
    \\    host "localhost"
    \\    port 5432
    \\    name "myapp"
    \\    pool-size 10
    \\    ssl #true
    \\}
    \\
    \\server {
    \\    host "0.0.0.0"
    \\    port 8080
    \\    workers 4
    \\}
;

var doc = try kdl.parse(allocator, source);
defer doc.deinit();

// Access database config
const db = doc.getNode("database").?;
for (db.children) |child| {
    std.debug.print("{s}: ", .{child.name});
    if (child.arguments.len > 0) {
        // Print the first argument
        switch (child.arguments[0].value) {
            .string => |s| std.debug.print("{s}\n", .{s}),
            .integer => |i| std.debug.print("{d}\n", .{i}),
            .boolean => |b| std.debug.print("{}\n", .{b}),
            else => std.debug.print("...\n", .{}),
        }
    }
}
```

### Working with Arguments and Properties

```zig
const source =
    \\node "arg1" "arg2" key="value" count=42
;

var doc = try kdl.parse(allocator, source);
defer doc.deinit();

const node = doc.nodes[0];

// Access arguments by index
const arg0 = node.getArg(0).?.value.asString().?;  // "arg1"
const arg1 = node.getArg(1).?.value.asString().?;  // "arg2"

// Access properties by name
const key = node.getProp("key").?.value.asString().?;  // "value"
const count = node.getProp("count").?.value.asInt().?; // 42
```

### Type Annotations

```zig
const source =
    \\node (u8)255 (date)"2024-01-15"
    \\(important)warning "Check this!"
;

var doc = try kdl.parse(allocator, source);
defer doc.deinit();

// Access type annotations on values
const val = doc.nodes[0].arguments[0];
std.debug.print("Type: {s}, Value: {d}\n", .{
    val.type_annotation.?,  // "u8"
    val.value.asInt().?,    // 255
});

// Access type annotations on nodes
const warning = doc.nodes[1];
std.debug.print("Node type: {s}\n", .{warning.type_annotation.?}); // "important"
```

### Nested Children

```zig
const source =
    \\package {
    \\    name "my-app"
    \\    version "1.0.0"
    \\    
    \\    dependencies {
    \\        library "std" version="0.11.0"
    \\        library "json" version="1.2.3"
    \\    }
    \\    
    \\    scripts {
    \\        build "zig build"
    \\        test "zig build test"
    \\    }
    \\}
;

var doc = try kdl.parse(allocator, source);
defer doc.deinit();

const pkg = doc.getNode("package").?;

// Get nested children
if (pkg.getChild("dependencies")) |deps| {
    for (deps.children) |lib| {
        const name = lib.arguments[0].value.asString().?;
        const version = lib.getProp("version").?.value.asString().?;
        std.debug.print("  {s}: {s}\n", .{name, version});
    }
}
```

### Different Number Formats

```zig
const source =
    \\numbers {
    \\    decimal 1_000_000
    \\    hex 0xDEAD_BEEF
    \\    octal 0o755
    \\    binary 0b1010_1010
    \\    float 3.14159
    \\    scientific 6.022e23
    \\    negative -42
    \\}
;

var doc = try kdl.parse(allocator, source);
defer doc.deinit();

const numbers = doc.getNode("numbers").?;
for (numbers.children) |child| {
    const val = child.arguments[0].value;
    switch (val) {
        .integer => |i| std.debug.print("{s}: {d}\n", .{child.name, i}),
        .float => |f| std.debug.print("{s}: {d}\n", .{child.name, f.value}),
        else => {},
    }
}
```

### Raw and Multiline Strings

```zig
const source =
    \\// Raw strings don't process escapes
    \\path #"C:\Users\name"#
    \\regex #"\d+\.\d+"#
    \\
    \\// Multiline strings
    \\description """
    \\    This is a multiline string.
    \\    Leading whitespace is dedented.
    \\    """
    \\
    \\// Multiline raw strings
    \\code #"""
    \\    fn main() {
    \\        println!("Hello!");
    \\    }
    \\    """#
;

var doc = try kdl.parse(allocator, source);
defer doc.deinit();

const path = doc.getNode("path").?.arguments[0].value.asString().?;
// path = "C:\Users\name" (backslash preserved)

const desc = doc.getNode("description").?.arguments[0].value.asString().?;
// desc = "This is a multiline string.\nLeading whitespace is dedented."
```

### Output Formatting

```zig
var doc = try kdl.parse(allocator, source);
defer doc.deinit();

// Format document back to KDL
var output = std.ArrayList(u8).init(allocator);
defer output.deinit();
try std.fmt.format(output.writer(), "{}", .{doc});
std.debug.print("{s}\n", .{output.items});
```

## API Reference

### Types

| Type | Description |
|------|-------------|
| `Document` | Root container holding all top-level nodes |
| `Node` | A KDL node with name, arguments, properties, and children |
| `TypedValue` | A value with optional type annotation |
| `Value` | Union of string, integer (i128), float, boolean, or null |
| `Property` | A name-value pair |

### Parsing

```zig
pub fn parse(allocator: Allocator, source: []const u8) ParseError!Document
```

### Document Methods

```zig
pub fn deinit(self: *Document) void
pub fn getNode(self: Document, name: []const u8) ?*const Node
pub fn format(self: Document, writer: anytype) !void
```

### Node Methods

```zig
pub fn getArg(self: Node, index: usize) ?TypedValue
pub fn getProp(self: Node, name: []const u8) ?TypedValue  // Returns rightmost
pub fn getChild(self: Node, name: []const u8) ?*const Node
pub fn getChildren(self: Node, name: []const u8, buf: []Node) []Node
```

### Value Methods

```zig
pub fn asString(self: Value) ?[]const u8
pub fn asInt(self: Value) ?i64      // Returns null if out of i64 range
pub fn asInt128(self: Value) ?i128
pub fn asFloat(self: Value) ?f64
pub fn asBool(self: Value) ?bool
pub fn isNull(self: Value) bool
```

## Performance

The parser is optimized for minimal allocations - identifiers, raw strings, and quoted strings without escapes are returned as slices into the source (zero-copy). This means **the source string must outlive the Document**.

Allocator choice significantly impacts performance:

| Allocator | Time per parse | Notes |
|-----------|---------------|-------|
| `std.heap.GeneralPurposeAllocator` | ~7.8 µs | Safe, good for debugging |
| `std.heap.page_allocator` | ~3.1 µs | Simple, no cleanup needed |
| `std.heap.c_allocator` | ~0.7 µs | Fastest, requires libc |

*Benchmarked on Apple M1, parsing a typical 150-byte config with 6 nodes.*

For performance-critical applications, use `c_allocator` or a custom arena/pool allocator.

## Building

```bash
# Run unit tests
zig build test

# Run official KDL v2 test suite (336 tests)
zig build test-suite
```

## License

MIT
