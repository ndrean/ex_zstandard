const beam = @import("beam");
const std = @import("std");
const builtin = @import("builtin");
const z = @cImport({
    @cDefine("ZSTD_STATIC_LINKING_ONLY", "1");
    @cInclude("zstd.h");
    @cInclude("zdict.h");
});

// Check if NIF timing is enabled (compile-time based on build mode)
// Timing is automatically enabled in Debug builds, disabled in Release builds
// No runtime overhead - the check is optimized away at compile time
inline fn isTimingEnabled() bool {
    return builtin.mode == .Debug;
}

pub fn version() []const u8 {
    return std.mem.span(z.ZSTD_versionString());
}

const ZstdError = error{
    CompressionFailed,
    DecompressionFailed,
    InvalidInput,
    OutOfMemory,
    InvalidCompressionLevel,
    StreamCompressionFailed,
    StreamDecompressionFailed,
};

// -----------------------------------------------------
// Strategy
// -----------------------------------------------------

pub const ZSTD_strategy = enum(i16) {
    ZSTD_fast = 1,
    ZSTD_dfast = 2,
    ZSTD_greedy = 3,
    ZSTD_lazy = 4,
    ZSTD_lazy2 = 5,
    ZSTD_btlazy2 = 6,
    ZSTD_btopt = 7,
    ZSTD_btultra = 8,
    ZSTD_btultra2 = 9,
};

/// Compression recipes for different data types.
/// Level 1 is fastest, 22 is slowest but best compression. 3 is the default.
/// Use presets like "text", "structured_data", or "binary" for optimized compression of specific data types.
pub const CompressionRecipe = enum {
    /// Fast compression for any data type (level 1, fast strategy)
    fast,
    /// Balanced compression/speed (level 3, default strategy)
    balanced,
    /// Maximum compression (level 22, btultra2 strategy)
    maximum,
    /// Optimized for text/code (level 9, btopt strategy)
    text,
    /// Optimized for JSON/XML (level 9, btultra strategy)
    structured_data,
    /// Optimized for binary data (level 6, lazy2 strategy)
    binary,

    pub fn getLevel(self: CompressionRecipe) i16 {
        return switch (self) {
            .fast => 1,
            .balanced => 3,
            .maximum => 22,
            .text => 9,
            .structured_data => 9,
            .binary => 6,
        };
    }

    pub fn getStrategy(self: CompressionRecipe) ZSTD_strategy {
        return switch (self) {
            .fast => .ZSTD_fast,
            .balanced => .ZSTD_dfast,
            .maximum => .ZSTD_btultra2,
            .text => .ZSTD_btopt,
            .structured_data => .ZSTD_btultra,
            .binary => .ZSTD_lazy2,
        };
    }
};

// -----------------------------------------------------
// Simple one-shot compression and decompression functions
// -----------------------------------------------------

/// Compress binary data with the specified `level` (1-22).
/// Returns the compressed data or an error if compression fails.
fn simple_compress(input: []const u8, level: i32) ZstdError!beam.term {
    const enable_timing = isTimingEnabled();
    const start_time = if (enable_timing) std.time.nanoTimestamp() else 0;
    defer if (enable_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        std.debug.print("[NIF Simple Compress] {d:.3} ms, level: {d}, for: {} bytes)\n", .{ elapsed_ms, level, input.len });
    };

    const max_compressed_size = z.ZSTD_compressBound(input.len);
    if (z.ZSTD_isError(max_compressed_size) == 1) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(max_compressed_size));
        std.log.err("Compression failed: {s}", .{err_name});
        return ZstdError.CompressionFailed;
    }

    const compressed = try beam.allocator.alloc(u8, max_compressed_size);
    errdefer beam.allocator.free(compressed);

    const compressed_size = z.ZSTD_compress(
        compressed.ptr,
        max_compressed_size,
        input.ptr,
        input.len,
        level,
    );
    if (z.ZSTD_isError(compressed_size) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(compressed_size));
        std.log.err("Compression failed: {s}", .{err_name});
        return ZstdError.CompressionFailed;
    }

    const slice = beam.allocator.realloc(compressed, compressed_size) catch {
        return ZstdError.OutOfMemory;
    };
    defer beam.allocator.free(slice);
    return beam.make(slice, .{});
}

