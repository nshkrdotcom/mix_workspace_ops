defmodule MixWorkspaceOps.Release.Receipt do
  @moduledoc "Durable append-only transition receipts for release transactions."

  alias MixWorkspaceOps.Report

  @spec open(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def open(state_root, transaction_id) do
    releases = state_root |> Path.expand() |> Path.join("releases")
    directory = Path.join(releases, transaction_id)
    path = Path.join(directory, "events.jsonl")

    with :ok <- File.mkdir_p(releases),
         :ok <- create_transaction_directory(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      {:ok, %{io: io, path: path, directory: directory}}
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
end
