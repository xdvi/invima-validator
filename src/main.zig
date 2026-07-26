const std = @import("std");
const build_options = @import("build_options");

pub const models = @import("models.zig");
pub const client = @import("client.zig");
pub const soql = @import("soql.zig");
pub const mapping = @import("mapping.zig");

const InvimaClient = client.InvimaClient;

const allocator = std.heap.c_allocator;

pub const InvimaClientHandle = struct {
    threaded: std.Io.Threaded,
    client: InvimaClient,
};

export fn invima_client_new(app_token: ?[*:0]const u8) ?*InvimaClientHandle {
    const token = if (app_token) |t| std.mem.span(t) else null;
    const handle = allocator.create(InvimaClientHandle) catch return null;

    handle.threaded = std.Io.Threaded.init(allocator, .{});
    const io = handle.threaded.io();

    handle.client = InvimaClient.init(allocator, io, token);
    return handle;
}

export fn invima_client_free(handle: ?*InvimaClientHandle) void {
    if (handle) |h| {
        h.client.deinit();
        h.threaded.deinit();
        allocator.destroy(h);
    }
}

export fn invima_search_medicines(
    handle: ?*const InvimaClientHandle,
    query_ptr: ?[*:0]const u8,
    status_ptr: ?[*:0]const u8,
    limit: usize,
    out_json: ?*?[*:0]u8,
) i32 {
    const h = handle orelse return -1;
    const q_ptr = query_ptr orelse return -1;
    const s_ptr = status_ptr orelse return -1;
    const out = out_json orelse return -1;

    const query = std.mem.span(q_ptr);
    const status_str = std.mem.span(s_ptr);

    const status = models.RegistrationStatus.parse(status_str) orelse {
        writeError(out, "estado de registro inválido") catch return -2;
        return -2;
    };

    const suggestions = h.client.searchMedicines(query, status, limit) catch |err| {
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };
    defer {
        for (suggestions) |s| {
            h.client.freeSuggestion(s);
        }
        allocator.free(suggestions);
    }

    return writeJsonResult(out, suggestions);
}

export fn invima_find_by_field(
    handle: ?*const InvimaClientHandle,
    field_ptr: ?[*:0]const u8,
    value_ptr: ?[*:0]const u8,
    status_ptr: ?[*:0]const u8,
    limit: usize,
    out_json: ?*?[*:0]u8,
) i32 {
    const h = handle orelse return -1;
    const f_ptr = field_ptr orelse return -1;
    const v_ptr = value_ptr orelse return -1;
    const s_ptr = status_ptr orelse return -1;
    const out = out_json orelse return -1;

    const field_str = std.mem.span(f_ptr);
    const value = std.mem.span(v_ptr);
    const status_str = std.mem.span(s_ptr);

    const field = models.FindField.parse(field_str) orelse {
        writeError(out, "campo de búsqueda inválido") catch return -2;
        return -2;
    };

    const status = models.RegistrationStatus.parse(status_str) orelse {
        writeError(out, "estado de registro inválido") catch return -2;
        return -2;
    };

    const suggestions = h.client.findByField(field, value, status, limit) catch |err| {
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };
    defer {
        for (suggestions) |s| {
            h.client.freeSuggestion(s);
        }
        allocator.free(suggestions);
    }

    return writeJsonResult(out, suggestions);
}

export fn invima_get_medicine_by_cum(
    handle: ?*const InvimaClientHandle,
    expediente_ptr: ?[*:0]const u8,
    consecutivo_cum_ptr: ?[*:0]const u8,
    cantidad_cum_ptr: ?[*:0]const u8,
    status_ptr: ?[*:0]const u8,
    out_json: ?*?[*:0]u8,
) i32 {
    const h = handle orelse return -1;
    const exp_ptr = expediente_ptr orelse return -1;
    const cons_ptr = consecutivo_cum_ptr orelse return -1;
    const cant_ptr = cantidad_cum_ptr orelse return -1;
    const s_ptr = status_ptr orelse return -1;
    const out = out_json orelse return -1;

    const expediente = std.mem.span(exp_ptr);
    const consecutivo = std.mem.span(cons_ptr);
    const cantidad = std.mem.span(cant_ptr);
    const status_str = std.mem.span(s_ptr);

    const status = models.RegistrationStatus.parse(status_str) orelse {
        writeError(out, "estado de registro inválido") catch return -2;
        return -2;
    };

    const medicine = h.client.getMedicineByCum(expediente, consecutivo, cantidad, status) catch |err| {
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };
    defer h.client.freeMedicine(medicine);

    return writeJsonResult(out, medicine);
}

export fn invima_search_tramites(
    handle: ?*const InvimaClientHandle,
    texto_ptr: ?[*:0]const u8,
    limit: usize,
    offset: usize,
    out_json: ?*?[*:0]u8,
) i32 {
    const h = handle orelse return -1;
    const out = out_json orelse return -1;

    const texto = if (texto_ptr) |t| std.mem.span(t) else null;

    const result = h.client.searchTramites(allocator, texto, limit, offset) catch |err| {
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };
    defer h.client.freeTramiteSearchResult(result);

    return writeJsonResult(out, result);
}

export fn invima_free_string(ptr: ?[*:0]u8) void {
    if (ptr) |p| {
        const len = std.mem.span(p).len;
        // La porción reservada en stringify o writeError tiene tamaño = len + 1 (incluyendo el byte nulo)
        const allocated_slice = p[0 .. len + 1];
        allocator.free(allocated_slice);
    }
}

const version_z: [:0]const u8 = build_options.version[0..build_options.version.len :0];

export fn invima_version() ?[*:0]const u8 {
    return version_z.ptr;
}

fn stringifyZ(value: anytype) ![:0]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try std.json.Stringify.value(value, .{}, &aw.writer);
    return aw.toOwnedSliceSentinel(0);
}

/// Serializa `value` en `out`. La cadena resultante se libera con `invima_free_string`.
fn writeJsonResult(out: *?[*:0]u8, value: anytype) i32 {
    const json = stringifyZ(value) catch |err| {
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };
    out.* = json.ptr;
    return 0;
}

fn writeError(out: *?[*:0]u8, message: []const u8) !void {
    const json = try std.fmt.allocPrintSentinel(allocator, "{{\"error\":\"{s}\"}}", .{message}, 0);
    out.* = json.ptr;
}
