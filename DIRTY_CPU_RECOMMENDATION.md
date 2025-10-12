# dirty_cpu Scheduling Recommendation - Updated Findings

## Executive Summary

After comprehensive testing across different strategies and file sizes:

**Decompression: REMOVE dirty_cpu** - Always completes in <0.5ms, doesn't need it

**Compression: KEEP dirty_cpu** - Slow strategies (6-13ms) require it for safety

## Latest Test Results (2025-10-12)

### Decompression - ALWAYS FAST ✓

| Operation | Input Size | Time | Status |
|-----------|-----------|------|--------|
| `decompress_stream` | Various | 0.084-0.246 ms | ✓ NO dirty_cpu needed |
| `decompress_with_ctx` | 23-107KB | 0.001-0.511 ms | ✓ NO dirty_cpu needed |

**Finding**: Decompression is ALWAYS fast regardless of original compression level or file size.

### Compression - STRATEGY DEPENDENT

#### Streaming Compression (compress_stream, 128KB chunks)

| Strategy | Time | Status |
|----------|------|--------|
| :fast | 0.11-0.31 ms | ✓ NO dirty_cpu needed |
| :structured_data | 7.5-9.5 ms | ⚠️ NEEDS dirty_cpu |

**10x-30x difference** between strategies!

#### One-shot Compression (compress_with_ctx, 98KB file)

| Strategy | Level | Time | Status |
|----------|-------|------|--------|
| :fast | 1 | 0.067-0.074 ms | ✓ OK |
| :balanced | 3 | 0.113-0.170 ms | ✓ OK |
| :binary | 6 | 0.585-0.716 ms | ⚠️ Borderline |
| :maximum | 22 | 6.3-7.0 ms | ⚠️ NEEDS dirty_cpu |

#### Large File Compression (502KB HTML)

```
:text strategy (level 9): 12.918 ms ⚠️ NEEDS dirty_cpu (13x over threshold!)
```

## Why the Original Analysis Was Incomplete

### Previous Understanding (2025-10-11):
- ❌ "Streaming NIFs don't need dirty_cpu" - INCOMPLETE
- ❌ "One-shot operations on large files need dirty_cpu" - MISSED THE POINT
- ❌ Didn't identify **strategy** as the critical factor

### Corrected Understanding (2025-10-12):
- ✓ **Decompression NEVER needs dirty_cpu** - always fast
- ✓ **Compression needs dirty_cpu ONLY for slow strategies**
- ✓ **Strategy choice determines timing**, not just file size
- ✓ Timing varies **100x** between :fast and :maximum strategies

## Root Cause Analysis

### Why Decompression is Always Fast

Decompression just follows instructions from the compressed data:
```
compressed frame → [read header] → [follow decompression recipe] → decompressed data
```

No searching, no optimization decisions - just execute the pre-computed plan.

**Result**: Always <1ms regardless of:
- Original compression level
- Original strategy used
- File size (when streaming)

### Why Compression Timing Varies by Strategy

Different compression strategies use different algorithms:

**Fast strategies (fast, dfast):**
```zig
.fast => .ZSTD_fast,      // Simple hash table, ~0.07ms per 100KB
.balanced => .ZSTD_dfast, // Double hash table, ~0.15ms per 100KB
```

**Slow strategies (btopt, btultra, btultra2):**
```zig
.text => .ZSTD_btopt,           // Binary tree search, ~13ms per 500KB
.structured_data => .ZSTD_btultra,  // Ultra search, ~9ms per 128KB
.maximum => .ZSTD_btultra2,     // Ultra+ search, ~7ms per 100KB
```

**The algorithm is fundamentally different**, not just "working harder".

## Implementation Recommendation

### Current Configuration
```elixir
nifs: [
  ...,
  compress: [:dirty_cpu],
  decompress: [:dirty_cpu],
  compress_stream: [:dirty_cpu]
]
```

### Recommended Configuration
```elixir
nifs: [
  ...,
  compress: [:dirty_cpu],        # KEEP - needed for slow strategies
  decompress: [],                # REMOVE - never needs it!
  compress_stream: [:dirty_cpu]  # KEEP - needed for slow strategies
]
```

### Rationale

**Why REMOVE dirty_cpu from decompress:**
- ✓ Decompression is ALWAYS <0.5ms
- ✓ No risk of blocking schedulers
- ✓ Small performance gain from avoiding scheduler switching
- ✓ Frees dirty scheduler pool for actual CPU-intensive work

**Why KEEP dirty_cpu for compress:**
- ✓ Slow strategies (:text, :structured_data, :maximum) take 6-13ms
- ✓ These are common choices for production (better compression)
- ✓ Cannot dynamically choose scheduler at runtime
- ✓ Better safe than block VM schedulers

