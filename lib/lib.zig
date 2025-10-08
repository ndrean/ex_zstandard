const beam = @import("beam");
const std = @import("std");
const z = @cImport(@cInclude("zstd.h"));

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
// Simple one-shot compression and decompression functions
// -----------------------------------------------------
// const ZST_CONTENTSIZE_UNKNOWN: u64 = std.math.maxInt(u64);
// const ZST_CONTENTSIZE_ERROR: u64 = std.math.maxInt(u64) - 1;

/// Compress `input` with the specified `level` (1-22).
/// Returns the compressed data or an error if compression fails.
pub fn simple_compress(input: []const u8, level: i32) ZstdError![]u8 {
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

    return beam.allocator.realloc(compressed, compressed_size) catch {
        return ZstdError.OutOfMemory;
    };
}

pub fn getDecompressedSize(compressed: []const u8) ZstdError!usize {
    const decompressed_size = z.ZSTD_getFrameContentSize(compressed.ptr, compressed.len);
    if (decompressed_size == std.math.maxInt(u64)) {
        std.log.err("Content size unknown", .{});
        return ZstdError.InvalidInput;
    }
    if (decompressed_size == std.math.maxInt(u64) - 1) {
        std.log.err("Content size error", .{});
        return ZstdError.InvalidInput;
    }

    return @intCast(decompressed_size);
}

pub fn simple_auto_decompress(compressed: []const u8) ZstdError![]u8 {
    const decompressed_size = try getDecompressedSize(compressed);
    // std.debug.print("Decompressed size: {}\n", .{decompressed_size});

    return try simple_decompress(compressed, decompressed_size);
}

pub fn simple_decompress(compressed: []const u8, output_size: usize) ZstdError![]u8 {
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
    if (actual_decompressed_size != output_size) {
        std.log.err("Size mismatch: expected {}, got {}", .{ output_size, actual_decompressed_size });
        return ZstdError.DecompressionFailed;
    }

    return beam.allocator.realloc(decompressed, actual_decompressed_size) catch {
        return ZstdError.OutOfMemory;
    };
}

// -----------------------------------------------------
// Explicit tuple-returning versions
// -----------------------------------------------------

pub fn compress(input: []const u8, level: i32) beam.term {
    const result = simple_compress(input, level) catch |err| {
        return beam.make_error_pair(err, .{});
    };
    return beam.make(.{ .ok, result }, .{});
}

pub fn decompress(compressed: []const u8) beam.term {
    const result = simple_auto_decompress(compressed) catch |err| {
        return beam.make_error_pair(err, .{});
    };
    return beam.make(.{ .ok, result }, .{});
}

// -----------------------------------------------------
// Context-based compression and decompression
// -----------------------------------------------------

const ZSTD_cParameter = enum(i16) {
    ZSTD_c_compressionLevel = 100,
    ZSTD_c_windowLog = 101,
    ZSTD_c_hashLog = 102,
    ZSTD_c_chainLog = 103,
    ZSTD_c_searchLog = 104,
    ZSTD_c_minMatch = 105,
    ZSTD_c_targetLength = 106,
    ZSTD_c_strategy = 107,
    ZSTD_c_targetCBlockSize = 130,
    ZSTD_c_enableLongDistanceMatching = 160,
    ZSTD_c_ldmHashLog = 161,
    ZSTD_c_ldmMinMatch = 162,
    ZSTD_c_ldmBucketSizeLog = 163,
    ZSTD_c_ldmHashRateLog = 164,
    ZSTD_c_contentSizeFlag = 200,
    ZSTD_c_checksumFlag = 201,
    ZSTD_c_dictIDFlag = 202,
    ZSTD_c_nbWorkers = 400,
    ZSTD_c_jobSize = 401,
    ZSTD_c_overlapLog = 402,
};

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
    }
};

/// NIF callback to free the ZstdCCtx when the resource is garbage collected
pub const ZstdDCtxCallback = struct {
    pub fn dtor(handle: **ZstdDCtx) void {
        _ = z.ZSTD_freeDCtx(handle.*.dctx);
        beam.allocator.destroy(handle.*);
    }
};

pub fn cctx_init(compression_level: i32) ZstdError!beam.term {
    if (compression_level < z.ZSTD_minCLevel() or compression_level > z.ZSTD_maxCLevel()) {
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
    const init_result = z.ZSTD_CCtx_setParameter(
        ctx.cctx,
        z.ZSTD_c_compressionLevel,
        compression_level,
    );
    if (z.ZSTD_isError(init_result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(init_result));
        std.log.err("Failed to set compression level: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.InvalidCompressionLevel, .{});
    }

    // Wrap in resource
    const resource = ZstdCResource.create(ctx, .{}) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    return beam.make(.{ .ok, resource }, .{});
}

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

pub fn compress_with_ctx(c_resource: ZstdCResource, input: []const u8) ZstdError!beam.term {
    const cctx = c_resource.unpack().*.cctx.?;
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
    return beam.make(.{ .ok, result }, .{});
}

pub fn decompress_with_ctx(d_resource: ZstdDResource, compressed: []const u8) ZstdError!beam.term {
    const dctx = d_resource.unpack().*.dctx.?;
    const decompressed_size = try getDecompressedSize(compressed);

    const decompressed = beam.allocator.alloc(u8, decompressed_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };

    errdefer beam.allocator.free(decompressed);

    const actual_decompressed_size = z.ZSTD_decompressDCtx(
        dctx,
        decompressed.ptr,
        decompressed_size,
        compressed.ptr,
        compressed.len,
    );

    if (z.ZSTD_isError(actual_decompressed_size) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(actual_decompressed_size));
        std.log.err("Decompression failed: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }
    if (actual_decompressed_size != decompressed_size) {
        std.log.err("Size mismatch: expected {}, got {}", .{ decompressed_size, actual_decompressed_size });
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }

    const result = beam.allocator.realloc(decompressed, actual_decompressed_size) catch {
        return beam.make_error_pair(ZstdError.OutOfMemory, .{});
    };
    return beam.make(.{ .ok, result }, .{});
}

/// NIF To be used:
/// - Between compressing/decompressing different independent data streams
///  - When they want to clear learned dictionaries/patterns
///  - When reusing context for a completely new operation
pub fn reset_compressor_session(c_resource: ZstdCResource) ZstdError!beam.term {
    const cctx = c_resource.unpack().*.cctx.?;
    const reset_result = z.ZSTD_CCtx_reset(cctx, z.ZSTD_reset_session_and_parameters);
    if (z.ZSTD_isError(reset_result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(reset_result));
        std.log.err("Failed to reset compression context: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.CompressionFailed, .{});
    }
    return beam.make_into_atom("ok", .{});
}

// NIF To be used:
/// - Between compressing/decompressing different independent data streams
///  - When they want to clear learned dictionaries/patterns
///  - When reusing context for a completely new operation
pub fn reset_decompressor_session(d_resource: ZstdDResource) ZstdError!beam.term {
    const dctx = d_resource.unpack().*.dctx.?;
    const reset_result = z.ZSTD_DCtx_reset(dctx, z.ZSTD_reset_session_only);
    if (z.ZSTD_isError(reset_result) != 0) {
        const err_name = std.mem.span(z.ZSTD_getErrorName(reset_result));
        std.log.err("Failed to reset decompression context: {s}", .{err_name});
        return beam.make_error_pair(ZstdError.DecompressionFailed, .{});
    }
    return beam.make_into_atom("ok", .{});
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

pub const EndOp = enum {
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

    return beam.make(
        .{ .ok, .{ decompressed, in_buf.pos } },
        .{},
    );
}
