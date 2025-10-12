# Compression Strategy and dirty_cpu Timing Analysis

## Executive Summary

**The need for `dirty_cpu` scheduling depends primarily on the compression STRATEGY, not just file size.**

Timing varies by ~100x between strategies:
- `:fast` strategy: **0.08-0.35 ms** ✓ No dirty_cpu needed
- `:maximum` strategy: **6-10 ms** ⚠️ Requires dirty_cpu

## Test Results

### compress_with_ctx() - 98KB PNG file

| Strategy | Level | ZSTD Algorithm | Execution Time | Status |
|----------|-------|----------------|----------------|--------|
| :fast | 1 | fast (1) | 0.078-0.107 ms | ✓ OK |
| :balanced | 3 | dfast (2) | 0.121-0.174 ms | ✓ OK |
| :binary | 6 | lazy2 (5) | 0.617-0.665 ms | ⚠️ Borderline |
| :maximum | 22 | btultra2 (9) | 6.419-6.715 ms | ⚠️ NEEDS dirty_cpu |

### compress_stream() - 128KB chunks

| Strategy | Execution Time | Status |
|----------|----------------|--------|
| :fast | 0.124-0.349 ms | ✓ OK |
| :structured_data | 8.803-10.197 ms | ⚠️ NEEDS dirty_cpu |

### compress_with_ctx() - 502KB HTML file

| Strategy | Execution Time | Status |
|----------|----------------|--------|
| :structured_data (level 9, btultra) | 13.884 ms | ⚠️ NEEDS dirty_cpu |

## Analysis

### Why Strategy Matters More Than Size

The ZSTD compression algorithm used by each strategy has dramatically different performance characteristics:

1. **Fast algorithms (fast, dfast)**
   - Simple pattern matching
   - Limited search depth
   - Optimized for speed
   - **~0.1-0.2 ms per 100KB**

2. **Balanced algorithms (greedy, lazy, lazy2)**
   - Moderate pattern matching
   - Reasonable search depth
   - Good speed/ratio tradeoff
   - **~0.3-0.7 ms per 100KB**

3. **High-compression algorithms (btopt, btultra, btultra2)**
   - Binary tree search structures
   - Deep pattern analysis
   - Optimized for compression ratio
   - **~6-14 ms per 100KB**

### The 1ms Threshold

BEAM VM guidelines recommend `dirty_cpu` for operations taking >1ms:

- ✓ **OK**: :fast, :balanced - Always under 1ms even for large chunks
- ⚠️ **BORDERLINE**: :binary - Approaches 1ms for moderate files
- ⚠️ **REQUIRES dirty_cpu**: :maximum, :text, :structured_data - Consistently >1ms

## Current Configuration Problem

```elixir
nifs: [
  ...,
  compress: [:dirty_cpu],
  decompress: [:dirty_cpu],
  compress_stream: [:dirty_cpu]
]
```

This applies `dirty_cpu` to ALL operations, which:

**Pros:**
- ✓ Safe for all strategies
- ✓ Prevents scheduler blocking for slow strategies

**Cons:**
- ✗ Adds unnecessary overhead for fast strategies (0.1ms → slower)
- ✗ Wastes limited dirty scheduler pool
- ✗ May reduce throughput for fast operations

## The Fundamental Constraint

**NIFs cannot dynamically choose dirty_cpu at runtime.** The scheduler type is a compile-time decision.

You cannot do:
```elixir
# This doesn't exist in Erlang/Elixir
def compress(data, level) when level > 10 do
  compress_dirty_cpu(data, level)  # Use dirty scheduler
end
def compress(data, level) do
  compress_regular(data, level)  # Use regular scheduler
end
```

## Solution Options

### Option 1: Keep Current Configuration (Conservative)

**Recommendation**: KEEP `dirty_cpu` for all compression operations

**Rationale:**
- Users choose slow strategies (:text, :structured_data, :maximum) because they want better compression
- These are the common use cases for production
- The overhead of dirty_cpu on fast operations is small compared to the risk of blocking schedulers
- Better to be safe than block the VM

**Tradeoffs:**
- Fast strategies pay a small penalty
- But scheduler blocking is worse

### Option 2: Remove dirty_cpu (Aggressive)

