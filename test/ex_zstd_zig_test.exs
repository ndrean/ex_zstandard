defmodule ExZstdZigTest do
  use ExUnit.Case
  # doctest ExZstdZig

  test "simple" do
    file = File.read!("test/fixtures/test.png")
    init_size = byte_size(file)
    compressed_binary = ExZstdZig.simple_compress(file, 22)

    assert ExZstdZig.getDecompressedSize(compressed_binary) == init_size

    decompressed_binary = ExZstdZig.simple_auto_decompress(compressed_binary)
    assert decompressed_binary == file

    returned_binary = ExZstdZig.simple_decompress(compressed_binary, init_size)
    assert returned_binary == file
  end

  test "simple-via system zstd" do
    if File.exists?("test/fixtures/test.zst"), do: File.rm!("test/fixtures/test.zst")

    init_file = File.read!("test/fixtures/test.png")
    init_size = byte_size(init_file)

    System.cmd("zstd", ["-k", "test/fixtures/test.png", "-o", "test/fixtures/test.zst", "-f"])
    compressed_file = File.read!("test/fixtures/test.zst")
    assert ExZstdZig.getDecompressedSize(compressed_file) == init_size
    decompressed_binary = ExZstdZig.simple_auto_decompress(compressed_file)
    assert decompressed_binary == init_file

    if File.exists?("test/fixtures/test.zst"), do: File.rm!("test/fixtures/test.zst")
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
    {:ok, ref_c} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :balanced})

    {:ok, ref_d} = ExZstdZig.dctx_init(nil)

    {:ok, file} = File.read("test/fixtures/test.png")
    {:ok, compressed} = ExZstdZig.compress_with_ctx(ref_c, file)
    assert ExZstdZig.getDecompressedSize(compressed) == byte_size(file)
    {:ok, decompressed} = ExZstdZig.decompress_with_ctx(ref_d, compressed)
    assert decompressed == file
    :ok = ExZstdZig.reset_compressor_session(ref_c)
    :ok = ExZstdZig.reset_decompressor_session(ref_d)
    {:ok, compressed} = ExZstdZig.compress_with_ctx(ref_c, file)
    assert ExZstdZig.getDecompressedSize(compressed) == byte_size(file)
    {:ok, decompressed} = ExZstdZig.decompress_with_ctx(ref_d, compressed)
    assert decompressed == file
  end

  test "dctx_init with max_window parameter" do
    # Test with default (no max window limit)
    {:ok, ref_d_default} = ExZstdZig.dctx_init(nil)
    {:ok, file} = File.read("test/fixtures/streaming_test.html")

    {:ok, ref_c} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :text})
    {:ok, compressed} = ExZstdZig.compress_with_ctx(ref_c, file)
    {:ok, decompressed} = ExZstdZig.decompress_with_ctx(ref_d_default, compressed)
    assert decompressed == file

    # Test with valid max_window (15 is reasonable for small data)
    {:ok, ref_d_limited} = ExZstdZig.dctx_init(15)
    {:ok, decompressed_limited} = ExZstdZig.decompress_with_ctx(ref_d_limited, compressed)
    assert decompressed_limited == file

    # Test with larger max_window (25)
    {:ok, ref_d_large} = ExZstdZig.dctx_init(25)
    {:ok, decompressed_large} = ExZstdZig.decompress_with_ctx(ref_d_large, compressed)
    assert decompressed_large == file

    # Test invalid values (should fail)
    # too small
    assert {:error, :InvalidInput} = ExZstdZig.dctx_init(5)
    # too large
    assert {:error, :InvalidInput} = ExZstdZig.dctx_init(32)
  end

  test "compress-decompress file in stream" do
    if File.exists?("test/fixtures/stream_compressed2.zst"),
      do: File.rm!("test/fixtures/stream_compressed2.zst")

    if File.exists?("test/fixtures/test_decompressed2.html"),
      do: File.rm!("test/fixtures/test_decompressed2.html")

    # full streaming compression with compress_file
    :ok =
      ExZstdZig.compress_file(
        "test/fixtures/streaming_test2.html",
        "test/fixtures/stream_compressed2.zst"
      )

    {:ok, dctx} = ExZstdZig.dctx_init(nil)
    # full streaming decompression with decompress_file
    :ok =
      ExZstdZig.decompress_file(
        "test/fixtures/stream_compressed2.zst",
        "test/fixtures/stream_decompressed2.html",
        dctx: dctx
      )

    assert File.read!("test/fixtures/streaming_test2.html") ==
             File.read!("test/fixtures/stream_decompressed2.html")

    # Streaming decompression with unfold
    if File.exists?("test/fixtures/stream_decompressed2.html"),
      do: File.rm!("test/fixtures/stream_decompressed2.html")

    compressed_data = File.read!("test/fixtures/stream_compressed2.zst")

    decompressed_data =
      ExZstdZig.decompress_unfold(
        compressed_data,
        dctx: dctx
      )

    input = File.read!("test/fixtures/streaming_test2.html")

    assert decompressed_data == input
  end

  # test "compress/decompress multiple files with context reuse" do
  #   # Clean up any existing test files
  #   ["file1.txt.zst", "file2.txt.zst", "file1_out.txt", "file2_out.txt"]
  #   |> Enum.each(fn file ->
  #     path = "test/fixtures/#{file}"
  #     if File.exists?(path), do: File.rm!(path)
  #   end)

  #   # Create test files
  #   File.write!("test/fixtures/file1.txt", "This is test file 1 with some content")
  #   File.write!("test/fixtures/file2.txt", "This is test file 2 with different content")

  #   # Create contexts once
  #   {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5, strategy: :text})
  #   {:ok, dctx} = ExZstdZig.dctx_init(nil)

  #   # Compress first file
  #   :ok =
  #     ExZstdZig.compress_file("test/fixtures/file1.txt", "test/fixtures/file1.txt.zst",
  #       cctx: cctx
  #     )

  #   # Reset and compress second file
  #   :ok = ExZstdZig.reset_compressor_session(cctx)

  #   :ok =
  #     ExZstdZig.compress_file("test/fixtures/file2.txt", "test/fixtures/file2.txt.zst",
  #       cctx: cctx
  #     )

  #   # Decompress first file
  #   :ok =
  #     ExZstdZig.decompress_file("test/fixtures/file1.txt.zst", "test/fixtures/file1_out.txt",
  #       dctx: dctx
  #     )

  #   # Reset and decompress second file
  #   :ok = ExZstdZig.reset_decompressor_session(dctx)

  #   :ok =
  #     ExZstdZig.decompress_file("test/fixtures/file2.txt.zst", "test/fixtures/file2_out.txt",
  #       dctx: dctx
  #     )

  #   # Verify contents
  #   assert File.read!("test/fixtures/file1.txt") == File.read!("test/fixtures/file1_out.txt")
  #   assert File.read!("test/fixtures/file2.txt") == File.read!("test/fixtures/file2_out.txt")

  #   # Clean up test files
  #   ["file1.txt", "file2.txt", "file1.txt.zst", "file2.txt.zst", "file1_out.txt", "file2_out.txt"]
  #   |> Enum.each(fn file ->
  #     path = "test/fixtures/#{file}"
  #     if File.exists?(path), do: File.rm!(path)
  #   end)
  # end

  test "dictionary training and compression" do
    # Create sample data for training (similar small JSON documents)
    samples = [
      ~s({"id": 1, "name": "Alice", "email": "alice@example.com", "age": 30}),
      ~s({"id": 2, "name": "Bob", "email": "bob@example.com", "age": 25}),
      ~s({"id": 3, "name": "Charlie", "email": "charlie@example.com", "age": 35}),
      ~s({"id": 4, "name": "Diana", "email": "diana@example.com", "age": 28}),
      ~s({"id": 5, "name": "Eve", "email": "eve@example.com", "age": 32}),
      ~s({"id": 6, "name": "Frank", "email": "frank@example.com", "age": 40}),
      ~s({"id": 7, "name": "Grace", "email": "grace@example.com", "age": 27}),
      ~s({"id": 8, "name": "Henry", "email": "henry@example.com", "age": 33}),
      ~s({"id": 9, "name": "Ivy", "email": "ivy@example.com", "age": 29}),
      ~s({"id": 10, "name": "Jack", "email": "jack@example.com", "age": 31})
    ]

    # Train dictionary (use 1024 bytes - minimum recommended size)
    {:ok, dictionary} = ExZstdZig.train_dictionary(samples, 1024)
    assert byte_size(dictionary) > 0

    # Test data to compress
    test_data = ~s({"id": 11, "name": "Kate", "email": "kate@example.com", "age": 26})

    # Create compression and decompression contexts
    {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :structured_data})
    {:ok, dctx} = ExZstdZig.dctx_init(nil)

    # Compress with dictionary
    {:ok, compressed_with_dict} = ExZstdZig.compress_with_dict(cctx, test_data, dictionary)

    # Compress without dictionary for comparison
    :ok = ExZstdZig.reset_compressor_session(cctx)
    {:ok, compressed_without_dict} = ExZstdZig.compress_with_ctx(cctx, test_data)

    # Dictionary should provide better compression for similar data
    assert byte_size(compressed_with_dict) < byte_size(compressed_without_dict)

    # Decompress with dictionary
    {:ok, decompressed} = ExZstdZig.decompress_with_dict(dctx, compressed_with_dict, dictionary)
    assert decompressed == test_data
  end

  test "load dictionary and reuse across multiple operations" do
    samples = [
      "The quick brown fox jumps over the lazy dog",
      "The lazy dog jumps high into the air",
      "The quick cat runs fast through the grass",
      "The brown dog sleeps under the big tree",
      "The small fox hunts in the dark forest",
      "The big cat sleeps on the soft pillow",
      "The fast dog runs across the green field",
      "The lazy fox rests near the cold river",
      "The brown cat climbs up the tall tree",
      "The quick dog chases after the small ball"
    ]

    {:ok, dictionary} = ExZstdZig.train_dictionary(samples, 512)

    {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5, strategy: :text})
    {:ok, dctx} = ExZstdZig.dctx_init(nil)

    # Load dictionary once
    :ok = ExZstdZig.load_compression_dictionary(cctx, dictionary)
    :ok = ExZstdZig.load_decompression_dictionary(dctx, dictionary)

    # Compress multiple items using the same loaded dictionary
    data1 = "The quick rabbit hops"
    data2 = "The brown fox jumps"

    {:ok, compressed1} = ExZstdZig.compress_with_ctx(cctx, data1)
    :ok = ExZstdZig.reset_compressor_session(cctx)
    :ok = ExZstdZig.load_compression_dictionary(cctx, dictionary)
    {:ok, compressed2} = ExZstdZig.compress_with_ctx(cctx, data2)

    # Decompress both
    {:ok, decompressed1} = ExZstdZig.decompress_with_ctx(dctx, compressed1)
    :ok = ExZstdZig.reset_decompressor_session(dctx)
    :ok = ExZstdZig.load_decompression_dictionary(dctx, dictionary)
    {:ok, decompressed2} = ExZstdZig.decompress_with_ctx(dctx, compressed2)

    assert decompressed1 == data1
    assert decompressed2 == data2
  end

  # @tag :network_dependent
  test "HTTP fetch and compress on-the-fly" do
    # Compression works on-the-fly because it's fast enough for HTTP callbacks
    # The callback compresses each chunk as it arrives and writes to file

    compressed_file = "test/fixtures/http_stream_compressed.zst"
    decompressed_file = "test/fixtures/http_stream_decompressed.html"

    if File.exists?(compressed_file), do: File.rm!(compressed_file)
    if File.exists?(decompressed_file), do: File.rm!(decompressed_file)

    url =
      "https://raw.githubusercontent.com/ndrean/ex_zstd_zig/refs/heads/main/test/fixtures/streaming_test2.html"

    # Compress as chunks arrive
    {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :fast})
    compressed_pid = File.open!(compressed_file, [:write, :binary])

    Req.get!(url,
      into: fn
        {:data, chunk}, {req, resp} ->
          # Compress chunk immediately (fast enough for HTTP callback)
          {:ok, {compressed, _, _}} = ExZstdZig.compress_stream(cctx, chunk, :flush)
          :ok = IO.binwrite(compressed_pid, compressed)
          {:cont, {req, resp}}
      end
    )

    File.close(compressed_pid)

    # compressed_size = File.stat!(compressed_file).size

    # Verify by decompressing
    {:ok, dctx} = ExZstdZig.dctx_init(nil)
    ExZstdZig.decompress_file(compressed_file, decompressed_file, dctx: dctx)

    assert File.read!("test/fixtures/streaming_test2.html") ==
             File.read!(decompressed_file)

    # Cleanup
    if File.exists?(compressed_file), do: File.rm!(compressed_file)
    if File.exists?(decompressed_file), do: File.rm!(decompressed_file)
  end

  @tag :network_dependent
  test "HTTP fetch compressed then decompress (2-step)" do
    # Decompression CANNOT be done on-the-fly in HTTP callbacks because:
    # - HTTP/2 has no back-pressure mechanism (Finch documentation)
    # - Decompression + file I/O is too slow, blocking the callback
    # - This causes HTTP connection timeouts and data loss
    #
    # Solution: 2-step process
    #   1) Download compressed data and write to file (fast callback)
    #   2) Decompress the file afterwards using streaming decompression

    compressed_file = "test/fixtures/http_download_compressed.zst"
    decompressed_file = "test/fixtures/http_download_decompressed.html"

    if File.exists?(compressed_file), do: File.rm!(compressed_file)
    if File.exists?(decompressed_file), do: File.rm!(decompressed_file)

    url =
      "https://github.com/ndrean/ex_zstd_zig/raw/refs/heads/main/test/fixtures/stream_compressed2.zst"

    # Step 1: Download compressed file (fast, no processing in callback)
    c_pid = File.open!(compressed_file, [:write, :binary])

    Req.get!(url,
      into: fn
        {:data, chunk}, {req, resp} ->
          :ok = IO.binwrite(c_pid, chunk)
          {:cont, {req, resp}}
      end
    )

    File.close(c_pid)

    # downloaded_size = File.stat!(compressed_file).size

    # Step 2: Decompress the file using streaming decompression
    {:ok, dctx} = ExZstdZig.dctx_init(nil)
    ExZstdZig.decompress_file(compressed_file, decompressed_file, dctx: dctx)

    # Verify result
    assert File.read!("test/fixtures/streaming_test2.html") ==
             File.read!(decompressed_file)

    # Verify decompress_unfold works too
    decompressed_bin =
      File.read!(compressed_file)
      |> ExZstdZig.decompress_unfold(dctx: dctx)

    assert File.stat!(decompressed_file).size == byte_size(decompressed_bin)
    # Cleanup
    if File.exists?(compressed_file), do: File.rm!(compressed_file)
    if File.exists?(decompressed_file), do: File.rm!(decompressed_file)
  end

  @tag :network_dependent
  test "speed test" do
    url =
      "https://github.com/ndrean/ex_zstd_zig/raw/refs/heads/main/test/fixtures/stream_compressed2.zst"

    {:ok, dctx} = ExZstdZig.dctx_init(nil)
    decompressed_file = "test/fixtures/http_download_decompressed.html"
    compressed_file = "test/fixtures/http_download_compressed.zst"

    :timer.tc(fn ->
      for _ <- 1..10 do
        c_pid = File.open!(compressed_file, [:write, :binary])

        Req.get!(url,
          into: fn
            {:data, chunk}, {req, resp} ->
              :ok = IO.binwrite(c_pid, chunk)
              {:cont, {req, resp}}
          end
        )

        File.close(c_pid)

        File.read!(compressed_file)
        |> ExZstdZig.decompress_unfold(dctx: dctx)

        File.rm!(compressed_file)
      end
    end)
    |> IO.inspect(label: "Streaming Decompression (microseconds)")

    :timer.tc(fn ->
      for _ <- 1..10 do
        c_pid = File.open!(compressed_file, [:write, :binary])

        Req.get!(url,
          into: fn
            {:data, chunk}, {req, resp} ->
              :ok = IO.binwrite(c_pid, chunk)
              {:cont, {req, resp}}
          end
        )

        File.close(c_pid)

        ExZstdZig.decompress_file(compressed_file, decompressed_file, dctx: dctx)
        File.rm!(compressed_file)
        File.rm!(decompressed_file)
      end
    end)
    |> IO.inspect(label: "Unfold Decompression (microseconds)")
  end
