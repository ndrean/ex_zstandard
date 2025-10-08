defmodule ExZstdZigTest do
  use ExUnit.Case
  # doctest ExZstdZig

  test "simple" do
    file = File.read!("test/fixtures/test.png")
    init_size = byte_size(file)
    compressed_binary = ExZstdZig.simple_compress(file, 22)
    # byte_size(compressed_binary) |> IO.inspect(label: "Compressed size")

    assert ExZstdZig.getDecompressedSize(compressed_binary) == init_size

    decompressed_binary = ExZstdZig.simple_auto_decompress(compressed_binary)
    assert decompressed_binary == file

    returned_binary = ExZstdZig.simple_decompress(compressed_binary, init_size)
    assert returned_binary == file
  end

  test "simple-via system zstd" do
    init_file = File.read!("test/fixtures/test.png")
    init_size = byte_size(init_file)

    System.cmd("zstd", ["-k", "test/fixtures/test.png", "-o", "test/fixtures/test.zst", "-f"])
    compressed_file = File.read!("test/fixtures/test.zst")
    # byte_size(compressed_file) |> IO.inspect(label: "Compressed file size")
    assert ExZstdZig.getDecompressedSize(compressed_file) == init_size
    decompressed_binary = ExZstdZig.simple_auto_decompress(compressed_file)
    assert decompressed_binary == init_file
  end

  test "simple return tuple" do
    file = File.read!("test/fixtures/test.png")
    init_size = byte_size(file)
    {:ok, compressed_binary} = ExZstdZig.compress(file, 3)
    assert ExZstdZig.getDecompressedSize(compressed_binary) == init_size
    {:ok, decompressed_binary} = ExZstdZig.decompress(compressed_binary)
    assert decompressed_binary == file
  end

  test "compress with resource with reset_session" do
    {:ok, ref_c} = ExZstdZig.cctx_init(3)

    {:ok, ref_d} = ExZstdZig.dctx_init(nil)

    {:ok, f} = File.read("test/fixtures/test.png")
    {:ok, compressed} = ExZstdZig.compress_with_ctx(ref_c, f)
    assert ExZstdZig.getDecompressedSize(compressed) == byte_size(f)
    {:ok, decompressed} = ExZstdZig.decompress_with_ctx(ref_d, compressed)
    assert decompressed == f
    :ok = ExZstdZig.reset_compressor_session(ref_c)
    :ok = ExZstdZig.reset_decompressor_session(ref_d)
    {:ok, compressed} = ExZstdZig.compress_with_ctx(ref_c, f)
    assert ExZstdZig.getDecompressedSize(compressed) == byte_size(f)
    {:ok, decompressed} = ExZstdZig.decompress_with_ctx(ref_d, compressed)
    assert decompressed == f
  end

  test "dctx_init with max_window parameter" do
    # Test with default (no max window limit)
    {:ok, ref_d_default} = ExZstdZig.dctx_init(nil)
    {:ok, f} = File.read("test/fixtures/streaming_test.html")
    {:ok, ref_c} = ExZstdZig.cctx_init(3)
    {:ok, compressed} = ExZstdZig.compress_with_ctx(ref_c, f)
    {:ok, decompressed} = ExZstdZig.decompress_with_ctx(ref_d_default, compressed)
    assert decompressed == f

    # Test with valid max_window (15 is reasonable for small data)
    {:ok, ref_d_limited} = ExZstdZig.dctx_init(15)
    {:ok, decompressed_limited} = ExZstdZig.decompress_with_ctx(ref_d_limited, compressed)
    assert decompressed_limited == f

    # Test with larger max_window (25)
    {:ok, ref_d_large} = ExZstdZig.dctx_init(25)
    {:ok, decompressed_large} = ExZstdZig.decompress_with_ctx(ref_d_large, compressed)
    assert decompressed_large == f

    # Test invalid values (should fail)
    # too small
    assert {:error, :InvalidInput} = ExZstdZig.dctx_init(5)
    # too large
    assert {:error, :InvalidInput} = ExZstdZig.dctx_init(32)
  end

  # test "streaming compression and decompression with flush" do
  #   {:ok, original_file} = File.read("test/fixtures/streaming_test.html")

  #   # Get recommended buffer sizes
  #   in_size = ExZstdZig.recommended_c_in_size()
  #   IO.inspect(in_size, label: "recommended input size")

  #   # Initialize contexts
  #   {:ok, cctx} = ExZstdZig.cctx_init(3)
  #   {:ok, dctx} = ExZstdZig.dctx_init(nil)

  #   # Compress using File.stream! |> Stream.map with :flush
  #   # This ensures each chunk produces output
  #   compressed_chunks =
  #     "test/fixtures/streaming_test.html"
  #     |> File.stream!([], in_size)
  #     |> Stream.map(fn chunk ->
  #       {:ok, {compressed, bytes_consumed, remaining}} =
  #         ExZstdZig.compress_stream(cctx, chunk, :flush)

  #       dbg({:flush, byte_size(chunk), bytes_consumed, byte_size(compressed), remaining})
  #       compressed
  #     end)
  #     |> Enum.to_list()

  #   # End the frame
  #   {:ok, {final_compressed, bytes_consumed, remaining}} =
  #     ExZstdZig.compress_stream(cctx, <<>>, :end_frame)

  #   # dbg({:end_frame, bytes_consumed, byte_size(final_compressed), remaining})

  #   compressed_data = IO.iodata_to_binary(compressed_chunks ++ [final_compressed])
  #   # dbg({:compressed_total, byte_size(compressed_data), byte_size(original_file)})
  #   assert byte_size(compressed_data) > 0
  #   assert byte_size(compressed_data) < byte_size(original_file)

  #   # Decompress using Stream.unfold
  #   decompressed_data =
  #     compressed_data
  #     |> Stream.unfold(fn
  #       <<>> ->
  #         nil

  #       data ->
  #         # Feed compressed data to decompressor
  #         {:ok, {decompressed, bytes_consumed}} =
  #           ExZstdZig.decompress_stream(dctx, data)

  #         # Split off the consumed bytes, keep the rest for next iteration
  #         <<_consumed::binary-size(bytes_consumed), rest::binary>> = data

  #         dbg(
  #           {:decompress, byte_size(data), bytes_consumed, byte_size(decompressed),
  #            byte_size(rest)}
  #         )

  #         {decompressed, rest}
  #     end)
  #     |> Enum.to_list()
  #     |> IO.iodata_to_binary()

  #   dbg({:decompressed_total, byte_size(decompressed_data), byte_size(original_file)})
  #   # assert decompressed_data == original_file
  # end

  # test "streaming compression with continue_op (buffering)" do
  #   {:ok, original_file} = File.read("test/fixtures/streaming_test.html")
  #   in_size = ExZstdZig.recommended_c_in_size()
  #   IO.inspect(in_size, label: "recommended input size")

  #   {:ok, cctx} = ExZstdZig.cctx_init(3)
  #   {:ok, dctx} = ExZstdZig.dctx_init(nil)

  #   # Using :continue_op - chunks may produce empty output (buffering)
  #   compressed_chunks =
  #     "test/fixtures/streaming_test.html"
  #     |> File.stream!([], in_size)
  #     |> Stream.map(fn chunk ->
  #       {:ok, {compressed, bytes_consumed, remaining}} =
  #         ExZstdZig.compress_stream(cctx, chunk, :continue_op)

  #       dbg({:continue_op, byte_size(chunk), bytes_consumed, byte_size(compressed), remaining})
  #       # May be empty!
  #       compressed
  #     end)
  #     |> Enum.to_list()

  #   # End frame flushes all buffered data
  #   {:ok, {final_compressed, _bytes_consumed, _remaining}} =
  #     ExZstdZig.compress_stream(cctx, <<>>, :end_frame)

  #   # dbg({:end_frame, bytes_consumed, byte_size(final_compressed), remaining})

  #   compressed_data = IO.iodata_to_binary(compressed_chunks ++ [final_compressed])
  #   # dbg({:compressed_total, byte_size(compressed_data), byte_size(original_file)})
  #   # assert byte_size(compressed_data) > 0

  #   # Decompress
  #   decompressed_data =
  #     compressed_data
  #     |> Stream.unfold(fn
  #       <<>> ->
  #         nil

  #       data ->
  #         # Feed compressed data to decompressor
  #         {:ok, {decompressed, bytes_consumed}} = ExZstdZig.decompress_stream(dctx, data)

  #         # Split off the consumed bytes, keep the rest for next iteration
  #         <<_consumed::binary-size(bytes_consumed), rest::binary>> = data

  #         # dbg(
  #         #   {:decompress, byte_size(data), bytes_consumed, byte_size(decompressed),
  #         #    byte_size(rest)}
  #         # )

  #         {decompressed, rest}
  #     end)
  #     |> Enum.to_list()
  #     |> IO.iodata_to_binary()

  #   # dbg({:decompressed_total, byte_size(decompressed_data), byte_size(original_file)})
  #   assert decompressed_data == original_file
  # end

  test "streaming with File.open and Stream.resource" do
    File.rm!("test/fixtures/stream_compressed.zst")
    # Get original file size for comparison (but don't load the whole file)
    original_size = File.stat!("test/fixtures/streaming_test.html").size

    {:ok, cctx} = ExZstdZig.cctx_init(3)
    {:ok, dctx} = ExZstdZig.dctx_init(nil)

    chunk_size = ExZstdZig.recommended_c_in_size()

    # Compress using Stream.resource for proper streaming
    # compressed_data =
    Stream.resource(
      # start_fun: {file_pid, eof_seen?}
      fn ->
        {File.open!("test/fixtures/streaming_test.html", [:read, :binary]), false}
      end,

      # read_fun
      fn
        {file_pid, true} ->
          # Already handled EOF, halt now
          {:halt, file_pid}

        {file_pid, false} ->
          case IO.binread(file_pid, chunk_size) do
            :eof ->
              # Finish the frame and emit final data
              {:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)
              {[final], {file_pid, true}}

            {:error, reason} ->
              raise "Failed to read file: #{reason}"

            data ->
              {:ok, {compressed, _, _}} = ExZstdZig.compress_stream(cctx, data, :flush)
              {[compressed], {file_pid, false}}
          end
      end,

      # after_fun
      fn file_pid ->
        File.close(file_pid)
      end
    )
    |> Stream.into(File.stream!("test/fixtures/stream_compressed.zst", [:append]))
    |> Stream.run()

    # Read back the compressed file to verify
    compressed_data = File.read!("test/fixtures/stream_compressed.zst")

    dbg(byte_size(compressed_data))
    assert byte_size(compressed_data) > 0
    assert byte_size(compressed_data) < original_size

    # Decompress using Stream.unfold
    decompressed_data =
      Stream.unfold(compressed_data, fn
        <<>> ->
          nil

        data ->
          {:ok, {decompressed, bytes_consumed}} = ExZstdZig.decompress_stream(dctx, data)
          <<_::binary-size(bytes_consumed), rest::binary>> = data
          {decompressed, rest}
      end)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert byte_size(decompressed_data) == original_size

    # Verify decompressed data matches original
    # {:ok, original_file} = File.read("test/fixtures/streaming_test.html")
    # assert decompressed_data == original_file
  end

  test "streaming with single chunk" do
    {:ok, file} = File.read("test/fixtures/test.png")

    {:ok, cctx} = ExZstdZig.cctx_init(5)
    {:ok, dctx} = ExZstdZig.dctx_init(nil)

    # Compress entire file in one go
    {:ok, {compressed, bytes_consumed, remaining}} =
      ExZstdZig.compress_stream(cctx, file, :end_frame)

    assert bytes_consumed == byte_size(file)
    # All flushed
    assert remaining == 0

    # Decompress entire compressed data in one go
    {:ok, {decompressed, _bytes_consumed}} =
      ExZstdZig.decompress_stream(dctx, compressed)

    assert decompressed == file
  end

  test "final" do
    File.rm!("test/fixtures/test.png.zst")
    :ok = ExZstdZig.compress_file("test/fixtures/test.png", "test/fixtures/test.png.zst")

    :ok =
      ExZstdZig.decompress_file(
        "test/fixtures/test.png.zst",
        "test/fixtures/test_decompressed.png",
        []
      )

    assert File.read!("test/fixtures/test.png") ==
             File.read!("test/fixtures/test_decompressed.png")
  end
end
