const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Compilation = @import("Compilation.zig");
const Module = @import("Module.zig");
const fs = std.fs;
const trace = @import("tracy.zig").trace;
const Package = @import("Package.zig");
const Type = @import("type.zig").Type;
const Cache = @import("Cache.zig");
const build_options = @import("build_options");
const LibCInstallation = @import("libc_installation.zig").LibCInstallation;
const log = std.log.scoped(.link);

pub const producer_string = if (std.builtin.is_test) "zig test" else "zig " ++ build_options.version;

pub const Options = struct {
    /// Where the output will go.
    directory: Compilation.Directory,
    /// Path to the output file, relative to `directory`.
    sub_path: []const u8,
    target: std.Target,
    output_mode: std.builtin.OutputMode,
    link_mode: std.builtin.LinkMode,
    object_format: std.builtin.ObjectFormat,
    optimize_mode: std.builtin.Mode,
    machine_code_model: std.builtin.CodeModel,
    root_name: []const u8,
    /// Not every Compilation compiles .zig code! For example you could do `zig build-exe foo.o`.
    module: ?*Module,
    dynamic_linker: ?[]const u8 = null,
    /// Used for calculating how much space to reserve for symbols in case the binary file
    /// does not already have a symbol table.
    symbol_count_hint: u64 = 32,
    /// Used for calculating how much space to reserve for executable program code in case
    /// the binary file does not already have such a section.
    program_code_size_hint: u64 = 256 * 1024,
    entry_addr: ?u64 = null,
    stack_size_override: ?u64 = null,
    /// Set to `true` to omit debug info.
    strip: bool = false,
    /// If this is true then this link code is responsible for outputting an object
    /// file and then using LLD to link it together with the link options and other objects.
    /// Otherwise (depending on `use_llvm`) this link code directly outputs and updates the final binary.
    use_lld: bool = false,
    /// If this is true then this link code is responsible for making an LLVM IR Module,
    /// outputting it to an object file, and then linking that together with link options and
    /// other objects.
    /// Otherwise (depending on `use_lld`) this link code directly outputs and updates the final binary.
    use_llvm: bool = false,
    link_libc: bool = false,
    link_libcpp: bool = false,
    function_sections: bool = false,
    eh_frame_hdr: bool = false,
    rdynamic: bool = false,
    z_nodelete: bool = false,
    z_defs: bool = false,
    bind_global_refs_locally: bool,
    is_native_os: bool,
    pic: bool,
    valgrind: bool,
    stack_check: bool,
    single_threaded: bool,
    verbose_link: bool = false,
    dll_export_fns: bool,
    error_return_tracing: bool,
    gc_sections: ?bool = null,
    allow_shlib_undefined: ?bool = null,
    linker_script: ?[]const u8 = null,
    version_script: ?[]const u8 = null,
    override_soname: ?[]const u8 = null,
    /// Extra args passed directly to LLD. Ignored when not linking with LLD.
    extra_lld_args: []const []const u8 = &[0][]const u8,

    objects: []const []const u8 = &[0][]const u8{},
    framework_dirs: []const []const u8 = &[0][]const u8{},
    frameworks: []const []const u8 = &[0][]const u8{},
    system_libs: []const []const u8 = &[0][]const u8{},
    lib_dirs: []const []const u8 = &[0][]const u8{},
    rpath_list: []const []const u8 = &[0][]const u8{},

    version: ?std.builtin.Version,
    libc_installation: ?*const LibCInstallation,

    pub fn effectiveOutputMode(options: Options) std.builtin.OutputMode {
        return if (options.use_lld) .Obj else options.output_mode;
    }
};

