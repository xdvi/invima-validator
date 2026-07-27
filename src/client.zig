const std = @import("std");
pub const models = @import("models.zig");
pub const error_mod = @import("error.zig");
pub const soql = @import("soql.zig");
pub const mapping = @import("mapping.zig");
const InvimaError = error_mod.InvimaError;

const BASE_URL = "https://www.datos.gov.co/resource";
const SUIT_DATASET_ID = "48fq-mxnm";
const INVIMA_ENTITY = "INSTITUTO NACIONAL DE VIGILANCIA DE MEDICAMENTOS Y ALIMENTOS";

/// The upstream AWS NLB resets fresh TCP connections in bursts (~29% in a bad
/// window); std.http.Client reports this as `TlsInitializationFailed`. A reset
/// arrives before any request is sent, so retrying is safe; eight attempts with
/// linear backoff (~7s total) ride out a burst. It never reaches zero — the
/// reset is server-side — but drops it far below what a caller would notice.
const connect_attempts = 8;
const retry_backoff_ms = 250;
/// A stalled connection would otherwise block the caller forever; std.http.Client
/// exposes no request timeout, so each attempt races against a deadline.
const default_timeout_ms = 30_000;

/// Errors worth another attempt: the connection never carried a response, so
/// retrying cannot duplicate a side effect. These reads are idempotent anyway.
pub fn isTransient(err: anyerror) bool {
    return switch (err) {
        error.TlsInitializationFailed,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.NetworkUnreachable,
        error.HostLacksNetworkAddresses,
        error.UnknownHostName,
        => true,
        else => false,
    };
}

fn deadlineArm(io: std.Io, ms: u64) void {
    io.sleep(.fromMilliseconds(std.math.lossyCast(i64, ms)), .awake) catch {};
}

/// Cancels the losing arm and frees a body that completed in a race with the deadline.
fn drainSelect(select: anytype, allocator: std.mem.Allocator) void {
    while (select.cancel()) |leftover| {
        switch (leftover) {
            .fetch => |body| if (body) |slice| allocator.free(slice) else |_| {},
            .deadline => {},
        }
    }
}

/// Runs `work(args)` against a deadline. Returns `error.ConnectionTimedOut` if the
/// deadline wins; the work's body, if it completes in the race, is freed by the drain.
/// Falls back to running `work` unbounded if concurrency is unavailable.
pub fn raceWithDeadline(
    io: std.Io,
    allocator: std.mem.Allocator,
    timeout_ms: u64,
    comptime work: anytype,
    args: anytype,
) anyerror![]u8 {
    const Outcome = union(enum) { fetch: anyerror![]u8, deadline: void };
    var slots: [2]Outcome = undefined;
    var select = std.Io.Select(Outcome).init(io, &slots);

    // The deadline is armed first: without it there is no bound, so fall back to
    // a plain call rather than run the fetch arm with nothing to cut it.
    select.concurrent(.deadline, deadlineArm, .{ io, timeout_ms }) catch {
        return @call(.auto, work, args);
    };
    select.concurrent(.fetch, work, args) catch {
        drainSelect(&select, allocator);
        return @call(.auto, work, args);
    };

    const first = select.await() catch |err| {
        drainSelect(&select, allocator);
        return err;
    };
    drainSelect(&select, allocator);

    return switch (first) {
        .fetch => |body| body,
        .deadline => error.ConnectionTimedOut,
    };
}

