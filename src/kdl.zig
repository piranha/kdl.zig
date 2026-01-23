const std = @import("std");
const testing = std.testing;

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
                if (std.math.isNan(fv.value)) {
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

const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
    had_whitespace_before: bool = true, // whether there was whitespace/newline before this token

    const Tag = enum {
        // Literals
        identifier,
        string,
        raw_string,
        multiline_string,
        multiline_raw_string,
        integer,
        float,

        // Keywords (with # prefix in v2)
        true_kw,
        false_kw,
        null_kw,
        inf_kw,
        neg_inf_kw,
        nan_kw,

        // Punctuation
        open_brace,
        close_brace,
        open_paren,
        close_paren,
        equals,
        semicolon,
        newline,

        // Comments/whitespace
        slashdash,
        line_continuation,

        eof,
        invalid,
    };
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

fn isNewline(c: u8) bool {
    // Note: U+0085 (NEL) is handled separately as a 2-byte UTF-8 sequence (C2 85)
    return c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

fn isNonIdentifierChar(c: u8) bool {
    if (c <= 0x20) return true;
    return switch (c) {
        '(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=' => true,
        0x7F => true,
        else => false,
    };
}

const Tokenizer = struct {
    source: []const u8,
    index: usize = 0,
    seen_bom: bool = false,
    had_whitespace: bool = true, // Track if whitespace was seen before current token

    fn makeToken(self: *Tokenizer, tag: Token.Tag, start: usize, end: usize) Token {
        return Token{ .tag = tag, .start = start, .end = end, .had_whitespace_before = self.had_whitespace };
    }

    fn next(self: *Tokenizer) ParseError!Token {
        self.had_whitespace = self.index == 0; // Start of document counts as having whitespace

        // Skip whitespace and comments
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == ' ' or c == '\t') {
                self.index += 1;
                self.had_whitespace = true;
            } else if (c == '/') {
                if (self.index + 1 < self.source.len) {
                    const c2 = self.source[self.index + 1];
                    if (c2 == '/') {
                        // Single-line comment
                        self.index += 2;
                        while (self.index < self.source.len and !isNewline(self.source[self.index])) {
                            self.index += 1;
                        }
                    } else if (c2 == '*') {
                        // Multi-line comment
                        try self.skipBlockComment();
                        self.had_whitespace = true;
                    } else if (c2 == '-') {
                        const sd_start = self.index;
                        self.index += 2;
                        return self.makeToken(.slashdash, sd_start, self.index);
                    } else {
                        break;
                    }
                } else {
                    break;
                }
            } else if (self.isUnicodeSpace()) |len| {
                // BOM is only allowed at the very beginning
                if (len == 3 and self.index + 2 < self.source.len and
                    self.source[self.index] == 0xEF and
                    self.source[self.index + 1] == 0xBB and
                    self.source[self.index + 2] == 0xBF)
                {
                    if (self.index > 0 or self.seen_bom) {
                        return error.InvalidCharacter;
                    }
                    self.seen_bom = true;
                }
                self.index += len;
                self.had_whitespace = true;
            } else if (try self.isDisallowedChar()) {
                return error.InvalidCharacter;
            } else {
                break;
            }
        }

        if (self.index >= self.source.len) {
            return self.makeToken(.eof, self.index, self.index);
        }

        const start = self.index;
        const c = self.source[self.index];

        // Newlines (count as whitespace for the next token)
        if (isNewline(c)) {
            if (c == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                self.index += 2;
            } else {
                self.index += 1;
            }
            return self.makeToken(.newline, start, self.index);
        }

        // Multi-byte unicode newlines (LS, PS)
        if (self.isUnicodeNewline()) |len| {
            self.index += len;
            return self.makeToken(.newline, start, self.index);
        }

        // Punctuation
        switch (c) {
            '{' => {
                self.index += 1;
                return self.makeToken(.open_brace, start, self.index);
            },
            '}' => {
                self.index += 1;
                return self.makeToken(.close_brace, start, self.index);
            },
            '(' => {
                self.index += 1;
                return self.makeToken(.open_paren, start, self.index);
            },
            ')' => {
                self.index += 1;
                return self.makeToken(.close_paren, start, self.index);
            },
            '=' => {
                self.index += 1;
                return self.makeToken(.equals, start, self.index);
            },
            ';' => {
                self.index += 1;
                return self.makeToken(.semicolon, start, self.index);
            },
            '\\' => {
                return self.readLineContinuation(start);
            },
            '"' => {
                // Check for multiline string """
                if (self.index + 2 < self.source.len and
                    self.source[self.index + 1] == '"' and
                    self.source[self.index + 2] == '"')
                {
                    return self.readMultilineString();
                }
                return self.readQuotedString();
            },
            '#' => {
                return self.readHashPrefixed();
            },
            else => {},
        }

        // Numbers
        if (c == '-' or c == '+' or isDigit(c)) {
            return self.readNumberOrIdentifier();
        }

        // Identifier
        if (!isNonIdentifierChar(c)) {
            return self.readIdentifier();
        }

        self.index += 1;
        return self.makeToken(.invalid, start, self.index);
    }

    fn readLineContinuation(self: *Tokenizer, start: usize) ParseError!Token {
        self.index += 1; // Skip backslash

        // Skip whitespace after backslash (including multiline comments)
        while (self.index < self.source.len) {
            const cc = self.source[self.index];
            if (cc == ' ' or cc == '\t') {
                self.index += 1;
            } else if (cc == '/' and self.index + 1 < self.source.len) {
                if (self.source[self.index + 1] == '/') {
                    // Single-line comment after backslash
                    self.index += 2;
                    while (self.index < self.source.len and !isNewline(self.source[self.index])) {
                        self.index += 1;
                    }
                    break; // Don't consume the newline here, let the check below do it
                } else if (self.source[self.index + 1] == '*') {
                    try self.skipBlockComment();
                } else {
                    break;
                }
            } else if (self.isUnicodeSpace()) |len| {
                self.index += len;
            } else {
                break;
            }
        }

        // Must be followed by newline or EOF
        if (self.index >= self.source.len) {
            // EOF after backslash is OK (acts like a line continuation to nothing)
            return self.makeToken(.line_continuation, start, self.index);
        }
        if (isNewline(self.source[self.index])) {
            if (self.source[self.index] == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
                self.index += 2;
            } else {
                self.index += 1;
            }
            return self.makeToken(.line_continuation, start, self.index);
        } else if (self.isUnicodeNewline()) |len| {
            self.index += len;
            return self.makeToken(.line_continuation, start, self.index);
        }
        return self.makeToken(.invalid, start, self.index);
    }

    fn readHashPrefixed(self: *Tokenizer) ParseError!Token {
        const start = self.index;

        // Check for raw string #"..." or ##"..."##
        var hash_count: usize = 0;
        var temp = self.index;
        while (temp < self.source.len and self.source[temp] == '#') {
            hash_count += 1;
            temp += 1;
        }

        if (temp < self.source.len and self.source[temp] == '"') {
            // It's a raw string
            self.index = temp + 1; // Move past hashes and opening quote

            // Check for multiline raw string
            if (hash_count >= 1 and self.index + 1 < self.source.len and
                self.source[self.index] == '"' and self.source[self.index + 1] == '"')
            {
                self.index += 2; // Skip the other two quotes
                return self.readMultilineRawStringBody(start, hash_count);
            }

            return self.readRawStringBody(start, hash_count);
        }

        // Otherwise it's a keyword
        self.index += 1; // Skip #

        // Check for keywords
        if (self.matchKeyword("true")) {
            return self.makeToken(.true_kw, start, self.index);
        } else if (self.matchKeyword("false")) {
            return self.makeToken(.false_kw, start, self.index);
        } else if (self.matchKeyword("null")) {
            return self.makeToken(.null_kw, start, self.index);
        } else if (self.matchKeyword("-inf")) {
            return self.makeToken(.neg_inf_kw, start, self.index);
        } else if (self.matchKeyword("inf")) {
            return self.makeToken(.inf_kw, start, self.index);
        } else if (self.matchKeyword("nan")) {
            return self.makeToken(.nan_kw, start, self.index);
        }

        return self.makeToken(.invalid, start, self.index);
    }

    fn matchKeyword(self: *Tokenizer, keyword: []const u8) bool {
        if (self.index + keyword.len > self.source.len) return false;
        if (!std.mem.eql(u8, self.source[self.index .. self.index + keyword.len], keyword)) return false;

        // Make sure keyword ends here
        if (self.index + keyword.len < self.source.len) {
            const next_char = self.source[self.index + keyword.len];
            if (!isNonIdentifierChar(next_char) and !isNewline(next_char)) return false;
        }

        self.index += keyword.len;
        return true;
    }

    fn skipBlockComment(self: *Tokenizer) ParseError!void {
        self.index += 2; // Skip /*
        var depth: usize = 1;
        while (depth > 0 and self.index < self.source.len) {
            if (self.index + 1 < self.source.len) {
                if (self.source[self.index] == '/' and self.source[self.index + 1] == '*') {
                    depth += 1;
                    self.index += 2;
                    continue;
                } else if (self.source[self.index] == '*' and self.source[self.index + 1] == '/') {
                    depth -= 1;
                    self.index += 2;
                    continue;
                }
            }
            self.index += 1;
        }
        if (depth > 0) return error.UnterminatedBlockComment;
    }

    fn readQuotedString(self: *Tokenizer) ParseError!Token {
        const start = self.index;
        self.index += 1; // Skip opening quote
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '"') {
                self.index += 1;
                return self.makeToken(.string, start, self.index);
            } else if (c == '\\') {
                if (self.index + 1 >= self.source.len) return error.UnterminatedString;
                const escaped = self.source[self.index + 1];
                // Skip escaped char
                self.index += 2;
                // Handle \u{...}
                if (escaped == 'u' and self.index < self.source.len and self.source[self.index] == '{') {
                    while (self.index < self.source.len and self.source[self.index] != '}') {
                        self.index += 1;
                    }
                    if (self.index < self.source.len) self.index += 1; // Skip }
                }
                // Handle whitespace escape - skip all whitespace including newlines
                if (escaped == ' ' or escaped == '\t' or isNewline(escaped)) {
                    while (self.index < self.source.len) {
                        const cc = self.source[self.index];
                        if (cc == ' ' or cc == '\t' or isNewline(cc)) {
                            self.index += 1;
                        } else {
                            break;
                        }
                    }
                }
            } else if (isNewline(c)) {
                return error.UnterminatedString;
            } else {
                self.index += 1;
            }
        }
        return error.UnterminatedString;
    }

    fn readMultilineString(self: *Tokenizer) ParseError!Token {
        const start = self.index;
        self.index += 3; // Skip """

        // Must be immediately followed by newline
        if (self.index >= self.source.len) return error.UnterminatedMultilineString;
        if (!isNewline(self.source[self.index]) and self.isUnicodeNewline() == null) {
            return error.UnterminatedMultilineString;
        }

        // Skip the newline
        if (self.source[self.index] == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
            self.index += 2;
        } else if (self.isUnicodeNewline()) |len| {
            self.index += len;
        } else {
            self.index += 1;
        }

        // Find closing """
        while (self.index + 2 < self.source.len) {
            if (self.source[self.index] == '"' and
                self.source[self.index + 1] == '"' and
                self.source[self.index + 2] == '"')
            {
                self.index += 3;
                return self.makeToken(.multiline_string, start, self.index);
            }
            if (self.source[self.index] == '\\') {
                self.index += 1;
                if (self.index < self.source.len) self.index += 1;
            } else {
                self.index += 1;
            }
        }
        return error.UnterminatedMultilineString;
    }

    fn readRawStringBody(self: *Tokenizer, start: usize, hash_count: usize) ParseError!Token {
        // Find closing quote with matching hashes
        while (self.index < self.source.len) {
            if (self.source[self.index] == '"') {
                var closing_hashes: usize = 0;
                var temp = self.index + 1;
                while (temp < self.source.len and self.source[temp] == '#' and closing_hashes < hash_count) {
                    closing_hashes += 1;
                    temp += 1;
                }
                if (closing_hashes == hash_count) {
                    self.index = temp;
                    return self.makeToken(.raw_string, start, self.index);
                }
            }
            if (isNewline(self.source[self.index])) {
                return error.UnterminatedRawString;
            }
            self.index += 1;
        }
        return error.UnterminatedRawString;
    }

    fn readMultilineRawStringBody(self: *Tokenizer, start: usize, hash_count: usize) ParseError!Token {
        // Must be immediately followed by newline
        if (self.index >= self.source.len) return error.UnterminatedRawString;
        if (!isNewline(self.source[self.index]) and self.isUnicodeNewline() == null) {
            return error.UnterminatedRawString;
        }

        // Skip the newline
        if (self.source[self.index] == '\r' and self.index + 1 < self.source.len and self.source[self.index + 1] == '\n') {
            self.index += 2;
        } else if (self.isUnicodeNewline()) |len| {
            self.index += len;
        } else {
            self.index += 1;
        }

        // Find closing """### with matching hash count
        while (self.index < self.source.len) {
            if (self.index + 2 < self.source.len and
                self.source[self.index] == '"' and
                self.source[self.index + 1] == '"' and
                self.source[self.index + 2] == '"')
            {
                var temp = self.index + 3;
                var closing_hashes: usize = 0;
                while (temp < self.source.len and self.source[temp] == '#' and closing_hashes < hash_count) {
                    closing_hashes += 1;
                    temp += 1;
                }
                if (closing_hashes == hash_count) {
                    self.index = temp;
                    return self.makeToken(.multiline_raw_string, start, self.index);
                }
            }
            self.index += 1;
        }
        return error.UnterminatedRawString;
    }

    fn readNumberOrIdentifier(self: *Tokenizer) ParseError!Token {
        const start = self.index;

        // Sign
        var has_sign = false;
        if (self.source[self.index] == '-' or self.source[self.index] == '+') {
            has_sign = true;
            self.index += 1;
        }

        if (self.index >= self.source.len) {
            // Just a sign - treat as identifier
            return self.makeToken(.identifier, start, self.index);
        }

        // After sign, check what follows
        const after_sign = self.source[self.index];

        // Check for hex/octal/binary
        if (after_sign == '0' and self.index + 1 < self.source.len) {
            const radix_char = self.source[self.index + 1];
            if (radix_char == 'x' or radix_char == 'X') {
                self.index += 2;
                // Must start with hex digit (not underscore)
                if (self.index >= self.source.len or !isHexDigit(self.source[self.index])) {
                    // Invalid, rewind and treat as identifier
                    self.index = start;
                    return self.readIdentifier();
                }
                while (self.index < self.source.len and (isHexDigit(self.source[self.index]) or self.source[self.index] == '_')) {
                    self.index += 1;
                }
                return self.makeToken(.integer, start, self.index);
            } else if (radix_char == 'o' or radix_char == 'O') {
                self.index += 2;
                // Must start with octal digit (not underscore)
                if (self.index >= self.source.len or !isOctalDigit(self.source[self.index])) {
                    self.index = start;
                    return self.readIdentifier();
                }
                while (self.index < self.source.len and (isOctalDigit(self.source[self.index]) or self.source[self.index] == '_')) {
                    self.index += 1;
                }
                return self.makeToken(.integer, start, self.index);
            } else if (radix_char == 'b' or radix_char == 'B') {
                self.index += 2;
                // Must start with binary digit (not underscore)
                if (self.index >= self.source.len or (self.source[self.index] != '0' and self.source[self.index] != '1')) {
                    self.index = start;
                    return self.readIdentifier();
                }
                while (self.index < self.source.len and (self.source[self.index] == '0' or self.source[self.index] == '1' or self.source[self.index] == '_')) {
                    self.index += 1;
                }
                return self.makeToken(.integer, start, self.index);
            }
        }

        // Regular decimal number or identifier
        if (!isDigit(after_sign)) {
            // Check for .N pattern which is not a valid number
            if (after_sign == '.' and self.index + 1 < self.source.len and isDigit(self.source[self.index + 1])) {
                return self.makeToken(.invalid, start, self.index);
            }
            // It's an identifier
            self.index = start;
            return self.readIdentifier();
        }

        // Digits before dot
        while (self.index < self.source.len and (isDigit(self.source[self.index]) or self.source[self.index] == '_')) {
            self.index += 1;
        }

        var is_float = false;

        // Check for trailing dot (1. is invalid)
        if (self.index < self.source.len and self.source[self.index] == '.') {
            // Need a digit after the dot
            if (self.index + 1 >= self.source.len or !isDigit(self.source[self.index + 1])) {
                // 1. or 1.e is invalid
                return self.makeToken(.invalid, start, self.index + 1);
            }
            is_float = true;
            self.index += 1;
            // Fraction must start with digit, not underscore
            if (self.index < self.source.len and self.source[self.index] == '_') {
                return self.makeToken(.invalid, start, self.index + 1);
            }
            while (self.index < self.source.len and (isDigit(self.source[self.index]) or self.source[self.index] == '_')) {
                self.index += 1;
            }
        }

        // Exponent
        if (self.index < self.source.len and (self.source[self.index] == 'e' or self.source[self.index] == 'E')) {
            is_float = true;
            self.index += 1;
            if (self.index < self.source.len and (self.source[self.index] == '+' or self.source[self.index] == '-')) {
                self.index += 1;
            }
            // Must have at least one digit after exponent
            if (self.index >= self.source.len or (!isDigit(self.source[self.index]) and self.source[self.index] != '_')) {
                return self.makeToken(.invalid, start, self.index);
            }
            while (self.index < self.source.len and (isDigit(self.source[self.index]) or self.source[self.index] == '_')) {
                self.index += 1;
            }
        }

        return self.makeToken(if (is_float) .float else .integer, start, self.index);
    }

    fn readIdentifier(self: *Tokenizer) ParseError!Token {
        const start = self.index;

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (isNonIdentifierChar(c) or isNewline(c)) break;
            if (self.isUnicodeSpace() != null) break;
            if (self.isUnicodeNewline() != null) break;
            // Check for disallowed characters in identifier
            if ((try self.isDisallowedChar())) break;
            self.index += 1;
        }

        const text = self.source[start..self.index];

        // Check for disallowed bare identifiers (keywords)
        if (std.mem.eql(u8, text, "true") or
            std.mem.eql(u8, text, "false") or
            std.mem.eql(u8, text, "null") or
            std.mem.eql(u8, text, "inf") or
            std.mem.eql(u8, text, "-inf") or
            std.mem.eql(u8, text, "nan"))
        {
            return self.makeToken(.invalid, start, self.index);
        }

        // Check for legacy r"..." raw string syntax (not allowed in v2)
        if (text.len >= 1 and text[0] == 'r' and self.index < self.source.len and self.source[self.index] == '"') {
            return self.makeToken(.invalid, start, self.index);
        }

        // Check for .digit patterns (.0, .1, etc.) which are invalid
        if (text.len >= 2 and text[0] == '.' and isDigit(text[1])) {
            return self.makeToken(.invalid, start, self.index);
        }

        // Check for numeric-looking identifiers (disallowed)
        // Patterns: 0x..., digit + letter combo, etc.
        if (text.len >= 2) {
            const first = text[0];
            const second = text[1];

            // Digit followed by non-digit, non-underscore, non-dot, non-E = invalid
            // e.g., 0n, 123abc
            if (isDigit(first)) {
                // Check if it looks like an invalid number format
                // Numbers can have: digits, underscores, dots, e/E for exponent, x/o/b for radix
                var has_invalid = false;
                var i: usize = 0;
                var after_radix = false;
                var is_hex = false;

                if (first == '0' and (second == 'x' or second == 'X' or second == 'o' or second == 'O' or second == 'b' or second == 'B')) {
                    after_radix = true;
                    is_hex = (second == 'x' or second == 'X');
                    const is_octal = (second == 'o' or second == 'O');
                    const is_binary = (second == 'b' or second == 'B');
                    i = 2;

                    // Must have at least one digit after radix prefix
                    if (i >= text.len) {
                        has_invalid = true;
                    }

                    // After radix prefix, must start with valid digit (not underscore)
                    if (i < text.len and text[i] == '_') {
                        has_invalid = true;
                    }

                    // For non-decimal bases, only allow valid digits and underscores
                    while (i < text.len and !has_invalid) : (i += 1) {
                        const ch = text[i];
                        if (ch == '_') continue; // underscores allowed after first digit
                        if (is_hex and isHexDigit(ch)) continue;
                        if (is_octal and isOctalDigit(ch)) continue;
                        if (is_binary and (ch == '0' or ch == '1')) continue;
                        has_invalid = true;
                        break;
                    }
                } else {
                    while (i < text.len) : (i += 1) {
                        const ch = text[i];
                        if (isDigit(ch) or ch == '_') continue;
                        if (!after_radix and (ch == '.' or ch == 'e' or ch == 'E')) continue;
                        if (!after_radix and i > 0 and (ch == '+' or ch == '-')) {
                            // Could be exponent sign
                            const prev = text[i - 1];
                            if (prev == 'e' or prev == 'E') continue;
                        }
                        has_invalid = true;
                        break;
                    }
                }

                if (has_invalid) {
                    return self.makeToken(.invalid, start, self.index);
                }
            }
        }

        return self.makeToken(.identifier, start, self.index);
    }

    fn isUnicodeSpace(self: *Tokenizer) ?usize {
        if (self.index >= self.source.len) return null;

        // Check for BOM at start
        if (self.index + 2 < self.source.len and
            self.source[self.index] == 0xEF and
            self.source[self.index + 1] == 0xBB and
            self.source[self.index + 2] == 0xBF)
        {
            return 3;
        }

        // Check for multi-byte unicode whitespace
        if (self.index + 2 < self.source.len and self.source[self.index] == 0xE2) {
            if (self.source[self.index + 1] == 0x80) {
                const b2 = self.source[self.index + 2];
                // U+2000-U+200A
                if (b2 >= 0x80 and b2 <= 0x8A) return 3;
                // U+202F
                if (b2 == 0xAF) return 3;
            } else if (self.source[self.index + 1] == 0x81 and self.source[self.index + 2] == 0x9F) {
                // U+205F
                return 3;
            }
        }
        // U+3000 ideographic space
        if (self.index + 2 < self.source.len and
            self.source[self.index] == 0xE3 and
            self.source[self.index + 1] == 0x80 and
            self.source[self.index + 2] == 0x80)
        {
            return 3;
        }
        // U+00A0 no-break space
        if (self.index + 1 < self.source.len and
            self.source[self.index] == 0xC2 and
            self.source[self.index + 1] == 0xA0)
        {
            return 2;
        }
        // U+1680 ogham space mark
        if (self.index + 2 < self.source.len and
            self.source[self.index] == 0xE1 and
            self.source[self.index + 1] == 0x9A and
            self.source[self.index + 2] == 0x80)
        {
            return 3;
        }
        return null;
    }

    fn isUnicodeNewline(self: *Tokenizer) ?usize {
        if (self.index + 2 < self.source.len and self.source[self.index] == 0xE2 and self.source[self.index + 1] == 0x80) {
            // U+2028 (LS) or U+2029 (PS)
            if (self.source[self.index + 2] == 0xA8 or self.source[self.index + 2] == 0xA9) {
                return 3;
            }
        }
        // U+0085 (NEL) - this is actually single byte in the range we handle elsewhere
        if (self.index + 1 < self.source.len and self.source[self.index] == 0xC2 and self.source[self.index + 1] == 0x85) {
            return 2;
        }
        return null;
    }

    /// Check for disallowed unicode characters (direction control, etc.)
    fn isDisallowedChar(self: *Tokenizer) ParseError!bool {
        if (self.index >= self.source.len) return false;

        // Check for 3-byte unicode sequences
        if (self.index + 2 < self.source.len and self.source[self.index] == 0xE2) {
            const b1 = self.source[self.index + 1];
            const b2 = self.source[self.index + 2];

            // U+200E LRM, U+200F RLM (E2 80 8E, E2 80 8F)
            if (b1 == 0x80 and (b2 == 0x8E or b2 == 0x8F)) return true;

            // U+202A LRE, U+202B RLE, U+202C PDF, U+202D LRO, U+202E RLO
            // (E2 80 AA - E2 80 AE)
            if (b1 == 0x80 and b2 >= 0xAA and b2 <= 0xAE) return true;

            // U+2066 LRI, U+2067 RLI, U+2068 FSI, U+2069 PDI
            // (E2 81 A6 - E2 81 A9)
            if (b1 == 0x81 and b2 >= 0xA6 and b2 <= 0xA9) return true;
        }

        return false;
    }

    fn getText(self: *Tokenizer, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }
};

