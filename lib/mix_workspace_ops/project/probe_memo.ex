defmodule MixWorkspaceOps.Project.ProbeMemo do
  @moduledoc """
  Invocation memo backed optionally by immutable, exact-key disk entries.

  The ETS table coalesces duplicate questions in one VM. A configured root
  carries answers between invocations; malformed entries are quarantined and
  treated as misses. Values are never searched by project name or timestamp:
  the caller supplies the complete semantic input key.
  """

  alias Mix.Sync.Lock, as: SyncLock

  @schema "mix_workspace_ops.probe_metadata/v4"
  @enforce_keys [:table]
  defstruct [:table, :root]

  @type t :: %__MODULE__{table: :ets.tid(), root: String.t() | nil}

  @spec new(String.t() | nil) :: t()
  def new(root \\ nil) do
    %__MODULE__{
      table:
        :ets.new(__MODULE__, [
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ]),
      root: if(is_binary(root), do: Path.expand(root), else: nil)
    }
  end

  @spec fetch(t(), term(), (-> value)) :: value when value: term()
  def fetch(%__MODULE__{table: table} = memo, key, miss) when is_function(miss, 0) do
    case :ets.lookup(table, {:value, key}) do
      [{{:value, ^key}, value}] ->
        count(table, :memory_hits)
        value

      [] ->
        SyncLock.with_lock(lock_key(memo, key), fn -> locked_fetch(memo, key, miss) end)
    end
  end

  @doc false
  @spec put_snapshot(t(), term(), term()) :: :ok
  def put_snapshot(%__MODULE__{table: table}, key, value) do
    true = :ets.insert(table, {{:snapshot, key}, value})
    :ok
  end

  @doc false
  @spec snapshot(t(), term()) :: {:hit, term()} | :miss
  def snapshot(%__MODULE__{table: table}, key) do
    case :ets.lookup(table, {:snapshot, key}) do
      [{{:snapshot, ^key}, value}] -> {:hit, value}
      [] -> :miss
    end
  end

  @doc "Returns hit/miss counters for acceptance and concise reports."
  @spec stats(t()) :: map()
  def stats(%__MODULE__{table: table}) do
    for(name <- [:memory_hits, :disk_hits, :misses], into: %{}, do: {name, counter(table, name)})
  end

  defp locked_fetch(%__MODULE__{table: table} = memo, key, miss) do
    case :ets.lookup(table, {:value, key}) do
      [{{:value, ^key}, value}] ->
        count(table, :memory_hits)
        value

      [] ->
        read_or_compute(memo, key, miss)
    end
  end

  defp read_or_compute(%__MODULE__{table: table} = memo, key, miss) do
    case read(memo, key) do
      {:ok, value} ->
        :ets.insert(table, {{:value, key}, value})
        count(table, :disk_hits)
        value

      :miss ->
        value = miss.()
        if persistable?(value), do: :ok = write(memo, key, value)
        :ets.insert(table, {{:value, key}, value})
        count(table, :misses)
        value
    end
  end

  defp read(%__MODULE__{root: nil}, _key), do: :miss

  defp read(%__MODULE__{} = memo, key) do
    path = path(memo, key)

    with {:ok, bytes} <- File.read(path),
         %{schema: @schema, key: stored_key, value: value} <-
           :erlang.binary_to_term(bytes, [:safe]),
         true <- stored_key == key do
      {:ok, value}
    else
      {:error, :enoent} -> :miss
      _invalid -> quarantine(path)
    end
  rescue
    _invalid -> quarantine(path(memo, key))
  end

  defp write(%__MODULE__{root: nil}, _key, _value), do: :ok

  defp write(%__MODULE__{} = memo, key, value) do
    path = path(memo, key)
    temporary = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"
    bytes = :erlang.term_to_binary(%{schema: @schema, key: key, value: value}, [:deterministic])

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(memo.root, 0o700),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(temporary, bytes, [:sync]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        raise File.Error, reason: reason, action: "write probe metadata", path: path
    end
  end

  defp quarantine(path) do
    if File.exists?(path) do
      suffix = "#{System.system_time(:millisecond)}.#{System.unique_integer([:positive])}"
      _ = File.rename(path, path <> ".corrupt." <> suffix)
    end

    :miss
  end

  defp persistable?({:ok, value}) when is_map(value), do: true
  defp persistable?(_other), do: false

  defp path(%__MODULE__{root: root}, key) do
    digest = digest(key)
    Path.join([root, String.slice(digest, 0, 2), digest <> ".term"])
  end

  defp lock_key(%__MODULE__{root: nil, table: table}, key),
    do: "mix_workspace_ops:probe:memory:#{inspect(table)}:" <> digest(key)

  defp lock_key(%__MODULE__{root: root}, key),
    do: "mix_workspace_ops:probe:" <> root <> ":" <> digest(key)

  defp digest(key) do
    key
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp count(table, name),
    do: :ets.update_counter(table, {:counter, name}, {2, 1}, {{:counter, name}, 0})

  defp counter(table, name) do
    case :ets.lookup(table, {:counter, name}) do
      [{{:counter, ^name}, value}] -> value
      [] -> 0
    end
  end
end
