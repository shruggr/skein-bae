// skein-bae: Bae, as an installable app.
//
//   zig build        → zig-out/bin/site.wasm
//   zig build bin    the same, written to bin/site.wasm (the app tree's module)
//   zig build test   path checks, natively
const std = @import("std");

pub fn build(b: *std.Build) void {
    const wasi = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .wasi });
    const exe = b.addExecutable(.{ .name = "site", .root_module = module(b, wasi, .ReleaseSafe, true) });
    b.installArtifact(exe);

    const bin = b.addUpdateSourceFiles();
    bin.addCopyFileToSource(exe.getEmittedBin(), "bin/site.wasm");
    b.step("bin", "write the module into the app tree: bin/site.wasm").dependOn(&bin.step);

    const tests = b.addTest(.{ .root_module = module(b, b.standardTargetOptions(.{}), .Debug, false) });
    b.step("test", "path checks").dependOn(&b.addRunArtifact(tests).step);
}

fn module(b: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, strip: bool) *std.Build.Module {
    const sdk = b.dependency("skein_sdk", .{ .target = t, .optimize = o, .wallet = false });
    return b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = t,
        .optimize = o,
        .strip = strip,
        .imports = &.{
            .{ .name = "cbor", .module = sdk.module("cbor") },
            .{ .name = "sk", .module = sdk.module("sk") },
        },
    });
}