pub const InvimaClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    app_token: ?[]const u8,
    /// Heap-allocated so `*const InvimaClient` can still reuse its connection pool.
    http: ?*std.http.Client,
    timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, app_token: ?[]const u8) InvimaClient {
        const token_copy = if (app_token) |t| allocator.dupe(u8, t) catch null else null;
        const http = allocator.create(std.http.Client) catch null;
        if (http) |h| h.* = .{ .allocator = allocator, .io = io };
        return .{
            .allocator = allocator,
            .io = io,
            .app_token = token_copy,
            .http = http,
            .timeout_ms = default_timeout_ms,
        };
    }

    pub fn deinit(self: *InvimaClient) void {
        if (self.app_token) |token| {
            self.allocator.free(token);
        }
        if (self.http) |h| {
            h.deinit();
            self.allocator.destroy(h);
        }
    }

    fn get(self: *const InvimaClient, url: []const u8) ![]u8 {
        var attempt: usize = 0;
        while (true) {
            return self.getBounded(url) catch |err| {
                attempt += 1;
                if (attempt >= connect_attempts or !isTransient(err)) return err;
                // A failed or timed-out handshake can leave a poisoned pooled connection behind.
                self.resetPool();
                self.io.sleep(.fromMilliseconds(retry_backoff_ms * @as(i64, @intCast(attempt))), .awake) catch {};
                continue;
            };
        }
    }

    /// Runs one fetch against a deadline. `error.ConnectionTimedOut` (transient,
    /// so `get` retries it) is returned if the deadline wins the race.
    fn getBounded(self: *const InvimaClient, url: []const u8) ![]u8 {
        return raceWithDeadline(self.io, self.allocator, self.timeout_ms, fetchErased, .{ self, url });
    }

    fn fetchErased(self: *const InvimaClient, url: []const u8) anyerror![]u8 {
        return self.getOnce(url);
    }

    fn resetPool(self: *const InvimaClient) void {
        const h = self.http orelse return;
        h.deinit();
        h.* = .{ .allocator = self.allocator, .io = self.io };
    }

    fn getOnce(self: *const InvimaClient, url: []const u8) ![]u8 {
        const client = self.http orelse return error.OutOfMemory;

        const uri = try std.Uri.parse(url);

        var headers: std.ArrayList(std.http.Header) = .empty;
        defer headers.deinit(self.allocator);

        try headers.append(self.allocator, .{ .name = "Accept", .value = "application/json" });
        if (self.app_token) |token| {
            try headers.append(self.allocator, .{ .name = "X-App-Token", .value = token });
        }

        var req = try client.request(.GET, uri, .{
            .extra_headers = headers.items,
            .headers = .{
                .accept_encoding = .omit,
            },
        });
        defer req.deinit();

        try req.sendBodiless();

        var redirect_buffer: [1024]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);

        if (response.head.status != .ok) {
            return error.HttpRequestFailed;
        }

        var transfer_buffer: [4096]u8 = undefined;
        var r = response.reader(&transfer_buffer);

        var body_buffer: std.ArrayList(u8) = .empty;
        errdefer body_buffer.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const read = try r.readSliceShort(&buf);
            if (read == 0) break;
            try body_buffer.appendSlice(self.allocator, buf[0..read]);
        }

        return body_buffer.toOwnedSlice(self.allocator);
    }

    pub fn searchMedicines(
        self: *const InvimaClient,
        query: []const u8,
        status: models.RegistrationStatus,
        limit: usize,
    ) ![]models.MedicineSuggestion {
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidStatus;

        const escaped = try soql.escapeSoqlString(self.allocator, trimmed);
        defer self.allocator.free(escaped);

        const stmt = try std.fmt.allocPrint(self.allocator, "SELECT * ORDER BY `:id` ASC NULL LAST SEARCH \"{s}\" LIMIT {d} OFFSET 0", .{ escaped, limit });
        defer self.allocator.free(stmt);

        return self.suggestionsFromSoql(status, stmt);
    }

    /// Búsqueda exacta por columna. Un slice vacío significa sin coincidencias, no error.
    pub fn findByField(
        self: *const InvimaClient,
        field: models.FindField,
        value: []const u8,
        status: models.RegistrationStatus,
        limit: usize,
    ) ![]models.MedicineSuggestion {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidStatus;
        if (!soql.isFindValueQueryable(field, trimmed)) return self.allocator.alloc(models.MedicineSuggestion, 0);

        const stmt = try soql.buildFindSoql(self.allocator, field, trimmed, soql.normalizeFindLimit(limit));
        defer self.allocator.free(stmt);

        return self.suggestionsFromSoql(status, stmt);
    }

    fn suggestionsFromSoql(
        self: *const InvimaClient,
        status: models.RegistrationStatus,
        stmt: []const u8,
    ) ![]models.MedicineSuggestion {
        const medicines = try self.stmtCumDataset(status, stmt);
        defer {
            for (medicines) |m| {
                // Free the parsed models
                self.freeMedicine(m);
            }
            self.allocator.free(medicines);
        }

        return mapping.toSuggestions(self.allocator, medicines);
    }

    pub fn getMedicineByCum(
        self: *const InvimaClient,
        expediente: []const u8,
        consecutivo_cum: []const u8,
        cantidad_cum: []const u8,
        status: models.RegistrationStatus,
    ) !models.Medicine {
        const esc_exp = try soql.escapeSoqlString(self.allocator, expediente);
        defer self.allocator.free(esc_exp);
        const esc_cant = try soql.escapeSoqlString(self.allocator, cantidad_cum);
        defer self.allocator.free(esc_cant);

        // We assume consecutivo_cum is simple number/string, escape as safety
        const esc_cons = try soql.escapeSoqlString(self.allocator, consecutivo_cum);
        defer self.allocator.free(esc_cons);

        const stmt = try std.fmt.allocPrint(self.allocator, "SELECT * WHERE `expediente` = '{s}' AND `consecutivocum` = {s} AND `cantidadcum` = '{s}'", .{ esc_exp, esc_cons, esc_cant });
        defer self.allocator.free(stmt);

        const medicines = try self.stmtCumDataset(status, stmt);
        if (medicines.len == 0) {
            self.allocator.free(medicines);
            return error.InvalidHttpResponse;
        }

        const match = medicines[0];
        // Free the rest of the slice but keep the matched one
        for (medicines[1..]) |m| {
            self.freeMedicine(m);
        }
        self.allocator.free(medicines);

        return match;
    }

    fn stmtCumDataset(self: *const InvimaClient, status: models.RegistrationStatus, stmt: []const u8) ![]models.Medicine {
        const encoded = try soql.urlEncode(self.allocator, stmt);
        defer self.allocator.free(encoded);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/{s}.json?$query={s}", .{ BASE_URL, status.datasetId(), encoded });
        defer self.allocator.free(url);

        const body = try self.get(url);
        defer self.allocator.free(body);

        return parseMedicines(self.allocator, body);
    }

    pub fn freeMedicine(self: *const InvimaClient, m: models.Medicine) void {
        freeMedicineWith(self.allocator, m);
    }

    pub fn freeSuggestion(self: *const InvimaClient, s: models.MedicineSuggestion) void {
        mapping.freeSuggestion(self.allocator, s);
    }

    fn querySuit(
        self: *const InvimaClient,
        allocator: std.mem.Allocator,
        select: ?[]const u8,
        where_clause: ?[]const u8,
        group: ?[]const u8,
        order: ?[]const u8,
        limit: usize,
        offset: usize,
    ) ![]std.json.Value {
        var query_params: std.ArrayList(u8) = .empty;
        defer query_params.deinit(allocator);

        try query_params.print(allocator, "$limit={}&$offset={}", .{ limit, offset });

        if (select) |s| {
            const escaped = try soql.urlEncode(allocator, s);
            defer allocator.free(escaped);
            try query_params.print(allocator, "&$select={s}", .{escaped});
        }
        if (where_clause) |w| {
            const escaped = try soql.urlEncode(allocator, w);
            defer allocator.free(escaped);
            try query_params.print(allocator, "&$where={s}", .{escaped});
        }
        if (group) |g| {
            const escaped = try soql.urlEncode(allocator, g);
            defer allocator.free(escaped);
            try query_params.print(allocator, "&$group={s}", .{escaped});
        }
        if (order) |o| {
            const escaped = try soql.urlEncode(allocator, o);
            defer allocator.free(escaped);
            try query_params.print(allocator, "&$order={s}", .{escaped});
        }

        const url = try std.fmt.allocPrint(allocator, "{s}/{s}.json?{s}", .{ BASE_URL, SUIT_DATASET_ID, query_params.items });
        defer allocator.free(url);

        const body = try self.get(url);
        defer allocator.free(body);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const root_val = parsed.value;
        if (root_val != .array) return error.InvalidJsonResponse;

        // Clone the JSON array values to survive parsed.deinit()
        var cloned_list: std.ArrayList(std.json.Value) = .empty;
        errdefer {
            for (cloned_list.items) |v| freeJsonValue(allocator, v);
            cloned_list.deinit(allocator);
        }

        for (root_val.array.items) |item| {
            try cloned_list.append(allocator, try cloneJsonValue(allocator, item));
        }

        return cloned_list.toOwnedSlice(allocator);
    }

    fn countDistinctTramites(self: *const InvimaClient, allocator: std.mem.Allocator, where_clause: []const u8) !usize {
        const rows = try self.querySuit(
            allocator,
            "count(distinct n_mero_unico) as total",
            where_clause,
            null,
            null,
            1,
            0,
        );
        defer {
            for (rows) |row| freeJsonValue(allocator, row);
            allocator.free(rows);
        }

        if (rows.len == 0) return 0;
        const first_row = rows[0];
        if (first_row != .object) return 0;

        const total_val = first_row.object.get("total") orelse return 0;
        if (total_val != .string) return 0;

        return std.fmt.parseInt(usize, total_val.string, 10) catch 0;
    }

    fn fetchTramitePasos(
        self: *const InvimaClient,
        allocator: std.mem.Allocator,
        base_where: []const u8,
        numero_unicos: []const []const u8,
    ) !std.StringHashMap([]models.TramitePaso) {
        var map = std.StringHashMap([]models.TramitePaso).init(allocator);
        errdefer {
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.*) |paso| {
                    if (paso.orden_paso) |s| allocator.free(s);
                    if (paso.descripcion_paso) |s| allocator.free(s);
                    if (paso.orden_condicion) |s| allocator.free(s);
                    if (paso.tipo_accion_condicion) |s| allocator.free(s);
                    if (paso.documento_nombre) |s| allocator.free(s);
                    if (paso.documento_tipo) |s| allocator.free(s);
                    if (paso.descripcion_del_pago) |s| allocator.free(s);
                }
                allocator.free(entry.value_ptr.*);
            }
            map.deinit();
        }

        if (numero_unicos.len == 0) return map;

        var ids_buf: std.ArrayList(u8) = .empty;
        defer ids_buf.deinit(allocator);

        for (numero_unicos, 0..) |id, idx| {
            if (idx > 0) try ids_buf.appendSlice(allocator, ", ");
            const escaped = try soql.escapeSqlString(allocator, id);
            defer allocator.free(escaped);
            try ids_buf.print(allocator, "'{s}'", .{escaped});
        }

        const query_where = try std.fmt.allocPrint(allocator, "{s} AND n_mero_unico in ({s})", .{ base_where, ids_buf.items });
        defer allocator.free(query_where);

        const select = "n_mero_unico, orden_paso, descripcion_paso, orden_condicion, tipo_accion_condicion, documento_nombre, documento_tipo, descripcion_del_pago";

        const rows = try self.querySuit(
            allocator,
            select,
            query_where,
            null,
            "n_mero_unico, orden_paso, orden_condicion",
            numero_unicos.len * 50,
            0,
        );
        defer {
            for (rows) |row| freeJsonValue(allocator, row);
            allocator.free(rows);
        }

        var temp_map = std.StringHashMap(std.ArrayList(models.TramitePaso)).init(allocator);
        errdefer {
            var it = temp_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.items) |paso| {
                    if (paso.orden_paso) |s| allocator.free(s);
                    if (paso.descripcion_paso) |s| allocator.free(s);
                    if (paso.orden_condicion) |s| allocator.free(s);
                    if (paso.tipo_accion_condicion) |s| allocator.free(s);
                    if (paso.documento_nombre) |s| allocator.free(s);
                    if (paso.documento_tipo) |s| allocator.free(s);
                    if (paso.descripcion_del_pago) |s| allocator.free(s);
                }
                entry.value_ptr.deinit(allocator);
            }
            temp_map.deinit();
        }

        for (rows) |row| {
            if (row != .object) continue;
            const num_val = row.object.get("n_mero_unico") orelse continue;
            if (num_val != .string) continue;

            const num_str = num_val.string;

            var gpr = try temp_map.getOrPut(num_str);
            if (!gpr.found_existing) {
                gpr.key_ptr.* = try allocator.dupe(u8, num_str);
                gpr.value_ptr.* = .empty;
            }

            const getStr = struct {
                fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
                    if (obj.get(key)) |val| {
                        if (val == .string) return val.string;
                    }
                    return null;
                }
            }.getStr;

            const paso = models.TramitePaso{
                .orden_paso = try cleanValue(allocator, getStr(row.object, "orden_paso")),
                .descripcion_paso = try cleanValue(allocator, getStr(row.object, "descripcion_paso")),
                .orden_condicion = try cleanValue(allocator, getStr(row.object, "orden_condicion")),
                .tipo_accion_condicion = try cleanValue(allocator, getStr(row.object, "tipo_accion_condicion")),
                .documento_nombre = try cleanValue(allocator, getStr(row.object, "documento_nombre")),
                .documento_tipo = try cleanValue(allocator, getStr(row.object, "documento_tipo")),
                .descripcion_del_pago = try cleanValue(allocator, getStr(row.object, "descripcion_del_pago")),
            };

            try gpr.value_ptr.append(allocator, paso);
        }

        var it = temp_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            var list = entry.value_ptr.*;
            const steps_slice = try list.toOwnedSlice(allocator);
            try map.put(key, steps_slice);
        }

        temp_map.deinit();

        return map;
    }

    pub fn searchTramites(
        self: *const InvimaClient,
        allocator: std.mem.Allocator,
        texto: ?[]const u8,
        limit: usize,
        offset: usize,
    ) !models.TramiteSearchResult {
        const where_clause = try buildSuitWhereClause(allocator, texto);
        defer allocator.free(where_clause);

        const total = try self.countDistinctTramites(allocator, where_clause);

        const select = "n_mero_unico, max(nombre_del_tr_mite_u_otro) as nombre_tramite, max(nombre_com_n) as nombre_comun, max(prop_sito_del_tr_mite_u_otro) as proposito, max(nombre_resultado) as resultado, max(clase) as clase_tramite, max(fecha_de_actualizaci_n) as fecha_actualizacion";

        const rows = try self.querySuit(
            allocator,
            select,
            where_clause,
            "n_mero_unico",
            "nombre_tramite ASC",
            limit,
            offset,
        );
        defer {
            for (rows) |row| freeJsonValue(allocator, row);
            allocator.free(rows);
        }

        var ids: std.ArrayList([]const u8) = .empty;
        defer ids.deinit(allocator);

        for (rows) |row| {
            if (row != .object) continue;
            if (row.object.get("n_mero_unico")) |num_val| {
                if (num_val == .string) {
                    try ids.append(allocator, num_val.string);
                }
            }
        }

        var pasos_map = try self.fetchTramitePasos(allocator, where_clause, ids.items);
        defer {
            var it = pasos_map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                for (entry.value_ptr.*) |paso| {
                    if (paso.orden_paso) |s| allocator.free(s);
                    if (paso.descripcion_paso) |s| allocator.free(s);
                    if (paso.orden_condicion) |s| allocator.free(s);
                    if (paso.tipo_accion_condicion) |s| allocator.free(s);
                    if (paso.documento_nombre) |s| allocator.free(s);
                    if (paso.documento_tipo) |s| allocator.free(s);
                    if (paso.descripcion_del_pago) |s| allocator.free(s);
                }
                allocator.free(entry.value_ptr.*);
            }
            pasos_map.deinit();
        }

        var tramites_list: std.ArrayList(models.TramiteSuit) = .empty;
        errdefer {
            for (tramites_list.items) |t| {
                if (t.numero_unico) |s| allocator.free(s);
                if (t.nombre_tramite) |s| allocator.free(s);
                if (t.nombre_comun) |s| allocator.free(s);
                if (t.proposito) |s| allocator.free(s);
                if (t.nombre_resultado) |s| allocator.free(s);
                if (t.clase) |s| allocator.free(s);
                allocator.free(t.entidad);
                if (t.fecha_actualizacion) |s| allocator.free(s);
                for (t.categorias) |cat| allocator.free(cat);
                allocator.free(t.categorias);
                for (t.pasos) |paso| {
                    if (paso.orden_paso) |s| allocator.free(s);
                    if (paso.descripcion_paso) |s| allocator.free(s);
                    if (paso.orden_condicion) |s| allocator.free(s);
                    if (paso.tipo_accion_condicion) |s| allocator.free(s);
                    if (paso.documento_nombre) |s| allocator.free(s);
                    if (paso.documento_tipo) |s| allocator.free(s);
                    if (paso.descripcion_del_pago) |s| allocator.free(s);
                }
                allocator.free(t.pasos);
            }
            tramites_list.deinit(allocator);
        }

        for (rows) |row| {
            if (row != .object) continue;

            const getStr = struct {
                fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
                    if (obj.get(key)) |val| {
                        if (val == .string) return val.string;
                    }
                    return null;
                }
            }.getStr;

            const raw_num = getStr(row.object, "n_mero_unico");
            const raw_nom = getStr(row.object, "nombre_tramite");
            const raw_com = getStr(row.object, "nombre_comun");
            const raw_prop = getStr(row.object, "proposito");
            const raw_res = getStr(row.object, "resultado");
            const raw_clase = getStr(row.object, "clase_tramite");
            const raw_fecha = getStr(row.object, "fecha_actualizacion");

            const clean_num = try cleanValue(allocator, raw_num);
            errdefer if (clean_num) |s| allocator.free(s);
            const clean_nom = try cleanValue(allocator, raw_nom);
            errdefer if (clean_nom) |s| allocator.free(s);
            const clean_com = try cleanValue(allocator, raw_com);
            errdefer if (clean_com) |s| allocator.free(s);
            const clean_prop = try cleanValue(allocator, raw_prop);
            errdefer if (clean_prop) |s| allocator.free(s);
            const clean_res = try cleanValue(allocator, raw_res);
            errdefer if (clean_res) |s| allocator.free(s);
            const clean_clase = try cleanValue(allocator, raw_clase);
            errdefer if (clean_clase) |s| allocator.free(s);
            const clean_fecha = try formatDate(allocator, raw_fecha);
            errdefer if (clean_fecha) |s| allocator.free(s);

            const categories = try detectCategories(allocator, clean_nom, clean_com, clean_prop);
            errdefer {
                for (categories) |cat| allocator.free(cat);
                allocator.free(categories);
            }

            var steps_slice: []models.TramitePaso = &.{};
            if (clean_num) |num| {
                if (pasos_map.get(num)) |steps| {
                    var cloned_steps = try std.ArrayList(models.TramitePaso).initCapacity(allocator, steps.len);
                    errdefer {
                        for (cloned_steps.items) |p| {
                            if (p.orden_paso) |s| allocator.free(s);
                            if (p.descripcion_paso) |s| allocator.free(s);
                            if (p.orden_condicion) |s| allocator.free(s);
                            if (p.tipo_accion_condicion) |s| allocator.free(s);
                            if (p.documento_nombre) |s| allocator.free(s);
                            if (p.documento_tipo) |s| allocator.free(s);
                            if (p.descripcion_del_pago) |s| allocator.free(s);
                        }
                        cloned_steps.deinit(allocator);
                    }
                    for (steps) |step| {
                        try cloned_steps.append(allocator, .{
                            .orden_paso = if (step.orden_paso) |s| try allocator.dupe(u8, s) else null,
                            .descripcion_paso = if (step.descripcion_paso) |s| try allocator.dupe(u8, s) else null,
                            .orden_condicion = if (step.orden_condicion) |s| try allocator.dupe(u8, s) else null,
                            .tipo_accion_condicion = if (step.tipo_accion_condicion) |s| try allocator.dupe(u8, s) else null,
                            .documento_nombre = if (step.documento_nombre) |s| try allocator.dupe(u8, s) else null,
                            .documento_tipo = if (step.documento_tipo) |s| try allocator.dupe(u8, s) else null,
                            .descripcion_del_pago = if (step.descripcion_del_pago) |s| try allocator.dupe(u8, s) else null,
                        });
                    }
                    steps_slice = try cloned_steps.toOwnedSlice(allocator);
                }
            }
            errdefer {
                for (steps_slice) |p| {
                    if (p.orden_paso) |s| allocator.free(s);
                    if (p.descripcion_paso) |s| allocator.free(s);
                    if (p.orden_condicion) |s| allocator.free(s);
                    if (p.tipo_accion_condicion) |s| allocator.free(s);
                    if (p.documento_nombre) |s| allocator.free(s);
                    if (p.documento_tipo) |s| allocator.free(s);
                    if (p.descripcion_del_pago) |s| allocator.free(s);
                }
                allocator.free(steps_slice);
            }

            const tramite = models.TramiteSuit{
                .numero_unico = clean_num,
                .nombre_tramite = clean_nom,
                .nombre_comun = clean_com,
                .proposito = clean_prop,
                .nombre_resultado = clean_res,
                .clase = clean_clase,
                .entidad = try allocator.dupe(u8, "INSTITUTO NACIONAL DE VIGILANCIA DE MEDICAMENTOS Y ALIMENTOS - INVIMA"),
                .fecha_actualizacion = clean_fecha,
                .categorias = categories,
                .pasos = steps_slice,
            };

            try tramites_list.append(allocator, tramite);
        }

        return .{
            .total = total,
            .limit = limit,
            .offset = offset,
            .tramites = try tramites_list.toOwnedSlice(allocator),
        };
    }

    pub fn freeTramiteSearchResult(self: *const InvimaClient, result: models.TramiteSearchResult) void {
        for (result.tramites) |t| {
            if (t.numero_unico) |s| self.allocator.free(s);
            if (t.nombre_tramite) |s| self.allocator.free(s);
            if (t.nombre_comun) |s| self.allocator.free(s);
            if (t.proposito) |s| self.allocator.free(s);
            if (t.nombre_resultado) |s| self.allocator.free(s);
            if (t.clase) |s| self.allocator.free(s);
            self.allocator.free(t.entidad);
            if (t.fecha_actualizacion) |s| self.allocator.free(s);
            for (t.categorias) |cat| self.allocator.free(cat);
            self.allocator.free(t.categorias);
            for (t.pasos) |paso| {
                if (paso.orden_paso) |s| self.allocator.free(s);
                if (paso.descripcion_paso) |s| self.allocator.free(s);
                if (paso.orden_condicion) |s| self.allocator.free(s);
                if (paso.tipo_accion_condicion) |s| self.allocator.free(s);
                if (paso.documento_nombre) |s| self.allocator.free(s);
                if (paso.documento_tipo) |s| self.allocator.free(s);
                if (paso.descripcion_del_pago) |s| self.allocator.free(s);
            }
            self.allocator.free(t.pasos);
        }
        self.allocator.free(result.tramites);
    }
};

