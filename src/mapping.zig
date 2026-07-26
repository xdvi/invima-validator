//! Proyección de los registros crudos del dataset a los modelos que expone la FFI.

const std = @import("std");
const models = @import("models.zig");

pub fn freeSuggestion(allocator: std.mem.Allocator, s: models.MedicineSuggestion) void {
    if (s.expediente) |v| allocator.free(v);
    if (s.producto) |v| allocator.free(v);
    if (s.titular) |v| allocator.free(v);
    if (s.registrosanitario) |v| allocator.free(v);
    if (s.consecutivocum) |v| allocator.free(v);
    if (s.cantidadcum) |v| allocator.free(v);
    if (s.descripcioncomercial) |v| allocator.free(v);
    if (s.atc) |v| allocator.free(v);
    if (s.nombrerol) |v| allocator.free(v);
    if (s.muestramedica) |v| allocator.free(v);
}

/// Proyecta medicamentos a sugerencias, descartando muestras médicas.
pub fn toSuggestions(
    allocator: std.mem.Allocator,
    medicines: []const models.Medicine,
) ![]models.MedicineSuggestion {
    var suggestions: std.ArrayList(models.MedicineSuggestion) = .empty;
    errdefer {
        for (suggestions.items) |s| {
            freeSuggestion(allocator, s);
        }
        suggestions.deinit(allocator);
    }

    for (medicines) |m| {
        if (m.muestramedica) |mm| {
            if (std.ascii.eqlIgnoreCase(mm, "si")) continue;
        }
        const s = models.MedicineSuggestion{
            .expediente = if (m.expediente) |v| try allocator.dupe(u8, v) else null,
            .producto = if (m.producto) |v| try allocator.dupe(u8, v) else null,
            .titular = if (m.titular) |v| try allocator.dupe(u8, v) else null,
            .registrosanitario = if (m.registrosanitario) |v| try allocator.dupe(u8, v) else null,
            .consecutivocum = if (m.consecutivocum) |v| try allocator.dupe(u8, v) else null,
            .cantidadcum = if (m.cantidadcum) |v| try allocator.dupe(u8, v) else null,
            .descripcioncomercial = if (m.descripcioncomercial) |v| try allocator.dupe(u8, v) else null,
            .atc = if (m.atc) |v| try allocator.dupe(u8, v) else null,
            .nombrerol = if (m.nombrerol) |v| try allocator.dupe(u8, v) else null,
            .muestramedica = if (m.muestramedica) |v| try allocator.dupe(u8, v) else null,
        };
        try suggestions.append(allocator, s);
    }

    return suggestions.toOwnedSlice(allocator);
}