pub const Parser = struct {
    tokenizer: Tokenizer,
    arena: std.heap.ArenaAllocator,
    current: Token,
    peeked: ?Token = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Parser {
        return Parser{
            .tokenizer = Tokenizer{ .source = source },
            .arena = std.heap.ArenaAllocator.init(allocator),
            .current = Token{ .tag = .eof, .start = 0, .end = 0 },
        };
    }

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Document {
        var parser = Parser.init(allocator, source);
        errdefer parser.arena.deinit();

        const nodes = try parser.parseNodes(false);
        return Document{
            .nodes = nodes,
            .arena = parser.arena,
        };
    }

    fn advance(self: *Parser) ParseError!void {
        if (self.peeked) |p| {
            self.current = p;
            self.peeked = null;
        } else {
            self.current = try self.tokenizer.next();
        }
    }

    fn peek(self: *Parser) ParseError!Token {
        if (self.peeked) |p| return p;
        self.peeked = try self.tokenizer.next();
        return self.peeked.?;
    }

    fn skipNewlinesAndContinuations(self: *Parser) ParseError!void {
        while (true) {
            const tok = try self.peek();
            if (tok.tag == .newline or tok.tag == .line_continuation) {
                try self.advance();
            } else {
                break;
            }
        }
    }

    fn skipContinuations(self: *Parser) ParseError!void {
        while (true) {
            const tok = try self.peek();
            if (tok.tag == .line_continuation) {
                try self.advance();
            } else {
                break;
            }
        }
    }

    fn parseNodes(self: *Parser, in_block: bool) ParseError![]Node {
        const alloc = self.arena.allocator();
        var nodes: std.ArrayList(Node) = .empty;

        try self.skipNewlinesAndContinuations();

        while (true) {
            const tok = try self.peek();
            if (tok.tag == .eof) break;
            if (in_block and tok.tag == .close_brace) break;

            if (tok.tag == .slashdash) {
                // Skip commented-out node
                try self.advance();
                try self.skipNewlinesAndContinuations();
                _ = try self.parseNode();
                try self.skipNewlinesAndContinuations();
                continue;
            }

            const node = try self.parseNode();
            try nodes.append(alloc, node);
            try self.skipNewlinesAndContinuations();
        }

        return nodes.toOwnedSlice(alloc);
    }

    fn parseNode(self: *Parser) ParseError!Node {
        const alloc = self.arena.allocator();

        // Optional type annotation
        var type_annotation: ?[]const u8 = null;
        var tok = try self.peek();
        if (tok.tag == .open_paren) {
            type_annotation = try self.parseTypeAnnotation();
            try self.skipContinuations();
            tok = try self.peek();
        }

        // Node name
        try self.advance();
        if (!isStringToken(tok.tag)) {
            return error.UnexpectedToken;
        }
        const name = try self.processStringToken(tok);

        // Arguments and properties
        var arguments: std.ArrayList(TypedValue) = .empty;
        var properties: std.ArrayList(Property) = .empty;
        var first_entry = true;

        while (true) {
            tok = try self.peek();

            // Skip line continuations
            if (tok.tag == .line_continuation) {
                try self.advance();
                first_entry = false; // After line continuation, we've had whitespace
                continue;
            }

            // Check for node terminator
            if (tok.tag == .newline or tok.tag == .semicolon or tok.tag == .eof or tok.tag == .close_brace or tok.tag == .open_brace) {
                break;
            }

            // Slashdash for skipping args/props/children
            // Slashdash doesn't require whitespace before it
            if (tok.tag == .slashdash) {
                // Peek ahead to see if it's a children block
                const save_idx = self.tokenizer.index;
                const save_ws = self.tokenizer.had_whitespace;
                try self.advance();
                try self.skipNewlinesAndContinuations();
                const next = try self.peek();
                if (next.tag == .open_brace) {
                    // Slashdashed children block - restore position and break to children handling
                    self.tokenizer.index = save_idx;
                    self.tokenizer.had_whitespace = save_ws;
                    self.peeked = tok;
                    break;
                } else {
                    // Skip the next arg or prop
                    _ = try self.parseArgOrProp();
                }
                first_entry = false;
                continue;
            }

            // Check for zero-width space issue: arguments must have whitespace before them
            if (!tok.had_whitespace_before) {
                return error.UnexpectedToken;
            }

            const arg_or_prop = try self.parseArgOrProp();
            if (arg_or_prop.prop) |prop| {
                try properties.append(alloc, prop);
            } else {
                try arguments.append(alloc, arg_or_prop.arg);
            }
            first_entry = false;
        }

        // Children (can have slashdashed children blocks before/after actual children)
        // Only one actual children block allowed
        var children: []Node = &.{};
        var has_actual_children = false;

        while (true) {
            tok = try self.peek();

            // Handle line continuation
            if (tok.tag == .line_continuation) {
                try self.advance();
                continue;
            }

            // Slashdashed children block
            if (tok.tag == .slashdash) {
                try self.advance();
                try self.skipNewlinesAndContinuations();
                const next = try self.peek();
                if (next.tag == .open_brace) {
                    try self.advance();
                    try self.skipNewlinesAndContinuations();
                    _ = try self.parseNodes(true);
                    const close = try self.peek();
                    if (close.tag != .close_brace) return error.UnexpectedToken;
                    try self.advance();
                    continue;
                } else {
                    // Slashdash not followed by brace at this point is an error
                    // (we're in children-only mode now)
                    return error.UnexpectedToken;
                }
            }

            // Actual children block
            if (tok.tag == .open_brace) {
                if (has_actual_children) {
                    // Can't have two actual children blocks
                    return error.UnexpectedToken;
                }
                try self.advance();
                try self.skipNewlinesAndContinuations();
                children = try self.parseNodes(true);
                tok = try self.peek();
                if (tok.tag != .close_brace) {
                    return error.UnexpectedToken;
                }
                try self.advance();
                has_actual_children = true;
                // Continue to allow trailing slashdashed children blocks
                continue;
            }

            // No more children blocks - check it's a valid terminator
            // (not an argument/property which would be invalid after children started)
            if (tok.tag != .newline and tok.tag != .semicolon and tok.tag != .eof and tok.tag != .close_brace) {
                // Something that's not a valid node terminator - likely an argument after children
                return error.UnexpectedToken;
            }
            break;
        }

        // Skip terminator
        tok = try self.peek();
        if (tok.tag == .semicolon or tok.tag == .newline) {
            try self.advance();
        } else if (tok.tag != .eof and tok.tag != .close_brace) {
            // If there's more content, it must have whitespace before it
            // (except for EOF and close brace which are valid terminators)
            if (!tok.had_whitespace_before) {
                return error.UnexpectedToken;
            }
        }

        return Node{
            .type_annotation = type_annotation,
            .name = name,
            .arguments = try arguments.toOwnedSlice(alloc),
            .properties = try properties.toOwnedSlice(alloc),
            .children = children,
        };
    }

    const ArgOrProp = struct {
        arg: TypedValue,
        prop: ?Property,
    };

    fn parseArgOrProp(self: *Parser) ParseError!ArgOrProp {
        // Check for type annotation
        var type_annotation: ?[]const u8 = null;
        var tok = try self.peek();
        if (tok.tag == .open_paren) {
            type_annotation = try self.parseTypeAnnotation();
            try self.skipContinuations();
            tok = try self.peek();
        }

        try self.advance();

        // Check if it's a property (string followed by =)
        if (isStringToken(tok.tag)) {
            const next = try self.peek();
            if (next.tag == .equals) {
                // It's a property - type annotation on key is not allowed
                if (type_annotation != null) {
                    return error.UnexpectedToken;
                }
                try self.advance(); // consume =
                try self.skipContinuations();
                const value = try self.parseValue();
                const name = try self.processStringToken(tok);
                return ArgOrProp{
                    .arg = undefined,
                    .prop = Property{
                        .name = name,
                        .value = value,
                    },
                };
            }
        }

        // It's an argument
        const value = try self.tokenToValue(tok, type_annotation);
        return ArgOrProp{
            .arg = value,
            .prop = null,
        };
    }

    fn parseValue(self: *Parser) ParseError!TypedValue {
        var type_annotation: ?[]const u8 = null;
        var tok = try self.peek();

        if (tok.tag == .open_paren) {
            type_annotation = try self.parseTypeAnnotation();
            try self.skipContinuations();
            tok = try self.peek();
        }

        try self.advance();
        return self.tokenToValue(tok, type_annotation);
    }

    fn parseTypeAnnotation(self: *Parser) ParseError![]const u8 {
        try self.advance(); // consume (
        try self.skipContinuations();
        const tok = try self.peek();
        if (!isStringToken(tok.tag)) {
            return error.UnexpectedToken;
        }
        try self.advance();
        const name = try self.processStringToken(tok);
        try self.skipContinuations();
        const close = try self.peek();
        if (close.tag != .close_paren) {
            return error.UnexpectedToken;
        }
        try self.advance();
        return name;
    }

    fn isStringToken(tag: Token.Tag) bool {
        return switch (tag) {
            .identifier, .string, .raw_string, .multiline_string, .multiline_raw_string => true,
            else => false,
        };
    }

    fn tokenToValue(self: *Parser, tok: Token, type_annotation: ?[]const u8) ParseError!TypedValue {
        const value: Value = switch (tok.tag) {
            .string => .{ .string = try self.processQuotedString(tok) },
            .raw_string => .{ .string = try self.processRawString(tok) },
            .multiline_string => .{ .string = try self.processMultilineString(tok) },
            .multiline_raw_string => .{ .string = try self.processMultilineRawString(tok) },
            .identifier => .{ .string = try self.arena.allocator().dupe(u8, self.tokenizer.source[tok.start..tok.end]) },
            .integer => .{ .integer = try self.parseInteger(tok) },
            .float => .{ .float = try self.parseFloat(tok) },
            .true_kw => .{ .boolean = true },
            .false_kw => .{ .boolean = false },
            .null_kw => .null,
            .inf_kw => .{ .float = .{ .value = std.math.inf(f64) } },
            .neg_inf_kw => .{ .float = .{ .value = -std.math.inf(f64) } },
            .nan_kw => .{ .float = .{ .value = std.math.nan(f64) } },
            else => return error.UnexpectedToken,
        };
        return TypedValue{ .type_annotation = type_annotation, .value = value };
    }

    fn processStringToken(self: *Parser, tok: Token) ParseError![]const u8 {
        return switch (tok.tag) {
            .string => self.processQuotedString(tok),
            .raw_string => self.processRawString(tok),
            .multiline_string => self.processMultilineString(tok),
            .multiline_raw_string => self.processMultilineRawString(tok),
            .identifier => self.arena.allocator().dupe(u8, self.tokenizer.source[tok.start..tok.end]),
            else => error.UnexpectedToken,
        };
    }

    fn processQuotedString(self: *Parser, tok: Token) ParseError![]const u8 {
        const text = self.tokenizer.source[tok.start..tok.end];
        // Remove quotes
        const inner = text[1 .. text.len - 1];
        return self.processEscapes(inner);
    }

    fn processEscapes(self: *Parser, inner: []const u8) ParseError![]const u8 {
        // Check if we need to process escapes
        if (std.mem.indexOf(u8, inner, "\\") == null) {
            return self.arena.allocator().dupe(u8, inner);
        }

        const alloc = self.arena.allocator();
        var result: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < inner.len) {
            if (inner[i] == '\\' and i + 1 < inner.len) {
                const escaped = inner[i + 1];
                switch (escaped) {
                    'n' => try result.append(alloc, '\n'),
                    'r' => try result.append(alloc, '\r'),
                    't' => try result.append(alloc, '\t'),
                    '\\' => try result.append(alloc, '\\'),
                    '"' => try result.append(alloc, '"'),
                    'b' => try result.append(alloc, 0x08),
                    'f' => try result.append(alloc, 0x0C),
                    's' => try result.append(alloc, ' '),
                    'u' => {
                        // Unicode escape \u{XXXX}
                        if (i + 2 < inner.len and inner[i + 2] == '{') {
                            var end = i + 3;
                            while (end < inner.len and inner[end] != '}') {
                                end += 1;
                            }
                            if (end >= inner.len) return error.InvalidEscape;
                            const hex = inner[i + 3 .. end];
                            // Unicode scalar value must be 1-6 hex digits
                            if (hex.len == 0 or hex.len > 6) return error.InvalidEscape;
                            const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscape;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidEscape;
                            try result.appendSlice(alloc, buf[0..len]);
                            i = end + 1;
                            continue;
                        } else {
                            return error.InvalidEscape;
                        }
                    },
                    ' ', '\t', '\n', '\r' => {
                        // Whitespace escape - skip backslash and all following whitespace
                        i += 1;
                        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t' or inner[i] == '\n' or inner[i] == '\r')) {
                            i += 1;
                        }
                        continue;
                    },
                    else => return error.InvalidEscape,
                }
                i += 2;
            } else {
                try result.append(alloc, inner[i]);
                i += 1;
            }
        }
        return result.toOwnedSlice(alloc);
    }

    fn processRawString(self: *Parser, tok: Token) ParseError![]const u8 {
        const text = self.tokenizer.source[tok.start..tok.end];
        // #"..."# format - find the actual string content
        var start: usize = 0;
        while (start < text.len and text[start] == '#') {
            start += 1;
        }
        start += 1; // Skip opening quote

        var end = text.len;
        while (end > start and text[end - 1] == '#') {
            end -= 1;
        }
        end -= 1; // Skip closing quote

        return self.arena.allocator().dupe(u8, text[start..end]);
    }

    fn processMultilineString(self: *Parser, tok: Token) ParseError![]const u8 {
        const text = self.tokenizer.source[tok.start..tok.end];
        // """...""" format
        // Skip opening """ and first newline
        var start: usize = 3;
        while (start < text.len and (text[start] == '\r' or text[start] == '\n')) {
            if (text[start] == '\r' and start + 1 < text.len and text[start + 1] == '\n') {
                start += 2;
            } else {
                start += 1;
            }
            break;
        }

        // Find closing """
        const end = text.len - 3;

        // Get the content
        const content = text[start..end];

        // Find the last line to get the indentation prefix
        var last_newline: usize = content.len;
        var i = content.len;
        while (i > 0) {
            i -= 1;
            if (content[i] == '\n') {
                last_newline = i + 1;
                break;
            }
        }
        if (i == 0 and content.len > 0 and content[0] != '\n') {
            last_newline = 0;
        }

        const prefix = content[last_newline..];

        // Process the content, removing prefix and handling escapes
        const alloc = self.arena.allocator();
        var result: std.ArrayList(u8) = .empty;

        // Get the body content (excluding the final newline before the prefix line)
        var body_end = last_newline;
        if (body_end > 0 and content[body_end - 1] == '\n') {
            body_end -= 1;
            if (body_end > 0 and content[body_end - 1] == '\r') {
                body_end -= 1;
            }
        }

        var lines = std.mem.splitAny(u8, content[0..body_end], "\n");
        var first = true;

        while (lines.next()) |line| {
            if (!first) {
                try result.append(alloc, '\n');
            }
            first = false;

            // Handle CR
            var actual_line = line;
            if (actual_line.len > 0 and actual_line[actual_line.len - 1] == '\r') {
                actual_line = actual_line[0 .. actual_line.len - 1];
            }

            // Check if line is whitespace-only
            var is_whitespace_only = true;
            for (actual_line) |c| {
                if (c != ' ' and c != '\t') {
                    is_whitespace_only = false;
                    break;
                }
            }

            if (is_whitespace_only) {
                // Empty line in output
                continue;
            }

            // Remove prefix
            if (actual_line.len >= prefix.len and std.mem.startsWith(u8, actual_line, prefix)) {
                actual_line = actual_line[prefix.len..];
            } else if (prefix.len > 0) {
                return error.MultilineStringIndentError;
            }

            // Process escapes in this line
            const processed = try self.processEscapes(actual_line);
            try result.appendSlice(alloc, processed);
        }

        return result.toOwnedSlice(alloc);
    }

    fn processMultilineRawString(self: *Parser, tok: Token) ParseError![]const u8 {
        const text = self.tokenizer.source[tok.start..tok.end];

        // #"""..."""# format
        var hash_count: usize = 0;
        while (hash_count < text.len and text[hash_count] == '#') {
            hash_count += 1;
        }

        // Skip #""" and first newline
        var start: usize = hash_count + 3;
        while (start < text.len and (text[start] == '\r' or text[start] == '\n')) {
            if (text[start] == '\r' and start + 1 < text.len and text[start + 1] == '\n') {
                start += 2;
            } else {
                start += 1;
            }
            break;
        }

        // Find closing """#
        const end = text.len - hash_count - 3;

        const content = text[start..end];

        // Find the last line to get the indentation prefix
        var last_newline: usize = content.len;
        var i = content.len;
        while (i > 0) {
            i -= 1;
            if (content[i] == '\n') {
                last_newline = i + 1;
                break;
            }
        }
        if (i == 0 and content.len > 0 and content[0] != '\n') {
            last_newline = 0;
        }

        const prefix = content[last_newline..];

        // Process the content, removing prefix (no escapes in raw strings)
        // Don't include the newline before the closing line
        var body_end = last_newline;
        if (body_end > 0 and content[body_end - 1] == '\n') {
            body_end -= 1;
            if (body_end > 0 and content[body_end - 1] == '\r') {
                body_end -= 1;
            }
        }

        const alloc = self.arena.allocator();
        var result: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitAny(u8, content[0..body_end], "\n");
        var first_line = true;

        while (lines.next()) |line| {
            if (!first_line) {
                try result.append(alloc, '\n');
            }
            first_line = false;

            var actual_line = line;
            if (actual_line.len > 0 and actual_line[actual_line.len - 1] == '\r') {
                actual_line = actual_line[0 .. actual_line.len - 1];
            }

            // Check if line is whitespace-only
            var is_whitespace_only = true;
            for (actual_line) |c| {
                if (c != ' ' and c != '\t') {
                    is_whitespace_only = false;
                    break;
                }
            }

            if (is_whitespace_only) {
                continue;
            }

            // Remove prefix
            if (actual_line.len >= prefix.len and std.mem.startsWith(u8, actual_line, prefix)) {
                actual_line = actual_line[prefix.len..];
            } else if (prefix.len > 0) {
                return error.MultilineStringIndentError;
            }

            try result.appendSlice(alloc, actual_line);
        }

        return result.toOwnedSlice(alloc);
    }

    fn parseInteger(self: *Parser, tok: Token) ParseError!i128 {
        const text = self.tokenizer.source[tok.start..tok.end];

        // Remove underscores
        var clean: [128]u8 = undefined;
        var len: usize = 0;
        for (text) |c| {
            if (c != '_') {
                if (len >= clean.len) return error.InvalidNumber;
                clean[len] = c;
                len += 1;
            }
        }
        const cleaned = clean[0..len];

        // Handle sign
        var start: usize = 0;
        var negative = false;
        if (cleaned.len > 0 and cleaned[0] == '-') {
            negative = true;
            start = 1;
        } else if (cleaned.len > 0 and cleaned[0] == '+') {
            start = 1;
        }

        // Handle radix
        var base: u8 = 10;
        if (start + 2 <= cleaned.len and cleaned[start] == '0') {
            const radix_char = cleaned[start + 1];
            if (radix_char == 'x' or radix_char == 'X') {
                base = 16;
                start += 2;
            } else if (radix_char == 'o' or radix_char == 'O') {
                base = 8;
                start += 2;
            } else if (radix_char == 'b' or radix_char == 'B') {
                base = 2;
                start += 2;
            }
        }

        const num = std.fmt.parseInt(i128, cleaned[start..], base) catch return error.InvalidNumber;
        return if (negative) -num else num;
    }

    fn parseFloat(self: *Parser, tok: Token) ParseError!Value.FloatValue {
        const text = self.tokenizer.source[tok.start..tok.end];

        // Check for exponent and decimal in original input
        var has_exponent = false;
        var has_decimal = false;
        for (text) |c| {
            if (c == 'e' or c == 'E') has_exponent = true;
            if (c == '.') has_decimal = true;
        }

        // Remove underscores
        var clean: [128]u8 = undefined;
        var len: usize = 0;
        for (text) |c| {
            if (c != '_') {
                if (len >= clean.len) return error.InvalidNumber;
                clean[len] = c;
                len += 1;
            }
        }
        const value = std.fmt.parseFloat(f64, clean[0..len]) catch return error.InvalidNumber;
        return .{
            .value = value,
            .has_exponent = has_exponent,
            .has_decimal = has_decimal,
        };
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Document {
    return Parser.parse(allocator, source);
}

// ============================================================================
// Tests
// ============================================================================

test "parse empty document" {
    var doc = try parse(testing.allocator, "");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.nodes.len);
}