/// Decodifica una respuesta Socrata; cada elemento se libera con `freeMedicineWith`.
pub fn parseMedicines(allocator: std.mem.Allocator, body: []const u8) ![]models.Medicine {
    const parsed = try std.json.parseFromSlice([]models.Medicine, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var list: std.ArrayList(models.Medicine) = .empty;
    errdefer {
        for (list.items) |item| freeMedicineWith(allocator, item);
        list.deinit(allocator);
    }

    for (parsed.value) |m| {
        var copy = models.Medicine{
            .expediente = if (m.expediente) |v| try allocator.dupe(u8, v) else null,
            .producto = if (m.producto) |v| try allocator.dupe(u8, v) else null,
            .titular = if (m.titular) |v| try allocator.dupe(u8, v) else null,
            .registrosanitario = if (m.registrosanitario) |v| try allocator.dupe(u8, v) else null,
            .fechaexpedicion = if (m.fechaexpedicion) |v| try allocator.dupe(u8, v) else null,
            .fechavencimiento = if (m.fechavencimiento) |v| try allocator.dupe(u8, v) else null,
            .estadoregistro = if (m.estadoregistro) |v| try allocator.dupe(u8, v) else null,
            .expedientecum = if (m.expedientecum) |v| try allocator.dupe(u8, v) else null,
            .consecutivocum = if (m.consecutivocum) |v| try allocator.dupe(u8, v) else null,
            .cantidadcum = if (m.cantidadcum) |v| try allocator.dupe(u8, v) else null,
            .descripcioncomercial = if (m.descripcioncomercial) |v| try allocator.dupe(u8, v) else null,
            .estadocum = if (m.estadocum) |v| try allocator.dupe(u8, v) else null,
            .fechaactivo = if (m.fechaactivo) |v| try allocator.dupe(u8, v) else null,
            .fechainactivo = if (m.fechainactivo) |v| try allocator.dupe(u8, v) else null,
            .muestramedica = if (m.muestramedica) |v| try allocator.dupe(u8, v) else null,
            .unidad = if (m.unidad) |v| try allocator.dupe(u8, v) else null,
            .atc = if (m.atc) |v| try allocator.dupe(u8, v) else null,
            .descripcionatc = if (m.descripcionatc) |v| try allocator.dupe(u8, v) else null,
            .viaadministracion = if (m.viaadministracion) |v| try allocator.dupe(u8, v) else null,
            .concentracion = if (m.concentracion) |v| try allocator.dupe(u8, v) else null,
            .principioactivo = if (m.principioactivo) |v| try allocator.dupe(u8, v) else null,
            .unidadmedida = if (m.unidadmedida) |v| try allocator.dupe(u8, v) else null,
            .unidadreferencia = if (m.unidadreferencia) |v| try allocator.dupe(u8, v) else null,
            .formafarmaceutica = if (m.formafarmaceutica) |v| try allocator.dupe(u8, v) else null,
            .nombrerol = if (m.nombrerol) |v| try allocator.dupe(u8, v) else null,
            .tiporol = if (m.tiporol) |v| try allocator.dupe(u8, v) else null,
            .modalidad = if (m.modalidad) |v| try allocator.dupe(u8, v) else null,
            .ium = if (m.ium) |v| try allocator.dupe(u8, v) else null,
        };
        if (m.cantidad) |val| {
            copy.cantidad = try cloneJsonValue(allocator, val);
        }
        errdefer freeMedicineWith(allocator, copy);
        try list.append(allocator, copy);
    }

    return list.toOwnedSlice(allocator);
}

pub fn freeMedicineWith(allocator: std.mem.Allocator, m: models.Medicine) void {
    if (m.expediente) |v| allocator.free(v);
    if (m.producto) |v| allocator.free(v);
    if (m.titular) |v| allocator.free(v);
    if (m.registrosanitario) |v| allocator.free(v);
    if (m.fechaexpedicion) |v| allocator.free(v);
    if (m.fechavencimiento) |v| allocator.free(v);
    if (m.estadoregistro) |v| allocator.free(v);
    if (m.expedientecum) |v| allocator.free(v);
    if (m.consecutivocum) |v| allocator.free(v);
    if (m.cantidadcum) |v| allocator.free(v);
    if (m.descripcioncomercial) |v| allocator.free(v);
    if (m.estadocum) |v| allocator.free(v);
    if (m.fechaactivo) |v| allocator.free(v);
    if (m.fechainactivo) |v| allocator.free(v);
    if (m.muestramedica) |v| allocator.free(v);
    if (m.unidad) |v| allocator.free(v);
    if (m.atc) |v| allocator.free(v);
    if (m.descripcionatc) |v| allocator.free(v);
    if (m.viaadministracion) |v| allocator.free(v);
    if (m.concentracion) |v| allocator.free(v);
    if (m.principioactivo) |v| allocator.free(v);
    if (m.unidadmedida) |v| allocator.free(v);
    if (m.unidadreferencia) |v| allocator.free(v);
    if (m.formafarmaceutica) |v| allocator.free(v);
    if (m.nombrerol) |v| allocator.free(v);
    if (m.tiporol) |v| allocator.free(v);
    if (m.modalidad) |v| allocator.free(v);
    if (m.ium) |v| allocator.free(v);
    if (m.cantidad) |v| freeJsonValue(allocator, v);
}

pub fn cleanValue(allocator: std.mem.Allocator, val: ?[]const u8) !?[]const u8 {
    const v = val orelse return null;
    const trimmed = std.mem.trim(u8, v, " \t\r\n");
    if (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "null")) {
        return null;
    }
    return try allocator.dupe(u8, trimmed);
}