/// Get the decompressed size from the compressed data frame header.
/// Returning null if unknown (for streaming-compressed data)
pub fn getDecompressedSize(compressed: []const u8) ?usize {
    const decompressed_size = z.ZSTD_getFrameContentSize(compressed.ptr, compressed.len);
    // ZSTD_CONTENTSIZE_UNKNOWN = maxInt(u64)
    if (decompressed_size == std.math.maxInt(u64)) {
        return null;
    }
    // ZSTD_CONTENTSIZE_ERROR = maxInt(u64) - 1 - corrupted frame
    if (decompressed_size == std.math.maxInt(u64) - 1) {
        return null;
    }
    return @intCast(decompressed_size);
}

/// Decompress binary data with automatic output size detection.
fn auto_decompress(compressed: []const u8) ZstdError!beam.term {
    const decompressed_size = getDecompressedSize(compressed) orelse compressed.len * 10;

    return try simple_decompress(compressed, decompressed_size);
}

/// Decompress binary data into a buffer of size `output_size`. Use `decompress` for automatic size detection instead.
fn simple_decompress(compressed: []const u8, output_size: usize) ZstdError!beam.term {
    const decompressed = beam.allocator.alloc(u8, output_size) catch {
        return ZstdError.OutOfMemory;
    };
    errdefer beam.allocator.free(decompressed);

    const actual_decompressed_size = z.ZSTD_decompress(
        decompressed.ptr,
        output_size,
        compressed.ptr,
        compressed.len,
    );

    if (z.ZSTD_isError(actual_decompressed_size) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(actual_decompressed_size));
        std.log.err("Decompression failed: {s}", .{err_name});
        return ZstdError.DecompressionFailed;
    }

    // Resize to actual size (no equality check needed - we allocated enough space)
    // This allows estimated sizes (e.g., compressed.len * 10) to work correctly
    const slice = beam.allocator.realloc(decompressed, actual_decompressed_size) catch {
        return ZstdError.OutOfMemory;
    };
    defer beam.allocator.free(slice);
    return beam.make(slice, .{});
}

// -----------------------------------------------------
// Explicit tuple-returning versions
// -----------------------------------------------------

/// Compress binary data with specified compression level (1-22).
pub fn compress(input: []const u8, level: i32) beam.term {
    const result = simple_compress(input, level) catch |err| {
        return beam.make_error_pair(err, .{});
    };
    return beam.make(.{ .ok, result }, .{});
}

/// Decompress binary data with automatic output size detection.
pub fn decompress(compressed: []const u8) beam.term {
    const enable_timing = isTimingEnabled();
    const start_time = if (enable_timing) std.time.nanoTimestamp() else 0;
    defer if (enable_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        std.debug.print("[NIF Simple Decompress] {d:.3} ms, for: {} bytes)\n", .{ elapsed_ms, compressed.len });
    };
    const result = auto_decompress(compressed) catch |err| {
        return beam.make_error_pair(err, .{});
    };

    return beam.make(.{ .ok, result }, .{});
}

// -----------------------------------------------------
// Context-based compression and decompression
// -----------------------------------------------------

/// Configuration for compression context
// pub const CompressionConfig = struct {
//     compression_level: i32 = 3,
//     strategy: ?CompressionRecipe = .balanced,
// };
pub const CompressionConfig = struct {
    compression_level: ?i32 = null,
    strategy: ?CompressionRecipe = .balanced,
};

const ZstdCCtx = struct {
    cctx: ?*z.ZSTD_CCtx,
};

const ZstdDCtx = struct {
    dctx: ?*z.ZSTD_DCtx,
};

pub const ZstdCResource = beam.Resource(*ZstdCCtx, @import("root"), .{ .Callbacks = ZstdCCtxCallback });
pub const ZstdDResource = beam.Resource(*ZstdDCtx, @import("root"), .{ .Callbacks = ZstdDCtxCallback });

/// NIF callback to free the ZstdCCtx when the resource is garbage collected
pub const ZstdCCtxCallback = struct {
    pub fn dtor(handle: **ZstdCCtx) void {
        _ = z.ZSTD_freeCCtx(handle.*.cctx);
        beam.allocator.destroy(handle.*);
        if (@import("builtin").mode == .Debug) std.debug.print("CDOTR called\n", .{});
    }
};

