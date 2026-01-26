const std = @import("std");
const kdl = @import("kdl.zig");
const tokenizer = @import("tokenizer.zig");

const Value = kdl.Value;
const TypedValue = kdl.TypedValue;
const Property = kdl.Property;
const Node = kdl.Node;
const Document = kdl.Document;
const ParseError = kdl.ParseError;
const Token = tokenizer.Token;
const Tokenizer = tokenizer.Tokenizer;
const isNewline = tokenizer.isNewline;

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
                const next_tok = try self.peek();
                if (next_tok.tag == .open_brace) {
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
                const next_tok = try self.peek();
                if (next_tok.tag == .open_brace) {
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
            const next_tok = try self.peek();
            if (next_tok.tag == .equals) {
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
            // Identifiers can reference source directly (no escapes possible)
            .identifier => .{ .string = self.tokenizer.source[tok.start..tok.end] },
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
            // Identifiers can reference source directly (no escapes possible)
            .identifier => self.tokenizer.source[tok.start..tok.end],
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
        // Check if we need to process escapes - if not, return slice into source
        if (std.mem.indexOfScalar(u8, inner, '\\') == null) {
            return inner;
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

        // Raw strings have no escapes, can return slice into source
        return text[start..end];
    }

    fn processMultilineString(self: *Parser, tok: Token) ParseError![]const u8 {
        const text = self.tokenizer.source[tok.start..tok.end];
        const alloc = self.arena.allocator();

        // """...""" format
        // Skip opening """ and first newline
        var start: usize = 3;
        if (start < text.len and text[start] == '\r') start += 1;
        if (start < text.len and text[start] == '\n') start += 1;

        // Content is between opening newline and closing """
        const end = text.len - 3;
        const content = text[start..end];

        // Parse into lines, tracking indent and text separately
        // This follows the Python kdlpy approach
        const Line = struct {
            indent: []const u8,
            text: std.ArrayList(u8),
        };

        var lines: std.ArrayList(Line) = .empty;
        var current_line = Line{
            .indent = &.{},
            .text = .empty,
        };

        var i: usize = 0;

        // Consume initial whitespace as indent for first line
        const indent_start = i;
        while (i < content.len) {
            if (isMultilineWhitespace(content, i)) |len| {
                i += len;
            } else {
                break;
            }
        }
        current_line.indent = content[indent_start..i];

        // Parse content
        while (i < content.len) {
            const c = content[i];

            // Check for newline
            if (c == '\n' or c == '\r') {
                // Finish current line
                try lines.append(alloc, current_line);

                // Skip newline
                if (c == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
                    i += 2;
                } else {
                    i += 1;
                }

                // Start new line - capture indent
                const new_indent_start = i;
                while (i < content.len) {
                    if (isMultilineWhitespace(content, i)) |len| {
                        i += len;
                    } else {
                        break;
                    }
                }
                current_line = Line{
                    .indent = content[new_indent_start..i],
                    .text = .empty,
                };
                continue;
            }

            // Check for escape
            if (c == '\\' and i + 1 < content.len) {
                const next_char = content[i + 1];
                switch (next_char) {
                    'n' => {
                        try current_line.text.append(alloc, '\n');
                        i += 2;
                    },
                    'r' => {
                        try current_line.text.append(alloc, '\r');
                        i += 2;
                    },
                    't' => {
                        try current_line.text.append(alloc, '\t');
                        i += 2;
                    },
                    '\\' => {
                        try current_line.text.append(alloc, '\\');
                        i += 2;
                    },
                    '"' => {
                        try current_line.text.append(alloc, '"');
                        i += 2;
                    },
                    'b' => {
                        try current_line.text.append(alloc, 0x08);
                        i += 2;
                    },
                    'f' => {
                        try current_line.text.append(alloc, 0x0C);
                        i += 2;
                    },
                    's' => {
                        try current_line.text.append(alloc, ' ');
                        i += 2;
                    },
                    'u' => {
                        if (i + 2 < content.len and content[i + 2] == '{') {
                            var ue = i + 3;
                            while (ue < content.len and content[ue] != '}') {
                                ue += 1;
                            }
                            if (ue >= content.len) return error.InvalidEscape;
                            const hex = content[i + 3 .. ue];
                            if (hex.len == 0 or hex.len > 6) return error.InvalidEscape;
                            const codepoint = std.fmt.parseInt(u21, hex, 16) catch return error.InvalidEscape;
                            var buf: [4]u8 = undefined;
                            const len = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidEscape;
                            try current_line.text.appendSlice(alloc, buf[0..len]);
                            i = ue + 1;
                        } else {
                            return error.InvalidEscape;
                        }
                    },
                    ' ', '\t', '\n', '\r' => {
                        // Whitespace escape - consume backslash and all following whitespace/newlines
                        i += 1; // skip backslash
                        while (i < content.len) {
                            if (isMultilineWhitespace(content, i)) |len| {
                                i += len;
                            } else if (content[i] == '\n' or content[i] == '\r') {
                                // Consume newline
                                if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
                                    i += 2;
                                } else {
                                    i += 1;
                                }
                                // Consume indent of next line (will be stripped later anyway)
                                while (i < content.len) {
                                    if (isMultilineWhitespace(content, i)) |len| {
                                        i += len;
                                    } else {
                                        break;
                                    }
                                }
                            } else {
                                break;
                            }
                        }
                    },
                    else => {
                        // Check for unicode whitespace
                        if (isMultilineWhitespace(content, i + 1)) |_| {
                            i += 1;
                            while (i < content.len) {
                                if (isMultilineWhitespace(content, i)) |len| {
                                    i += len;
                                } else if (content[i] == '\n' or content[i] == '\r') {
                                    if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') {
                                        i += 2;
                                    } else {
                                        i += 1;
                                    }
                                    while (i < content.len) {
                                        if (isMultilineWhitespace(content, i)) |len2| {
                                            i += len2;
                                        } else {
                                            break;
                                        }
                                    }
                                } else {
                                    break;
                                }
                            }
                        } else {
                            return error.InvalidEscape;
                        }
                    },
                }
                continue;
            }

            // Regular character
            try current_line.text.append(alloc, c);
            i += 1;
        }

        // current_line is the "last line" (closing line) - its indent is the prefix
        // and its text must be empty (only whitespace allowed before """)
        const last_line = current_line;
        if (last_line.text.items.len > 0) {
            return error.MultilineStringIndentError;
        }

        const prefix = last_line.indent;

        // Process lines: strip prefix, handle whitespace-only lines
        var result: std.ArrayList(u8) = .empty;
        for (lines.items, 0..) |*line, idx| {
            if (idx > 0) {
                try result.append(alloc, '\n');
            }

            // If line text is empty, it's whitespace-only - contributes just a newline
            if (line.text.items.len == 0) {
                continue;
            }

            // Strip prefix from indent
            if (prefix.len > 0) {
                if (line.indent.len >= prefix.len and std.mem.startsWith(u8, line.indent, prefix)) {
                    // Write remaining indent after prefix
                    try result.appendSlice(alloc, line.indent[prefix.len..]);
                } else {
                    // Indent doesn't match prefix - error
                    return error.MultilineStringIndentError;
                }
            } else {
                // No prefix, keep full indent
                try result.appendSlice(alloc, line.indent);
            }

            // Write text
            try result.appendSlice(alloc, line.text.items);
        }

        return result.toOwnedSlice(alloc);
    }

    fn isMultilineWhitespace(content: []const u8, pos: usize) ?usize {
        if (pos >= content.len) return null;
        const c = content[pos];

        // Basic ASCII whitespace (not newlines)
        if (c == ' ' or c == '\t') return 1;

        // Check for multi-byte unicode whitespace
        if (pos + 2 < content.len and c == 0xE2) {
            if (content[pos + 1] == 0x80) {
                const b2 = content[pos + 2];
                // U+2000-U+200A
                if (b2 >= 0x80 and b2 <= 0x8A) return 3;
                // U+202F
                if (b2 == 0xAF) return 3;
            } else if (content[pos + 1] == 0x81 and content[pos + 2] == 0x9F) {
                // U+205F
                return 3;
            }
        }
        // U+3000 ideographic space
        if (pos + 2 < content.len and
            c == 0xE3 and
            content[pos + 1] == 0x80 and
            content[pos + 2] == 0x80)
        {
            return 3;
        }
        // U+00A0 no-break space
        if (pos + 1 < content.len and
            c == 0xC2 and
            content[pos + 1] == 0xA0)
        {
            return 2;
        }
        // U+1680 ogham space mark
        if (pos + 2 < content.len and
            c == 0xE1 and
            content[pos + 1] == 0x9A and
            content[pos + 2] == 0x80)
        {
            return 3;
        }

        return null;
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

            // Check if line is whitespace-only (including unicode whitespace)
            var is_whitespace_only = true;
            {
                var j: usize = 0;
                while (j < actual_line.len) {
                    if (isMultilineWhitespace(actual_line, j)) |ws_len| {
                        j += ws_len;
                    } else {
                        is_whitespace_only = false;
                        break;
                    }
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

        // Check for overflow/underflow - if the parsed value is inf or 0 but the input
        // was a finite non-zero number, we need to preserve the raw string
        const needs_raw = (std.math.isInf(value) or (value == 0 and has_exponent)) and
            !std.mem.eql(u8, clean[0..len], "0.0") and
            !std.mem.startsWith(u8, clean[0..len], "inf") and
            !std.mem.startsWith(u8, clean[0..len], "-inf");

        return .{
            .value = value,
            .has_exponent = has_exponent,
            .has_decimal = has_decimal,
            .raw = if (needs_raw) text else null,
        };
    }
};
