// SPDX-License-Identifier: MIT
const std = @import("std");
const builtin = @import("builtin");

// Stock 0.17 omits an unspecified .libc_runtimes path only in protocol mode.
// Resolve that optional directory into a file; the consumer driver remains an
// ordinary process with inherited stdio and forwards a nonempty value unchanged.
pub fn main(init: std.process.Init) !void {
    var input_buffer: [1024]u8 = undefined;
    var output_buffer: [1024]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    var server: std.zig.Server = .{
        .in = &input.interface,
        .out = &output.interface,
    };
    try server.serveStringMessage(.zig_version, builtin.zig_version_string);
    var resolved = false;
    while (true) {
        const message = try server.receiveMessage();
        switch (message.tag) {
            .args => {
                var payload: std.Io.Reader = .fixed(try server.in.take(message.bytes_len));
                var directory: ?std.Io.Dir = null;
                var destination: ?std.Io.File = null;
                while (payload.seek < payload.end) {
                    switch (@as(std.zig.Client.Message.Arg, @fromBackingInt(try payload.takeByte()))) {
                        .input_dir => directory = .{
                            .handle = std.mem.bytesAsValue(std.Io.Dir.Handle, try payload.take(@sizeOf(std.Io.Dir.Handle))).*,
                        },
                        .output_file => destination = .{
                            .handle = std.mem.bytesAsValue(std.Io.File.Handle, try payload.take(@sizeOf(std.Io.File.Handle))).*,
                            .flags = .{ .nonblocking = false },
                        },
                        else => return error.UnexpectedProtocolArgument,
                    }
                }
                var file = (destination orelse return error.MissingOutputFile).writerStreaming(init.io, &.{});
                if (directory) |dir| {
                    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                    const length = try dir.realPath(init.io, &path_buffer);
                    try file.interface.writeAll(path_buffer[0..length]);
                }
                try file.interface.flush();
                resolved = true;
            },
            .query_test_metadata => {
                if (!resolved) return error.MissingProtocolArguments;
                // The general Run protocol requires this handshake even for a
                // generator. There are no tests: all real work finished above.
                try server.serveTestMetadata(.{
                    .names = &.{},
                    .expected_panic_msgs = &.{},
                    .string_bytes = &.{},
                });
            },
            .exit => return,
            else => return error.UnexpectedProtocolMessage,
        }
    }
}