test "parse simple node" {
    var doc = try parse(testing.allocator, "node");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqualStrings("node", doc.nodes[0].name);
}

test "parse node with string argument" {
    var doc = try parse(testing.allocator, "node \"hello\"");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqual(@as(usize, 1), doc.nodes[0].arguments.len);
    try testing.expectEqualStrings("hello", doc.nodes[0].arguments[0].value.asString().?);
}

test "parse node with multiple arguments" {
    var doc = try parse(testing.allocator, "node 1 2 3");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqual(@as(usize, 3), doc.nodes[0].arguments.len);
    try testing.expectEqual(@as(i64, 1), doc.nodes[0].arguments[0].value.asInt().?);
    try testing.expectEqual(@as(i64, 2), doc.nodes[0].arguments[1].value.asInt().?);
    try testing.expectEqual(@as(i64, 3), doc.nodes[0].arguments[2].value.asInt().?);
}

test "parse node with property" {
    var doc = try parse(testing.allocator, "node key=\"value\"");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqual(@as(usize, 1), doc.nodes[0].properties.len);
    try testing.expectEqualStrings("key", doc.nodes[0].properties[0].name);
    try testing.expectEqualStrings("value", doc.nodes[0].properties[0].value.value.asString().?);
}

test "parse node with children" {
    var doc = try parse(testing.allocator,
        \\parent {
        \\    child1
        \\    child2
        \\}
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqualStrings("parent", doc.nodes[0].name);
    try testing.expectEqual(@as(usize, 2), doc.nodes[0].children.len);
    try testing.expectEqualStrings("child1", doc.nodes[0].children[0].name);
    try testing.expectEqualStrings("child2", doc.nodes[0].children[1].name);
}

test "parse multiple nodes" {
    var doc = try parse(testing.allocator, "node1\nnode2\nnode3");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.nodes.len);
}

