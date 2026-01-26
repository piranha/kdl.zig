const std = @import("std");
const ParseError = @import("kdl.zig").ParseError;

pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn isHexDigit(c: u8) bool {
    return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

pub fn isOctalDigit(c: u8) bool {
    return c >= '0' and c <= '7';
}

pub fn isNewline(c: u8) bool {
    // Note: U+0085 (NEL) is handled separately as a 2-byte UTF-8 sequence (C2 85)
    return c == '\n' or c == '\r' or c == 0x0B or c == 0x0C;
}

pub fn isNonIdentifierChar(c: u8) bool {
    if (c <= 0x20) return true;
    return switch (c) {
        '(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=' => true,
        0x7F => true,
        else => false,
    };
}

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
    had_whitespace_before: bool = true, // whether there was whitespace/newline before this token

    pub const Tag = enum {
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

pub const Tokenizer = struct {
    source: []const u8,
    index: usize = 0,
    seen_bom: bool = false,
    had_whitespace: bool = true, // Track if whitespace was seen before current token

    fn makeToken(self: *Tokenizer, tag: Token.Tag, start: usize, end: usize) Token {
        return Token{ .tag = tag, .start = start, .end = end, .had_whitespace_before = self.had_whitespace };
    }

    pub fn next(self: *Tokenizer) ParseError!Token {
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

    pub fn isUnicodeSpace(self: *Tokenizer) ?usize {
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

    pub fn isUnicodeNewline(self: *Tokenizer) ?usize {
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

    pub fn getText(self: *Tokenizer, token: Token) []const u8 {
        return self.source[token.start..token.end];
    }
};