end

# test "streaming with File.open and Stream.resource" do
#   if File.exists?("test/fixtures/stream_compressed.zst"),
#     do: File.rm!("test/fixtures/stream_compressed.zst")

#   # Get original file size for comparison (but don't load the whole file)
#   original_size = File.stat!("test/fixtures/streaming_test.html").size

#   {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :structured_data})
#   {:ok, dctx} = ExZstdZig.dctx_init(nil)

#   chunk_size = ExZstdZig.recommended_c_in_size()

#   # Compress using Stream.resource for proper streaming
#   # compressed_data =
#   Stream.resource(
#     # start_fun: {file_pid, eof_seen?}
#     fn ->
#       {File.open!("test/fixtures/streaming_test.html", [:read, :binary]), false}
#     end,

#     # read_fun
#     fn
#       {file_pid, true} ->
#         # Already handled EOF, halt now
#         {:halt, file_pid}

#       {file_pid, false} ->
#         case IO.binread(file_pid, chunk_size) do
#           :eof ->
#             # Finish the frame and emit final data
#             {:ok, {final, _, _}} = ExZstdZig.compress_stream(cctx, <<>>, :end_frame)
#             {[final], {file_pid, true}}

#           {:error, reason} ->
#             raise "Failed to read file: #{reason}"

