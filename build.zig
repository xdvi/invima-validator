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
}
