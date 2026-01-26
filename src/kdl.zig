const std = @import("std");

// Re-export types from submodules
pub const Tokenizer = @import("tokenizer.zig").Tokenizer;
pub const Token = @import("tokenizer.zig").Token;
pub const Parser = @import("parser.zig").Parser;

pub const Value = union(enum) {
    string: []const u8,
    integer: i128,
    float: FloatValue,
    boolean: bool,
    null,

    pub const FloatValue = struct {
        value: f64,
        has_exponent: bool = false,
        has_decimal: bool = true,
        /// Raw string representation for values that overflow/underflow f64
        raw: ?[]const u8 = null,
    };

    pub fn asString(self: Value) ?[]const u8 {
        return if (self == .string) self.string else null;
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| if (i >= std.math.minInt(i64) and i <= std.math.maxInt(i64)) @intCast(i) else null,
            .float => |f| @intFromFloat(f.value),
            else => null,
        };
    }

    pub fn asInt128(self: Value) ?i128 {
        return switch (self) {
            .integer => |i| i,
            .float => |f| @intFromFloat(f.value),
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |f| f.value,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return if (self == .boolean) self.boolean else null;
    }

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    pub fn format(self: Value, writer: anytype) !void {
        switch (self) {
            .string => |s| try writeEscapedString(writer, s),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |fv| {
                // If we have a raw string (for overflow/underflow), use it
                if (fv.raw) |raw| {
                    try writer.writeAll(raw);
                } else if (std.math.isNan(fv.value)) {
                    try writer.writeAll("#nan");
                } else if (std.math.isPositiveInf(fv.value)) {
                    try writer.writeAll("#inf");
                } else if (std.math.isNegativeInf(fv.value)) {
                    try writer.writeAll("#-inf");
                } else {
                    try formatFloatValue(writer, fv);
                }
            },
            .boolean => |b| try writer.print("#{any}", .{b}),
            .null => try writer.writeAll("#null"),
        }
    }
};

fn formatFloatValue(writer: anytype, fv: Value.FloatValue) !void {
    const f = fv.value;
    const abs = @abs(f);

    // Use scientific notation if:
    // 1. Input had exponent, OR
    // 2. Value is very large or very small
    const use_scientific = fv.has_exponent or (abs != 0 and (abs >= 1e10 or abs < 1e-4));

    if (use_scientific) {
        try formatFloatScientific(writer, f, fv.has_decimal);
    } else {
        try formatFloatDecimal(writer, f);
    }
}

fn formatFloatDecimal(writer: anytype, f: f64) !void {
    var buf: [64]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
        try writer.print("{d}", .{f});
        return;
    };

    // Ensure there's a decimal point
    var has_dot = false;
    for (slice) |c| {
        if (c == '.') has_dot = true;
    }

    try writer.writeAll(slice);
    if (!has_dot) {
        try writer.writeAll(".0");
    }
}

fn formatFloatScientific(writer: anytype, f: f64, include_decimal: bool) !void {
    // Format float in scientific notation with uppercase E
    // and explicit sign on exponent
    var buf: [64]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{e}", .{f}) catch {
        // Fallback
        try writer.print("{d}", .{f});
        return;
    };

    // Find 'e' position and check if there's a decimal point in output
    var has_dot = false;
    for (slice) |c| {
        if (c == '.') has_dot = true;
    }

    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        if (slice[i] == 'e') {
            // Add .0 before E if needed and original had decimal
            if (!has_dot and include_decimal) {
                try writer.writeAll(".0");
            }
            try writer.writeByte('E');
            i += 1;
            if (i < slice.len) {
                if (slice[i] == '-') {
                    try writer.writeByte('-');
                } else if (slice[i] == '+') {
                    try writer.writeByte('+');
                } else {
                    // No explicit sign, add +
                    try writer.writeByte('+');
                    try writer.writeByte(slice[i]);
                    continue;
                }
            }
        } else {
            try writer.writeByte(slice[i]);
        }
    }
}

