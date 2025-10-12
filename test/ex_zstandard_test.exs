defmodule ExZstandardTest do
  use ExUnit.Case
  # doctest ExZstandard

  test "simple" do
    file = File.read!("test/fixtures/test.png")
    init_size = byte_size(file)

    IO.puts("\n=== Simple Compress PNG level 22 ---: #{Float.round(init_size / 1024, 2)}kB\n")

    {:ok, compressed_binary} = ExZstandard.compress(file, 22)

    IO.puts("#{Float.round(byte_size(compressed_binary) / 1024, 2)} kB")

    assert ExZstandard.getDecompressedSize(compressed_binary) == init_size

    {:ok, decompressed_binary} = ExZstandard.decompress(compressed_binary)
    assert decompressed_binary == file

    {:ok, returned_binary} = ExZstandard.decompress(compressed_binary)
    assert returned_binary == file

    IO.puts("\n=== Simple Compress PNG level 9\n")

    {:ok, compressed_binary} = ExZstandard.compress(file, 9)
    assert ExZstandard.getDecompressedSize(compressed_binary) == init_size
    {:ok, decompressed_binary} = ExZstandard.decompress(compressed_binary)
    IO.puts("#{Float.round(byte_size(compressed_binary) / 1024, 2)} kB")

    assert decompressed_binary == file
  end

  test "compress PNG with resource with different strategies" do
    {:ok, file} = File.read("test/fixtures/test.png")
    IO.puts("\n=== Compress PNG ---: #{Float.round(byte_size(file) / 1024, 2)}kB")

    IO.puts("\n :binary")
    {:ok, ref_c} = ExZstandard.cctx_init(%{strategy: :binary})
    {:ok, _compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, _compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    IO.puts(byte_size(compressed))
    :ok = ExZstandard.reset_compressor(ref_c)

    IO.puts("\n :balanced")
    {:ok, ref_c} = ExZstandard.cctx_init(%{strategy: :balanced})
    {:ok, _compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    IO.puts(byte_size(compressed))

    :ok = ExZstandard.reset_compressor(ref_c)

    IO.puts("\n :fast")
    {:ok, ref_c} = ExZstandard.cctx_init(%{strategy: :fast})
    {:ok, _compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    IO.puts(byte_size(compressed))

    :ok = ExZstandard.reset_compressor(ref_c)
    IO.puts("\n :maximum")
    {:ok, ref_c} = ExZstandard.cctx_init(%{strategy: :maximum})
    {:ok, _compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, _compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    IO.puts(byte_size(compressed))
  end

  test "decompress large file" do
    IO.puts("\n=== Simple Decompress large file\n")
    compressed = File.read!("test/fixtures/stream_compressed2.zst")
    ExZstandard.decompress(compressed)
  end

  test "dctx_init with max_window parameter" do
    # Test with default (no max window limit)
    {:ok, ref_d_default} = ExZstandard.dctx_init(nil)
    {:ok, file} = File.read("test/fixtures/streaming_test.html")

    {:ok, ref_c} = ExZstandard.cctx_init(%{compression_level: 3, strategy: :text})
    {:ok, compressed} = ExZstandard.compress_with_ctx(ref_c, file)
    {:ok, decompressed} = ExZstandard.decompress_with_ctx(ref_d_default, compressed)
    assert decompressed == file

    # Test with valid max_window (15 is reasonable for small data)
    {:ok, ref_d_limited} = ExZstandard.dctx_init(15)
    {:ok, decompressed_limited} = ExZstandard.decompress_with_ctx(ref_d_limited, compressed)
    assert decompressed_limited == file

    # Test with larger max_window (25)
    {:ok, ref_d_large} = ExZstandard.dctx_init(25)
    {:ok, decompressed_large} = ExZstandard.decompress_with_ctx(ref_d_large, compressed)
    assert decompressed_large == file

    # Test invalid values (should fail)
    # too small
    assert {:error, :InvalidInput} = ExZstandard.dctx_init(5)
    # too large
    assert {:error, :InvalidInput} = ExZstandard.dctx_init(32)
  end

  test "compress-decompress file in stream" do
    if File.exists?("test/fixtures/stream_compressed.zst"),
      do: File.rm!("test/fixtures/stream_compressed.zst")

    if File.exists?("test/fixtures/test_decompressed.html"),
      do: File.rm!("test/fixtures/test_decompressed.html")

    # full streaming compression with compress_file
    IO.puts("\n=== Compress file in streams -------\n")
    IO.puts(":structured\n")
    {:ok, cctx} = ExZstandard.cctx_init(%{strategy: :structured_data})

    :ok =
      ExZstandard.compress_file(
        "test/fixtures/streaming_test.html",
        "test/fixtures/stream_compressed.zst",
        cctx: cctx
      )

    File.rm!("test/fixtures/stream_compressed.zst")

    :ok = ExZstandard.reset_compressor(cctx)
    IO.puts("\n:fast\n")
    {:ok, cctx} = ExZstandard.cctx_init(%{strategy: :fast})

    :ok =
      ExZstandard.compress_file(
        "test/fixtures/streaming_test.html",
        "test/fixtures/stream_compressed.zst",
        cctx: cctx
      )

    {:ok, dctx} = ExZstandard.dctx_init(nil)
    # full streaming decompression with decompress_file
    IO.puts("\n=== Decompress file in streams -------\n")

    :ok =
      ExZstandard.decompress_file(
        "test/fixtures/stream_compressed.zst",
        "test/fixtures/stream_decompressed.html",
        dctx: dctx
      )

    assert File.read!("test/fixtures/streaming_test.html") ==
             File.read!("test/fixtures/stream_decompressed.html")

    File.rm!("test/fixtures/stream_compressed.zst")
    File.rm!("test/fixtures/stream_decompressed.html")
  end

  test "decompress unfold" do
    # Streaming decompression with unfold
    IO.puts("\n=== Compress as :structured_data\n")
    temp_compressed = System.tmp_dir() <> "stream_compressed.zst"
    {:ok, cctx} = ExZstandard.cctx_init(%{strategy: :structured_data})
    ExZstandard.compress_file("test/fixtures/streaming_test.html", temp_compressed, cctx: cctx)

    compressed_data = File.read!(temp_compressed)
    {:ok, dctx} = ExZstandard.dctx_init(nil)

    IO.puts("\n Stream unfold of structured data--\n")

    decompressed_data =
      ExZstandard.decompress_unfold(
        compressed_data,
        dctx: dctx
      )

    input = File.read!("test/fixtures/streaming_test.html")

    assert decompressed_data == input

    File.rm!(temp_compressed)
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
  #   {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 5, strategy: :text})
  #   {:ok, dctx} = ExZstandard.dctx_init(nil)

  #   # Compress first file
  #   :ok =
  #     ExZstandard.compress_file("test/fixtures/file1.txt", "test/fixtures/file1.txt.zst",
  #       cctx: cctx
  #     )

  #   # Reset and compress second file
  #   :ok = ExZstandard.reset_compressor(cctx)

  #   :ok =
  #     ExZstandard.compress_file("test/fixtures/file2.txt", "test/fixtures/file2.txt.zst",
  #       cctx: cctx
  #     )

  #   # Decompress first file
  #   :ok =
  #     ExZstandard.decompress_file("test/fixtures/file1.txt.zst", "test/fixtures/file1_out.txt",
  #       dctx: dctx
  #     )

  #   # Reset and decompress second file
  #   :ok = ExZstandard.reset_decompressor_session(dctx)

  #   :ok =
  #     ExZstandard.decompress_file("test/fixtures/file2.txt.zst", "test/fixtures/file2_out.txt",
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
    {:ok, dictionary} = ExZstandard.train_dictionary(samples, 1024)
    assert byte_size(dictionary) > 0

    # Test data to compress
    test_data = ~s({"id": 11, "name": "Kate", "email": "kate@example.com", "age": 26})

    # Create compression and decompression contexts
    {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 3, strategy: :structured_data})
    {:ok, dctx} = ExZstandard.dctx_init(nil)

    # Compress with dictionary
    {:ok, compressed_with_dict} = ExZstandard.compress_with_dict(cctx, test_data, dictionary)

    # Compress without dictionary for comparison
    :ok = ExZstandard.reset_compressor(cctx)
    {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 3, strategy: :structured_data})
    {:ok, compressed_without_dict} = ExZstandard.compress_with_ctx(cctx, test_data)

    # Dictionary should provide better compression for similar data
    assert byte_size(compressed_with_dict) < byte_size(compressed_without_dict)

    # Decompress with dictionary
    {:ok, decompressed} = ExZstandard.decompress_with_dict(dctx, compressed_with_dict, dictionary)
    assert decompressed == test_data
  end

  # test "load dictionary and reuse across multiple operations" do
  #   samples = [
  #     "The quick brown fox jumps over the lazy dog",
  #     "The lazy dog jumps high into the air",
  #     "The quick cat runs fast through the grass",
  #     "The brown dog sleeps under the big tree",
  #     "The small fox hunts in the dark forest",
  #     "The big cat sleeps on the soft pillow",
  #     "The fast dog runs across the green field",
  #     "The lazy fox rests near the cold river",
  #     "The brown cat climbs up the tall tree",
  #     "The quick dog chases after the small ball"
  #   ]

  #   {:ok, dictionary} = ExZstandard.train_dictionary(samples, 512)

  #   {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 5, strategy: :text})
  #   {:ok, dctx} = ExZstandard.dctx_init(nil)

  #   # Load dictionary once
  #   :ok = ExZstandard.load_compression_dictionary(cctx, dictionary)
  #   :ok = ExZstandard.load_decompression_dictionary(dctx, dictionary)

  #   # Compress multiple items using the same loaded dictionary
  #   data1 = "The quick rabbit hops"
  #   data2 = "The brown fox jumps"

  #   IO.puts("\n=== Dictionary ---\n")

  #   {:ok, compressed1} = ExZstandard.compress_with_ctx(cctx, data1)
  #   :ok = ExZstandard.load_compression_dictionary(cctx, dictionary)
  #   {:ok, compressed2} = ExZstandard.compress_with_ctx(cctx, data2)

  #   # Decompress both
  #   {:ok, decompressed1} = ExZstandard.decompress_with_ctx(dctx, compressed1)
  #   :ok = ExZstandard.load_decompression_dictionary(dctx, dictionary)
  #   {:ok, decompressed2} = ExZstandard.decompress_with_ctx(dctx, compressed2)

  #   assert decompressed1 == data1
  #   assert decompressed2 == data2
  # end

  @tag :network
  test "HTTP fetch and compress on-the-fly" do
    # Compression works on-the-fly because it's fast enough for HTTP callbacks
    # The callback compresses each chunk as it arrives and writes to file

    compressed_file = System.tmp_dir() <> "http_stream_compressed.zst"
    decompressed_file = System.tmp_dir() <> "http_stream_decompressed.html"
    # compressed_file = "test/fixtures/http_stream_compressed.zst"
    # decompressed_file = "test/fixtures/http_stream_decompressed.html"

    if File.exists?(compressed_file), do: File.rm!(compressed_file)
    if File.exists?(decompressed_file), do: File.rm!(decompressed_file)

    url =
      "https://raw.githubusercontent.com/ndrean/ex_zstd_zig/refs/heads/main/test/fixtures/streaming_test2.html"

    # Compress as chunks arrive
    IO.puts("\n Download & compress on-the-fly------\n")
    {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 3, strategy: :fast})
    compressed_pid = File.open!(compressed_file, [:write, :binary])

    Req.get!(url,
      into: fn
        {:data, chunk}, {req, resp} ->
          # Compress chunk immediately (fast enough for HTTP callback)
          {:ok, {compressed, _, _}} = ExZstandard.compress_stream(cctx, chunk, :flush)
          :ok = IO.binwrite(compressed_pid, compressed)
          {:cont, {req, resp}}
      end
    )

    File.close(compressed_pid)

    # compressed_size = File.stat!(compressed_file).size

    # Verify by decompressing
    # {:ok, dctx} = ExZstandard.dctx_init(nil)
    # ExZstandard.decompress_file(compressed_file, decompressed_file, dctx: dctx)

    # assert File.read!("test/fixtures/streaming_test2.html") ==
    #          File.read!(decompressed_file)

    # Cleanup
    File.rm!(compressed_file)
    # File.rm!(decompressed_file)
  end

  @tag :network
  test "HTTP fetch compressed then decompress (2-step)" do
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

    IO.puts("\n=== Decompress on-the-fly\n")
    # Step 2: Decompress the file using streaming decompression
    {:ok, dctx} = ExZstandard.dctx_init(nil)
    ExZstandard.decompress_file(compressed_file, decompressed_file, dctx: dctx)

    # Verify result
    assert File.read!("test/fixtures/streaming_test2.html") ==
             File.read!(decompressed_file)

    # Verify decompress_unfold works too
    decompressed_bin =
      File.read!(compressed_file)
      |> ExZstandard.decompress_unfold(dctx: dctx)

    assert File.stat!(decompressed_file).size == byte_size(decompressed_bin)
    # Cleanup
    if File.exists?(compressed_file), do: File.rm!(compressed_file)
    if File.exists?(decompressed_file), do: File.rm!(decompressed_file)
  end

  # @tag :network
  # test "speed test" do
  #   url =
  #     "https://github.com/ndrean/ex_zstd_zig/raw/refs/heads/main/test/fixtures/stream_compressed2.zst"

  #   {:ok, dctx} = ExZstandard.dctx_init(nil)
  #   decompressed_file = "test/fixtures/http_download_decompressed.html"
  #   compressed_file = "test/fixtures/http_download_compressed.zst"

  #   IO.puts("\n=== Speed Test: decompress_unfold ===")

  #   unfold_times =
  #     for i <- 1..2 do
  #       c_pid = File.open!(compressed_file, [:write, :binary])

  #       Req.get!(url,
  #         into: fn
  #           {:data, chunk}, {req, resp} ->
  #             :ok = IO.binwrite(c_pid, chunk)
  #             {:cont, {req, resp}}
  #         end
  #       )

  #       File.close(c_pid)

  #       compressed = File.read!(compressed_file)

  #       # Reset context for clean measurement
  #       :ok = ExZstandard.reset_decompressor_session(dctx)

  #       {time_us, _decompressed_binary} =
  #         :timer.tc(fn ->
  #           ExZstandard.decompress_unfold(compressed, dctx: dctx)
  #         end)

  #       if rem(i, 5) == 0,
  #         do: IO.puts("  Iteration #{i}: #{time_us} μs (#{Float.round(time_us / 1000, 3)} ms)")

  #       File.rm!(compressed_file)
  #       time_us
  #     end

  #   avg_unfold = Enum.sum(unfold_times) / length(unfold_times)
  #   IO.puts("Average: #{Float.round(avg_unfold, 2)} μs (#{Float.round(avg_unfold / 1000, 3)} ms)")
  #   IO.puts("Status: #{if avg_unfold > 1000, do: "⚠️  NEEDS dirty_cpu", else: "✓ OK"}")

  #   IO.puts("\n=== Speed Test: decompress_file ===")

  #   file_times =
  #     for i <- 1..2 do
  #       c_pid = File.open!(compressed_file, [:write, :binary])

  #       Req.get!(url,
  #         into: fn
  #           {:data, chunk}, {req, resp} ->
  #             :ok = IO.binwrite(c_pid, chunk)
  #             {:cont, {req, resp}}
  #         end
  #       )

  #       File.close(c_pid)

  #       # Reset context for clean measurement
  #       :ok = ExZstandard.reset_decompressor_session(dctx)

  #       {time_us, _result} =
  #         :timer.tc(fn ->
  #           ExZstandard.decompress_file(compressed_file, decompressed_file, dctx: dctx)
  #         end)

  #       if rem(i, 5) == 0,
  #         do: IO.puts("  Iteration #{i}: #{time_us} μs (#{Float.round(time_us / 1000, 3)} ms)")

  #       File.rm!(compressed_file)
  #       File.rm!(decompressed_file)
  #       time_us
  #     end

  #   avg_file = Enum.sum(file_times) / length(file_times)
  #   IO.puts("Average: #{Float.round(avg_file, 2)} μs (#{Float.round(avg_file / 1000, 3)} ms)")
  #   IO.puts("Status: #{if avg_file > 1000, do: "⚠️  NEEDS dirty_cpu", else: "✓ OK"}")
  # end

  # test "NIF timing - measure compress_stream and decompress_stream" do
  #   # Load test data
  #   file = File.read!("test/fixtures/test.png")
  #   {:ok, cctx} = ExZstandard.cctx_init(%{compression_level: 3, strategy: :balanced})
  #   {:ok, dctx} = ExZstandard.dctx_init(nil)

  #   # Measure compress_stream with different chunk sizes
  #   IO.puts("\n=== Compression Timing ===")

  #   chunk_sizes = [1024, 4096, 16384, 65536, 131_072]

  #   for chunk_size <- chunk_sizes do
  #     times = for _ <- 1..100 do
  #       # Reset context to ensure clean compression state
  #       :ok = ExZstandard.reset_compressor_session(cctx)

  #       chunk = :binary.part(file, 0, min(chunk_size, byte_size(file)))
  #       {time_us, _result} = :timer.tc(fn ->
  #         ExZstandard.compress_stream(cctx, chunk, :flush)
  #       end)
  #       time_us
  #     end

  #     avg_time = Enum.sum(times) / length(times)
  #     max_time = Enum.max(times)
  #     min_time = Enum.min(times)

  #     IO.puts("Chunk size: #{chunk_size} bytes")
  #     IO.puts("  Avg: #{Float.round(avg_time, 2)} μs (#{Float.round(avg_time / 1000, 3)} ms)")
  #     IO.puts("  Min: #{min_time} μs, Max: #{max_time} μs")
  #     IO.puts("  Status: #{if avg_time > 1000, do: "⚠️  NEEDS dirty_cpu", else: "✓ OK"}")
  #   end

  #   # Compress full file for decompression test
  #   ExZstandard.reset_compressor_session(cctx)
  #   {:ok, compressed} = ExZstandard.compress_with_ctx(cctx, file)

  #   # Measure decompress_stream with different chunk sizes
  #   IO.puts("\n=== Decompression Timing ===")

  #   for chunk_size <- chunk_sizes do
  #     times = for _ <- 1..100 do
  #       # Reset decompression context to ensure clean state
  #       :ok = ExZstandard.reset_decompressor_session(dctx)

  #       chunk = :binary.part(compressed, 0, min(chunk_size, byte_size(compressed)))
  #       {time_us, _result} = :timer.tc(fn ->
  #         ExZstandard.decompress_stream(dctx, chunk)
  #       end)
  #       time_us
  #     end

  #     avg_time = Enum.sum(times) / length(times)
  #     max_time = Enum.max(times)
  #     min_time = Enum.min(times)

  #     IO.puts("Chunk size: #{chunk_size} bytes")
  #     IO.puts("  Avg: #{Float.round(avg_time, 2)} μs (#{Float.round(avg_time / 1000, 3)} ms)")
  #     IO.puts("  Min: #{min_time} μs, Max: #{max_time} μs")
  #     IO.puts("  Status: #{if avg_time > 1000, do: "⚠️  NEEDS dirty_cpu", else: "✓ OK"}")
  #   end
  # end
end
