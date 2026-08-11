defmodule MixWorkspaceOps.Report do
  @moduledoc "Stable JSON reports for operator and packet evidence."

  @spec encode(term()) :: String.t()
  def encode(value) do
    value
    |> normalize()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @spec write(String.t(), term()) :: :ok | {:error, term()}
  def write(path, value) do
    path = Path.expand(path)
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, encode(value) <> "\n", [:sync]) do
      File.rename(temporary, path)
    end
  end

  defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> normalize()
  defp normalize(nil), do: :null
  defp normalize(value) when value in [true, false, :null], do: value
  defp normalize(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp normalize(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
