//! Raíz de la suite de tests: agrupa los archivos de `tests/`.

comptime {
    _ = @import("models_test.zig");
    _ = @import("soql_test.zig");
    _ = @import("mapping_test.zig");
}
