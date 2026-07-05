const std = @import("std");
const models = @import("models.zig");
const client_mod = @import("client.zig");
const InvimaClient = client_mod.InvimaClient;

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

    var string_list: std.ArrayList(u8) = .empty;
    errdefer string_list.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &string_list);
    errdefer string_list = aw.toArrayList();

    std.json.Stringify.value(suggestions, .{}, &aw.writer) catch |err| {
        string_list = aw.toArrayList();
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };

    string_list = aw.toArrayList();
    string_list.append(allocator, 0) catch return -2;

    const slice = string_list.toOwnedSlice(allocator) catch return -2;
    out.* = @ptrCast(slice.ptr);
    return 0;
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

    var string_list: std.ArrayList(u8) = .empty;
    errdefer string_list.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &string_list);
    errdefer string_list = aw.toArrayList();

    std.json.Stringify.value(medicine, .{}, &aw.writer) catch |err| {
        string_list = aw.toArrayList();
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };

    string_list = aw.toArrayList();
    string_list.append(allocator, 0) catch return -2;

    const slice = string_list.toOwnedSlice(allocator) catch return -2;
    out.* = @ptrCast(slice.ptr);
    return 0;
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

    var string_list: std.ArrayList(u8) = .empty;
    errdefer string_list.deinit(allocator);

    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, &string_list);
    errdefer string_list = aw.toArrayList();

    std.json.Stringify.value(result, .{}, &aw.writer) catch |err| {
        string_list = aw.toArrayList();
        writeError(out, @errorName(err)) catch return -2;
        return -2;
    };

    string_list = aw.toArrayList();
    string_list.append(allocator, 0) catch return -2;

    const slice = string_list.toOwnedSlice(allocator) catch return -2;
    out.* = @ptrCast(slice.ptr);
    return 0;
}

export fn invima_free_string(ptr: ?[*:0]u8) void {
    if (ptr) |p| {
        const len = std.mem.span(p).len;
        // La porción reservada en stringify o writeError tiene tamaño = len + 1 (incluyendo el byte nulo)
        const allocated_slice = p[0 .. len + 1];
        allocator.free(allocated_slice);
    }
}

export fn invima_version() ?[*:0]const u8 {
    return "0.1.0-zig-beta";
}

fn writeError(out: *?[*:0]u8, message: []const u8) !void {
    const json = try std.fmt.allocPrintSentinel(allocator, "{{\"error\":\"{s}\"}}", .{message}, 0);
    out.* = json.ptr;
}
