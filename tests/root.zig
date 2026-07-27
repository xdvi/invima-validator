//! Raíz de la suite de tests: agrupa los archivos de `tests/`.

comptime {
    _ = @import("models_test.zig");
    _ = @import("soql_test.zig");
    _ = @import("mapping_test.zig");
    _ = @import("ffi_test.zig");
    _ = @import("client_parse_test.zig");
    _ = @import("retry_test.zig");
}
