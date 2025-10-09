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
    {:ok, ref_c} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :fast})

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

  test "streaming with File.open and Stream.resource" do
    if File.exists?("test/fixtures/stream_compressed.zst"),
      do: File.rm!("test/fixtures/stream_compressed.zst")

    # Get original file size for comparison (but don't load the whole file)
    original_size = File.stat!("test/fixtures/streaming_test.html").size

    {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 3, strategy: :structured_data})
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
    {:ok, original_file} = File.read("test/fixtures/streaming_test.html")
    assert decompressed_data == original_file
  end

  test "streaming with single chunk" do
    {:ok, file} = File.read("test/fixtures/test.png")

    {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5, strategy: :structured_data})
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
    if File.exists?("test/fixtures/stream_compressed.zst"),
      do: File.rm!("test/fixtures/stream_compressed.zst")

    if File.exists?("test/fixtures/test_decompressed.html"),
      do: File.rm!("test/fixtures/test_decompressed.html")

    :ok =
      ExZstdZig.compress_file(
        "test/fixtures/streaming_test.html",
        "test/fixtures/stream_compressed.zst"
      )

    :ok =
      ExZstdZig.decompress_file(
        "test/fixtures/stream_compressed.zst",
        "test/fixtures/test_decompressed.html",
        []
      )

    assert File.read!("test/fixtures/streaming_test.html") ==
             File.read!("test/fixtures/test_decompressed.html")
  end

  test "compress/decompress multiple files with context reuse" do
    # Clean up any existing test files
    ["file1.txt.zst", "file2.txt.zst", "file1_out.txt", "file2_out.txt"]
    |> Enum.each(fn file ->
      path = "test/fixtures/#{file}"
      if File.exists?(path), do: File.rm!(path)
    end)

    # Create test files
    File.write!("test/fixtures/file1.txt", "This is test file 1 with some content")
    File.write!("test/fixtures/file2.txt", "This is test file 2 with different content")

    # Create contexts once
    {:ok, cctx} = ExZstdZig.cctx_init(%{compression_level: 5, strategy: :fast})
    {:ok, dctx} = ExZstdZig.dctx_init(nil)

    # Compress first file
    :ok =
      ExZstdZig.compress_file("test/fixtures/file1.txt", "test/fixtures/file1.txt.zst",
        cctx: cctx
      )

    # Reset and compress second file
    :ok = ExZstdZig.reset_compressor_session(cctx)

    :ok =
      ExZstdZig.compress_file("test/fixtures/file2.txt", "test/fixtures/file2.txt.zst",
        cctx: cctx
      )

    # Decompress first file
    :ok =
      ExZstdZig.decompress_file("test/fixtures/file1.txt.zst", "test/fixtures/file1_out.txt",
        dctx: dctx
      )

    # Reset and decompress second file
    :ok = ExZstdZig.reset_decompressor_session(dctx)

    :ok =
      ExZstdZig.decompress_file("test/fixtures/file2.txt.zst", "test/fixtures/file2_out.txt",
        dctx: dctx
      )

    # Verify contents
    assert File.read!("test/fixtures/file1.txt") == File.read!("test/fixtures/file1_out.txt")
    assert File.read!("test/fixtures/file2.txt") == File.read!("test/fixtures/file2_out.txt")
  end

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
end
