//! Extracts the build configuration (modules, import graph, compilations)
//! from a project's `build.zig` using the configure/make split introduced in
//! Zig 0.17 (ziglang/zig#35428).
//!
//! This implementation intentionally avoids the build system protocol
//! (`zig build --listen=-`, ziglang/zig#36147) because it has not been merged
//! into Zig master yet. Instead it runs `zig build --print-configuration-path`
//! which exits after the configure phase and prints the path to the serialized
//! `std.Build.Configuration`, which is then loaded with `Configuration.loadFile`.
//!
//! Limitations compared to the protocol-based approach:
//! - Modules whose root source file is generated during the make phase cannot
//!   be resolved (requires running steps and receiving generated file paths).
//! - `build.zig` compile errors are not reported as LSP diagnostics; they are
//!   forwarded to ZLS's stderr instead.
//! - Build-On-Save is disabled (requires streaming step results over the
//!   protocol).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Dir = Io.Dir;
const Directory = std.Build.Cache.Directory;
const Configuration = std.Build.Configuration;

const log = std.log.scoped(.bsp);

const DiagnosticsCollection = @import("DiagnosticsCollection.zig");
const Uri = @import("Uri.zig");

pub const BuildConfig = struct {
    /// The `dependencies` in `build.zig.zon`.
    dependencies: std.json.ArrayHashMap([]const u8),
    /// The key is the `root_source_file`.
    /// All modules with the same root source file are merged. This limitation may be lifted in the future.
    modules: std.json.ArrayHashMap(Module),
    /// List of all compilations units.
    compilations: []const Compile,

    pub const Module = struct {
        import_table: std.json.ArrayHashMap([]const u8),
    };

    pub const Compile = struct {
        /// Key in `BuildConfig.modules`.
        root_module: []const u8,

        // may contain additional information in the future like `target` or `link_libc`.
    };
};