pub fn formatDate(allocator: std.mem.Allocator, val: ?[]const u8) !?[]const u8 {
    const cleaned = try cleanValue(allocator, val) orelse return null;
    errdefer allocator.free(cleaned);
    if (cleaned.len >= 10) {
        if (cleaned[4] == '-' and cleaned[7] == '-') {
            const dupe = try allocator.dupe(u8, cleaned[0..10]);
            allocator.free(cleaned);
            return dupe;
        }
    }
    return cleaned;
}

fn normalizeText(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var i: usize = 0;
    while (i < value.len) {
        const codepoint_len = std.unicode.utf8ByteSequenceLength(value[i]) catch 1;
        if (codepoint_len == 1) {
            const ch = std.ascii.toLower(value[i]);
            try output.append(allocator, ch);
            i += 1;
        } else {
            const next_i = i + codepoint_len;
            if (next_i <= value.len) {
                const slice = value[i..next_i];
                if (std.mem.eql(u8, slice, "á") or std.mem.eql(u8, slice, "Á")) {
                    try output.append(allocator, 'a');
                } else if (std.mem.eql(u8, slice, "é") or std.mem.eql(u8, slice, "É")) {
                    try output.append(allocator, 'e');
                } else if (std.mem.eql(u8, slice, "í") or std.mem.eql(u8, slice, "Í")) {
                    try output.append(allocator, 'i');
                } else if (std.mem.eql(u8, slice, "ó") or std.mem.eql(u8, slice, "Ó")) {
                    try output.append(allocator, 'o');
                } else if (std.mem.eql(u8, slice, "ú") or std.mem.eql(u8, slice, "Ú") or std.mem.eql(u8, slice, "ü") or std.mem.eql(u8, slice, "Ü")) {
                    try output.append(allocator, 'u');
                } else if (std.mem.eql(u8, slice, "ñ") or std.mem.eql(u8, slice, "Ñ")) {
                    try output.append(allocator, 'n');
                } else {
                    try output.appendSlice(allocator, slice);
                }
            }
            i = next_i;
        }
    }
    return output.toOwnedSlice(allocator);
}