test "parse type annotation on node" {
    var doc = try parse(testing.allocator, "(mytype)node");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqualStrings("mytype", doc.nodes[0].type_annotation.?);
    try testing.expectEqualStrings("node", doc.nodes[0].name);
}

test "parse type annotation on value" {
    var doc = try parse(testing.allocator, "node (u8)123");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes[0].arguments.len);
    try testing.expectEqualStrings("u8", doc.nodes[0].arguments[0].type_annotation.?);
    try testing.expectEqual(@as(i64, 123), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse boolean values (v2 syntax)" {
    var doc = try parse(testing.allocator, "node #true #false");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try testing.expectEqual(true, doc.nodes[0].arguments[0].value.asBool().?);
    try testing.expectEqual(false, doc.nodes[0].arguments[1].value.asBool().?);
}

test "parse null value (v2 syntax)" {
    var doc = try parse(testing.allocator, "node #null");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes[0].arguments.len);
    try testing.expect(doc.nodes[0].arguments[0].value.isNull());
}

test "parse float keywords (v2 syntax)" {
    var doc = try parse(testing.allocator, "floats #inf #-inf #nan");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.nodes[0].arguments.len);
    try testing.expect(std.math.isPositiveInf(doc.nodes[0].arguments[0].value.asFloat().?));
    try testing.expect(std.math.isNegativeInf(doc.nodes[0].arguments[1].value.asFloat().?));
    try testing.expect(std.math.isNan(doc.nodes[0].arguments[2].value.asFloat().?));
}