/// Runs the configure phase of the build.zig and extracts modules and imports.
pub fn loadBuildConfiguration(
    io: Io,
    allocator: Allocator,
    environ_map: *const std.process.Environ.Map,
    zig_exe_path: []const u8,
    zig_lib_directory: Directory,
    diagnostics_collection: *DiagnosticsCollection,
    build_file_uri: Uri,
    build_file_version: u32,
) !std.json.Parsed(BuildConfig) {
    // TODO push `build.zig` compile errors into the diagnostics collection.
    // Without the build system protocol there is no `std.zig.ErrorBundle`
    // available; the child's stderr is inherited instead.
    _ = diagnostics_collection;
    _ = build_file_version;

    const build_file_path = try build_file_uri.toFsPath(allocator);
    defer allocator.free(build_file_path);

    const cwd_path = Dir.path.dirname(build_file_path).?;
    var cwd: Directory = .{
        .handle = try Dir.cwd().openDir(io, cwd_path, .{}),
        .path = cwd_path,
    };
    defer cwd.handle.close(io);

    const argv: []const []const u8 = &.{
        zig_exe_path,
        "build",
        "--print-configuration-path",
    };

    var child_environ_map = try environ_map.clone(allocator);
    defer child_environ_map.deinit();

    try child_environ_map.put("ZIG_DEBUG_MAKER", "1");
    try child_environ_map.put("ZIG_LIB_DIR", zig_lib_directory.path.?);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .dir = cwd.handle },
        .environ_map = &child_environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit, // build.zig errors and progress end up on ZLS's stderr
    });
    errdefer child.kill(io);

    var arena_allocator: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    const configuration_file_path = path: {
        var stdout_buffer: [256]u8 = undefined;
        var stdout_reader = child.stdout.?.reader(io, &stdout_buffer);
        const raw = stdout_reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return stdout_reader.err.?,
            else => |e| return e,
        };
        defer allocator.free(raw);

        const term = try child.wait(io);
        if (!term.success()) {
            log.err("failed to run '{s} build --print-configuration-path' in {s}: {t}", .{
                zig_exe_path, cwd_path, term,
            });
            return error.AlreadyReported;
        }

        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) {
            log.err("'{s} build --print-configuration-path' in {s} printed no configuration path", .{
                zig_exe_path, cwd_path,
            });
            return error.AlreadyReported;
        }
        break :path try arena.dupe(u8, trimmed);
    };

    const configuration: Configuration = blk: {
        const configuration_file = cwd.handle.openFile(io, configuration_file_path, .{}) catch |err| {
            log.err("failed to open configuration file {s}: {t}", .{ configuration_file_path, err });
            return error.AlreadyReported;
        };
        defer configuration_file.close(io);
        break :blk Configuration.loadFile(arena, io, configuration_file) catch |err| {
            log.err("failed to load configuration file {s}: {t}", .{ configuration_file_path, err });
            return error.AlreadyReported;
        };
    };

    // The configuration file lives at `<local_cache_root>/c/<digest>`.
    const local_cache_path = local_cache: {
        const c_dir = Dir.path.dirname(configuration_file_path) orelse break :local_cache null;
        const cache_root = Dir.path.dirname(c_dir) orelse break :local_cache null;
        break :local_cache try Dir.path.resolve(arena, &.{ cwd_path, cache_root });
    };

    const global_cache_path: ?[]const u8 = if (environ_map.get("ZIG_GLOBAL_CACHE_DIR")) |p|
        try Dir.path.resolve(arena, &.{ cwd_path, p })
    else
        null;

    const install_prefix = try Dir.path.join(arena, &.{ cwd_path, "zig-out" });

    var maker: Maker = .{
        .configuration = configuration,
        .cwd = cwd.path orelse ".",
        .zig_exe = zig_exe_path,
        .global_cache_root = global_cache_path,
        .local_cache_root = local_cache_path,
        .zig_lib_directory = zig_lib_directory.path.?,
        .build_root_directory = cwd_path,
        .install_paths = .{
            .prefix = install_prefix,
            .lib = try Dir.path.join(arena, &.{ install_prefix, "lib" }),
            .bin = try Dir.path.join(arena, &.{ install_prefix, "bin" }),
            .include = try Dir.path.join(arena, &.{ install_prefix, "include" }),
        },
    };
    const c = &maker.configuration;

    // The value tracks whether the step is a decendant of the default step step.
    var all_steps: std.array_hash_map.Auto(Configuration.Step.Index, bool) = .empty;
    defer all_steps.deinit(allocator);

    // collect all steps that are decendants of the "install" step.
    {
        try all_steps.putNoClobber(allocator, c.default_step, true);

        var i: usize = 0;
        while (i < all_steps.count()) : (i += 1) {
            const step = all_steps.keys()[i].ptr(c);
            const deps = step.deps.slice(c);

            try all_steps.ensureUnusedCapacity(allocator, deps.len);
            for (deps) |other_step| {
                all_steps.putAssumeCapacity(other_step, true);
            }
        }
    }

    // collect all other steps
    {
        var i: usize = all_steps.count();

        try all_steps.ensureUnusedCapacity(allocator, configuration.steps.len);
        for (configuration.steps, 0..) |*conf_step, step_index_usize| {
            if (conf_step.owner != .root) continue;
            const step_index: Configuration.Step.Index = @enumFromInt(step_index_usize);
            const flags = conf_step.flags(&configuration);
            if (flags.tag != .top_level) continue;
            all_steps.putAssumeCapacity(step_index, true);
        }

        while (i < all_steps.count()) : (i += 1) {
            const step = all_steps.keys()[i].ptr(c);
            const deps = step.deps.slice(c);

            try all_steps.ensureUnusedCapacity(allocator, deps.len);
            for (deps) |other_step| {
                all_steps.putAssumeCapacity(other_step, true);
            }
        }
    }

    // NOTE: Without the build system protocol we cannot run the steps that
    // generate root source files, so `maker.generated_files` stays empty and
    // modules with generated root source files are skipped.

    // We collect modules in the following order:
    // - public modules (`std.Build.addModule`)
    // - modules that are reachable from the "install" step
    // - all other reachable modules
    var resolved_modules: std.array_hash_map.String(BuildConfig.Module) = .empty;

    var modules: std.array_hash_map.Auto(Configuration.Module.Index, void) = .empty;
    defer modules.deinit(allocator);

    // We loop twice through all steps so that decendants of the "install" step are processed first.
    for ([_]bool{ true, false }) |want_install_step_decendant| {
        for (all_steps.keys(), all_steps.values()) |step_index, is_install_step_decendant| {
            if (is_install_step_decendant != want_install_step_decendant) continue;
            const step = step_index.ptr(c);
            const compile = step.extended.cast(c, Configuration.Step.Compile) orelse continue;

            var index = modules.count();
            try modules.put(allocator, compile.root_module, {});
            while (index < modules.count()) : (index += 1) {
                const module = modules.keys()[index].get(c);
                const import_table = module.import_table.get(c).imports.mal;

                for (import_table.items(.module)) |import| try modules.put(allocator, import, {});

                const root_source_file = module.root_source_file.unwrap() orelse continue;
                const root_source_file_path = try maker.resolveLazyPath(arena, root_source_file.get(c)) orelse continue;

                // All modules with the same root source file are merged. This limitation may be lifted in the future.
                const gop = try resolved_modules.getOrPutValue(arena, root_source_file_path, .{
                    .import_table = .{},
                });

                for (import_table.items(.name), import_table.items(.module)) |name, import_module| {
                    const import_root_source_file = import_module.get(c).root_source_file.unwrap() orelse continue;
                    const import_root_source_file_path = try maker.resolveLazyPath(arena, import_root_source_file.get(c)) orelse continue;

                    const gop_import = try gop.value_ptr.import_table.map.getOrPut(arena, name.slice(c));
                    // This does not account for the possibility of collisions (i.e. modules with same root source file import different modules under the same name).
                    if (!gop_import.found_existing) {
                        gop_import.value_ptr.* = import_root_source_file_path;
                    }
                }
            }
        }
    }

    var compilations: std.ArrayList(BuildConfig.Compile) = .empty;
    for (all_steps.keys()) |step_index| {
        const step = step_index.ptr(c);
        const compile = step.extended.cast(c, Configuration.Step.Compile) orelse continue;
        const root_module = compile.root_module.get(c);
        const root_source_file = root_module.root_source_file.unwrap() orelse continue;
        const root_source_file_path = try maker.resolveLazyPath(arena, root_source_file.get(c)) orelse continue;
        try compilations.append(arena, .{
            .root_module = root_source_file_path,
        });
    }

    const build_config: BuildConfig = .{
        .dependencies = .{ .map = .empty }, // TODO
        .modules = .{ .map = resolved_modules },
        .compilations = compilations.items,
    };

    // std.debug.print("collected build system configuration:\n{f}\n", .{std.json.fmt(build_config, .{ .whitespace = .indent_2 })});

    const arena_allocator_ptr = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena_allocator_ptr);
    arena_allocator_ptr.* = arena_allocator;

    return .{
        .arena = arena_allocator_ptr,
        .value = build_config,
    };
}