const category_keywords_medicamentos = [_][]const u8{
    "medicament",
    "farmac",
    "biologic",
    "terapeut",
    "suero",
    "vigilancia sanitaria",
    "intrahospitalario",
};
const category_keywords_alimentos = [_][]const u8{
    "alimento",
    "nutric",
    "comest",
    "bebida",
    "alimenticio",
};
const category_keywords_cosmeticos = [_][]const u8{
    "cosmet",
    "higiene personal",
    "aseo personal",
    "perfume",
    "maquill",
    "aseo cosm",
};
const category_keywords_dispositivos = [_][]const u8{
    "dispositivo",
    "equipo medico",
    "instrumental",
    "in vitro",
    "reactivo de diagnostico",
    "implant",
};
const category_keywords_certificaciones = [_][]const u8{
    "certific",
    "inspecc",
    "auditor",
    "bpm",
    "verific",
    "licencia",
    "concepto sanitario",
};

fn categoryKeywords(categoria: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, categoria, "medicamentos")) return &category_keywords_medicamentos;
    if (std.mem.eql(u8, categoria, "alimentos")) return &category_keywords_alimentos;
    if (std.mem.eql(u8, categoria, "cosmeticos")) return &category_keywords_cosmeticos;
    if (std.mem.eql(u8, categoria, "dispositivos_medicos")) return &category_keywords_dispositivos;
    if (std.mem.eql(u8, categoria, "certificaciones")) return &category_keywords_certificaciones;
    return null;
}

