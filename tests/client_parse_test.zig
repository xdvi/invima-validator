//! Parsing y normalización de respuestas Socrata, sin red.

const std = @import("std");
const testing = std.testing;
const invima = @import("invima");
const client = invima.client;

fn freeMedicines(allocator: std.mem.Allocator, medicines: []invima.models.Medicine) void {
    for (medicines) |m| client.freeMedicineWith(allocator, m);
    allocator.free(medicines);
}

test "parseMedicines on empty array" {
    const medicines = try client.parseMedicines(testing.allocator, "[]");
    defer freeMedicines(testing.allocator, medicines);

    try testing.expectEqual(0, medicines.len);
}

test "parseMedicines maps known fields and leaves the rest null" {
    const body =
        \\[{"expediente":"19900001","producto":"ACETAMINOFEN 500MG",
        \\  "registrosanitario":"INVIMA 2020M-000001","estadoregistro":"Vigente",
        \\  "muestramedica":"no"}]
    ;

    const medicines = try client.parseMedicines(testing.allocator, body);
    defer freeMedicines(testing.allocator, medicines);

    try testing.expectEqual(1, medicines.len);
    const m = medicines[0];
    try testing.expectEqualStrings("19900001", m.expediente.?);
    try testing.expectEqualStrings("ACETAMINOFEN 500MG", m.producto.?);
    try testing.expectEqualStrings("INVIMA 2020M-000001", m.registrosanitario.?);
    try testing.expectEqualStrings("Vigente", m.estadoregistro.?);
    try testing.expectEqualStrings("no", m.muestramedica.?);
    try testing.expectEqual(null, m.titular);
    try testing.expectEqual(null, m.cantidad);
}

test "parseMedicines ignores unknown fields" {
    const body =
        \\[{"expediente":"1","campo_que_no_existe":"x","otro":{"anidado":true}}]
    ;

    const medicines = try client.parseMedicines(testing.allocator, body);
    defer freeMedicines(testing.allocator, medicines);

    try testing.expectEqual(1, medicines.len);
    try testing.expectEqualStrings("1", medicines[0].expediente.?);
}

test "parseMedicines clones the cantidad json value" {
    const body =
        \\[{"expediente":"1","cantidad":30}]
    ;

    const medicines = try client.parseMedicines(testing.allocator, body);
    defer freeMedicines(testing.allocator, medicines);

    const cantidad = medicines[0].cantidad orelse return error.MissingCantidad;
    try testing.expectEqual(30, cantidad.integer);
}

test "parseMedicines maps several records" {
    const body =
        \\[{"expediente":"1"},{"expediente":"2"},{"expediente":"3"}]
    ;

    const medicines = try client.parseMedicines(testing.allocator, body);
    defer freeMedicines(testing.allocator, medicines);

    try testing.expectEqual(3, medicines.len);
    try testing.expectEqualStrings("3", medicines[2].expediente.?);
}

test "parseMedicines rejects malformed json" {
    try testing.expectError(error.UnexpectedToken, client.parseMedicines(testing.allocator, "{"));
}

test "cleanValue trims and nulls empty or literal null" {
    try testing.expectEqual(null, try client.cleanValue(testing.allocator, null));
    try testing.expectEqual(null, try client.cleanValue(testing.allocator, "   "));
    try testing.expectEqual(null, try client.cleanValue(testing.allocator, "null"));
    try testing.expectEqual(null, try client.cleanValue(testing.allocator, "NULL"));

    const trimmed = try client.cleanValue(testing.allocator, "  ACETAMINOFEN \n") orelse
        return error.UnexpectedNull;
    defer testing.allocator.free(trimmed);
    try testing.expectEqualStrings("ACETAMINOFEN", trimmed);
}

test "formatDate truncates ISO timestamps to the date" {
    const date = try client.formatDate(testing.allocator, "2024-01-15T00:00:00.000") orelse
        return error.UnexpectedNull;
    defer testing.allocator.free(date);
    try testing.expectEqualStrings("2024-01-15", date);
}

test "formatDate leaves non-ISO values untouched" {
    const raw = try client.formatDate(testing.allocator, "15/01/2024") orelse
        return error.UnexpectedNull;
    defer testing.allocator.free(raw);
    try testing.expectEqualStrings("15/01/2024", raw);

    try testing.expectEqual(null, try client.formatDate(testing.allocator, "  "));
}

test "detectCategories matches keywords ignoring case and accents" {
    const categories = try client.detectCategories(
        testing.allocator,
        "Registro sanitario de MEDICAMENTOS",
        null,
        "Trámite de cosméticos",
    );
    defer {
        for (categories) |c| testing.allocator.free(c);
        testing.allocator.free(categories);
    }

    try testing.expectEqual(2, categories.len);
    try testing.expectEqualStrings("Medicamentos", categories[0]);
    try testing.expectEqualStrings("Cosméticos", categories[1]);
}

test "detectCategories returns empty when nothing matches" {
    const categories = try client.detectCategories(testing.allocator, "xyz", null, null);
    defer testing.allocator.free(categories);

    try testing.expectEqual(0, categories.len);
}
