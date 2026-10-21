const std = @import("std");
const log = std.log;

const Server = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    var server: Server = .{
        .alloc = init.gpa,
        .io = init.io,
        .options = try .parse(&args),
    };
    try server.listen();
}