/// NIF callback to free the ZstdDCtx when the resource is garbage collected
pub const ZstdDCtxCallback = struct {
    pub fn dtor(handle: **ZstdDCtx) void {
        _ = z.ZSTD_freeDCtx(handle.*.dctx);
        beam.allocator.destroy(handle.*);
        if (@import("builtin").mode == .Debug) std.debug.print("DDOTR called\n", .{});
    }
};

/// The compression context initialization function.
/// It takes a CompressionConfig struct with optional compression_level (1-22) and optional strategy (CompressionRecipe).
///
/// Usage:
///   - cctx_init(.{}) - Use defaults: level 3 + dfast strategy
///   - cctx_init(.{.strategy = .text}) - Use recipe defaults: level 9 + btopt strategy
///   - cctx_init(.{.compression_level = 15, .strategy = .text}) - Custom level with recipe strategy
///   - cctx_init(.{.compression_level = 5}) - Custom level with default strategy
pub fn cctx_init(config: CompressionConfig) ZstdError!beam.term {
    // Determine compression level: explicit > recipe default > 3
    const level = if (config.strategy) |recipe| blk: {
        // Recipe provided: use explicit level or recipe's level
        break :blk config.compression_level orelse recipe.getLevel();
    } else blk: {
        // No recipe: use explicit level or default 3
        break :blk config.compression_level orelse 3;
    };

    if (level < z.ZSTD_minCLevel() or level > z.ZSTD_maxCLevel()) {
        return beam.make_error_pair(ZstdError.InvalidCompressionLevel, .{});
    }

    // Create the ZstdCCtx struct
    const ctx = beam.allocator.create(ZstdCCtx) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.destroy(ctx);

    // Create the libzstd compression context
    ctx.cctx = z.ZSTD_createCCtx() orelse {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer _ = z.ZSTD_freeCCtx(ctx.cctx);

    // Set compression level
    var result = z.ZSTD_CCtx_setParameter(
        ctx.cctx,
        z.ZSTD_c_compressionLevel,
        level,
    );
    if (z.ZSTD_isError(result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(result));
        std.log.err("Failed to set compression level: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.InvalidCompressionLevel, .{});
    }

    // Set strategy from recipe or use default
    const strategy = if (config.strategy) |recipe|
        recipe.getStrategy()
    else
        ZSTD_strategy.ZSTD_dfast;

    result = z.ZSTD_CCtx_setParameter(
        ctx.cctx,
        z.ZSTD_c_strategy,
        @intFromEnum(strategy),
    );
    if (z.ZSTD_isError(result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(result));
        std.log.err("Failed to set strategy: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.InvalidCompressionLevel, .{});
    }

    // Wrap in resource
    const resource = ZstdCResource.create(ctx, .{}) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    return beam.make(.{ .ok, resource }, .{});
}

/// The decompression context initialization function.
/// It takes a max_window: Optional maximum window size as power of 2 (10-31), or `nil`.
pub fn dctx_init(max_window: ?i32) ZstdError!beam.term {
    // Create the ZstdDCtx struct
    const ctx = beam.allocator.create(ZstdDCtx) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.destroy(ctx);

    // Create the libzstd decompression context
    ctx.dctx = z.ZSTD_createDCtx() orelse {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer _ = z.ZSTD_freeDCtx(ctx.dctx);

    // Set max window size if provided
    if (max_window) |mw| {
        if (mw < 10 or mw > 31) {
            return beam.make_error_pair(ZstdError.InvalidInput, .{});
        }

        const result = z.ZSTD_DCtx_setParameter(
            ctx.dctx,
            z.ZSTD_d_windowLogMax,
            mw,
        );
        if (z.ZSTD_isError(result) != 0) {
            const err_name = std.mem.span(z.ZSTD_getErrorName(result));
            std.log.err("Failed to set max window size: {s}", .{err_name});
            return beam.make_error_pair(ZstdError.InvalidInput, .{});
        }
    }

    // Wrap in resource
    const resource = ZstdDResource.create(ctx, .{}) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    return beam.make(.{ .ok, resource }, .{});
}

/// Compress binary data using the provided compression context.
/// PERFORMANCE NOTE: For large inputs (>1MB), this may take >1ms. Consider using compress_file for very large data.
pub fn compress_with_ctx(c_resource: ZstdCResource, input: []const u8) ZstdError!beam.term {
    const cctx = c_resource.unpack().*.cctx.?;
    const enable_timing = isTimingEnabled();
    const start_time = if (enable_timing) std.time.nanoTimestamp() else 0;
    defer if (enable_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        var c_level: i32 = undefined;
        var c_strategy: i32 = undefined;
        _ = z.ZSTD_CCtx_getParameter(cctx, z.ZSTD_c_compressionLevel, &c_level);
        _ = z.ZSTD_CCtx_getParameter(cctx, z.ZSTD_c_strategy, &c_strategy);

        std.debug.print("[NIF Compress_with_ctx] level: {d}, strategy: {d}, duration: {d:.3} ms, for: {} bytes)\n", .{ c_level, c_strategy, elapsed_ms, input.len });
    };

    const max_compressed_size = z.ZSTD_compressBound(input.len);
    if (z.ZSTD_isError(max_compressed_size) == 1) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(max_compressed_size));
        std.log.err("Compression failed: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    const compressed = beam.allocator.alloc(u8, max_compressed_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.free(compressed);

    const compressed_size = z.ZSTD_compress2(
        cctx,
        compressed.ptr,
        max_compressed_size,
        input.ptr,
        input.len,
    );
    if (z.ZSTD_isError(compressed_size) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(compressed_size));
        std.log.err("Compression failed: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    const result = beam.allocator.realloc(compressed, compressed_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(result);
    return beam.make(.{ .ok, result }, .{});
}

/// Decompress binary data using the provided decompression context.
/// Requires the compressed data to have the decompressed size in the frame header.
/// For streaming-compressed data without size, use decompress_with_ctx_streaming instead.
/// PERFORMANCE NOTE: For large outputs (>1MB), this may take >1ms. Consider using decompress_unfold or decompress_file for very large data.
// pub fn decompress_with_ctx(d_resource: ZstdDResource, compressed: []const u8) ZstdError!beam.term {
//     const dctx = d_resource.unpack().*.dctx.?;
//     const decompressed_size = try getDecompressedSize(compressed);

//     const decompressed = beam.allocator.alloc(u8, decompressed_size) catch {
//         return beam.make_error_pair(ZstdError.OutOfMemory, .{});
//     };

//     errdefer beam.allocator.free(decompressed);

//     const actual_decompressed_size = z.ZSTD_decompressDCtx(
//         dctx,
//         decompressed.ptr,
//         decompressed_size,
//         compressed.ptr,
//         compressed.len,
//     );

//     if (z.ZSTD_isError(actual_decompressed_size) != 0) {
//         const err_name = std.mem.span(z.ZSTD_getErrorName(actual_decompressed_size));
//         std.log.err("Decompression failed: {s}", .{err_name});
//         return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
//     }
//     if (actual_decompressed_size != decompressed_size) {
//         std.log.err("Size mismatch: expected {}, got {}", .{ decompressed_size, actual_decompressed_size });
//         return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
//     }

//     const result = beam.allocator.realloc(decompressed, actual_decompressed_size) catch {
//         return beam.make_error_pair(ZstdError.OutOfMemory, .{});
//     };
//     return beam.make(.{ .ok, result }, .{});
// }

/// Decompress binary data using the provided decompression context.
/// Works with both regular and streaming-compressed data (with or without size in frame).
/// For streaming-compressed data, uses incremental decompression with buffer growth.
/// PERFORMANCE WARNING: This decompresses the entire input in one shot and can take >1ms for large files (>1MB).
/// For very large files, prefer decompress_file or decompress_unfold which use chunked streaming.
pub fn decompress_with_ctx(d_resource: ZstdDResource, compressed: []const u8) ZstdError!beam.term {
    const dctx = d_resource.unpack().*.dctx.?;
    const enable_timing = isTimingEnabled();
    const start_time = if (enable_timing) std.time.nanoTimestamp() else 0;
    defer if (enable_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

        std.debug.print("[NIF decompress_with_ctx] {d:.3} ms, for: {} bytes)\n", .{ elapsed_ms, compressed.len });
    };

    // Try to get the size from frame header first
    if (getDecompressedSize(compressed)) |known_size| {
        // Size is known, use regular decompression
        const decompressed = beam.allocator.alloc(u8, known_size) catch {
            return beam.make_error_pair(ZstdError.OutOfMemory, .{});
        };
        errdefer beam.allocator.free(decompressed);

        const actual_size = z.ZSTD_decompressDCtx(
            dctx,
            decompressed.ptr,
            known_size,
            compressed.ptr,
            compressed.len,
        );

        if (z.ZSTD_isError(actual_size) != 0) {
            const err_name = std.mem.span(z.ZSTD_getErrorName(actual_size));
            std.log.err("Decompression failed: {s}", .{err_name});
            return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
        }

        const result = beam.allocator.realloc(decompressed, actual_size) catch {
            return beam.make_error_pair(ZstdError.OutOfMemory, .{});
        };
        defer beam.allocator.free(result);
        return beam.make(.{ .ok, result }, .{});
    } else {
        // Size unknown - estimate based on compressed size (typical compression ratio)
        // Start with 10x the compressed size as initial buffer
        const initial_estimate = compressed.len * 10;
        const decompressed = beam.allocator.alloc(u8, initial_estimate) catch {
            return beam.make_error_pair(ZstdError.OutOfMemory, .{});
        };
        errdefer beam.allocator.free(decompressed);

        const actual_size = z.ZSTD_decompressDCtx(
            dctx,
            decompressed.ptr,
            initial_estimate,
            compressed.ptr,
            compressed.len,
        );

        if (z.ZSTD_isError(actual_size) != 0) {
            const err_name = std.mem.span(z.ZSTD_getErrorName(actual_size));
            std.log.err("Decompression failed: {s}", .{err_name});
            return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
        }

        // Resize to actual size
        const result = beam.allocator.realloc(decompressed, actual_size) catch {
            return beam.make_error_pair(ZstdError.OutOfMemory, .{});
        };
        defer beam.allocator.free(result);
        return beam.make(.{ .ok, result }, .{});
    }
}

/// Reset compression context to reuse for a new independent operation.
/// Use this:
/// - Between compressing different independent data streams
/// - To clear learned dictionaries/patterns
/// - When reusing context for a completely new operation
pub fn reset_compressor(c_resource: ZstdCResource) ZstdError!beam.term {
    const cctx = c_resource.unpack().*.cctx.?;
    const reset_result = z.ZSTD_CCtx_reset(cctx, z.ZSTD_reset_session_and_parameters);
    if (z.ZSTD_isError(reset_result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(reset_result));
        std.log.err("Failed to reset compression context: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }
    return beam.make_into_atom("ok", .{});
}

/// Reset decompression context to reuse for a new independent operation.
/// Use this:
/// - Between decompressing different independent data streams
/// - To clear loaded dictionaries
/// - When reusing context for a completely new operation
pub fn reset_decompressor(d_resource: ZstdDResource) ZstdError!beam.term {
    const dctx = d_resource.unpack().*.dctx.?;
    const reset_result = z.ZSTD_DCtx_reset(dctx, z.ZSTD_reset_session_and_parameters);
    if (z.ZSTD_isError(reset_result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(reset_result));
        std.log.err("Failed to reset decompression context: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }
    return beam.make_into_atom("ok", .{});
}

/// Get compression parameters from a compression context.
/// Returns {:ok, {level, strategy_atom, window_log}}
///
/// Example return value:
/// {:ok, {9, :btopt, 23}}
pub fn get_compression_params(c_resource: ZstdCResource) beam.term {
    const cctx = c_resource.unpack().*.cctx.?;

    // Get compression level
    var level: i32 = undefined;
    var result = z.ZSTD_CCtx_getParameter(cctx, z.ZSTD_c_compressionLevel, &level);
    if (z.ZSTD_isError(result) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    // Get strategy
    var strategy_value: i32 = undefined;
    result = z.ZSTD_CCtx_getParameter(cctx, z.ZSTD_c_strategy, &strategy_value);
    if (z.ZSTD_isError(result) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    // Get window log
    var window_log: i32 = undefined;
    result = z.ZSTD_CCtx_getParameter(cctx, z.ZSTD_c_windowLog, &window_log);
    if (z.ZSTD_isError(result) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    // Convert strategy int to atom
    const strategy_atom = switch (strategy_value) {
        1 => beam.make_into_atom("fast", .{}),
        2 => beam.make_into_atom("dfast", .{}),
        3 => beam.make_into_atom("greedy", .{}),
        4 => beam.make_into_atom("lazy", .{}),
        5 => beam.make_into_atom("lazy2", .{}),
        6 => beam.make_into_atom("btlazy2", .{}),
        7 => beam.make_into_atom("btopt", .{}),
        8 => beam.make_into_atom("btultra", .{}),
        9 => beam.make_into_atom("btultra2", .{}),
        else => beam.make_into_atom("unknown", .{}),
    };

    // Return tuple
    return beam.make(.{ .ok, .{ level, strategy_atom, window_log } }, .{});
}

// -----------------------------------------------------
// Context-based streaming compression and decompression
// -----------------------------------------------------

/// Returns the recommended input buffer size for streaming compression (typically 128KB)
pub fn recommended_c_in_size() usize {
    return z.ZSTD_CStreamInSize();
}

/// Returns the recommended output buffer size for streaming compression
pub fn recommended_c_out_size() usize {
    return z.ZSTD_CStreamOutSize();
}

/// Returns the recommended input buffer size for streaming decompression (typically 128KB)
pub fn recommended_d_in_size() usize {
    return z.ZSTD_DStreamInSize();
}

/// Returns the recommended output buffer size for streaming decompression (typically 128KB)
pub fn recommended_d_out_size() usize {
    return z.ZSTD_DStreamOutSize();
}

// EndOp modes:
/// - :continue_op - Buffer data for better compression. May produce little/no output.
/// Use when more data is coming.
/// - :flush - Force output of buffered data into a complete block. Guarantees output.
/// Slightly reduces compression ratio. Use for real-time streaming.
/// - :end_frame - Finalize and close the frame. Call with empty input (<<>>) after
/// all data is sent, or with the last chunk. Adds frame footer/checksum.
const EndOp = enum {
    continue_op,
    flush,
    end_frame,

    fn toZstd(self: EndOp) c_uint {
        return switch (self) {
            .continue_op => z.ZSTD_e_continue,
            .flush => z.ZSTD_e_flush,
            .end_frame => z.ZSTD_e_end,
        };
    }
};

/// Compress a chunk of data using streaming compression.
/// Returns {:ok, {compressed_data, bytes_consumed, remaining_bytes}} or {:error, reason}
///
/// Parameters:
/// - ctx: Compression context created with cctx_init
/// - input: Data to compress (all input will be consumed)
/// - end_op: Operation mode (see below)
///
/// EndOp modes:
/// - :continue_op - Buffer data for better compression. May produce little/no output.
///                  Use when more data is coming.
/// - :flush - Force output of buffered data into a complete block. Guarantees output.
///            Slightly reduces compression ratio. Use for real-time streaming.
/// - :end_frame - Finalize and close the frame. Call with empty input (<<>>) after
///                all data is sent, or with the last chunk. Adds frame footer/checksum.
///
/// Return values:
/// - compressed_data: Compressed output (may be empty with :continue_op if buffering)
/// - bytes_consumed: How many input bytes were processed (usually all)
/// - remaining_bytes: Work remaining hint (0 = operation complete, >0 = call again)
///                    For :end_frame, if >0, call again with <<>> until it returns 0
pub fn compress_stream(ctx: ZstdCResource, input: []const u8, end_op: EndOp) ZstdError!beam.term {
    const enable_timing = isTimingEnabled();
    const start_time = if (enable_timing) std.time.nanoTimestamp() else 0;
    defer if (enable_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        const elapsed_us = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        std.debug.print("\n[NIF compress_stream] {d:.3} ms, for: {} bytes\n", .{ elapsed_us, input.len });
    };

    const cctx = ctx.unpack().*.cctx.?;

    // Allocate output buffer using recommended size
    const out_buf_size = z.ZSTD_CStreamOutSize();
    const output_data = beam.allocator.alloc(u8, out_buf_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.free(output_data);

    // Setup buffers
    var in_buf = z.ZSTD_inBuffer_s{
        .src = input.ptr,
        .size = input.len,
        .pos = 0,
    };

    var out_buf = z.ZSTD_outBuffer_s{
        .dst = output_data.ptr,
        .size = out_buf_size,
        .pos = 0,
    };

    // Compress
    const remaining = z.ZSTD_compressStream2(
        cctx,
        &out_buf,
        &in_buf,
        end_op.toZstd(),
    );

    if (z.ZSTD_isError(remaining) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(remaining));
        std.log.err("Stream compression failed: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.StreamCompressionFailed, .{});
    }

    // Resize output to actual size
    const compressed = beam.allocator.realloc(output_data, out_buf.pos) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(compressed);

    return beam.make(
        .{ .ok, .{ compressed, in_buf.pos, remaining } },
        .{},
    );
}

/// Decompress a chunk of data using streaming decompression.
/// Returns {:ok, {decompressed_data, bytes_consumed}} or {:error, reason}
///
/// - decompressed_data: The decompressed output (may be empty if buffering)
/// - bytes_consumed: How many bytes from input were consumed
pub fn decompress_stream(ctx: ZstdDResource, input: []const u8) ZstdError!beam.term {
    const enable_timing = isTimingEnabled();
    const start_time = if (enable_timing) std.time.nanoTimestamp() else 0;
    defer if (enable_timing) {
        const elapsed_ns = std.time.nanoTimestamp() - start_time;
        const elapsed_us = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
        std.debug.print("[NIF decompress_stream] {d:.3} ms , for: {} bytes\n", .{ elapsed_us, input.len });
    };

    const dctx = ctx.unpack().*.dctx.?;

    // Allocate output buffer using recommended size
    const out_buf_size = z.ZSTD_DStreamOutSize();
    const output_data = beam.allocator.alloc(u8, out_buf_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.free(output_data);

    // Setup buffers
    var in_buf = z.ZSTD_inBuffer_s{
        .src = input.ptr,
        .size = input.len,
        .pos = 0,
    };

    var out_buf = z.ZSTD_outBuffer_s{
        .dst = output_data.ptr,
        .size = out_buf_size,
        .pos = 0,
    };

    // Decompress
    const result = z.ZSTD_decompressStream(dctx, &out_buf, &in_buf);

    if (z.ZSTD_isError(result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(result));
        std.log.err("Stream decompression failed: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.StreamDecompressionFailed, .{});
    }

    // Resize output to actual size
    const decompressed = beam.allocator.realloc(output_data, out_buf.pos) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(decompressed);

    return beam.make(
        .{ .ok, .{ decompressed, in_buf.pos } },
        .{},
    );
}

// -----------------------------------------------------
// Dictionary compression and decompression
// -----------------------------------------------------

/// Train a dictionary from sample data for better compression of similar small files.
///
/// Parameters:
/// - samples: List of sample data buffers to train on (minimum 20 samples recommended)
/// - dict_size: Target dictionary size in bytes (typically 100KB for small data)
///
/// Returns {:ok, dictionary} on success, {:error, reason} on failure
pub fn train_dictionary(samples: [][]const u8, dict_size: usize) ZstdError!beam.term {
    if (samples.len == 0) {
        return beam.make_error_pair(ZstdError.InvalidInput, .{});
    }

    // Calculate total samples size
    var total_size: usize = 0;
    for (samples) |sample| {
        total_size += sample.len;
    }

    // Flatten samples into contiguous buffer and create sizes array
    const samples_buffer = beam.allocator.alloc(u8, total_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(samples_buffer);

    const sample_sizes = beam.allocator.alloc(usize, samples.len) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(sample_sizes);

    var offset: usize = 0;
    for (samples, 0..) |sample, i| {
        @memcpy(samples_buffer[offset .. offset + sample.len], sample);
        sample_sizes[i] = sample.len;
        offset += sample.len;
    }

    // Allocate dictionary buffer
    var dict_buffer = beam.allocator.alloc(u8, dict_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.free(dict_buffer);

    // Train dictionary
    const result = z.ZDICT_trainFromBuffer(
        dict_buffer.ptr,
        dict_size,
        samples_buffer.ptr,
        sample_sizes.ptr,
        @intCast(samples.len),
    );

    if (z.ZDICT_isError(result) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    // Resize to actual dictionary size
    // Note: realloc frees dict_buffer internally if it allocates new memory
    dict_buffer = beam.allocator.realloc(dict_buffer, result) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(dict_buffer);

    return beam.make(.{ .ok, dict_buffer }, .{});
}

/// Load a dictionary into a compression context for reuse across multiple compressions.
/// The dictionary remains loaded until a new one is loaded or the context is reset.
pub fn load_compression_dictionary(c_resource: ZstdCResource, dictionary: []const u8) ZstdError!beam.term {
    const cctx = c_resource.unpack().*.cctx.?;

    const result = z.ZSTD_CCtx_loadDictionary(cctx, dictionary.ptr, dictionary.len);
    if (z.ZSTD_isError(result) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    return beam.make(.ok, .{});
}

/// Load a dictionary into a decompression context for reuse across multiple decompressions.
/// The dictionary remains loaded until a new one is loaded or the context is reset.
pub fn load_decompression_dictionary(d_resource: ZstdDResource, dictionary: []const u8) ZstdError!beam.term {
    const dctx = d_resource.unpack().*.dctx.?;

    const result = z.ZSTD_DCtx_loadDictionary(dctx, dictionary.ptr, dictionary.len);
    if (z.ZSTD_isError(result) != 0) {
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }

    return beam.make(.ok, .{});
}

/// Compress data using a dictionary for better compression of small similar files.
/// The dictionary should be trained on representative sample data.
/// Uses the compression settings already configured in the context.
pub fn compress_with_dict(c_resource: ZstdCResource, input: []const u8, dictionary: []const u8) ZstdError!beam.term {
    const bound = z.ZSTD_compressBound(input.len);
    if (z.ZSTD_isError(bound) == 1) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    const out = beam.allocator.alloc(u8, bound) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.free(out);

    const cctx = c_resource.unpack().*.cctx.?;

    // Load dictionary into context
    const load_result = z.ZSTD_CCtx_loadDictionary(cctx, dictionary.ptr, dictionary.len);
    if (z.ZSTD_isError(load_result) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    // Compress using the context with loaded dictionary
    const written_size = z.ZSTD_compress2(cctx, out.ptr, bound, input.ptr, input.len);
    if (z.ZSTD_isError(written_size) != 0) {
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }

    const compressed = beam.allocator.realloc(out, written_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    defer beam.allocator.free(compressed);

    return beam.make(.{ .ok, compressed }, .{});
}

/// Decompress data that was compressed using a dictionary.
/// Output size is automatically determined from the frame.
pub fn decompress_with_dict(d_resource: ZstdDResource, input: []const u8, dictionary: []const u8) ZstdError!beam.term {
    const dctx = d_resource.unpack().*.dctx.?;

    // Get decompressed size from frame
    const decompressed_size = z.ZSTD_getFrameContentSize(input.ptr, input.len);
    // ZSTD_CONTENTSIZE_ERROR = max u64 - 1
    // ZSTD_CONTENTSIZE_UNKNOWN = max u64
    if (decompressed_size == std.math.maxInt(u64) - 1) {
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }
    if (decompressed_size == std.math.maxInt(u64)) {
        return beam.make_error_pair(ZstdError.InvalidInput, .{});
    }

    const out = beam.allocator.alloc(u8, decompressed_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    errdefer beam.allocator.free(out);

    // Load dictionary into context
    const load_result = z.ZSTD_DCtx_loadDictionary(dctx, dictionary.ptr, dictionary.len);
    if (z.ZSTD_isError(load_result) != 0) {
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }

    // Decompress using the context with loaded dictionary
    const written = z.ZSTD_decompressDCtx(dctx, out.ptr, decompressed_size, input.ptr, input.len);
    if (z.ZSTD_isError(written) != 0) {
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }
    defer beam.allocator.free(out);

    return beam.make(.{ .ok, out }, .{});
}