#           data ->
#             {:ok, {compressed, _, _}} = ExZstdZig.compress_stream(cctx, data, :flush)
#             {[compressed], {file_pid, false}}
#         end
#     end,

#     # after_fun
#     fn file_pid ->
#       File.close(file_pid)
#     end
#   )
#   |> Stream.into(File.stream!("test/fixtures/stream_compressed.zst", [:append]))
#   |> Stream.run()

#   # Read back the compressed file to verify
#   compressed_data = File.read!("test/fixtures/stream_compressed.zst")

#   assert byte_size(compressed_data) > 0
#   assert byte_size(compressed_data) < original_size

#   # Decompress using Stream.unfold
#   decompressed_data =
#     Stream.unfold(compressed_data, fn
#       <<>> ->
#         nil

#       data ->
#         {:ok, {decompressed, bytes_consumed}} = ExZstdZig.decompress_stream(dctx, data)
#         <<_::binary-size(bytes_consumed), rest::binary>> = data
#         {decompressed, rest}
#     end)
#     |> Enum.to_list()
#     |> IO.iodata_to_binary()

#   assert byte_size(decompressed_data) == original_size

#   # Verify decompressed data matches original
#   {:ok, original_file} = File.read("test/fixtures/streaming_test.html")
#   assert decompressed_data == original_file
# end

# test "streaming with single chunk" do
#   {:ok, file} = File.read("test/fixtures/test.png")

#   {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 1, strategy: :structured_data})
#   {:ok, dctx} = ExZstdZig.dctx_init(nil)

#   # Compress entire file in one go
#   {:ok, {compressed, bytes_consumed, remaining}} =
#     ExZstdZig.compress_stream(cctx, file, :end_frame)

#   assert bytes_consumed == byte_size(file)
#   # All flushed
#   assert remaining == 0

#   # Decompress entire compressed data in one go
#   {:ok, {decompressed, _bytes_consumed}} =
#     ExZstdZig.decompress_stream(dctx, compressed)

#   assert decompressed == file
# end