const Maker = struct {
    configuration: Configuration,

    cwd: []const u8,
    zig_exe: []const u8,
    global_cache_root: ?[]const u8,
    local_cache_root: ?[]const u8,
    zig_lib_directory: []const u8,
    build_root_directory: []const u8,
    install_paths: InstallPaths,

    const InstallPaths = struct {
        prefix: []const u8,
        lib: []const u8,
        bin: []const u8,
        include: []const u8,
    };

    pub fn resolveLazyPath(
        maker: *const Maker,
        arena: Allocator,
        lazy_path: Configuration.LazyPath,
    ) Allocator.Error!?[]const u8 {
        const c = &maker.configuration;
        return switch (lazy_path) {
            .source_path => |sp| try packagePath(maker, arena, sp.owner, sp.sub_path.slice(c)),
            .relative => |relative| try relativePath(maker, arena, relative.flags.base, relative.sub_path.slice(c)),
            // Generated file paths are only known when the generating steps are
            // actually run, which requires the build system protocol.
            .generated => null,
        };
    }

    fn packagePath(
        maker: *const Maker,
        arena: Allocator,
        package_index: Configuration.Package.Index,
        sub_path: []const u8,
    ) Allocator.Error![]const u8 {
        const c = &maker.configuration;
        const package = package_index.get(c) orelse return try Dir.path.join(arena, &.{ maker.build_root_directory, sub_path });
        return try Dir.path.resolve(arena, &.{ maker.cwd, package.root_path.slice(c), sub_path });
    }

    fn relativePath(
        maker: *const Maker,
        arena: Allocator,
        base: Configuration.LazyPath.Relative.Base,
        sub_path: []const u8,
    ) Allocator.Error!?[]const u8 {
        const base_path = maker.basePath(base) orelse return null;
        if (sub_path.len == 0) return base_path;
        return try Dir.path.join(arena, &.{ base_path, sub_path });
    }

    fn basePath(maker: *const Maker, base: Configuration.LazyPath.Relative.Base) ?[]const u8 {
        return switch (base) {
            .cwd => maker.cwd,
            .zig_exe => maker.zig_exe,
            .local_cache => maker.local_cache_root orelse missingBasePath(.local_cache),
            .global_cache => maker.global_cache_root orelse missingBasePath(.global_cache),
            .build_root => maker.build_root_directory,
            .zig_lib => maker.zig_lib_directory,
            .install_prefix => maker.install_paths.prefix,
            .install_lib => maker.install_paths.lib,
            .install_bin => maker.install_paths.bin,
            .install_include => maker.install_paths.include,
        };
    }

    fn missingBasePath(base: Configuration.LazyPath.Relative.Base) ?[]const u8 {
        log.warn("cannot resolve a path rooted at {t}; the referencing module will be skipped", .{base});
        return null;
    }
};

