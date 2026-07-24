const std = @import("std");
const builtin = @import("builtin");

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
