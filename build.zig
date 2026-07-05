const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 1. Crear el módulo para la biblioteca
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
        .single_threaded = true,
        .unwind_tables = .none,
    });

    // 2. Crear la biblioteca compartida (.so, .dll, .dylib) vinculando el módulo
    const lib = b.addLibrary(.{
        .name = "invima_ffi",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });

    b.installArtifact(lib);

    // 3. Crear el módulo para el cliente de uso común
    const client_mod = b.createModule(.{
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 4. Crear el módulo para el ejecutable de ejemplo
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
        .single_threaded = true,
        .unwind_tables = .none,
    });
    exe_mod.addImport("client", client_mod);

    // 5. Crear el ejecutable de ejemplo
    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);
}
