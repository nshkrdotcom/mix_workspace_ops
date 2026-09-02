defmodule MixWorkspaceOps.Toolchain do
  @moduledoc false

  alias MixWorkspaceOps.Command

  @cache_key {__MODULE__, :elixir_executable}

  @doc false
  @spec executable(String.t()) :: String.t()
  def executable(name) when name in ["elixir", "iex", "mix"] do
    candidate = Path.join(Path.dirname(elixir_executable()), name)
    if File.regular?(candidate), do: candidate, else: System.find_executable(name) || name
  end

  defp elixir_executable do
    case :persistent_term.get(@cache_key, nil) do
      nil -> cache_elixir_executable()
      path -> path
    end
  end

  defp cache_elixir_executable do
    candidate =
      :elixir
      |> :code.lib_dir()
      |> Path.join("../../bin/elixir")
      |> Path.expand()

    path = if File.regular?(candidate), do: candidate, else: version_manager_elixir()
    :persistent_term.put(@cache_key, path)
    path
  end

  defp version_manager_elixir do
    with {:ok, result} <- Command.run("asdf", ["which", "elixir"], cd: System.tmp_dir!()),
         path = String.trim(result.output),
         true <- Path.type(path) == :absolute and File.regular?(path) do
      path
    else
      _unavailable -> System.find_executable("elixir") || "elixir"
    end
  end
end
