defmodule MixWorkspaceOps.Release.Receipt do
  @moduledoc "Durable append-only transition receipts for release transactions."

  alias MixWorkspaceOps.{Report, StrictJSON}

  @transaction_id ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/

  @spec open(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(state_root, transaction_id), do: open(state_root, transaction_id, :new)

  @spec open(String.t(), String.t(), :new | :resume) :: {:ok, map()} | {:error, term()}
  def open(state_root, transaction_id, mode) when mode in [:new, :resume] do
    with :ok <- validate_transaction_id(transaction_id) do
      do_open(state_root, transaction_id, mode)
    end
  end

  defp do_open(state_root, transaction_id, :new) do
    releases = state_root |> Path.expand() |> Path.join("releases")
    directory = Path.join(releases, transaction_id)
    path = Path.join(directory, "events.jsonl")

    with :ok <- File.mkdir_p(releases),
         :ok <- create_transaction_directory(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      {:ok, %{io: io, path: path, directory: directory, events: []}}
    end
  end

  defp do_open(state_root, transaction_id, :resume) do
    releases = state_root |> Path.expand() |> Path.join("releases")
    directory = Path.join(releases, transaction_id)
    path = Path.join(directory, "events.jsonl")

    with true <- File.dir?(directory) || {:error, {:unknown_transaction, directory}},
         {:ok, events} <- read(path),
         {:ok, io} <- File.open(path, [:append, :binary]) do
      {:ok, %{io: io, path: path, directory: directory, events: events}}
    else
      false -> {:error, {:unknown_transaction, directory}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_transaction_directory(directory) do
    case File.mkdir(directory) do
      :ok -> :ok
      {:error, :eexist} -> {:error, {:transaction_exists, directory}}
      {:error, reason} -> {:error, {:transaction_directory, directory, reason}}
    end
  end

  @spec append(map(), map()) :: :ok | {:error, term()}
  def append(receipt, event) do
    bytes = Report.encode(event) <> "\n"

    with :ok <- IO.binwrite(receipt.io, bytes) do
      :file.sync(receipt.io)
    end
  end

  @spec close(map()) :: :ok
  def close(receipt), do: File.close(receipt.io)

  @doc "Reads every complete JSONL event or refuses the receipt as malformed."
  @spec read(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read(path) do
    with {:ok, bytes} <- File.read(path) do
      bytes
      |> String.split("\n", trim: true)
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, acc} ->
        case StrictJSON.decode(line, maximum_bytes: 4 * 1024 * 1024) do
          {:ok, event} when is_map(event) -> {:cont, {:ok, [event | acc]}}
          {:ok, _other} -> {:halt, {:error, {:invalid_receipt_event, number}}}
          {:error, reason} -> {:halt, {:error, {:invalid_receipt_event, number, reason}}}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
        error -> error
      end
    end
  end

  defp validate_transaction_id(transaction_id) when is_binary(transaction_id) do
    if Regex.match?(@transaction_id, transaction_id),
      do: :ok,
      else: {:error, :invalid_transaction_id}
  end

  defp validate_transaction_id(_transaction_id), do: {:error, :invalid_transaction_id}
end
