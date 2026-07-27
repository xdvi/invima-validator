//! El mecanismo de deadline: `std.Io.Select` devuelve el brazo más rápido y
//! cancela el lento. Es la carrera exacta que usa `InvimaClient.getBounded`.

const std = @import("std");
const testing = std.testing;

fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(.fromMilliseconds(std.math.lossyCast(i64, ms)), .awake) catch {};
}

test "select yields the earlier arm and cancels the slower one" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const Outcome = union(enum) { slow: void, fast: void };
    var slots: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &slots);

    select.concurrent(.slow, sleepMs, .{ io, 5000 }) catch return error.SkipZigTest;
    select.concurrent(.fast, sleepMs, .{ io, 50 }) catch return error.SkipZigTest;

    const started = std.Io.Clock.now(.awake, io);
    const first = try select.await();
    while (select.cancel()) |_| {}
    const elapsed = std.Io.Clock.now(.awake, io).durationTo(started).toNanoseconds();
    const elapsed_ms = @abs(elapsed) / std.time.ns_per_ms;

    try testing.expect(first == .fast);
    // The 5s arm must have been cancelled, not awaited.
    try testing.expect(elapsed_ms < 2000);
}
