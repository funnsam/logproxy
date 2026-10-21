const std = @import("std");
const log = std.log;

const Options = @import("Options.zig");

const Self = @This();

alloc: std.mem.Allocator,
io: std.Io,
options: Options,

client_group: std.Io.Group = .init,

pub fn listen(self: *Self) !void {
    var server = try self.options.addr.listen(self.io, .{
        .reuse_address = true,
    });
    defer server.deinit(self.io);

    defer self.client_group.cancel(self.io);

    log.info("started proxy server on {f}", .{self.options.addr});

    while (true) {
        const stream = try server.accept(self.io);
        self.client_group.async(self.io, handleClient, .{ self, stream });
    }
}

fn handleClient(
    self: *const Self,
    stream: std.Io.net.Stream,
) std.Io.Cancelable!void {
    self._handleClient(stream) catch |err| {
        if (err == std.Io.Cancelable.Canceled) {
            return std.Io.Cancelable.Canceled;
        }

        log.err("{}", .{err});
    };
}

fn _handleClient(self: *const Self, stream: std.Io.net.Stream) !void {
    log.debug("a client connected", .{});
    defer log.debug("a client disconnected", .{});

    defer stream.close(self.io);

    var reader_buf: [1024]u8 = undefined;
    var writer_buf: [1024]u8 = undefined;

    var r = stream.reader(self.io, &reader_buf);
    var w = stream.writer(self.io, &writer_buf);

    var srv: std.http.Server = .init(&r.interface, &w.interface);

    while (true) {
        var req = srv.receiveHead() catch |err| {
            if (err == std.http.Server.ReceiveHeadError.HttpConnectionClosing) {
                return;
            }

            return err;
        };

        log.info("{s} {s}", .{
            @tagName(req.head.method),
            req.head.target,
        });

        switch (self.options.action) {
            .forward => try self.forwardRequest(&req),
            .reject => try req.respond("Rejected by proxy", .{
                .status = .bad_gateway,
            }),
        }
    }
}

fn forwardRequest(self: *const Self, req: *std.http.Server.Request) !void {
    if (req.head.method == .CONNECT) {
        return self.tunnel(req);
    }

    var arena: std.heap.ArenaAllocator = .init(self.alloc);
    defer arena.deinit();

    var fwd_headers: std.ArrayList(std.http.Header) = .empty;
    var connection: []const u8 = "";

    var header_iter = req.iterateHeaders();
    while (header_iter.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Connection")) {
            connection = header.value;
            continue;
        }

        for (h2h_headers) |h2h| {
            if (std.ascii.eqlIgnoreCase(header.name, h2h)) {
                break;
            }
        } else {
            try fwd_headers.append(arena.allocator(), header);
        }
    }

    var i: usize = fwd_headers.items.len;
    var cit = std.mem.tokenizeScalar(u8, connection, ',');
    while (i > 0) {
        i -= 1;

        cit.reset();
        while (cit.next()) |_c| {
            const c = std.mem.trim(u8, _c, " ");
            if (std.ascii.eqlIgnoreCase(fwd_headers.items[i], c)) {
                fwd_headers.swapRemove(i);
                break;
            }
        }
    }

    if (true) @panic("TODO");

    var client: std.http.Client = .{
        .allocator = arena.allocator(),
        .io = self.io,
    };
    defer client.deinit();

    var fwd_req = try client.request(req.head.method, req.head.target, .{
        .headers = .{
            .connection = .omit,
            .accept_encoding = .omit,
            .authorization = .omit,
            .content_type = .omit,
            .host = .omit,
            .user_agent = .omit,
        },
        .extra_headers = fwd_headers.items,
        .keep_alive = false,
    });
    defer fwd_req.deinit();
}

fn tunnel(self: *const Self, req: *std.http.Server.Request) !void {
    _ = self;
    _ = req;
    @panic("TODO: tunnel");
}

const h2h_headers: []const []const u8 = &.{
    "Connection",
    "Keep-Alive",
    "Proxy-Authenticate",
    "Proxy-Authorization",
    "TE",
    "Trailer",
    "Transfer-Encoding",
    "Upgrade",
};
