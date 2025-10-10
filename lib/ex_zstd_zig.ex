defmodule ExZstdZig do
  @moduledoc """
  Elixir bindings for the Zstandard (zstd) compression library, implemented in `Zig` via the wonderful `Zigler` library.

  `Zstandard` is a fast compression algorithm providing high compression ratios. This library
  offers a complete API for compression and decompression with multiple usage patterns.

  ## Features

  - **One-shot compression/decompression** - Simple functions for complete data in memory
  - **Context-based operations** - Reusable contexts for better performance across multiple operations
  - **Streaming API** - Process large files without loading them entirely into memory
  - **Dictionary support** - Train dictionaries for better compression of similar small files
  - **Compression strategies** - Optimized presets for different data types (text, JSON, binary)
  - **File operations** - High-level functions for compressing/decompressing files

  ## Installation

  Add to your `mix.exs`:

  ```elixir
  def deps do
    [
      {:ex_zstd_zig, "~> 0.1.0"}
    ]
  end
  ```

  Requires `libzstd` to be installed on your system:
  - macOS: `brew install zstd`
  - Ubuntu/Debian: `apt-get install libzstd-dev`
  - Fedora: `dnf install libzstd-devel`

  ## Quick Start

  ### One-shot compression

  ```elixir
  # Compress data
  data = "Hello, World!"
  {:ok, compressed} = ExZstdZig.compress(data, 3)

  # Decompress
  {:ok, decompressed} = ExZstdZig.decompress(compressed)
  ```

  ### File compression

  ```elixir
  # Compress a file
  :ok = ExZstdZig.compress_file("input.txt", "output.txt.zst")

  # Decompress a file
  :ok = ExZstdZig.decompress_file("output.txt.zst", "restored.txt")
  ```

  ### Context reuse for better performance

  ```elixir
  # Create a context once (use recipe defaults for text compression)
  {:ok, cctx} = ExZstdZig.cctx_init(%{strategy: :text})

  # Compress multiple items
  {:ok, compressed1} = ExZstdZig.compress_with_ctx(cctx, data1)
  :ok = ExZstdZig.reset_compressor_session(cctx)
  {:ok, compressed2} = ExZstdZig.compress_with_ctx(cctx, data2)
  ```

  ### Streaming compression

  The `compress_stream/3` function accepts three modes:

  - **`:continue_op`** - Better compression (buffers data, may produce no output)
  - **`:flush`** - Guaranteed output per chunk (for real-time streaming)
  - **`:end_frame`** - Finalize frame (required to complete compression)

  ```elixir
  {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :balanced})

  # Option 1: Better compression with :continue_op (batch processing)
  {:ok, {out1, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk1, :continue_op)
  {:ok, {out2, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk2, :continue_op)
  {:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)
  compressed = IO.iodata_to_binary([out1, out2, final])

  # Option 2: Real-time streaming with :flush (HTTP, network)
  {:ok, {chunk1, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk1, :flush)
  {:ok, {chunk2, _, _}} = ExZstdZig.compress_stream(cctx, data_chunk2, :flush)
  {:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)
  compressed = IO.iodata_to_binary([chunk1, chunk2, final])
  ```

  ### Dictionary compression

  ```elixir
  # Train a dictionary from sample data
  samples = [sample1, sample2, sample3, ...]
  {:ok, dictionary} = ExZstdZig.train_dictionary(samples, 1024)

  # Compress with dictionary
  {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3})
  {:ok, compressed} = ExZstdZig.compress_with_dict(cctx, data, dictionary)

  # Decompress with dictionary
  {:ok, dctx} = ExZstdZig.dctx_init(nil)
  {:ok, decompressed} = ExZstdZig.decompress_with_dict(dctx, compressed, dictionary)
  ```

  ## Compression Strategies

  Each recipe provides optimized defaults for compression level and ZSTD algorithm:
  - `:fast` - Fastest compression (level 1, fast algorithm)
  - `:balanced` - Good balance of speed/ratio (level 3, dfast algorithm, default)
  - `:maximum` - Maximum compression (level 22, btultra2 algorithm)
  - `:text` - Optimized for text/code (level 9, btopt algorithm)
  - `:structured_data` - Optimized for JSON/XML (level 9, btultra algorithm)
  - `:binary` - Optimized for binary data (level 6, lazy2 algorithm)

  ### Configuration Flexibility

  You can use recipes in multiple ways:

  ```elixir
  # Use recipe defaults (recommended)
  {:ok, cctx} = ExZstdZig.cctx_init(%{strategy: :text})
  # → level 9 + btopt algorithm

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

  1. **Reuse contexts** - Creating contexts has overhead. Reuse them with `reset_*_session/1`
  2. **Choose appropriate level** - Level 3 is usually optimal. Higher levels give diminishing returns
  3. **Use dictionaries** - For many small similar files (< 1KB each)
  4. **Stream large files** - Use `compress_file/3` or streaming API for files > 100MB
  5. **Pick the right strategy** - Use `:text` for code, `:structured_data` for JSON/XML

  ## Function Categories

  ### One-shot Functions
  - `compress/2`, `decompress/1` - Simple compression with tuple returns
  - `simple_compress/2`, `simple_auto_decompress/1` - Direct result or error

  ### Context Management
  - `cctx_init/1`, `dctx_init/1` - Create compression/decompression contexts
  - `reset_compressor_session/1`, `reset_decompressor_session/1` - Reset for reuse

  ### Context-based Operations
  - `compress_with_ctx/2`, `decompress_with_ctx/2` - Use existing contexts

  ### Streaming
  - `compress_stream/3`, `decompress_stream/2` - Process data in chunks
  - `decompress_unfold/2` - Convenient streaming decompression for in-memory binaries
  - `recommended_c_in_size/0`, `recommended_d_in_size/0` - Get optimal buffer sizes

  ### File Operations
  - `compress_file/3`, `decompress_file/3` - Handle files without loading into memory

  ### Dictionary Support
  - `train_dictionary/2` - Train from sample data
  - `load_compression_dictionary/2`, `load_decompression_dictionary/2` - Load into contexts
  - `compress_with_dict/3`, `decompress_with_dict/3` - Compress/decompress with dictionary

  ### Utilities
  - `getDecompressedSize/1` - Get decompressed size from compressed data
  - `version/0` - Get zstd library version
  """
  use Zig,
    otp_app: :ex_zstd_zig,
    c: [link_lib: {:system, "zstd"}],
    zig_code_path: "lib.zig",
    resources: [:ZstdCResource, :ZstdDResource]

  @doc """
  Compress a file using streaming compression and write to output file.

  This function provides true streaming compression - data is read, compressed,
  and written in chunks without loading the entire file into memory.

  ## Parameters
    - `input_path` - Path to the file to compress
    - `output_path` - Path where compressed file will be written
    - `opts` - Keyword list of options:
      - `:cctx` - Existing compression context to reuse (optional). If not provided, a new context will be created.
      - `:compression_level` - Compression level (1-22), default: 3 (ignored if `:cctx` is provided)
      - `:strategy` - Compression strategy (`:fast`, `:balanced`, etc.), default: `:balanced` (ignored if `:cctx` is provided)
      - `:chunk_size` - Size of chunks to read/process, default: recommended size from zstd
      - `:mode` - `:flush` (guaranteed output per chunk) or `:continue_op` (better compression), default: `:flush`

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      # Auto-create context with defaults
      iex> ExZstdZig.compress_file("input.txt", "output.txt.zst")
      :ok

      # Auto-create context with custom settings
      iex> ExZstdZig.compress_file("input.txt", "output.txt.zst", compression_level: 10, strategy: :text)
      :ok

      # Reuse existing context for multiple files
      iex> {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5, strategy: :fast})
      iex> ExZstdZig.compress_file("file1.txt", "file1.txt.zst", cctx: cctx)
      iex> ExZstdZig.reset_compressor_session(cctx)
      iex> ExZstdZig.compress_file("file2.txt", "file2.txt.zst", cctx: cctx)
      :ok
  """
  def compress_file(input_path, output_path, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, recommended_c_in_size())
    mode = Keyword.get(opts, :mode, :flush)

    cctx =
      case Keyword.get(opts, :cctx) do
        nil ->
          compression_level = Keyword.get(opts, :compression_level, 3)
          strategy = Keyword.get(opts, :strategy, :balanced)
          {:ok, ctx} = cctx_init(%{compression_level: compression_level, strategy: strategy})
          ctx

        existing_ctx ->
          existing_ctx
      end

    with cctx do
      Stream.resource(
        # start_fun: state= {pid, true|false}
        fn ->
          {File.open!(input_path, [:read, :binary]), false}
        end,
        # read_fun
        # (state = {pid, true|false}) ->{[compressed], state} | {:halt, state}
        # compressed is emitted to next stream step (Stream.write)
        fn
          {file_pid, true} ->
            {:halt, file_pid}

          {file_pid, false} ->
            case IO.binread(file_pid, chunk_size) do
              :eof ->
                {:ok, {final, _, _}} = compress_stream(cctx, <<>>, :end_frame)
                {[final], {file_pid, true}}

              {:error, reason} ->
                raise "Failed to read file: #{inspect(reason)}"

              data ->
                {:ok, {compressed, _, _}} = compress_stream(cctx, data, mode)
                # dbg({byte_size(data), byte_size(compressed)})
                {[compressed], {file_pid, false}}
            end
        end,
        # after_fun
        fn file_pid -> File.close(file_pid) end
      )
      |> Stream.into(File.stream!(output_path, [:append]))
      |> Stream.run()

      :ok
    end
  end

  @doc """
  Decompress a compressed binary using streaming decompression with `Stream.unfold`.

  This function provides a convenient way to decompress data that's already in memory
  using streaming decompression internally. It's useful when you have compressed data
  as a binary and want to decompress it efficiently without loading it all at once
  into a single decompression call.

  ## When to use

  - You have compressed data in memory (not a file)
  - The compressed data is moderately sized (< 100MB)
  - You want streaming decompression benefits without file I/O
  - You prefer a simpler API than manual `decompress_stream/2` calls

  ## Comparison with other methods

  - Use `decompress/1` for small data when simplicity is preferred
  - Use `decompress_unfold/2` for medium-sized data in memory with streaming benefits
  - Use `decompress_file/3` for large files to avoid loading everything into memory

  ## Parameters

    - `input` - Compressed binary data
    - `opts` - Keyword list of options:
      - `:dctx` - Existing decompression context to reuse (optional)

  ## Returns

  The decompressed binary (built in memory)

  ## Examples

      # Simple usage - decompress a binary
      iex> compressed = File.read!("data.zst")
      iex> decompressed = ExZstdZig.decompress_unfold(compressed)
      iex> byte_size(decompressed)
      1024000

      # Reuse context for multiple decompressions
      iex> {:ok, dctx} = ExZstdZig.dctx_init(nil)
      iex> data1 = ExZstdZig.decompress_unfold(compressed1, dctx: dctx)
      iex> ExZstdZig.reset_decompressor_session(dctx)
      iex> data2 = ExZstdZig.decompress_unfold(compressed2, dctx: dctx)

  ## Notes

  The entire decompressed result is built in memory. For very large data (> 100MB),
  prefer `decompress_file/3` which streams to disk.
  """
  def decompress_unfold(input, opts \\ []) do
    dctx = Keyword.get(opts, :dctx) || ExZstdZig.dctx_init(nil) |> elem(1)

    Stream.unfold(input, fn
      <<>> ->
        nil

      data ->
        case decompress_stream(dctx, data) do
          {:ok, {decompressed, bytes_consumed}} ->
            remaining = binary_part(data, bytes_consumed, byte_size(data) - bytes_consumed)
            {decompressed, remaining}

          {:error, reason} ->
            raise "Decompression error: #{inspect(reason)}"
        end
    end)
    |> Enum.to_list()
    |> IO.iodata_to_binary()

    # |> Stream.into(File.stream!(output, [:append]))
    # |> Stream.run()
  end

  @doc """
  Decompress a file using streaming decompression and write to output file.

  This function provides true streaming decompression - data is read, decompressed,
  and written in chunks without loading the entire file into memory.

  ## Parameters
    - `input_path` - Path to the compressed file
    - `output_path` - Path where decompressed file will be written
    - `opts` - Keyword list of options:
      - `:dctx` - Existing decompression context to reuse (optional). If not provided, a new context will be created.
      - `:max_window` - Maximum window size for decompression (10-31), default: nil (ignored if `:dctx` is provided)
      - `:chunk_size` - Size of chunks to read, default: recommended size from zstd

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      # Auto-create context with defaults
      iex> ExZstdZig.decompress_file("input.txt.zst", "output.txt")
      :ok

      # Auto-create context with max window size
      iex> ExZstdZig.decompress_file("input.txt.zst", "output.txt", max_window: 20)
      :ok

      # Reuse existing context for multiple files
      iex> {:ok, dctx} = ExZstdZig.dctx_init(nil)
      iex> ExZstdZig.decompress_file("file1.txt.zst", "file1.txt", dctx: dctx)
      iex> ExZstdZig.reset_decompressor_session(dctx)
      iex> ExZstdZig.decompress_file("file2.txt.zst", "file2.txt", dctx: dctx)
      :ok
  """
  def decompress_file(input_path, output_path, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, recommended_d_in_size())

    dctx =
      case Keyword.get(opts, :dctx) do
        nil ->
          max_window = Keyword.get(opts, :max_window, nil)
          {:ok, ctx} = dctx_init(max_window)
          ctx

        existing_ctx ->
          existing_ctx
      end

    with dctx do
      # Ensure output file is empty before starting
      if File.exists?(output_path), do: File.rm!(output_path)

      Stream.resource(
        # start_fun: () -> state = {pid, buffer = unconsumed}
        fn -> {File.open!(input_path, [:read, :binary]), <<>>} end,

        # read_fun :
        # (state = {pid, unconsumed}) ->{[decompressed], {pid, unconsumed}} | {:halt, state}
        # decompressed is emitted to next stream step (Stream.write)
        fn
          # Already processed EOF and emitted final data, now halt
          {:done, file_pid} ->
            {:halt, file_pid}

          {file_pid, buffer} ->
            case IO.binread(file_pid, chunk_size) do
              :eof when buffer == <<>> ->
                # No more data to process
                {:halt, file_pid}

              :eof ->
                # Process all remaining buffered data
                # One decompress_stream call may not consume everything, so loop until empty
                decompressed_chunks = drain_buffer(dctx, buffer, [])
                # Emit chunks to the stream and mark as done (will halt on next call)
                {Enum.reverse(decompressed_chunks), {:done, file_pid}}

              {:error, reason} ->
                raise "Failed to read file: #{inspect(reason)}"

              chunk ->
                # "normal" iteration: append chunk to buffer
                data = buffer <> chunk
                {:ok, {decompressed, bytes_consumed}} = decompress_stream(dctx, data)

                # Keep unconsumed bytes for next iteration
                remaining = binary_part(data, bytes_consumed, byte_size(data) - bytes_consumed)

                # dbg(
                #   {byte_size(chunk), byte_size(buffer), byte_size(decompressed), bytes_consumed,
                #    byte_size(remaining)}
                # )

                {[decompressed], {file_pid, remaining}}
            end
        end,
        # after_fun: (acc) -> ()
        fn file_pid -> File.close(file_pid) end
      )
      |> Stream.into(File.stream!(output_path, [:append]))
      |> Stream.run()

      :ok
    end
  end

  # Helper function: recursively decompress until buffer is empty
  defp drain_buffer(_dctx, <<>>, acc), do: acc

  defp drain_buffer(dctx, buffer, acc) do
    # dbg(length(acc))
    {:ok, {decompressed, bytes_consumed}} = decompress_stream(dctx, buffer)

    if bytes_consumed == 0 do
      # Can't make progress - corrupted data
      raise "Decompression stalled with #{byte_size(buffer)} bytes remaining"
    end

    remaining = binary_part(buffer, bytes_consumed, byte_size(buffer) - bytes_consumed)
    # dbg({byte_size(buffer), byte_size(remaining)})
    drain_buffer(dctx, remaining, [decompressed | acc])
  end
end
