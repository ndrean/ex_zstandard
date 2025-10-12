defmodule Example do
  use GenServer

  def start(map \\ %{}) when is_map(map) do
    GenServer.start(__MODULE__, map, name: __MODULE__)
  end

  def stop() do
    GenServer.stop(__MODULE__)
  end

  def compress(data, level) do
    GenServer.call(__MODULE__, {:compress, data, level})
  end

  def decompress(data) do
    GenServer.call(__MODULE__, {:decompress, data})
  end

  def compress_with_ctx(data) do
    GenServer.call(__MODULE__, {:compress_with_ctx, data})
  end

  def stream_file_compress(data) do
    GenServer.call(__MODULE__, {:stream_compress, data})
  end

  def stream_download_compress(url, path) do
    GenServer.call(__MODULE__, {:stream_download_compress, url, path})
  end

  def stream_download_decompress(url, path) do
    GenServer.call(__MODULE__, {:stream_download_decompress, url, path})
  end

  def decompress_with_ctx(data) do
    GenServer.call(__MODULE__, {:decompress_with_ctx, data})
  end

  def stream_file_decompress(data) do
    GenServer.call(__MODULE__, {:stream_decompress, data})
  end

  def decompress_unfold(data) do
    GenServer.call(__MODULE__, {:decompress_unfold, data})
  end

  def init(map) do
    strategy = Map.get(map, :strategy, :fast)
    max_window = Map.get(map, :max_window, nil)

    with {:ok, cctx} <- ExZstandard.cctx_init(%{strategy: strategy}),
         {:ok, dctx} <- ExZstandard.dctx_init(max_window) do
      {:ok, %{cctx: cctx, dctx: dctx, strategy: strategy}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  def handle_call({:stream_download_compress, url, path}, _, state) do
    :ok = ExZstandard.stream_download_compress(state.cctx, url, path)
    {:reply, :ok, state}
  end

  def handle_call({:stream_download_decompress, url, path}, _, state) do
    :ok = ExZstandard.stream_download_decompress(state.dctx, url, path)
    {:reply, :ok, state}
  end

  def handle_call({:compress, data, level}, _, state) do
    case ExZstandard.compress(data, level) do
      {:ok, compressed} ->
        {:reply, {:ok, compressed}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decompress, data}, _, state) do
    case ExZstandard.decompress(data) do
      {:ok, decompressed} ->
        {:reply, {:ok, decompressed}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decompress_unfold, data}, _from, state) do
    result = ExZstandard.decompress_unfold(data, dctx: state.dctx)
    {:reply, result, state}
  end

  def handle_call({:compress_with_ctx, data}, _from, state) do
    case ExZstandard.compress_with_ctx(state.cctx, data) do
      {:ok, compressed} ->
        {:reply, compressed, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:decompress_with_ctx, data}, _, state) do
    case ExZstandard.decompress_with_ctx(state.dctx, data) do
      {:ok, decompressed} ->
        {:reply, decompressed, state}

      {:error, reason} ->
        IO.puts("Error: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end
end
