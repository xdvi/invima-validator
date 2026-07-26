const std = @import("std");
const testing = std.testing;

const models = @import("invima").models;

test "FindField.parse acepta nombres válidos sin distinguir mayúsculas" {
    try testing.expectEqual(models.FindField.expediente, models.FindField.parse("expediente").?);
    try testing.expectEqual(models.FindField.expediente, models.FindField.parse("EXPEDIENTE").?);
    try testing.expectEqual(models.FindField.registrosanitario, models.FindField.parse("registrosanitario").?);
    try testing.expectEqual(models.FindField.registrosanitario, models.FindField.parse("registro_sanitario").?);
}

test "FindField.parse rechaza columnas fuera de la lista blanca" {
    try testing.expectEqual(@as(?models.FindField, null), models.FindField.parse("producto"));
    try testing.expectEqual(@as(?models.FindField, null), models.FindField.parse(""));
    try testing.expectEqual(@as(?models.FindField, null), models.FindField.parse("expediente` = '1' OR '1"));
}

test "RegistrationStatus.parse resuelve los datasets por estado" {
    try testing.expectEqualStrings("i7cb-raxc", models.RegistrationStatus.parse("vigente").?.datasetId());
    try testing.expectEqualStrings("vgr4-gemg", models.RegistrationStatus.parse("renovación").?.datasetId());
    try testing.expectEqualStrings("vwwf-4ftk", models.RegistrationStatus.parse("VENCIDO").?.datasetId());
    try testing.expectEqualStrings("spzp-dfuc", models.RegistrationStatus.parse("otros").?.datasetId());
    try testing.expectEqual(@as(?models.RegistrationStatus, null), models.RegistrationStatus.parse("marciano"));
}
