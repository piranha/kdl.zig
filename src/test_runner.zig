const std = @import("std");
const kdl = @import("kdl.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const test_dir = if (args.len > 1) args[1] else "tests/test_cases";

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    const input_dir = try std.fs.cwd().openDir(try std.fs.path.join(allocator, &.{ test_dir, "input" }), .{ .iterate = true });
    const expected_dir = try std.fs.cwd().openDir(try std.fs.path.join(allocator, &.{ test_dir, "expected_kdl" }), .{});

    var dir_iter = input_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".kdl")) continue;

        const is_fail_test = std.mem.indexOf(u8, entry.name, "_fail") != null;

        // Read input file
        const input_content = input_dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch |err| {
            std.debug.print("SKIP {s}: cannot read input: {}\n", .{ entry.name, err });
            skipped += 1;
            continue;
        };
        defer allocator.free(input_content);

        // Try to parse
        var doc = kdl.parse(allocator, input_content) catch |err| {
            if (is_fail_test) {
                // Expected to fail
                passed += 1;
            } else {
                std.debug.print("FAIL {s}: parse error: {}\n", .{ entry.name, err });
                failed += 1;
            }
            continue;
        };
        defer doc.deinit();

        if (is_fail_test) {
            std.debug.print("FAIL {s}: expected parse failure but succeeded\n", .{entry.name});
            failed += 1;
            continue;
        }

        // Read expected output (if exists)
        const expected_content = expected_dir.readFileAlloc(allocator, entry.name, 1024 * 1024) catch {
            // No expected file - just check it parses
            passed += 1;
            continue;
        };
        defer allocator.free(expected_content);

        // Format our output
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        const writer = output.writer(allocator);
        std.fmt.format(writer, "{f}", .{doc}) catch |err| {
            std.debug.print("FAIL {s}: format error: {any}\n", .{ entry.name, err });
            failed += 1;
            continue;
        };

        // Compare (normalized)
        const our_output = std.mem.trim(u8, output.items, "\n\r ");
        const expected_trimmed = std.mem.trim(u8, expected_content, "\n\r ");

        if (std.mem.eql(u8, our_output, expected_trimmed)) {
            passed += 1;
        } else {
            std.debug.print("FAIL {s}:\n  expected:\n{s}\n  got:\n{s}\n", .{ entry.name, expected_trimmed, our_output });
            failed += 1;
        }
    }

    std.debug.print("\n{} passed, {} failed, {} skipped\n", .{ passed, failed, skipped });

    if (failed > 0) {
        std.process.exit(1);
    }
}