pub fn detectCategories(allocator: std.mem.Allocator, nombre_tramite: ?[]const u8, nombre_comun: ?[]const u8, proposito: ?[]const u8) ![][]const u8 {
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);

    if (nombre_tramite) |n| {
        const norm = try normalizeText(allocator, n);
        defer allocator.free(norm);
        try combined.appendSlice(allocator, norm);
        try combined.append(allocator, ' ');
    }
    if (nombre_comun) |c| {
        const norm = try normalizeText(allocator, c);
        defer allocator.free(norm);
        try combined.appendSlice(allocator, norm);
        try combined.append(allocator, ' ');
    }
    if (proposito) |p| {
        const norm = try normalizeText(allocator, p);
        defer allocator.free(norm);
        try combined.appendSlice(allocator, norm);
        try combined.append(allocator, ' ');
    }

    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    const categories = [_]struct { key: []const u8, label: []const u8 }{
        .{ .key = "medicamentos", .label = "Medicamentos" },
        .{ .key = "alimentos", .label = "Alimentos" },
        .{ .key = "cosmeticos", .label = "Cosméticos" },
        .{ .key = "dispositivos_medicos", .label = "Dispositivos médicos" },
        .{ .key = "certificaciones", .label = "Certificaciones o inspecciones" },
    };

    for (categories) |cat| {
        if (categoryKeywords(cat.key)) |keywords| {
            var match = false;
            for (keywords) |kw| {
                const norm_kw = try normalizeText(allocator, kw);
                defer allocator.free(norm_kw);
                if (std.mem.indexOf(u8, combined.items, norm_kw) != null) {
                    match = true;
                    break;
                }
            }
            if (match) {
                try list.append(allocator, try allocator.dupe(u8, cat.label));
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

fn buildSuitWhereClause(allocator: std.mem.Allocator, texto: ?[]const u8) ![]const u8 {
    var clauses = std.ArrayList([]const u8).empty;
    errdefer {
        for (clauses.items) |c| allocator.free(c);
        clauses.deinit(allocator);
    }

    const invima_escaped = try soql.escapeSqlString(allocator, "INSTITUTO NACIONAL DE VIGILANCIA DE MEDICAMENTOS Y ALIMENTOS - INVIMA");
    errdefer allocator.free(invima_escaped);

    const base_clause = try std.fmt.allocPrint(allocator, "nombre_de_la_entidad = '{s}'", .{invima_escaped});
    allocator.free(invima_escaped);
    try clauses.append(allocator, base_clause);

    if (texto) |t| {
        const trimmed = std.mem.trim(u8, t, " \t\r\n");
        if (trimmed.len > 0) {
            const sanitized = try soql.escapeSqlString(allocator, trimmed);
            defer allocator.free(sanitized);

            const upper_sanitized = try allocator.alloc(u8, sanitized.len);
            defer allocator.free(upper_sanitized);
            _ = std.ascii.upperString(upper_sanitized, sanitized);

            const text_clause = try std.fmt.allocPrint(allocator, "(upper(nombre_del_tr_mite_u_otro) like '%{0s}%' OR upper(nombre_com_n) like '%{0s}%' OR upper(prop_sito_del_tr_mite_u_otro) like '%{0s}%' OR upper(nombre_resultado) like '%{0s}%')", .{upper_sanitized});
            try clauses.append(allocator, text_clause);
        }
    }

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    for (clauses.items, 0..) |clause, idx| {
        if (idx > 0) {
            try output.appendSlice(allocator, " AND ");
        }
        try output.appendSlice(allocator, clause);
        allocator.free(clause);
    }

    return output.toOwnedSlice(allocator);
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            var new_arr = try std.json.Array.initCapacity(allocator, arr.items.len);
            for (arr.items) |item| {
                try new_arr.append(try cloneJsonValue(allocator, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .{};
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try cloneJsonValue(allocator, entry.value_ptr.*);
                try new_obj.put(allocator, key, val);
            }
            return .{ .object = new_obj };
        },
    };
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .number_string => |s| allocator.free(s),
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            var mutable_arr = arr;
            mutable_arr.deinit();
        },
        .object => |obj| {
            var mutable_obj = obj;
            var it = mutable_obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            mutable_obj.deinit(allocator);
        },
        else => {},
    }
}
