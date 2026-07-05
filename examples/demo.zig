const std = @import("std");
const client_mod = @import("client");
const models = client_mod.models;

pub fn main() !void {
    // Allocator para la demo
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client = client_mod.InvimaClient.init(allocator, io, null);
    defer client.deinit();

    std.debug.print("=== Búsqueda CUM: ibuprofeno (vigente) en Zig ===\n", .{});
    const suggestions = client.searchMedicines("ibuprofeno", .vigente, 3) catch |err| {
        std.debug.print("Error al buscar medicamentos: {s}\n", .{@errorName(err)});
        return;
    };
    defer {
        for (suggestions) |s| {
            client.freeSuggestion(s);
        }
        allocator.free(suggestions);
    }

    for (suggestions, 0..) |item, i| {
        std.debug.print("{d}. {s} | {s} | CUM {s}/{s}/{s}\n", .{
            i + 1,
            item.producto orelse "?",
            item.registrosanitario orelse "?",
            item.expediente orelse "?",
            item.consecutivocum orelse "?",
            item.cantidadcum orelse "?",
        });
    }

    if (suggestions.len > 0) {
        const first = suggestions[0];
        std.debug.print("\n=== Detalle por CUM del primer resultado en Zig ===\n", .{});
        
        const detail = client.getMedicineByCum(
            first.expediente orelse "",
            first.consecutivocum orelse "",
            first.cantidadcum orelse "",
            .vigente,
        ) catch |err| {
            std.debug.print("Error al buscar detalle por CUM: {s}\n", .{@errorName(err)});
            return;
        };
        defer client.freeMedicine(detail);

        std.debug.print("Producto:      {s}\n", .{detail.producto orelse "?"});
        std.debug.print("Titular:       {s}\n", .{detail.titular orelse "?"});
        std.debug.print("Principio:     {s}\n", .{detail.principioactivo orelse "?"});
        std.debug.print("Forma:         {s}\n", .{detail.formafarmaceutica orelse "?"});
        std.debug.print("Estado CUM:    {s}\n", .{detail.estadocum orelse "?"});
    }

    std.debug.print("\n=== Búsqueda de Trámites SUIT en Zig ===\n", .{});
    const suit_results = client.searchTramites(allocator, "registro sanitario", 2, 0) catch |err| {
        std.debug.print("Nota: La búsqueda de trámites falló con {s}.\n", .{@errorName(err)});
        std.debug.print("(El dataset público de trámites SUIT 48fq-mxnm requiere credenciales/App Token autorizado en datos.gov.co)\n", .{});
        return;
    };
    defer client.freeTramiteSearchResult(suit_results);

    std.debug.print("Total trámites encontrados: {}\n", .{suit_results.total});
    for (suit_results.tramites, 0..) |tramite, i| {
        std.debug.print("{d}. Código: {s} | {s}\n", .{
            i + 1,
            tramite.numero_unico orelse "?",
            tramite.nombre_tramite orelse "?",
        });
        std.debug.print("   Propósito: {s}\n", .{tramite.proposito orelse "?"});
        std.debug.print("   Categorías: ", .{});
        for (tramite.categorias, 0..) |cat, cat_idx| {
            if (cat_idx > 0) std.debug.print(", ", .{});
            std.debug.print("{s}", .{cat});
        }
        std.debug.print("\n", .{});
        
        if (tramite.pasos.len > 0) {
            std.debug.print("   Pasos (primeros 2):\n", .{});
            for (tramite.pasos[0..@min(2, tramite.pasos.len)]) |paso| {
                std.debug.print("     - Paso {s}: {s}\n", .{
                    paso.orden_paso orelse "?",
                    paso.descripcion_paso orelse "?",
                });
            }
        }
    }
}
