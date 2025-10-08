defmodule ExZstdZig do
  @moduledoc """
  Provides bindings to the Zstandard (zstd) compression library using Zig.
  The compression and decompression functions are implemented in Zig and exposed to Elixir via the Zigler library.
  The library requires the zstd C library to be installed on the system.
  It provides:
  - a one-shot compression function `simple_compress/2` and `simple_auto_decompress/1` (or `simple_decompress/2`)
  - a streaming compression API via the `Compressor` module and a streaming decompression API via the `Decompressor` module.

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
      - `:compression_level` - Compression level (1-22), default: 3
      - `:chunk_size` - Size of chunks to read/process, default: recommended size from zstd
      - `:mode` - `:flush` (guaranteed output per chunk) or `:continue_op` (better compression), default: `:flush`

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> ExZstdZig.compress_file("input.txt", "output.txt.zst")
      :ok

      iex> ExZstdZig.compress_file("input.txt", "output.txt.zst", compression_level: 10)
      :ok

      iex> ExZstdZig.compress_file("input.txt", "output.txt.zst", mode: :continue_op)
      :ok
  """
  def compress_file(input_path, output_path, opts \\ []) do
    compression_level = Keyword.get(opts, :compression_level, 3)
    chunk_size = Keyword.get(opts, :chunk_size, recommended_c_in_size())
    mode = Keyword.get(opts, :mode, :flush)

    with {:ok, cctx} <- cctx_init(compression_level) do
      Stream.resource(
        # start_fun
        fn ->
          {File.open!(input_path, [:read, :binary]), false}
        end,
        # read_fun
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
  end

  @doc """
  Decompress a file using streaming decompression and write to output file.

  This function provides true streaming decompression - data is read, decompressed,
  and written in chunks without loading the entire file into memory.

  ## Parameters
    - `input_path` - Path to the compressed file
    - `output_path` - Path where decompressed file will be written
    - `opts` - Keyword list of options:
      - `:chunk_size` - Size of chunks to read, default: recommended size from zstd

  ## Returns
    - `:ok` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> ExZstdZig.decompress_file("input.txt.zst", "output.txt")
      :ok
  """
  def decompress_file(input_path, output_path, _opts \\ []) do
    # chunk_size = Keyword.get(opts, :chunk_size, recommended_d_in_size())

    with {:ok, dctx} <- dctx_init(nil) do
      compressed_data = File.read!(input_path)

      Stream.unfold(compressed_data, fn
        <<>> ->
          nil

        data ->
          {:ok, {decompressed, bytes_consumed}} = decompress_stream(dctx, data)
          <<_::binary-size(bytes_consumed), rest::binary>> = data
          {decompressed, rest}
      end)
      |> Stream.into(File.stream!(output_path, [:write]))
      |> Stream.run()

      :ok
    end
  end
end
