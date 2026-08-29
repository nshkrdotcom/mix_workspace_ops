defmodule MixWorkspaceOps.Bootstrap do
  @moduledoc "Materializes the Mix-load bootstrap in operator-owned state."

  @environment_variable "MIX_WORKSPACE_OPS_BOOTSTRAP"
  @template Path.expand("../../priv/bootstrap/mix_workspace_ops_bootstrap.exs", __DIR__)
  @external_resource @template
  @contents File.read!(@template)

  @doc "Returns the variable containing the explicit operator bootstrap path."
  @spec environment_variable() :: String.t()
  def environment_variable, do: @environment_variable

  @spec contents() :: binary()
  def contents, do: @contents

  @doc "Writes or reuses the exact bootstrap beneath operator-owned state."
  @spec materialize(String.t()) :: {:ok, String.t()} | {:error, term()}
  def materialize(state_root) do
    path =
      state_root
      |> Path.expand()
      |> Path.join("bootstrap")
      |> Path.join(digest(contents()) <> ".exs")

    case File.read(path) do
      {:ok, bytes} when bytes == @contents ->
        with :ok <- File.chmod(path, 0o400), do: {:ok, path}

      {:ok, _bytes} ->
        {:error, {:bootstrap_digest_collision, path}}

      {:error, :enoent} ->
        write(path, contents())

      {:error, reason} ->
        {:error, {:bootstrap_read, path, reason}}
    end
  end

  defp write(path, bytes) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(temporary, bytes, [:sync]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path),
         :ok <- File.chmod(path, 0o400) do
      {:ok, path}
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
