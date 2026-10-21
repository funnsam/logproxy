const std = @import("std");
const builtin = @import("builtin");
const log = std.log;

const Server = @import("Server.zig");

var sigint_io: std.Io = undefined;
var exit_event: std.Io.Event = .unset;

pub fn main(init: std.process.Init) !void {
    sigint_io = init.io;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    if (comptime builtin.os.tag != .windows) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigInt },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }

    const U = union(enum) { a: std.Io.Cancelable!void };
    var buf: [2]U = undefined;
    var sel: std.Io.Select(U) = .init(init.io, &buf);
    defer sel.cancelDiscard();

    var server: Server = .{
        .alloc = init.gpa,
        .io = init.io,
        .options = try .parse(&args),
    };

    sel.async(.a, Server.listenAsync, .{&server});
    sel.async(.a, std.Io.Event.wait, .{ &exit_event, init.io });
    _ = try sel.await();
}

fn handleSigInt(_: std.posix.SIG) callconv(.c) void {
    exit_event.set(sigint_io);
    log.info("exiting", .{});
}