**Recommendation**: REMOVE `dirty_cpu` from all NIFs

**Rationale:**
- Streaming operations (compress_stream/decompress_stream) are already fast
- One-shot operations should only be used for small data
- For large data, users should use `compress_file` or streaming APIs anyway

**Tradeoffs:**
- Fast for :fast and :balanced strategies
- ⚠️ Will block schedulers if users choose :maximum or :structured_data
- Risky if users don't follow best practices

### Option 3: Create Separate Functions (Complex)

Create strategy-specific NIFs:

```zig
// Regular scheduler - for fast strategies
pub fn compress_with_ctx_fast(...)

// Dirty CPU - for slow strategies
pub fn compress_with_ctx_slow(...)
```

```elixir
# Elixir wrapper chooses which to call
nifs: [
  compress_with_ctx_fast: [],  # No dirty_cpu
  compress_with_ctx_slow: [:dirty_cpu]
]

def compress_with_ctx(ctx, data) do
  {:ok, {level, strategy, _}} = get_compression_params(ctx)

  if strategy in [:fast, :balanced] do
    compress_with_ctx_fast(ctx, data)
  else
    compress_with_ctx_slow(ctx, data)
  end
end
```

**Tradeoffs:**
- ✓ Optimal performance for all strategies
- ✗ Code duplication
- ✗ Maintenance burden
- ✗ More complex API

### Option 4: Document and Guide (Pragmatic)

Keep current configuration but add documentation:

```elixir
@doc """
## Performance Characteristics by Strategy

Compression time varies dramatically by strategy choice:

- `:fast`, `:balanced` - ~0.1-0.2ms (always safe)
- `:binary` - ~0.6ms (usually safe)
- `:text`, `:structured_data` - ~10-14ms (requires dirty_cpu)
- `:maximum` - ~6-7ms (requires dirty_cpu)

This library uses `dirty_cpu` scheduling for all compression to safely support slow strategies.

For highest throughput with fast strategies, consider using the streaming API (`compress_file`, `compress_stream`) which processes data in small chunks.
"""
```

## Recommendation

**Use Option 1 (Keep current configuration) + Option 4 (Documentation)**

**Reasoning:**

1. **Safety first**: Blocking VM schedulers is worse than small overhead
2. **Real-world usage**: Users typically choose :text, :structured_data, or :maximum for production (better compression ratios)
3. **Streaming alternatives**: Fast strategies can use `compress_file` which chunks data anyway
4. **Simplicity**: No code changes, just documentation

## User Guidelines

### When NIF timing doesn't matter (Use any strategy):
- Small files (< 1MB)
- Streaming operations (`compress_file`, `decompress_file`)
- Batch processing where latency is acceptable

### When NIF timing matters (Choose wisely):
- Real-time compression in HTTP callbacks
- Interactive applications
- High-throughput pipelines

**For real-time scenarios with large data:**
→ Use `:fast` strategy with `compress_stream` and `:flush` mode

**For batch/offline with best compression:**
→ Use `:maximum` or `:text` with dirty_cpu (current default)

## Testing Methodology

Enable NIF timing (already enabled in dev/test):
```zig
// lib.zig line 13-15
inline fn isTimingEnabled() bool {
    return builtin.mode == .Debug;
}
```

Run tests:
```bash
mix test --trace
```

Observe output:
```
[NIF Compress_with_ctx] level: 22, strategy: 9, duration: 6.649 ms, for: 98238 bytes)
[NIF compress_stream] 9.224 ms, for: 131072 bytes
```

## Conclusion

**The critical factor for dirty_cpu scheduling is the COMPRESSION STRATEGY, not just file size.**

- Fast strategies (:fast, :balanced) → ~0.1-0.2ms → No dirty_cpu needed
- Slow strategies (:maximum, :text, :structured_data) → 6-14ms → Requires dirty_cpu

Current configuration (dirty_cpu for all) is the safe, pragmatic choice until Erlang/BEAM supports dynamic scheduler selection.

---

**Date**: 2025-10-12
**Test Environment**: macOS Darwin 24.6.0, Zig 0.15.1, Elixir 1.18, OTP 28
**Measurement**: Direct Zig NIF timing in Debug mode
