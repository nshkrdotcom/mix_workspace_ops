defmodule MixWorkspaceOps.Bootstrap do
  @moduledoc "Installation and drift checks for the minimal project-side source bootstrap."

  @relative_path "build_support/mix_workspace_ops_bootstrap.exs"

  @spec relative_path() :: String.t()
  def relative_path, do: @relative_path

  @spec contents() :: binary()
  def contents do
    :mix_workspace_ops
    |> :code.priv_dir()
    |> to_string()
    |> Path.join("bootstrap/mix_workspace_ops_bootstrap.exs")
    |> File.read!()
  end

  @spec status(String.t()) :: :missing | :current | {:drifted, String.t()}
  def status(project_root) do
    path = Path.join(project_root, @relative_path)

    case File.read(path) do
      {:ok, bytes} -> if(bytes == contents(), do: :current, else: {:drifted, digest(bytes)})
      {:error, :enoent} -> :missing
      {:error, reason} -> {:drifted, inspect(reason)}
    end
  end

  @spec install(String.t()) :: {:ok, String.t()} | {:error, term()}
  def install(project_root) do
    path = Path.join(project_root, @relative_path)

    case status(project_root) do
      :current -> {:ok, path}
      :missing -> write(path, contents())
      {:drifted, digest} -> {:error, {:bootstrap_drift, path, digest}}
    end
  end

  defp write(path, bytes) do
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temporary, bytes, [:sync]),
         :ok <- File.rename(temporary, path) do
      {:ok, path}
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
