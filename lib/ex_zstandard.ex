defmodule ExZstandard do
  @check_leak Mix.env() in [:test, :dev]
  @release if Mix.env() == :prod, do: :fast, else: :debug

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
  {:ok, compressed} = ExZstandard.compress(data, 3)

  # Decompress
  {:ok, decompressed} = ExZstandard.decompress(compressed)
  ```

  ### File compression

  ```elixir
  # Compress a file
  :ok = ExZstandard.compress_file("input.txt", "output.txt.zst")

  # Decompress a file
  :ok = ExZstandard.decompress_file("output.txt.zst", "restored.txt")
  ```

  ### Context reuse for better performance

  ```elixir
  # Create a context once (use recipe defaults for text compression)
  {:ok, cctx} = ExZstandard.cctx_init(%{strategy: :text})

  # Compress multiple items
  {:ok, compressed1} = ExZstandard.compress_with_ctx(cctx, data1)
  :ok = ExZstandard.reset_compressor_session(cctx)
  {:ok, compressed2} = ExZstandard.compress_with_ctx(cctx, data2)
  ```

  ### Streaming compression

  The `compress_stream/3` function accepts three modes:

  - **`:continue_op`** - Better compression (buffers data, may produce no output)
  - **`:flush`** - Guaranteed output per chunk (for real-time streaming)
  - **`:end_frame`** - Finalize frame (required to complete compression)

  ```elixir
  {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 3, strategy: :balanced})

  # Option 1: Better compression with :continue_op (batch processing)
  {:ok, {out1, _, _}} = ExZstandard.compress_stream(cctx, data_chunk1, :continue_op)
  {:ok, {out2, _, _}} = ExZstandard.compress_stream(cctx, data_chunk2, :continue_op)
  {:ok, {final, _, _}} = ExZstandard.compress_stream(cctx, <<>>, :end_frame)
  compressed = IO.iodata_to_binary([out1, out2, final])

  # Option 2: Real-time streaming with :flush (HTTP, network)
  {:ok, {chunk1, _, _}} = ExZstandard.compress_stream(cctx, data_chunk1, :flush)
  {:ok, {chunk2, _, _}} = ExZstandard.compress_stream(cctx, data_chunk2, :flush)
  {:ok, {final, _, _}} = ExZstandard.compress_stream(cctx, <<>>, :end_frame)
  compressed = IO.iodata_to_binary([chunk1, chunk2, final])
  ```

  ### Dictionary compression

  ```elixir
  # Train a dictionary from sample data
  samples = [sample1, sample2, sample3, ...]
  {:ok, dictionary} = ExZstandard.train_dictionary(samples, 1024)

  # Compress with dictionary
  {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 3})
  {:ok, compressed} = ExZstandard.compress_with_dict(cctx, data, dictionary)

  # Decompress with dictionary
  {:ok, dctx} = ExZstandard.dctx_init(nil)
  {:ok, decompressed} = ExZstandard.decompress_with_dict(dctx, compressed, dictionary)
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
  {:ok, cctx} = ExZstandard.cctx_init(%{strategy: :text})
  # → level 9 + btopt algorithm

  # Override level while keeping recipe's algorithm
  {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 15, strategy: :text})
  # → level 15 + btopt algorithm

  # Custom level with default algorithm
  {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 5})
  # → level 5 + dfast algorithm

  # Use all defaults
  {:ok, cctx} = ExZstandard.cctx_init(%{})
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
    otp_app: :ex_zstandard,
    c: [link_lib: {:system, "zstd"}],
    zig_code_path: "lib.zig",
    release_mode: @release,
    leak_check: @check_leak,
    nifs: [
      ...,
      compress: [:dirty_cpu],
      decompress: [:dirty_cpu],
      compress_stream: [:dirty_cpu]
    ],
    resources: [:ZstdCResource, :ZstdDResource]

  @doc """
  Compress a file using streaming compression and write to output file as a side-effect.

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
      iex> ExZstandard.compress_file("input.txt", "output.txt.zst")
      :ok

      # Auto-create context with custom settings
      iex> ExZstandard.compress_file("input.txt", "output.txt.zst", compression_level: 10, strategy: :text)
      :ok

      # Reuse existing context for multiple files
      iex> {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 5, strategy: :fast})
      iex> ExZstandard.compress_file("file1.txt", "file1.txt.zst", cctx: cctx)
      iex> ExZstandard.reset_compressor_session(cctx)
      iex> ExZstandard.compress_file("file2.txt", "file2.txt.zst", cctx: cctx)
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

  @doc """
  Decompress a compressed binary using streaming decompression with `Stream.unfold`. It returns the full decompressed binary.

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
      iex> decompressed = ExZstandard.decompress_unfold(compressed)
      iex> byte_size(decompressed)
      1024000

      # Reuse context for multiple decompressions
      iex> {:ok, dctx} = ExZstandard.dctx_init(nil)
      iex> data1 = ExZstandard.decompress_unfold(compressed1, dctx: dctx)
      iex> ExZstandard.reset_decompressor_session(dctx)
      iex> data2 = ExZstandard.decompress_unfold(compressed2, dctx: dctx)

  ## Notes

  The entire decompressed result is built in memory. For very large data (> 100MB),
  prefer `decompress_file/3` which streams to disk.
  """
  def decompress_unfold(input, opts \\ []) do
    dctx = Keyword.get(opts, :dctx) || ExZstandard.dctx_init(nil) |> elem(1)

    input
    |> Stream.unfold(fn
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
  Decompress a file using streaming decompression and write to output file as a side-effect.

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
      iex> ExZstandard.decompress_file("input.txt.zst", "output.txt")
      :ok

      # Auto-create context with max window size
      iex> ExZstandard.decompress_file("input.txt.zst", "output.txt", max_window: 20)
      :ok

      # Reuse existing context for multiple files
      iex> {:ok, dctx} = ExZstandard.dctx_init(nil)
      iex> ExZstandard.decompress_file("file1.txt.zst", "file1.txt", dctx: dctx)
      iex> ExZstandard.reset_decompressor_session(dctx)
      iex> ExZstandard.decompress_file("file2.txt.zst", "file2.txt", dctx: dctx)
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

  def download_compress(cctx, url, path) do
    compressed_pid = File.open!(path, [:write, :binary])

    Req.get!(url,
      into: fn
        {:data, chunk}, {req, resp} ->
          # Compress chunk immediately (with strategy = .fast enough for HTTP callback)
          {:ok, {compressed, _, _}} = ExZstandard.compress_stream(cctx, chunk, :flush)
          :ok = IO.binwrite(compressed_pid, compressed)
          {:cont, {req, resp}}
      end
    )

    :ok = File.close(compressed_pid)
  end

  @doc """
  Download compressed data from URL and decompress on-the-fly to file.

  This function streams compressed data from an HTTP endpoint and decompresses
  it in real-time without creating temporary files. It uses the buffer/accumulator
  pattern to handle frame mis-alignment between HTTP chunks and zstd frames.

  ## Parameters
    - `dctx` - Decompression context to use
    - `url` - URL to download compressed data from
    - `path` - Path where decompressed file will be written

  ## Returns
    - `:ok` on success
    - Raises on error

  ## Examples

      iex> {:ok, dctx} = ExZstandard.dctx_init(nil)
      iex> ExZstandard.stream_download_decompress(dctx, "https://example.com/data.zst", "output.txt")
      :ok

  ## Notes

  This function handles the case where HTTP connections close with data still
  buffered by processing any remaining unconsumed bytes after the stream ends.
  """
  def download_decompress(dctx, url, path) do
    decompressed_pid = File.open!(path, [:write, :binary])

    # Download and decompress chunks as they arrive
    result =
      Req.get!(url,
        into: fn
          {:data, chunk}, {req, resp} ->
            # Get buffer from previous iteration (unconsumed bytes)
            buffer = Req.Response.get_private(resp, :buffer, <<>>)

            # Concatenate with new chunk
            data = buffer <> chunk

            # Decompress what we can
            {:ok, {decompressed, bytes_consumed}} = ExZstandard.decompress_stream(dctx, data)

            # Write decompressed data immediately
            :ok = IO.binwrite(decompressed_pid, decompressed)

            # Keep unconsumed bytes for next iteration
            remaining = binary_part(data, bytes_consumed, byte_size(data) - bytes_consumed)

            # Store buffer in response private for next iteration
            updated_resp = Req.Response.update_private(resp, :buffer, <<>>, fn _ -> remaining end)

            {:cont, {req, updated_resp}}
        end
      )

    # Process any remaining buffered data after stream ends (handle connection close!)
    final_buffer = Req.Response.get_private(result, :buffer, <<>>)

    if byte_size(final_buffer) > 0 do
      # Drain the final buffer (like in decompress_file)
      decompressed_chunks = drain_buffer(dctx, final_buffer, [])

      Enum.each(Enum.reverse(decompressed_chunks), fn chunk ->
        :ok = IO.binwrite(decompressed_pid, chunk)
      end)
    end

    :ok = File.close(decompressed_pid)
  end

  @doc """
  Get compression parameters from a compression context.

  Returns the current settings of a compression context including the compression
  level, strategy algorithm, and window log size.

  ## Parameters
    - `cctx` - Compression context created with `cctx_init/1`

  ## Returns
    - `{:ok, {level, strategy, window_log}}` - Tuple with compression level (integer), strategy (atom), and window log (integer)
    - `{:error, reason}` on failure

  ## Examples

      iex> {:ok, cctx} = ExZstandard.cctx_init(%{strategy: :text})
      iex> ExZstandard.get_compression_params(cctx)
      {:ok, {9, :btopt, 0}}

      iex> {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 15, strategy: :structured_data})
      iex> ExZstandard.get_compression_params(cctx)
      {:ok, {15, :btultra, 0}}

  ## Notes

  - The window_log value of 0 indicates automatic/default window size
  - Strategy atoms correspond to ZSTD compression algorithms
  - This function uses `ZSTD_CCtx_getParameter` from the zstd static API
  """
  # NIF function auto-generated by Zigler from lib.zig
end