test "parse float" {
    var doc = try parse(testing.allocator, "node 3.14159");
    defer doc.deinit();
    try testing.expectApproxEqAbs(@as(f64, 3.14159), doc.nodes[0].arguments[0].value.asFloat().?, 0.00001);
}

test "parse float with exponent" {
    var doc = try parse(testing.allocator, "node 1.5e10");
    defer doc.deinit();
    try testing.expectApproxEqAbs(@as(f64, 1.5e10), doc.nodes[0].arguments[0].value.asFloat().?, 1e5);
}

test "parse hex number" {
    var doc = try parse(testing.allocator, "node 0xdeadbeef");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 0xdeadbeef), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse octal number" {
    var doc = try parse(testing.allocator, "node 0o755");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 0o755), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse binary number" {
    var doc = try parse(testing.allocator, "node 0b11011011");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 0b11011011), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse negative number" {
    var doc = try parse(testing.allocator, "node -42");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, -42), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse number with underscores" {
    var doc = try parse(testing.allocator, "node 1_000_000");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 1_000_000), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse string with escapes" {
    var doc = try parse(testing.allocator, "node \"hello\\nworld\\t!\"");
    defer doc.deinit();
    try testing.expectEqualStrings("hello\nworld\t!", doc.nodes[0].arguments[0].value.asString().?);
}

