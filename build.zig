const std = @import("std");
const builtin = @import("builtin");
const zon = @import("build.zig.zon");

// Published releases must run on any cloud VM, not just the CPU that
// happened to build them. `standardTargetOptions` resolves to the *native*
// CPU when no `-Dtarget`/`-Dcpu` is passed — on a CI runner that's whatever
// GitHub gave it that day (previously produced a binary using VAES, which
// SIGILLs on any x86_64 host without it, e.g. Cascade Lake Xeons). Only the
// CPU model is pinned (OS/arch/ABI stay native) so cross-platform CI matrix
// builds (linux/macos/windows) are unaffected; x86_64_v2 (baseline + SSE4.2,
// no AVX) is guaranteed present on every x86_64 chip shipped since ~2009 and
// is plenty for this library's JSON/HTTP workload. Non-x86_64 hosts (e.g.
// Apple Silicon CI runners) are left fully native. Pass -Dcpu=native
// explicitly to opt back into host-tuned codegen for a self-built deploy.
const default_target: std.Target.Query = if (builtin.cpu.arch == .x86_64) .{
    .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
} else .{};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});

    const single_threaded = b.option(bool, "single-threaded", "Compile the library single-threaded") orelse false;

    // Única fuente de verdad de la versión: `build.zig.zon`.
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", zon.version);
    const build_options_mod = build_options.createModule();

    // 1. Crear el módulo para la biblioteca
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = true,
        .single_threaded = single_threaded,
        .unwind_tables = .none,
    });
    lib_mod.addImport("build_options", build_options_mod);

    // 2. Crear la biblioteca compartida (.so, .dll, .dylib) vinculando el módulo
    const lib = b.addLibrary(.{
        .name = "invima_ffi",
        .root_module = lib_mod,
        .linkage = .dynamic,
    });

    b.installArtifact(lib);

    // 3. Tests unitarios (funciones puras, sin red). `tests/` no puede importar
    // `src/` por ruta relativa, así que la biblioteca entra como módulo nombrado.
    const invima_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    invima_mod.addImport("build_options", build_options_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "invima", .module = invima_mod }},
    });
    test_mod.addImport("build_options", build_options_mod);

    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