fn writeEscapedString(writer: anytype, s: []const u8) !void {
    // Check if we need quoting
    const needs_quotes = s.len == 0 or needsQuoting(s);

    if (!needs_quotes) {
        try writer.writeAll(s);
        return;
    }

    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20 or c == 0x7F) {
                    try writer.print("\\u{{{x}}}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn needsQuoting(s: []const u8) bool {
    if (s.len == 0) return true;

    // Check if it looks like a keyword
    if (std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null") or
        std.mem.eql(u8, s, "inf") or
        std.mem.eql(u8, s, "-inf") or
        std.mem.eql(u8, s, "nan"))
    {
        return true;
    }

    // Check first character
    const first = s[0];
    if (isDigit(first)) return true;
    if (isNonIdentifierChar(first)) return true;

    // Check if it looks like a number
    if ((first == '+' or first == '-') and s.len > 1 and (isDigit(s[1]) or (s[1] == '.' and s.len > 2 and isDigit(s[2])))) {
        return true;
    }
    if (first == '.' and s.len > 1 and isDigit(s[1])) {
        return true;
    }

    // Check all characters
    for (s) |c| {
        if (isNonIdentifierChar(c)) return true;
    }

    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isNonIdentifierChar(c: u8) bool {
    if (c <= 0x20) return true;
    return switch (c) {
        '(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=' => true,
        0x7F => true,
        else => false,
    };
}

pub const TypedValue = struct {
    type_annotation: ?[]const u8 = null,
    value: Value,

    pub fn format(self: TypedValue, writer: anytype) !void {
        if (self.type_annotation) |t| {
            try writer.writeByte('(');
            try writeEscapedString(writer, t);
            try writer.writeByte(')');
        }
        try writer.print("{f}", .{self.value});
    }
};

pub const Property = struct {
    name: []const u8,
    value: TypedValue,
};

pub const Node = struct {
    type_annotation: ?[]const u8 = null,
    name: []const u8,
    arguments: []TypedValue,
    properties: []Property,
    children: []Node,

    pub fn getArg(self: Node, index: usize) ?TypedValue {
        return if (index < self.arguments.len) self.arguments[index] else null;
    }

    pub fn getProp(self: Node, name: []const u8) ?TypedValue {
        // Return rightmost property per spec
        var result: ?TypedValue = null;
        for (self.properties) |prop| {
            if (std.mem.eql(u8, prop.name, name)) result = prop.value;
        }
        return result;
    }

    pub fn getChild(self: Node, name: []const u8) ?*const Node {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.name, name)) return child;
        }
        return null;
    }

    pub fn getChildren(self: Node, name: []const u8, buf: []Node) []Node {
        var count: usize = 0;
        for (self.children) |child| {
            if (std.mem.eql(u8, child.name, name)) {
                if (count < buf.len) {
                    buf[count] = child;
                    count += 1;
                }
            }
        }
        return buf[0..count];
    }

    pub fn format(self: Node, writer: anytype) !void {
        try self.formatIndent(writer, 0);
    }

    fn formatIndent(self: Node, writer: anytype, indent: usize) !void {
        for (0..indent) |_| try writer.writeAll("    ");

        if (self.type_annotation) |t| {
            try writer.writeByte('(');
            try writeEscapedString(writer, t);
            try writer.writeByte(')');
        }
        try writeEscapedString(writer, self.name);

        for (self.arguments) |arg| {
            try writer.print(" {f}", .{arg});
        }

        // Output unique properties (keeping rightmost value for duplicates)
        if (self.properties.len > 0) {
            // For each property, check if it's the last occurrence of its name
            for (self.properties, 0..) |prop, i| {
                // Check if there's a later property with the same name
                var is_last = true;
                for (self.properties[i + 1 ..]) |later| {
                    if (std.mem.eql(u8, later.name, prop.name)) {
                        is_last = false;
                        break;
                    }
                }
                if (is_last) {
                    try writer.writeByte(' ');
                    try writeEscapedString(writer, prop.name);
                    try writer.writeByte('=');
                    try writer.print("{f}", .{prop.value});
                }
            }
        }

        if (self.children.len > 0) {
            try writer.writeAll(" {\n");
            for (self.children) |child| {
                try child.formatIndent(writer, indent + 1);
            }
            for (0..indent) |_| try writer.writeAll("    ");
            try writer.writeAll("}\n");
        } else {
            try writer.writeAll("\n");
        }
    }
};

pub const Document = struct {
    nodes: []Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    pub fn getNode(self: Document, name: []const u8) ?*const Node {
        for (self.nodes) |*node| {
            if (std.mem.eql(u8, node.name, name)) return node;
        }
        return null;
    }

    pub fn format(self: Document, writer: anytype) !void {
        for (self.nodes) |node| {
            try writer.print("{f}", .{node});
        }
    }
};

pub const ParseError = error{
    UnexpectedToken,
    InvalidNumber,
    InvalidEscape,
    UnterminatedString,
    UnterminatedMultilineString,
    UnterminatedRawString,
    UnterminatedBlockComment,
    UnexpectedEof,
    InvalidCharacter,
    InvalidIdentifier,
    OutOfMemory,
    MultilineStringIndentError,
};

/// Convenience function to parse a KDL document
pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Document {
    return Parser.parse(allocator, source);
}

// Include tests
test {
    _ = @import("tests.zig");
}