test "parse string with unicode escape" {
    var doc = try parse(testing.allocator, "node \"\\u{1F600}\"");
    defer doc.deinit();
    try testing.expectEqualStrings("😀", doc.nodes[0].arguments[0].value.asString().?);
}

test "parse raw string (v2 syntax)" {
    var doc = try parse(testing.allocator, "node #\"hello\\nworld\"#");
    defer doc.deinit();
    try testing.expectEqualStrings("hello\\nworld", doc.nodes[0].arguments[0].value.asString().?);
}

test "parse raw string with multiple hashes" {
    var doc = try parse(testing.allocator, "node ###\"\"#\"##\"###");
    defer doc.deinit();
    try testing.expectEqualStrings("\"#\"##", doc.nodes[0].arguments[0].value.asString().?);
}

test "parse single-line comment" {
    var doc = try parse(testing.allocator, "node // this is a comment\nnode2");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.nodes.len);
}

test "parse multi-line comment" {
    var doc = try parse(testing.allocator, "node /* comment */ 42");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes[0].arguments.len);
    try testing.expectEqual(@as(i64, 42), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse nested multi-line comment" {
    var doc = try parse(testing.allocator, "node /* outer /* inner */ outer */ 42");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 42), doc.nodes[0].arguments[0].value.asInt().?);
}

