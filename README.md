# ExZstdZig

Fast Zstandard (zstd) compression/decompression for Elixir, implemented with Zig NIFs via the wonderful Zigler library.

![Zig support](https://img.shields.io/badge/Zig-0.15.1-color?logo=zig&color=%23f3ab20)
![Static Badge](https://img.shields.io/badge/zigler-0.15.1-orange)
![Static Badge](https://img.shields.io/badge/zstd_1.5.7-green)

Zstandard is a fast compression algorithm offering high compression ratios. This library provides complete bindings with support for one-shot operations, streaming, context reuse, and dictionary training.

## Features

- ⚡ **Fast** - Native implementation using Zig with minimal overhead
- 🔄 **Streaming** - Process large files without loading them into memory
- 🎯 **Context reuse** - Better performance when compressing multiple items
- 📚 **Dictionary support** - Improved compression for similar small files
- 🎨 **Compression strategies** - Optimized presets for different data types
- 📦 **Complete API** - From simple one-shot to advanced streaming operations

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

The library requires `libzstd` to be installed on your system:

**macOS:**
```bash
brew install zstd
```

**Ubuntu/Debian:**
```bash
sudo apt-get install libzstd-dev
```

**Fedora:**
```bash
sudo dnf install libzstd-devel
```

## Quick Start

### Simple Compression

```elixir
# Compress data
data = "Hello, World!"
{:ok, compressed} = ExZstdZig.compress(data, 3)

# Decompress
{:ok, decompressed} = ExZstdZig.decompress(compressed)
```

### File Compression

```elixir
# Compress a file
:ok = ExZstdZig.compress_file("input.txt", "output.txt.zst")

# Decompress a file
:ok = ExZstdZig.decompress_file("output.txt.zst", "restored.txt")
```

### Context Reuse (Better Performance)

```elixir
# Create a context once
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5, strategy: :text})

# Compress multiple items efficiently
{:ok, compressed1} = ExZstdZig.compress_with_ctx(cctx, data1)

# Reset and reuse
:ok = ExZstdZig.reset_compressor_session(cctx)
{:ok, compressed2} = ExZstdZig.compress_with_ctx(cctx, data2)
```

### Streaming Compression

```elixir
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :balanced})

# Compress in chunks
{:ok, {chunk1, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk1, :flush)
{:ok, {chunk2, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk2, :flush)
{:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)

compressed = IO.iodata_to_binary([chunk1, chunk2, final])
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

Choose the right strategy for your data type:

- `:fast` - Fastest compression (level 1)
- `:balanced` - Good balance (level 3, **default**)
- `:maximum` - Maximum compression (level 22)
- `:text` - Optimized for text/code (level 9)
- `:structured_data` - Optimized for JSON/XML (level 9)
- `:binary` - Optimized for binary data (level 6)

Example:

```elixir
# For JSON data
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 9, strategy: :structured_data})

# For text files
{:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 9, strategy: :text})
```

## Performance Tips

1. **Reuse contexts** - Creating contexts has overhead. Reuse them for multiple operations
2. **Choose appropriate level** - Level 3 is usually optimal. Higher levels give diminishing returns
3. **Use dictionaries** - For compressing many small similar files (< 1KB each)
4. **Stream large files** - Use `compress_file/3` or streaming API for files > 100MB
5. **Pick the right strategy** - Match the strategy to your data type

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

## Benchmarks

Coming soon!

## License

MIT License - see [LICENSE](LICENSE) for details.

## Credits

- Built with [Zigler](https://github.com/E-xyza/zigler)
- Uses [Zstandard](https://facebook.github.io/zstd/) compression library