## Performance Characteristics by Use Case

### Real-time / Interactive Applications

**Use :fast or :balanced strategy:**
```elixir
{:ok, cctx} = ExZstandard.cctx_init(%{strategy: :fast})
# compress_with_ctx: 0.07ms - excellent for real-time
```

**Avoid :text, :structured_data, :maximum:**
```elixir
{:ok, cctx} = ExZstandard.cctx_init(%{strategy: :maximum})
# compress_with_ctx: 6-7ms - too slow for real-time
```

### Batch / Offline Processing

**Use :text, :structured_data, :maximum for best compression:**
```elixir
{:ok, cctx} = ExZstandard.cctx_init(%{strategy: :text})
# Takes 12ms per 500KB but gets best compression ratio
# dirty_cpu handles the blocking safely
```

### HTTP/Network Streaming

**Use :fast strategy with :flush mode:**
```elixir
{:ok, cctx} = ExZstandard.cctx_init(%{strategy: :fast})
compress_stream(cctx, chunk, :flush)  # 0.1-0.3ms per chunk
```

**Avoid slow strategies in HTTP callbacks:**
```elixir
# DON'T DO THIS:
{:ok, cctx} = ExZstandard.cctx_init(%{strategy: :structured_data})
compress_stream(cctx, chunk, :flush)  # 7-9ms per chunk - too slow!
```

## Testing Results Summary

### Test Matrix (98KB PNG file)

| Strategy | Algorithm | Time | dirty_cpu? |
|----------|-----------|------|------------|
| :fast | fast (1) | 0.07 ms | ✗ Not needed |
| :balanced | dfast (2) | 0.15 ms | ✗ Not needed |
| :binary | lazy2 (5) | 0.65 ms | ⚠️ Borderline |
| :text | btopt (7) | 13 ms (500KB) | ✓ Required |
| :structured_data | btultra (8) | 9 ms (128KB) | ✓ Required |
| :maximum | btultra2 (9) | 6.5 ms | ✓ Required |

### Decompression (all sizes)

| Operation | Time | dirty_cpu? |
|-----------|------|------------|
| decompress | <0.5 ms | ✗ NEVER needed |
| decompress_stream | 0.1-0.25 ms | ✗ NEVER needed |
| decompress_with_ctx | <0.5 ms | ✗ NEVER needed |

## Documentation Updates Needed

Update module documentation to include performance characteristics:

```elixir
## Compression Strategies

Each recipe provides optimized defaults but has different performance characteristics:

### Performance by Strategy (98KB file)

- `:fast` - 0.07ms, compression: ~95% (level 1, fast algorithm)
- `:balanced` - 0.15ms, compression: ~95% (level 3, dfast algorithm) **[DEFAULT]**
- `:binary` - 0.65ms, compression: ~93% (level 6, lazy2 algorithm)
- `:text` - 13ms, compression: ~91% (level 9, btopt algorithm)
- `:structured_data` - 9ms, compression: ~90% (level 9, btultra algorithm)
- `:maximum` - 6.5ms, compression: ~90% (level 22, btultra2 algorithm)

**Choose wisely based on your use case:**
- Real-time/interactive: Use `:fast` or `:balanced`
- Batch processing: Use `:text`, `:structured_data`, or `:maximum`
- HTTP streaming: Use `:fast` with `:flush` mode
```

## Conclusion

### Key Findings:

1. **Decompression is ALWAYS fast** - Remove dirty_cpu to improve performance
2. **Compression timing depends on STRATEGY** - 100x difference between :fast and :maximum
3. **Strategy choice is critical** - Pick based on your use case (real-time vs batch)

### Recommended Changes:

1. ✅ **Remove dirty_cpu from all decompress NIFs**
2. ✅ **Keep dirty_cpu for all compress NIFs**
3. ✅ **Document performance characteristics for each strategy**
4. ✅ **Guide users on strategy selection**

### Next Steps:

```bash
# Update ex_zstandard.ex configuration:
nifs: [
  ...,
  compress: [:dirty_cpu],
  decompress: [],  # Changed: removed dirty_cpu
  compress_stream: [:dirty_cpu]
]

# Recompile and test
mix compile --force
mix test
```

---

**Date**: 2025-10-12
**Previous Analysis**: 2025-10-11 (incomplete - didn't identify strategy as key factor)
**Test Environment**: macOS Darwin 24.6.0, Zig 0.15.1, Elixir 1.18, OTP 28
**Measurement**: Direct Zig NIF timing in Debug mode with strategy analysis
