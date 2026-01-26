const std = @import("std");
const testing = std.testing;
const kdl = @import("kdl.zig");
const parse = kdl.parse;

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
