//! Contrato del ABI C exportado, ejercitado vía `extern`.

const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");

const InvimaClientHandle = opaque {};

extern fn invima_client_new(app_token: ?[*:0]const u8) ?*InvimaClientHandle;
extern fn invima_client_free(handle: ?*InvimaClientHandle) void;
extern fn invima_search_medicines(
    handle: ?*const InvimaClientHandle,
    query_ptr: ?[*:0]const u8,
    status_ptr: ?[*:0]const u8,
    limit: usize,
    out_json: ?*?[*:0]u8,
) i32;
extern fn invima_find_by_field(
    handle: ?*const InvimaClientHandle,
    field_ptr: ?[*:0]const u8,
    value_ptr: ?[*:0]const u8,
    status_ptr: ?[*:0]const u8,
    limit: usize,
    out_json: ?*?[*:0]u8,
) i32;
extern fn invima_get_medicine_by_cum(
    handle: ?*const InvimaClientHandle,
    expediente_ptr: ?[*:0]const u8,
    consecutivo_cum_ptr: ?[*:0]const u8,
    cantidad_cum_ptr: ?[*:0]const u8,
    status_ptr: ?[*:0]const u8,
    out_json: ?*?[*:0]u8,
) i32;
extern fn invima_search_tramites(
    handle: ?*const InvimaClientHandle,
    texto_ptr: ?[*:0]const u8,
    limit: usize,
    offset: usize,
    out_json: ?*?[*:0]u8,
) i32;
extern fn invima_free_string(ptr: ?[*:0]u8) void;
extern fn invima_version() ?[*:0]const u8;

/// Comprueba que `out` quedó con un JSON `{"error": "..."}` y lo libera.
fn expectErrorJson(out: ?[*:0]u8) !void {
    const raw = out orelse return error.MissingErrorJson;
    defer invima_free_string(raw);

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        std.mem.span(raw),
        .{},
    );
    defer parsed.deinit();

    const message = parsed.value.object.get("error") orelse return error.MissingErrorField;
    try testing.expect(message == .string);
    try testing.expect(message.string.len > 0);
}

test "invima_version matches build.zig.zon version" {
    const v = invima_version() orelse return error.NullVersion;
    try testing.expectEqualStrings(build_options.version, std.mem.span(v));
}

test "free functions accept null" {
    invima_free_string(null);
    invima_client_free(null);
}

test "client handle roundtrip without app token" {
    const handle = invima_client_new(null) orelse return error.ClientNewFailed;
    invima_client_free(handle);
}

test "client handle roundtrip with app token" {
    const handle = invima_client_new("test-token") orelse return error.ClientNewFailed;
    invima_client_free(handle);
}

test "null handle returns -1" {
    var out: ?[*:0]u8 = null;
    try testing.expectEqual(-1, invima_search_medicines(null, "x", "vigente", 1, &out));
    try testing.expectEqual(-1, invima_find_by_field(null, "expediente", "x", "vigente", 1, &out));
    try testing.expectEqual(-1, invima_get_medicine_by_cum(null, "x", "1", "1", "vigente", &out));
    try testing.expectEqual(-1, invima_search_tramites(null, "x", 1, 0, &out));
    try testing.expectEqual(null, out);
}

test "null string arguments return -1" {
    const h = invima_client_new(null) orelse return error.ClientNewFailed;
    defer invima_client_free(h);

    var out: ?[*:0]u8 = null;

    try testing.expectEqual(-1, invima_search_medicines(h, null, "vigente", 1, &out));
    try testing.expectEqual(-1, invima_search_medicines(h, "x", null, 1, &out));

    try testing.expectEqual(-1, invima_find_by_field(h, null, "x", "vigente", 1, &out));
    try testing.expectEqual(-1, invima_find_by_field(h, "expediente", null, "vigente", 1, &out));
    try testing.expectEqual(-1, invima_find_by_field(h, "expediente", "x", null, 1, &out));

    try testing.expectEqual(-1, invima_get_medicine_by_cum(h, null, "1", "1", "vigente", &out));
    try testing.expectEqual(-1, invima_get_medicine_by_cum(h, "x", null, "1", "vigente", &out));
    try testing.expectEqual(-1, invima_get_medicine_by_cum(h, "x", "1", null, "vigente", &out));
    try testing.expectEqual(-1, invima_get_medicine_by_cum(h, "x", "1", "1", null, &out));

    try testing.expectEqual(null, out);
}

test "null out_json returns -1" {
    const h = invima_client_new(null) orelse return error.ClientNewFailed;
    defer invima_client_free(h);

    try testing.expectEqual(-1, invima_search_medicines(h, "x", "vigente", 1, null));
    try testing.expectEqual(-1, invima_find_by_field(h, "expediente", "x", "vigente", 1, null));
    try testing.expectEqual(-1, invima_get_medicine_by_cum(h, "x", "1", "1", "vigente", null));
    try testing.expectEqual(-1, invima_search_tramites(h, "x", 1, 0, null));
}

test "invalid status returns -2 with error JSON" {
    const h = invima_client_new(null) orelse return error.ClientNewFailed;
    defer invima_client_free(h);

    var out: ?[*:0]u8 = null;
    try testing.expectEqual(-2, invima_search_medicines(h, "acetaminofen", "no-existe", 1, &out));
    try expectErrorJson(out);

    out = null;
    try testing.expectEqual(-2, invima_find_by_field(h, "expediente", "1", "no-existe", 1, &out));
    try expectErrorJson(out);

    out = null;
    try testing.expectEqual(-2, invima_get_medicine_by_cum(h, "1", "1", "1", "no-existe", &out));
    try expectErrorJson(out);
}

test "invalid find field returns -2 with error JSON" {
    const h = invima_client_new(null) orelse return error.ClientNewFailed;
    defer invima_client_free(h);

    var out: ?[*:0]u8 = null;
    try testing.expectEqual(-2, invima_find_by_field(h, "no-existe", "1", "vigente", 1, &out));
    try expectErrorJson(out);
}
