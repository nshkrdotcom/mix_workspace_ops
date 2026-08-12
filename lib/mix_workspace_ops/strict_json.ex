defmodule MixWorkspaceOps.StrictJSON do
  @moduledoc "JSON decoding that rejects duplicate object keys at every nesting level."

  @default_maximum_bytes 16 * 1024 * 1024

  @spec decode(binary(), keyword()) :: {:ok, term()} | {:error, term()}
  def decode(bytes, opts \\ []) when is_binary(bytes) do
    maximum_bytes = Keyword.get(opts, :maximum_bytes, @default_maximum_bytes)

    if byte_size(bytes) > maximum_bytes do
      {:error, {:json_too_large, byte_size(bytes), maximum_bytes}}
    else
      decode_bounded(bytes)
    end
  end

  defp decode_bounded(bytes) do
    push = fn key, value, entries ->
      if List.keymember?(entries, key, 0), do: throw({:duplicate_json_key, key})
      [{key, value} | entries]
    end

    case :json.decode(bytes, :ok, %{object_push: push}) do
      {decoded, :ok, ""} -> {:ok, decoded}
      {_decoded, :ok, trailing} -> {:error, {:trailing_json, trailing}}
    end
  rescue
    error -> {:error, {:json, error.__struct__, Exception.message(error)}}
  catch
    :throw, {:duplicate_json_key, key} -> {:error, {:duplicate_json_key, key}}
    kind, reason -> {:error, {:json, kind, reason}}
  end
end
