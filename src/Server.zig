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
        try self.client_group.concurrent(self.io, handleClient, .{ self, stream });
    }
}

pub fn listenAsync(self: *Self) std.Io.Cancelable!void {
    self.listen() catch |err| {
        if (err == error.Canceled) {
            return error.Canceled;
        }

        log.err("got error while listening: {s}", .{@errorName(err)});
    };
}

fn handleClient(
    self: *const Self,
    stream: std.Io.net.Stream,
) std.Io.Cancelable!void {
    self._handleClient(stream) catch |err| {
        if (err == std.Io.Cancelable.Canceled) {
            return std.Io.Cancelable.Canceled;
        }

        log.err("handle client: {}", .{err});
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
                break;
            }

            return err;
        };

        log.info("{s} {s}", .{
            @tagName(req.head.method),
            req.head.target,
        });

        switch (self.options.action) {
            .forward => {
                if (req.head.method == .CONNECT) {
                    var split_it = std.mem.splitBackwardsScalar(u8, req.head.target, ':');
                    const port = split_it.next() orelse return error.ReadTargetError;
                    const port_num = try std.fmt.parseInt(u10, port, 10);
                    const host: std.Io.net.HostName = try .init(split_it.rest());

                    try req.respond("", .{ .status = .ok });

                    _ = try self.tunnel(host, port_num, &r, &w);

                    try stream.shutdown(self.io, .both);
                    return;
                }
                try self.forwardRequest(&req);
            },
            .reject => try req.respond("Rejected by proxy", .{
                .status = .bad_gateway,
            }),
        }
    }

    try stream.shutdown(self.io, .both);
}

fn forwardRequest(self: *const Self, req: *std.http.Server.Request) !void {
    std.debug.assert(req.head.method != .CONNECT);

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

    // filter away H2H headers in Connection header
    var i: usize = fwd_headers.items.len;
    var cit = std.mem.tokenizeScalar(u8, connection, ',');
    while (i > 0) {
        i -= 1;

        cit.reset();
        while (cit.next()) |_c| {
            const c = std.mem.trim(u8, _c, " ");
            if (std.ascii.eqlIgnoreCase(fwd_headers.items[i].name, c)) {
                _ = fwd_headers.swapRemove(i);
                break;
            }
        }
    }

    // clone strings to make them outlive client
    for (fwd_headers.items) |*h| {
        h.name = try arena.allocator().dupe(u8, h.name);
        h.value = try arena.allocator().dupe(u8, h.value);
    }

    var reader_buf: [1024]u8 = undefined;
    var writer_buf: [1024]u8 = undefined;

    var client: std.http.Client = .{
        .allocator = arena.allocator(),
        .io = self.io,
    };
    defer client.deinit();

    var fwd_req = try client.request(req.head.method, try .parse(req.head.target), .{
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
        .redirect_behavior = .unhandled,
    });
    defer fwd_req.deinit();

    req.head.expect = null;
    const req_reader = req.readerExpectNone(&reader_buf);

    // streaming request body

    if (req_reader.peekByte()) |_| {
        var fwd_req_w = try fwd_req.sendBodyUnflushed(&writer_buf);
        _ = try req_reader.streamRemaining(&fwd_req_w.writer);
        try fwd_req_w.end();
    } else |_| {
        try fwd_req.sendBodiless();
    }

    // start responding

    var fwd_resp = try fwd_req.receiveHead(&.{});

    log.info("forwarder got {}", .{@backingInt(fwd_resp.head.status)});

    fwd_headers.clearRetainingCapacity();
    header_iter = fwd_resp.head.iterateHeaders();
    while (header_iter.next()) |header| {
        for (ignore_resp_headers) |h| {
            if (std.ascii.eqlIgnoreCase(header.name, h)) {
                break;
            }
        } else {
            try fwd_headers.append(arena.allocator(), header);
        }
    }

    var resp_w = try req.respondStreaming(&writer_buf, .{
        .content_length = fwd_resp.head.content_length,
        .respond_options = .{
            .status = fwd_resp.head.status,
            .reason = fwd_resp.head.reason,
            .extra_headers = fwd_headers.items,
        },
    });
    try resp_w.flush(); // flush now to avoid memory copies

    // streaming back response

    const fwd_resp_r = fwd_resp.reader(&reader_buf);
    _ = try fwd_resp_r.streamRemaining(&resp_w.writer);
    try resp_w.end();
}

fn tunnel(
    self: *const Self,
    host: std.Io.net.HostName,
    port: u10,
    client_r: *std.Io.net.Stream.Reader,
    client_w: *std.Io.net.Stream.Writer,
) !void {
    const srv = try host.connect(self.io, port, .{
        .mode = .stream,
        .protocol = .tcp,
    });
    defer srv.close(self.io);

    var server_r_buf: [1024]u8 = undefined;
    var server_w_buf: [1024]u8 = undefined;

    var server_r = srv.reader(self.io, &server_r_buf);
    var server_w = srv.writer(self.io, &server_w_buf);

    const U = union(enum) { a: std.Io.Cancelable!void };
    var buf: [2]U = undefined;
    var sel: std.Io.Select(U) = .init(self.io, &buf);
    defer sel.cancelDiscard();

    try sel.concurrent(.a, tunnelStream, .{ client_r, &server_w, '<' });
    try sel.concurrent(.a, tunnelStream, .{ &server_r, client_w, '>' });

    _ = try sel.await();
    try srv.shutdown(self.io, .both);
}

fn tunnelStream(
    r: *std.Io.net.Stream.Reader,
    w: *std.Io.net.Stream.Writer,
    c: u8,
) std.Io.Cancelable!void {
    _tunnelStream(r, w, c) catch |err| {
        const e = switch (err) {
            std.Io.Reader.StreamError.ReadFailed => r.err,
            std.Io.Reader.StreamError.WriteFailed => w.err,
            std.Io.Reader.StreamError.EndOfStream => return error.Canceled,
        };
        if (e) |_e| {
            if (_e == error.Canceled) return error.Canceled;
        }

        log.err("tunneling: {c} {s} {?s}", .{
            c,
            @errorName(err),
            if (e) |_e| @errorName(_e) else null,
        });
    };

    log.debug("end {c}", .{c});
    return std.Io.Cancelable.Canceled;
}

fn _tunnelStream(
    r: *std.Io.net.Stream.Reader,
    w: *std.Io.net.Stream.Writer,
    c: u8,
) !void {
    _ = c;

    while (true) {
        _ = try r.interface.stream(&w.interface, .unlimited);
        try w.interface.flush();
    }
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

const ignore_resp_headers: []const []const u8 = &.{
    "Transfer-Encoding",
    "Content-Length",
};
