//! `raceWithDeadline`: la carrera exacta de `InvimaClient.getBounded`, ejercitada
//! sin red. `testing.allocator` detecta cualquier body no liberado.

const std = @import("std");
const testing = std.testing;
const client = @import("invima").client;

/// Duerme y luego devuelve un body propio del llamador. Si lo cancelan, el
/// sleep retorna temprano pero el body igual se produce — la carrera que el
/// drain debe cubrir.
fn slowBody(io: std.Io, allocator: std.mem.Allocator, sleep_ms: u64) anyerror![]u8 {
    io.sleep(.fromMilliseconds(std.math.lossyCast(i64, sleep_ms)), .awake) catch {};
    return allocator.dupe(u8, "body");
}

test "deadline wins: returns ConnectionTimedOut and frees the raced body" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const result = client.raceWithDeadline(
        io,
        testing.allocator,
        30,
        slowBody,
        .{ io, testing.allocator, 5000 },
    );
    try testing.expectError(error.ConnectionTimedOut, result);
    // If the drain failed to free the body slowBody produces after cancellation,
    // testing.allocator reports a leak when this test tears down.
}

test "work wins: returns the body" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const body = try client.raceWithDeadline(
        io,
        testing.allocator,
        5000,
        slowBody,
        .{ io, testing.allocator, 10 },
    );
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("body", body);
}
