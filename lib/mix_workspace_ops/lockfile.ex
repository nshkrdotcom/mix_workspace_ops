defmodule MixWorkspaceOps.Lockfile do
  @moduledoc """
  Safe literal handling for a private operational `mix.lock`.

  The module deliberately knows nothing about Hex or Git package objects. It
  accepts only literal map/tuple/list/primitive syntax, can project top-level
  entries for dependencies replaced by local paths, and can digest validated
  lock bytes for audit and runtime identity.
  """

  @maximum_bytes 16 * 1024 * 1024

  @spec parse_map(binary()) :: {:ok, map()} | {:error, term()}
  def parse_map(bytes) when is_binary(bytes) and byte_size(bytes) <= @maximum_bytes do
    with {:ok, quoted} <- Code.string_to_quoted(bytes, file: "mix.lock"),
         {:ok, lock} <- literal(quoted),
         true <- is_map(lock) || {:error, {:lock_literal, :root_not_map}} do
      {:ok, lock}
    else
      {:error, {line, error, token}} ->
        {:error, {:lock_syntax, line_number(line), error, token}}

      {:error, _reason} = error ->
        error
    end
  end

  def parse_map(bytes) when is_binary(bytes), do: {:error, {:lock_too_large, byte_size(bytes)}}
  def parse_map(value), do: {:error, {:lock_bytes, value}}

  @doc "Projects a source lock by omitting only top-level path-backed applications."
  @spec project_path_apps(binary(), [String.t() | atom()]) :: {:ok, binary()} | {:error, term()}
  def project_path_apps(bytes, applications) when is_binary(bytes) and is_list(applications) do
    dropped = applications |> Enum.map(&to_string/1) |> MapSet.new()

    if MapSet.size(dropped) == 0 do
      with {:ok, _lock} <- parse_map(bytes), do: {:ok, bytes}
    else
      with {:ok, lock} <- parse_map(bytes) do
        projected =
          Map.reject(lock, fn {application, _entry} ->
            MapSet.member?(dropped, to_string(application))
          end)

        {:ok, render(projected)}
      end
    end
  end

  def project_path_apps(bytes, applications),
    do: {:error, {:lock_projection, bytes, applications}}

  @doc "Returns a SHA-256 digest after validating that the bytes are a literal lock map."
  @spec digest(binary()) :: {:ok, String.t()} | {:error, term()}
  def digest(bytes) when is_binary(bytes) do
    with {:ok, _lock} <- parse_map(bytes) do
      {:ok, bytes |> :crypto.hash(:sha256) |> Base.encode16(case: :lower)}
    end
  end

  def digest(value), do: {:error, {:lock_bytes, value}}

  defp render(lock) do
    inspect(lock,
      pretty: true,
      limit: :infinity,
      printable_limit: :infinity,
      width: 98
    ) <> "\n"
  end

  defp line_number(metadata) when is_list(metadata), do: Keyword.get(metadata, :line)
  defp line_number(line) when is_integer(line), do: line
  defp line_number(_metadata), do: nil

  defp literal(value)
       when is_atom(value) or is_binary(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp literal(values) when is_list(values), do: literal_list(values, [])

  defp literal({:%{}, _meta, entries}) when is_list(entries) do
    with {:ok, pairs} <- literal_list(entries, []), do: {:ok, Map.new(pairs)}
  end

  defp literal({:{}, _meta, entries}) when is_list(entries) do
    with {:ok, values} <- literal_list(entries, []), do: {:ok, List.to_tuple(values)}
  end

  defp literal({left, right}) do
    with {:ok, left} <- literal(left),
         {:ok, right} <- literal(right) do
      {:ok, {left, right}}
    end
  end

  defp literal(other), do: {:error, {:lock_literal, Macro.to_string(other)}}

  defp literal_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp literal_list([value | rest], acc) do
    case literal(value) do
      {:ok, decoded} -> literal_list(rest, [decoded | acc])
      {:error, _reason} = error -> error
    end
  end
end