pub const File = struct {
    tag: Tag,
    options: Options,
    file: ?fs.File,
    allocator: *Allocator,
    /// When linking with LLD, this linker code will output an object file only at
    /// this location, and then this path can be placed on the LLD linker line.
    intermediary_basename: ?[]const u8 = null,

    /// Prevents other processes from clobbering files in the output directory
    /// of this linking operation.
    lock: ?Cache.Lock = null,

    pub const LinkBlock = union {
        elf: Elf.TextBlock,
        coff: Coff.TextBlock,
        macho: MachO.TextBlock,
        c: void,
        wasm: void,
    };

    pub const LinkFn = union {
        elf: Elf.SrcFn,
        coff: Coff.SrcFn,
        macho: MachO.SrcFn,
        c: void,
        wasm: ?Wasm.FnData,
    };

    /// For DWARF .debug_info.
    pub const DbgInfoTypeRelocsTable = std.HashMapUnmanaged(Type, DbgInfoTypeReloc, Type.hash, Type.eql, std.hash_map.DefaultMaxLoadPercentage);

    /// For DWARF .debug_info.
    pub const DbgInfoTypeReloc = struct {
        /// Offset from `TextBlock.dbg_info_off` (the buffer that is local to a Decl).
        /// This is where the .debug_info tag for the type is.
        off: u32,
        /// Offset from `TextBlock.dbg_info_off` (the buffer that is local to a Decl).
        /// List of DW.AT_type / DW.FORM_ref4 that points to the type.
        relocs: std.ArrayListUnmanaged(u32),
    };

    /// Attempts incremental linking, if the file already exists. If
    /// incremental linking fails, falls back to truncating the file and
    /// rewriting it. A malicious file is detected as incremental link failure
    /// and does not cause Illegal Behavior. This operation is not atomic.
    pub fn openPath(allocator: *Allocator, options: Options) !*File {
        const use_lld = build_options.have_llvm and options.use_lld; // comptime known false when !have_llvm
        const sub_path = if (use_lld) blk: {
            if (options.module == null) {
                // No point in opening a file, we would not write anything to it. Initialize with empty.
                return switch (options.object_format) {
                    .coff, .pe => &(try Coff.createEmpty(allocator, options)).base,
                    .elf => &(try Elf.createEmpty(allocator, options)).base,
                    .macho => &(try MachO.createEmpty(allocator, options)).base,
                    .wasm => &(try Wasm.createEmpty(allocator, options)).base,
                    .c => unreachable, // Reported error earlier.
                    .hex => return error.HexObjectFormatUnimplemented,
                    .raw => return error.RawObjectFormatUnimplemented,
                };
            }
            // Open a temporary object file, not the final output file because we want to link with LLD.
            break :blk try std.fmt.allocPrint(allocator, "{}{}", .{ options.sub_path, options.target.oFileExt() });
        } else options.sub_path;
        errdefer if (use_lld) allocator.free(sub_path);

        const file: *File = switch (options.object_format) {
            .coff, .pe => &(try Coff.openPath(allocator, sub_path, options)).base,
            .elf => &(try Elf.openPath(allocator, sub_path, options)).base,
            .macho => &(try MachO.openPath(allocator, sub_path, options)).base,
            .wasm => &(try Wasm.openPath(allocator, sub_path, options)).base,
            .c => &(try C.openPath(allocator, sub_path, options)).base,
            .hex => return error.HexObjectFormatUnimplemented,
            .raw => return error.RawObjectFormatUnimplemented,
        };

        if (use_lld) {
            file.intermediary_basename = sub_path;
        }

        return file;
    }

    pub fn cast(base: *File, comptime T: type) ?*T {
        if (base.tag != T.base_tag)
            return null;

        return @fieldParentPtr(T, "base", base);
    }

    pub fn makeWritable(base: *File) !void {
        switch (base.tag) {
            .coff, .elf, .macho => {
                if (base.file != null) return;
                base.file = try base.options.directory.handle.createFile(base.options.sub_path, .{
                    .truncate = false,
                    .read = true,
                    .mode = determineMode(base.options),
                });
            },
            .c, .wasm => {},
        }
    }

    pub fn makeExecutable(base: *File) !void {
        switch (base.tag) {
            .coff, .elf, .macho => if (base.file) |f| {
                if (base.intermediary_basename != null) {
                    // The file we have open is not the final file that we want to
                    // make executable, so we don't have to close it.
                    return;
                }
                f.close();
                base.file = null;
            },
            .c, .wasm => {},
        }
    }

    /// May be called before or after updateDeclExports but must be called
    /// after allocateDeclIndexes for any given Decl.
    pub fn updateDecl(base: *File, module: *Module, decl: *Module.Decl) !void {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).updateDecl(module, decl),
            .elf => return @fieldParentPtr(Elf, "base", base).updateDecl(module, decl),
            .macho => return @fieldParentPtr(MachO, "base", base).updateDecl(module, decl),
            .c => return @fieldParentPtr(C, "base", base).updateDecl(module, decl),
            .wasm => return @fieldParentPtr(Wasm, "base", base).updateDecl(module, decl),
        }
    }

    pub fn updateDeclLineNumber(base: *File, module: *Module, decl: *Module.Decl) !void {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).updateDeclLineNumber(module, decl),
            .elf => return @fieldParentPtr(Elf, "base", base).updateDeclLineNumber(module, decl),
            .macho => return @fieldParentPtr(MachO, "base", base).updateDeclLineNumber(module, decl),
            .c, .wasm => {},
        }
    }

    /// Must be called before any call to updateDecl or updateDeclExports for
    /// any given Decl.
    pub fn allocateDeclIndexes(base: *File, decl: *Module.Decl) !void {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).allocateDeclIndexes(decl),
            .elf => return @fieldParentPtr(Elf, "base", base).allocateDeclIndexes(decl),
            .macho => return @fieldParentPtr(MachO, "base", base).allocateDeclIndexes(decl),
            .c, .wasm => {},
        }
    }

    pub fn releaseLock(self: *File) void {
        if (self.lock) |*lock| {
            lock.release();
            self.lock = null;
        }
    }

    pub fn toOwnedLock(self: *File) Cache.Lock {
        const lock = self.lock.?;
        self.lock = null;
        return lock;
    }

    pub fn destroy(base: *File) void {
        base.releaseLock();
        if (base.file) |f| f.close();
        if (base.intermediary_basename) |sub_path| base.allocator.free(sub_path);
        switch (base.tag) {
            .coff => {
                const parent = @fieldParentPtr(Coff, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .elf => {
                const parent = @fieldParentPtr(Elf, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .macho => {
                const parent = @fieldParentPtr(MachO, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .c => {
                const parent = @fieldParentPtr(C, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
            .wasm => {
                const parent = @fieldParentPtr(Wasm, "base", base);
                parent.deinit();
                base.allocator.destroy(parent);
            },
        }
    }

    /// Commit pending changes and write headers. Takes into account final output mode
    /// and `use_lld`, not only `effectiveOutputMode`.
    pub fn flush(base: *File, comp: *Compilation) !void {
        const use_lld = build_options.have_llvm and base.options.use_lld;
        if (use_lld and base.options.output_mode == .Lib and base.options.link_mode == .Static and
            !base.options.target.isWasm())
        {
            return base.linkAsArchive(comp);
        }
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).flush(comp),
            .elf => return @fieldParentPtr(Elf, "base", base).flush(comp),
            .macho => return @fieldParentPtr(MachO, "base", base).flush(comp),
            .c => return @fieldParentPtr(C, "base", base).flush(comp),
            .wasm => return @fieldParentPtr(Wasm, "base", base).flush(comp),
        }
    }

    /// Commit pending changes and write headers. Works based on `effectiveOutputMode`
    /// rather than final output mode.
    pub fn flushModule(base: *File, comp: *Compilation) !void {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).flushModule(comp),
            .elf => return @fieldParentPtr(Elf, "base", base).flushModule(comp),
            .macho => return @fieldParentPtr(MachO, "base", base).flushModule(comp),
            .c => return @fieldParentPtr(C, "base", base).flushModule(comp),
            .wasm => return @fieldParentPtr(Wasm, "base", base).flushModule(comp),
        }
    }

    pub fn freeDecl(base: *File, decl: *Module.Decl) void {
        switch (base.tag) {
            .coff => @fieldParentPtr(Coff, "base", base).freeDecl(decl),
            .elf => @fieldParentPtr(Elf, "base", base).freeDecl(decl),
            .macho => @fieldParentPtr(MachO, "base", base).freeDecl(decl),
            .c => unreachable,
            .wasm => @fieldParentPtr(Wasm, "base", base).freeDecl(decl),
        }
    }

    pub fn errorFlags(base: *File) ErrorFlags {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).error_flags,
            .elf => return @fieldParentPtr(Elf, "base", base).error_flags,
            .macho => return @fieldParentPtr(MachO, "base", base).error_flags,
            .c => return .{ .no_entry_point_found = false },
            .wasm => return ErrorFlags{},
        }
    }

    /// May be called before or after updateDecl, but must be called after
    /// allocateDeclIndexes for any given Decl.
    pub fn updateDeclExports(
        base: *File,
        module: *Module,
        decl: *const Module.Decl,
        exports: []const *Module.Export,
    ) !void {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).updateDeclExports(module, decl, exports),
            .elf => return @fieldParentPtr(Elf, "base", base).updateDeclExports(module, decl, exports),
            .macho => return @fieldParentPtr(MachO, "base", base).updateDeclExports(module, decl, exports),
            .c => return {},
            .wasm => return @fieldParentPtr(Wasm, "base", base).updateDeclExports(module, decl, exports),
        }
    }

    pub fn getDeclVAddr(base: *File, decl: *const Module.Decl) u64 {
        switch (base.tag) {
            .coff => return @fieldParentPtr(Coff, "base", base).getDeclVAddr(decl),
            .elf => return @fieldParentPtr(Elf, "base", base).getDeclVAddr(decl),
            .macho => return @fieldParentPtr(MachO, "base", base).getDeclVAddr(decl),
            .c => unreachable,
            .wasm => unreachable,
        }
    }

    fn linkAsArchive(base: *File, comp: *Compilation) !void {
        const tracy = trace(@src());
        defer tracy.end();

        var arena_allocator = std.heap.ArenaAllocator.init(base.allocator);
        defer arena_allocator.deinit();
        const arena = &arena_allocator.allocator;

        const directory = base.options.directory; // Just an alias to make it shorter to type.

        // If there is no Zig code to compile, then we should skip flushing the output file because it
        // will not be part of the linker line anyway.
        const module_obj_path: ?[]const u8 = if (base.options.module) |module| blk: {
            try base.flushModule(comp);

            const obj_basename = base.intermediary_basename.?;
            const full_obj_path = if (directory.path) |dir_path|
                try std.fs.path.join(arena, &[_][]const u8{ dir_path, obj_basename })
            else
                obj_basename;
            break :blk full_obj_path;
        } else null;

        // This function follows the same pattern as link.Elf.linkWithLLD so if you want some
        // insight as to what's going on here you can read that function body which is more
        // well-commented.

        const id_symlink_basename = "llvm-ar.id";

        base.releaseLock();

        var ch = comp.cache_parent.obtain();
        defer ch.deinit();

        try ch.addListOfFiles(base.options.objects);
        for (comp.c_object_table.items()) |entry| {
            _ = try ch.addFile(entry.key.status.success.object_path, null);
        }
        try ch.addOptionalFile(module_obj_path);

        // We don't actually care whether it's a cache hit or miss; we just need the digest and the lock.
        _ = try ch.hit();
        const digest = ch.final();

        var prev_digest_buf: [digest.len]u8 = undefined;
        const prev_digest: []u8 = directory.handle.readLink(id_symlink_basename, &prev_digest_buf) catch |err| b: {
            log.debug("archive new_digest={} readlink error: {}", .{ digest, @errorName(err) });
            break :b prev_digest_buf[0..0];
        };
        if (mem.eql(u8, prev_digest, &digest)) {
            log.debug("archive digest={} match - skipping invocation", .{digest});
            base.lock = ch.toOwnedLock();
            return;
        }

        // We are about to change the output file to be different, so we invalidate the build hash now.
        directory.handle.deleteFile(id_symlink_basename) catch |err| switch (err) {
            error.FileNotFound => {},
            else => |e| return e,
        };

        var object_files = std.ArrayList([*:0]const u8).init(base.allocator);
        defer object_files.deinit();

        try object_files.ensureCapacity(base.options.objects.len + comp.c_object_table.items().len + 1);
        for (base.options.objects) |obj_path| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, obj_path));
        }
        for (comp.c_object_table.items()) |entry| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, entry.key.status.success.object_path));
        }
        if (module_obj_path) |p| {
            object_files.appendAssumeCapacity(try arena.dupeZ(u8, p));
        }

        const full_out_path = if (directory.path) |dir_path|
            try std.fs.path.join(arena, &[_][]const u8{ dir_path, base.options.sub_path })
        else
            base.options.sub_path;
        const full_out_path_z = try arena.dupeZ(u8, full_out_path);

        if (base.options.verbose_link) {
            std.debug.print("ar rcs {}", .{full_out_path_z});
            for (object_files.items) |arg| {
                std.debug.print(" {}", .{arg});
            }
            std.debug.print("\n", .{});
        }

        const llvm = @import("llvm.zig");
        const os_type = @import("target.zig").osToLLVM(base.options.target.os.tag);
        const bad = llvm.WriteArchive(full_out_path_z, object_files.items.ptr, object_files.items.len, os_type);
        if (bad) return error.UnableToWriteArchive;

        directory.handle.symLink(&digest, id_symlink_basename, .{}) catch |err| {
            std.log.warn("failed to save archive hash digest symlink: {}", .{@errorName(err)});
        };

        ch.writeManifest() catch |err| {
            std.log.warn("failed to write cache manifest when archiving: {}", .{@errorName(err)});
        };

        base.lock = ch.toOwnedLock();
    }

    pub const Tag = enum {
        coff,
        elf,
        macho,
        c,
        wasm,
    };

    pub const ErrorFlags = struct {
        no_entry_point_found: bool = false,
    };

    pub const C = @import("link/C.zig");
    pub const Coff = @import("link/Coff.zig");
    pub const Elf = @import("link/Elf.zig");
    pub const MachO = @import("link/MachO.zig");
    pub const Wasm = @import("link/Wasm.zig");
};

pub fn determineMode(options: Options) fs.File.Mode {
    // On common systems with a 0o022 umask, 0o777 will still result in a file created
    // with 0o755 permissions, but it works appropriately if the system is configured
    // more leniently. As another data point, C's fopen seems to open files with the
    // 666 mode.
    const executable_mode = if (std.Target.current.os.tag == .windows) 0 else 0o777;
    switch (options.effectiveOutputMode()) {
        .Lib => return switch (options.link_mode) {
            .Dynamic => executable_mode,
            .Static => fs.File.default_mode,
        },
        .Exe => return executable_mode,
        .Obj => return fs.File.default_mode,
    }
}
