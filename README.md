# ExZstdZig

Fast Zstandard (zstd) compression/decompression for Elixir, implemented with Zig NIFs via the wonderful Zigler library.

![Zig support](https://img.shields.io/badge/Zig-0.15.1-color?logo=zig&color=%23f3ab20)
![Static Badge](https://img.shields.io/badge/zigler-0.15.1-orange)
![Static Badge](https://img.shields.io/badge/zstd_1.5.7-green)

Zstandard is a fast compression algorithm offering high compression ratios. This library provides complete bindings with support for one-shot operations, streaming, context reuse, and dictionary training.

## Features

- **Fast** - Native implementation using Zig with minimal overhead
- **Streaming** - Process large files without loading them into memory
- **Context reuse** - Better performance when compressing multiple items
- **Dictionary support** - Improved compression for similar small files
- **Compression strategies** - Optimized presets for different data types
- **Complete API** - From simple one-shot to advanced streaming operations

## Installation

Add `ex_zstd_zig` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_zstd_zig, "~> 0.1.0"}
  ]
end
```

### System Requirements

The library requires `zstd` to be installed on your system:

**macOS:**

```bash
brew install zstd
```

**Ubuntu/Debian:**

```bash
sudo apt-get install libzstd-dev
```

## Quick Start

The tests contains worked examples.

### Simple Compression

```elixir
# Compress data
data = "Hello, World!"
{:ok, compressed} = ExZstdZig.compress(data, 3)

# Decompress
{:ok, decompressed} = ExZstdZig.decompress(compressed)
```

### File Compression with streams

```elixir
# Compress a file
:ok = ExZstdZig.compress_file("input.txt", "output.txt.zst")

# Decompress a file
:ok = ExZstdZig.decompress_file("output.txt.zst", "restored.txt")
```

### Context Reuse (Better Performance)

```elixir
# Create a context once (use recipe defaults for text compression)
{:ok, cctx} = ExZstdZig.cctx_init(%{strategy: :text})

# Compress multiple items efficiently
{:ok, compressed1} = ExZstdZig.compress_with_ctx(cctx, data1)

# Reset and reuse
:ok = ExZstdZig.reset_compressor_session(cctx)
{:ok, compressed2} = ExZstdZig.compress_with_ctx(cctx, data2)
```

### Streaming Compression

The `compress_stream/3` function accepts three modes that control buffering and output:

**`:continue_op`** - Better compression, batch processing

- Buffers data for better compression ratios
- May produce no output (buffering internally)
- Use when: Processing data in batches, compression ratio matters more than latency

**`:flush`** - Guaranteed output, real-time streaming

- Forces output for each chunk (guarantees non-empty result)
- Slightly reduces compression ratio
- Use when: Real-time streaming (HTTP, network), need output per chunk

**`:end_frame`** - Finalize frame

- Closes the compression frame with footer/checksum
- Call with empty input `<<>>` after last data chunk
- Required to complete valid compressed data

#### Example: Better compression with `:continue_op`

```elixir
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :balanced})

# Buffer data for better compression (may produce empty chunks)
{:ok, {out1, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk1, :continue_op)
{:ok, {out2, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk2, :continue_op)
{:ok, {out3, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk3, :continue_op)

# Finalize frame
{:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)

# Some outputs may be empty if data was buffered
compressed = IO.iodata_to_binary([out1, out2, out3, final])
```

#### Example: Real-time streaming with `:flush`

```elixir
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :balanced})

# Force output for each chunk (guaranteed non-empty)
{:ok, {chunk1, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk1, :flush)
{:ok, {chunk2, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk2, :flush)
{:ok, {chunk3, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk3, :flush)

# Finalize frame
{:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)

# All chunks contain data (good for streaming)
compressed = IO.iodata_to_binary([chunk1, chunk2, chunk3, final])
```

### In-Memory Streaming Decompression

For moderately-sized compressed data in memory, use `decompress_unfold/2`:

```elixir
# Decompress a binary with streaming (efficient for medium-sized data)
compressed = File.read!("data.zst")
decompressed = ExZstdZig.decompress_unfold(compressed)
```

### Dictionary Training

Train a dictionary for better compression of many small similar files:

```elixir
# Collect sample data
samples = [
  ~s({"id": 1, "name": "Alice", "email": "alice@example.com"}),
  ~s({"id": 2, "name": "Bob", "email": "bob@example.com"}),
  # ... more samples
]

# Train dictionary
{:ok, dictionary} = ExZstdZig.train_dictionary(samples, 1024)

# Compress with dictionary
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :structured_data})
{:ok, compressed} = ExZstdZig.compress_with_dict(cctx, new_data, dictionary)

# Decompress with dictionary
{:ok, dctx} = ExZstdZig.dctx_init(nil)
{:ok, decompressed} = ExZstdZig.decompress_with_dict(dctx, compressed, dictionary)
```

## Compression Strategies

Choose the right strategy for your data type. Each recipe provides optimized defaults for compression level and ZSTD algorithm:

- `:fast` - Fastest compression (level 1, fast algorithm)
- `:balanced` - Good balance (level 3, dfast algorithm, **default**)
- `:maximum` - Maximum compression (level 22, btultra2 algorithm)
- `:text` - Optimized for text/code (level 9, btopt algorithm)
- `:structured_data` - Optimized for JSON/XML (level 9, btultra algorithm)
- `:binary` - Optimized for binary data (level 6, lazy2 algorithm)

### Configuration Options

```elixir
# Use recipe defaults (recommended)
{:ok, cctx} = ExZstdZig.cctx_init(%{strategy: :text})
# → level 9 + btopt algorithm

{:ok, cctx} = ExZstdZig.cctx_init(%{strategy: :structured_data})
# → level 9 + btultra algorithm

# Override level while keeping recipe's algorithm
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 15, strategy: :text})
# → level 15 + btopt algorithm

