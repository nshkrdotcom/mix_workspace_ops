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
         {:ok, lock} <- acquire_lock(directory),
         {:ok, io} <- open_receipt(path, [:write, :exclusive, :binary], lock) do
      {:ok, %{io: io, lock: lock, path: path, directory: directory, events: []}}
    end
  end

  defp do_open(state_root, transaction_id, :resume) do
    releases = state_root |> Path.expand() |> Path.join("releases")
    directory = Path.join(releases, transaction_id)
    path = Path.join(directory, "events.jsonl")

    with true <- File.dir?(directory) || {:error, {:unknown_transaction, directory}},
         {:ok, lock} <- acquire_lock(directory),
         {:ok, events, io} <- open_existing_receipt(path, lock) do
      {:ok, %{io: io, lock: lock, path: path, directory: directory, events: events}}
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

  defp acquire_lock(directory) do
    case Enum.find(["/usr/bin/flock", "/bin/flock"], &File.regular?/1) do
      nil ->
        {:error, :receipt_lock_unavailable}

      executable ->
        path = Path.join(directory, ".receipt.lock")

        environment = "/usr/bin/env"

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(environment)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              :use_stdio,
              args:
                Enum.map(
                  [
                    "-i",
                    "LC_ALL=C",
                    executable,
                    "--exclusive",
                    "--nonblock",
                    path,
                    "/bin/sh",
                    "-c",
                    "printf ready; IFS= read -r _"
                  ],
                  &String.to_charlist/1
                )
            ]
          )

        await_lock(port, "")
    end
  end

  defp await_lock(port, output) do
    receive do
      {^port, {:data, bytes}} ->
        output = output <> bytes

        if String.contains?(output, "ready") do
          {:ok, port}
        else
          await_lock(port, output)
        end

      {^port, {:exit_status, 1}} ->
        {:error, :receipt_locked}

      {^port, {:exit_status, status}} ->
        {:error, {:receipt_lock_failed, status, String.trim(output)}}
    after
      2_000 ->
        close_lock(port)
        {:error, :receipt_lock_timeout}
    end
  end

  defp open_receipt(path, modes, lock) do
    case File.open(path, modes) do
      {:ok, io} ->
        {:ok, io}

      {:error, reason} ->
        close_lock(lock)
        {:error, reason}
    end
  end

  defp open_existing_receipt(path, lock) do
    case read(path) do
      {:ok, events} ->
        case open_receipt(path, [:append, :binary], lock) do
          {:ok, io} -> {:ok, events, io}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        close_lock(lock)
        {:error, reason}
    end
  end

  defp close_lock(port) do
    Port.command(port, "\n")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      2_000 -> Port.close(port)
    end
  rescue
    ArgumentError -> :ok
  end

  @spec append(map(), map()) :: :ok | {:error, term()}
  def append(receipt, event) do
    bytes = Report.encode(event) <> "\n"

    with :ok <- IO.binwrite(receipt.io, bytes) do
      :file.sync(receipt.io)
    end
  end

  @spec close(map()) :: :ok
  def close(receipt) do
    result = File.close(receipt.io)
    close_lock(receipt.lock)
    result
  end

  @doc "Reads every complete JSONL event or refuses the receipt as malformed."
  @spec read(String.t()) :: {:ok, [map()]} | {:error, term()}
  def read(path) do
    with {:ok, bytes} <- File.read(path),
         :ok <- complete_receipt(bytes) do
      decode_events(bytes)
    end
  end

  defp complete_receipt(""), do: :ok

  defp complete_receipt(bytes) do
    if String.ends_with?(bytes, "\n"), do: :ok, else: {:error, :truncated_receipt}
  end

  defp decode_events(bytes) do
    bytes
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, &decode_event/2)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp decode_event({line, number}, {:ok, acc}) do
    case StrictJSON.decode(line, maximum_bytes: 4 * 1024 * 1024) do
      {:ok, event} when is_map(event) -> {:cont, {:ok, [event | acc]}}
      {:ok, _other} -> {:halt, {:error, {:invalid_receipt_event, number}}}
      {:error, reason} -> {:halt, {:error, {:invalid_receipt_event, number, reason}}}
    end
  end

  defp validate_transaction_id(transaction_id) when is_binary(transaction_id) do
    if Regex.match?(@transaction_id, transaction_id),
      do: :ok,
      else: {:error, :invalid_transaction_id}
  end

  defp validate_transaction_id(_transaction_id), do: {:error, :invalid_transaction_id}
end