/// Build-On-Save requires streaming build results which is only possible with
/// the build system protocol (ziglang/zig#36147). Until that lands in Zig
/// master, Build-On-Save is unconditionally disabled at runtime.
pub const BuildOnSave = struct {
    pub const Supported = union(enum) {
        supported,
        invalid_linux_kernel_version: if (builtin.os.tag == .linux) @FieldType(std.os.linux.utsname, "release") else noreturn,
        unsupported_linux_kernel_version: if (builtin.os.tag == .linux) std.SemanticVersion else noreturn,
        unsupported_zig_version: void,
        unsupported_os: if (@TypeOf(os_support) == bool and !os_support) void else noreturn,

        /// std.build.Watch requires `AT_HANDLE_FID` which is Linux 6.5+
        /// https://github.com/ziglang/zig/issues/20720
        pub const minimum_linux_version: std.SemanticVersion = .{ .major = 6, .minor = 5, .patch = 0 };

        /// The Zig version that includes the build system protocol. Does not
        /// exist yet; see ziglang/zig#36147.
        pub const minimum_zig_version: std.SemanticVersion = .{ .major = 0, .minor = 17, .patch = 0 };

        pub const os_support = switch (builtin.os.tag) {
            .linux,
            .windows,
            .dragonfly,
            .freebsd,
            .netbsd,
            .openbsd,
            .ios,
            .macos,
            .tvos,
            .visionos,
            .watchos,
            .haiku,
            => true,
            else => false,
        };
    };

    pub inline fn isSupportedComptime() bool {
        if (!std.process.can_spawn) return false;
        if (builtin.single_threaded) return false;
        return true;
    }

    pub fn isSupportedRuntime(runtime_zig_version: std.SemanticVersion) Supported {
        comptime std.debug.assert(isSupportedComptime());
        _ = runtime_zig_version;
        // Requires the build system protocol which has not landed in Zig master.
        return .unsupported_zig_version;
    }

    pub const InitOptions = struct {
        io: Io,
        gpa: Allocator,
        environ_map: *const std.process.Environ.Map,
        build_root: Directory,
        build_on_save_args: []const []const u8,
        check_step_only: bool,
        zig_exe_path: []const u8,
        zig_lib_dir: Directory,

        diagnostics: *DiagnosticsCollection,
    };

    pub const InitError = error{
        Canceled,
        ConcurrencyUnavailable,
        OutOfMemory,
        AlreadyReported,
    };

    pub fn init(options: InitOptions) InitError!?BuildOnSave {
        const io = options.io;
        const gpa = options.gpa;

        var dir = options.build_root;
        dir.closeAndFree(gpa, io);

        log.warn("Build-On-Save is disabled: it requires the Zig build system protocol (ziglang/zig#36147) which has not been merged into Zig yet", .{});
        return null;
    }

    pub fn deinit(self: *BuildOnSave) void {
        self.* = undefined;
    }

    pub fn sendManualWatchUpdate(build_on_save: *BuildOnSave) void {
        _ = build_on_save;
    }
};