# Custom level with default algorithm
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5})
# → level 5 + dfast algorithm

# Use all defaults
{:ok, cctx} = ExZstdZig.cctx_init(%{})
# → level 3 + dfast algorithm
```

## Performance Tips

1. **Reuse contexts** - Creating contexts has overhead. Reuse them for multiple operations
2. **Choose appropriate level** - Level 3 is usually optimal. Higher levels give diminishing returns
3. **Use dictionaries** - For compressing many small similar files (< 1KB each)
4. **Stream large files** - Use `compress_file/3` or streaming API for files > 100MB
5. **Pick the right strategy** - Match the strategy to your data type

## HTTP Streaming

### Compression: On-the-fly

You **can** compress data on-the-fly during HTTP downloads because compression is fast enough:

```elixir
# Use level 3 for speed (level 9 would be too slow for on-the-fly compression)
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :structured_data})
compressed_pid = File.open!("output.zst", [:write, :binary])

Req.get!("https://example.com/large-file.json",
  into: fn
    {:data, chunk}, {req, resp} ->
      # Compress each chunk as it arrives (use :flush for guaranteed output)
      {:ok, {compressed, _, _}} = ExZstdZig.compress_stream(cctx, chunk, :flush)
      :ok = IO.binwrite(compressed_pid, compressed)
      {:cont, {req, resp}}
  end
)

# Finalize the compression frame
{:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)
IO.binwrite(compressed_pid, final)
File.close(compressed_pid)
```

### Decompression: 2-Step Process ⚠️

You **cannot** decompress on-the-fly in HTTP callbacks due to HTTP/2 back-pressure limitations. Use a 2-step process:

```elixir
# Step 1: Download compressed file (fast callback)
compressed_pid = File.open!("download.zst", [:write, :binary])

Req.get!("https://example.com/compressed-file.zst",
  into: fn
    {:data, chunk}, {req, resp} ->
      :ok = IO.binwrite(compressed_pid, chunk)
      {:cont, {req, resp}}
  end
)

File.close(compressed_pid)

# Step 2: Decompress using streaming decompression
{:ok, dctx} = ExZstdZig.dctx_init(nil)
ExZstdZig.decompress_file("download.zst", "output.txt", dctx: dctx)
```

**Why?** HTTP/2 (used by Finch/Req) has no back-pressure mechanism. Decompression + file I/O in callbacks is too slow, causing connection timeouts and data loss.

## API Overview

### One-shot Functions

- `compress/2` - Compress data, returns `{:ok, compressed}`
- `decompress/1` - Decompress data, returns `{:ok, decompressed}`
- `simple_compress/2` - Direct compression (raises on error)
- `simple_auto_decompress/1` - Direct decompression (raises on error)

### Context Management

- `cctx_init/1` - Create compression context
- `dctx_init/1` - Create decompression context
- `reset_compressor_session/1` - Reset compression context for reuse
- `reset_decompressor_session/1` - Reset decompression context for reuse

### Context-based Operations

- `compress_with_ctx/2` - Compress using context
- `decompress_with_ctx/2` - Decompress using context

### Streaming

- `compress_stream/3` - Compress data in chunks
- `decompress_stream/2` - Decompress data in chunks
- `decompress_unfold/2` - Convenient streaming decompression for in-memory binaries
- `recommended_c_in_size/0` - Get recommended input buffer size for compression
- `recommended_d_in_size/0` - Get recommended input buffer size for decompression

### File Operations

- `compress_file/3` - Compress file (streaming, low memory)
- `decompress_file/3` - Decompress file (streaming, low memory)

### Dictionary Support

- `train_dictionary/2` - Train dictionary from samples
- `load_compression_dictionary/2` - Load dictionary into compression context
- `load_decompression_dictionary/2` - Load dictionary into decompression context
- `compress_with_dict/3` - One-shot compression with dictionary
- `decompress_with_dict/3` - One-shot decompression with dictionary

### Utilities

- `getDecompressedSize/1` - Get decompressed size from compressed data
- `version/0` - Get zstd library version

## Documentation

Full documentation is available at [HexDocs](https://hexdocs.pm/ex_zstd_zig) (once published).

To generate documentation locally:

```bash
mix docs
```

Then open `doc/index.html` in your browser.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Credits

- Built with [Zigler](https://github.com/E-xyza/zigler)
- Uses [Zstandard](https://facebook.github.io/zstd/) compression library