test "parse slashdash node" {
    var doc = try parse(testing.allocator, "/-node\nnode2");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try testing.expectEqualStrings("node2", doc.nodes[0].name);
}

test "parse slashdash argument" {
    var doc = try parse(testing.allocator, "node /-1 2 3");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try testing.expectEqual(@as(i64, 2), doc.nodes[0].arguments[0].value.asInt().?);
    try testing.expectEqual(@as(i64, 3), doc.nodes[0].arguments[1].value.asInt().?);
}

test "parse slashdash property" {
    var doc = try parse(testing.allocator, "node /-key=\"value\" other=\"ok\"");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 1), doc.nodes[0].properties.len);
    try testing.expectEqualStrings("other", doc.nodes[0].properties[0].name);
}

test "parse slashdash children" {
    var doc = try parse(testing.allocator, "node /-{ child }");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.nodes[0].children.len);
}

test "parse line continuation" {
    var doc = try parse(testing.allocator, "node 1 2 \\\n    3 4");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 4), doc.nodes[0].arguments.len);
}

test "parse semicolon terminator" {
    var doc = try parse(testing.allocator, "node1; node2; node3");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 3), doc.nodes.len);
}

test "parse inline children" {
    var doc = try parse(testing.allocator, "parent { child1; child2 }");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.nodes[0].children.len);
}

