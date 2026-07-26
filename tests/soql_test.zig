const std = @import("std");
const testing = std.testing;

const soql = @import("invima").soql;

test "buildFindSoql filtra expediente por igualdad exacta" {
    const stmt = try soql.buildFindSoql(testing.allocator, .expediente, "20048021", 5);
    defer testing.allocator.free(stmt);

    try testing.expectEqualStrings(
        "SELECT * WHERE `expediente` = '20048021' ORDER BY `:id` ASC LIMIT 5",
        stmt,
    );
}

test "buildFindSoql compara registro sanitario ignorando mayúsculas" {
    const stmt = try soql.buildFindSoql(testing.allocator, .registrosanitario, "invima 2023m-0013598-r2", 5);
    defer testing.allocator.free(stmt);

    try testing.expectEqualStrings(
        "SELECT * WHERE upper(`registrosanitario`) = upper('invima 2023m-0013598-r2') ORDER BY `:id` ASC LIMIT 5",
        stmt,
    );
}

test "buildFindSoql duplica comillas simples del valor" {
    const stmt = try soql.buildFindSoql(testing.allocator, .expediente, "O'BRIEN", 5);
    defer testing.allocator.free(stmt);

    try testing.expectEqualStrings(
        "SELECT * WHERE `expediente` = 'O''BRIEN' ORDER BY `:id` ASC LIMIT 5",
        stmt,
    );
}

test "isFindValueQueryable rechaza expedientes no numéricos" {
    // `expediente` es columna NUMBER en Socrata: comparar contra texto da HTTP 400,
    // no un resultado vacío.
    try testing.expect(soql.isFindValueQueryable(.expediente, "20048021"));
    try testing.expect(!soql.isFindValueQueryable(.expediente, "INVIMA 2023M-0013598-R2"));
    try testing.expect(!soql.isFindValueQueryable(.expediente, "2004-8021"));
    try testing.expect(!soql.isFindValueQueryable(.expediente, ""));
}

test "isFindValueQueryable acepta cualquier registro sanitario" {
    try testing.expect(soql.isFindValueQueryable(.registrosanitario, "INVIMA 2023M-0013598-R2"));
    try testing.expect(soql.isFindValueQueryable(.registrosanitario, "20048021"));
}

test "normalizeFindLimit aplica valor por defecto y tope" {
    try testing.expectEqual(@as(usize, 5), soql.normalizeFindLimit(0));
    try testing.expectEqual(@as(usize, 1), soql.normalizeFindLimit(1));
    try testing.expectEqual(@as(usize, 100), soql.normalizeFindLimit(100));
    try testing.expectEqual(@as(usize, 100), soql.normalizeFindLimit(5000));
}

test "urlEncode escapa backticks, comillas y espacios de la query" {
    const encoded = try soql.urlEncode(testing.allocator, "a `b` 'c'");
    defer testing.allocator.free(encoded);

    try testing.expectEqualStrings("a%20%60b%60%20%27c%27", encoded);
}

test "escapeSqlString solo duplica comillas simples" {
    const escaped = try soql.escapeSqlString(testing.allocator, "a'b\\c\"d");
    defer testing.allocator.free(escaped);

    try testing.expectEqualStrings("a''b\\c\"d", escaped);
}

test "escapeSoqlString además escapa backslashes y comillas dobles" {
    const escaped = try soql.escapeSoqlString(testing.allocator, "a'b\\c\"d");
    defer testing.allocator.free(escaped);

    try testing.expectEqualStrings("a''b\\\\c\\\"d", escaped);
}
