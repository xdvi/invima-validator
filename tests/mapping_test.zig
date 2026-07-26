const std = @import("std");
const testing = std.testing;

const invima = @import("invima");
const models = invima.models;
const mapping = invima.mapping;

test "toSuggestions descarta muestras médicas y copia el resto" {
    const medicines = [_]models.Medicine{
        .{ .expediente = "1", .producto = "A", .muestramedica = "No" },
        .{ .expediente = "2", .producto = "B", .muestramedica = "SI" },
        .{ .expediente = "3", .producto = "C", .muestramedica = null },
    };

    const suggestions = try mapping.toSuggestions(testing.allocator, &medicines);
    defer {
        for (suggestions) |s| mapping.freeSuggestion(testing.allocator, s);
        testing.allocator.free(suggestions);
    }

    try testing.expectEqual(@as(usize, 2), suggestions.len);
    try testing.expectEqualStrings("A", suggestions[0].producto.?);
    try testing.expectEqualStrings("C", suggestions[1].producto.?);
}

test "toSuggestions sobre una lista vacía devuelve un slice vacío" {
    const suggestions = try mapping.toSuggestions(testing.allocator, &.{});
    defer testing.allocator.free(suggestions);

    try testing.expectEqual(@as(usize, 0), suggestions.len);
}
