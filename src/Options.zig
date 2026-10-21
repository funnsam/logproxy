const std = @import("std");

const Self = @This();

addr: std.Io.net.IpAddress = .{ .ip4 = .unspecified(8080) },
action: Action = .forward,

pub const Action = enum { forward, reject };

pub const ParseError = error{ UnknownFlag, MissingDetails } ||
    std.Io.net.IpAddress.ParseLiteralError;

pub fn parse(args: anytype) ParseError!Self {
    var ret: Self = .{};

    _ = args.skip();
    while (args.next()) |flag| {
        if (std.mem.eql(u8, flag, "-a")) {
            const text = args.next() orelse return ParseError.MissingDetails;
            ret.addr = try .parseLiteral(text);
        } else if (std.mem.eql(u8, flag, "--reject")) {
            ret.action = .reject;
        } else {
            return ParseError.UnknownFlag;
        }
    }

    return ret;
}
