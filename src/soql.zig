//! Construcción y escape de queries SoQL para los datasets de datos.gov.co.

const std = @import("std");
const models = @import("models.zig");

pub const FIND_LIMIT_DEFAULT: usize = 5;
pub const FIND_LIMIT_MAX: usize = 100;

pub fn urlEncode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    for (input) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try output.append(allocator, c),
            else => {
                try output.print(allocator, "%{X:0>2}", .{c});
            },
        }
    }
    return output.toOwnedSlice(allocator);
}

/// Escape para literales entre comillas dobles, como el argumento de `SEARCH "..."`.
pub fn escapeSoqlString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(allocator);

    for (input) |c| {
        if (c == '\\') {
            try tmp.appendSlice(allocator, "\\\\");
        } else if (c == '"') {
            try tmp.appendSlice(allocator, "\\\"");
        } else {
            try tmp.append(allocator, c);
        }
    }

    return std.mem.replaceOwned(u8, allocator, tmp.items, "'", "''");
}

/// Escape para literales entre comillas simples, donde SoQL no interpreta backslashes.
pub fn escapeSqlString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, input, "'", "''");
}

pub fn normalizeFindLimit(limit: usize) usize {
    if (limit == 0) return FIND_LIMIT_DEFAULT;
    return @min(limit, FIND_LIMIT_MAX);
}

/// `expediente` es columna numérica en Socrata: un valor no numérico produce
/// HTTP 400 en vez de un resultado vacío, así que se descarta antes de consultar.
pub fn isFindValueQueryable(field: models.FindField, value: []const u8) bool {
    if (value.len == 0) return false;
    return switch (field) {
        .expediente => for (value) |c| {
            if (!std.ascii.isDigit(c)) break false;
        } else true,
        .registrosanitario => true,
    };
}

/// Arma el SoQL de búsqueda exacta. `value` debe venir recortado y no vacío.
pub fn buildFindSoql(
    allocator: std.mem.Allocator,
    field: models.FindField,
    value: []const u8,
    limit: usize,
) ![]u8 {
    // escapeSqlString, no escapeSoqlString: este literal va entre comillas simples,
    // donde escapar backslashes corrompería el valor.
    const escaped = try escapeSqlString(allocator, value);
    defer allocator.free(escaped);

    return switch (field) {
        // El expediente es numérico: comparar tal cual mantiene la columna indexable.
        .expediente => std.fmt.allocPrint(
            allocator,
            "SELECT * WHERE `{s}` = '{s}' ORDER BY `:id` ASC LIMIT {d}",
            .{ field.column(), escaped, limit },
        ),
        .registrosanitario => std.fmt.allocPrint(
            allocator,
            "SELECT * WHERE upper(`{s}`) = upper('{s}') ORDER BY `:id` ASC LIMIT {d}",
            .{ field.column(), escaped, limit },
        ),
    };
}