test "parse quoted node name" {
    var doc = try parse(testing.allocator, "\"node with spaces\"");
    defer doc.deinit();
    try testing.expectEqualStrings("node with spaces", doc.nodes[0].name);
}

test "parse quoted property name" {
    var doc = try parse(testing.allocator, "node \"key with spaces\"=\"value\"");
    defer doc.deinit();
    try testing.expectEqualStrings("key with spaces", doc.nodes[0].properties[0].name);
}

test "parse mixed args and props" {
    var doc = try parse(testing.allocator, "node 1 key=2 3 other=4");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try testing.expectEqual(@as(usize, 2), doc.nodes[0].properties.len);
}

test "getNode helper" {
    var doc = try parse(testing.allocator, "foo\nbar\nbaz");
    defer doc.deinit();
    const node = doc.getNode("bar");
    try testing.expect(node != null);
    try testing.expectEqualStrings("bar", node.?.name);
}

test "getProp helper returns rightmost" {
    var doc = try parse(testing.allocator, "node a=1 a=2");
    defer doc.deinit();
    const val = doc.nodes[0].getProp("a");
    try testing.expect(val != null);
    try testing.expectEqual(@as(i64, 2), val.?.value.asInt().?);
}

test "getChild helper" {
    var doc = try parse(testing.allocator,
        \\parent {
        \\    child1
        \\    child2
        \\    child3
        \\}
    );
    defer doc.deinit();
    const child = doc.nodes[0].getChild("child2");
    try testing.expect(child != null);
    try testing.expectEqualStrings("child2", child.?.name);
}

test "multiline string" {
    var doc = try parse(testing.allocator,
        \\node """
        \\    hello
        \\    world
        \\    """
    );
    defer doc.deinit();
    try testing.expectEqualStrings("hello\nworld", doc.nodes[0].arguments[0].value.asString().?);
}

test "bare identifier with special chars" {
    var doc = try parse(testing.allocator, "foo123~!@$%^&*.:'|?+ \"weeee\"");
    defer doc.deinit();
    try testing.expectEqualStrings("foo123~!@$%^&*.:'|?+", doc.nodes[0].name);
}

test "disallowed bare identifiers" {
    // true, false, null, inf, -inf, nan should fail as bare identifiers
    try testing.expectError(error.UnexpectedToken, parse(testing.allocator, "true"));
    try testing.expectError(error.UnexpectedToken, parse(testing.allocator, "false"));
    try testing.expectError(error.UnexpectedToken, parse(testing.allocator, "null"));
    try testing.expectError(error.UnexpectedToken, parse(testing.allocator, "inf"));
    try testing.expectError(error.UnexpectedToken, parse(testing.allocator, "nan"));
}

test "negative hex" {
    var doc = try parse(testing.allocator, "node -0x10");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, -16), doc.nodes[0].arguments[0].value.asInt().?);
}

test "positive sign" {
    var doc = try parse(testing.allocator, "node +42");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 42), doc.nodes[0].arguments[0].value.asInt().?);
}

test "identifier starting with sign" {
    var doc = try parse(testing.allocator, "--flag");
    defer doc.deinit();
    try testing.expectEqualStrings("--flag", doc.nodes[0].name);
}

test "identifier starting with dot" {
    var doc = try parse(testing.allocator, ".hidden");
    defer doc.deinit();
    try testing.expectEqualStrings(".hidden", doc.nodes[0].name);
}

test "whitespace escape in string" {
    var doc = try parse(testing.allocator, "node \"hello\\   world\"");
    defer doc.deinit();
    try testing.expectEqualStrings("helloworld", doc.nodes[0].arguments[0].value.asString().?);
}

test "complex document" {
    var doc = try parse(testing.allocator,
        \\// This is a KDL document
        \\title "Hello, World"
        \\
        \\author "Alex Monad" email="alex@example.com" active=#true
        \\
        \\contents {
        \\    section "First section" {
        \\        paragraph "This is the first paragraph"
        \\        paragraph "This is the second paragraph"
        \\    }
        \\}
        \\
        \\// Numbers
        \\numbers (u8)10 (i32)20 myfloat=(f32)1.5
    );
    defer doc.deinit();

    try testing.expectEqual(@as(usize, 4), doc.nodes.len);

    // title
    const title = doc.getNode("title").?;
    try testing.expectEqualStrings("Hello, World", title.arguments[0].value.asString().?);

    // author
    const author = doc.getNode("author").?;
    try testing.expectEqualStrings("Alex Monad", author.arguments[0].value.asString().?);
    try testing.expectEqualStrings("alex@example.com", author.getProp("email").?.value.asString().?);
    try testing.expectEqual(true, author.getProp("active").?.value.asBool().?);

    // contents
    const contents = doc.getNode("contents").?;
    try testing.expectEqual(@as(usize, 1), contents.children.len);
    const section = contents.children[0];
    try testing.expectEqualStrings("section", section.name);
    try testing.expectEqualStrings("First section", section.arguments[0].value.asString().?);
    try testing.expectEqual(@as(usize, 2), section.children.len);

    // numbers
    const numbers = doc.getNode("numbers").?;
    try testing.expectEqualStrings("u8", numbers.arguments[0].type_annotation.?);
    try testing.expectEqualStrings("f32", numbers.getProp("myfloat").?.type_annotation.?);
}

test "empty children block" {
    var doc = try parse(testing.allocator, "node { }");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.nodes[0].children.len);
}

test "deeply nested children" {
    var doc = try parse(testing.allocator,
        \\a {
        \\    b {
        \\        c {
        \\            d
        \\        }
        \\    }
        \\}
    );
    defer doc.deinit();
    try testing.expectEqualStrings("a", doc.nodes[0].name);
    try testing.expectEqualStrings("b", doc.nodes[0].children[0].name);
    try testing.expectEqualStrings("c", doc.nodes[0].children[0].children[0].name);
    try testing.expectEqualStrings("d", doc.nodes[0].children[0].children[0].children[0].name);
}

test "line continuation with comment" {
    var doc = try parse(testing.allocator,
        \\node 1 2 \  // comment here
        \\    3 4
    );
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 4), doc.nodes[0].arguments.len);
}

test "binary trailing underscore" {
    var doc = try parse(testing.allocator, "node 0b1010_");
    defer doc.deinit();
    try testing.expectEqual(@as(i64, 0b1010), doc.nodes[0].arguments[0].value.asInt().?);
}

test "identifier string as arg" {
    var doc = try parse(testing.allocator, "node arg");
    defer doc.deinit();
    try testing.expectEqualStrings("arg", doc.nodes[0].arguments[0].value.asString().?);
}

test "identifier string as prop value" {
    var doc = try parse(testing.allocator, "node prop=val");
    defer doc.deinit();
    try testing.expectEqualStrings("val", doc.nodes[0].getProp("prop").?.value.asString().?);
}
