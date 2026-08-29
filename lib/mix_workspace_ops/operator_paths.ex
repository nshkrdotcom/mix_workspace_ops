defmodule MixWorkspaceOps.OperatorPaths do
  @moduledoc """
  Resolves operator-owned paths in one documented order.

  An explicit flag wins, followed by the matching environment variable, then
  `${XDG_CONFIG_HOME:-~/.config}/mix_workspace_ops/config.json`, then discovery
  by walking upward from the working directory. The configuration document may
  carry `registry` and `checkout_root`; both paths are expanded when read.
  """

  alias MixWorkspaceOps.{Git, StrictJSON}

  @fields %{
    registry: {"MIX_WORKSPACE_OPS_REGISTRY", "registry"},
    checkout_root: {"MIX_WORKSPACE_OPS_CHECKOUT_ROOT", "checkout_root"}
  }

  @spec resolve(map(), [atom()]) :: {:ok, map()} | {:error, term()}
  def resolve(options, fields) do
    config = config()

    fields
    |> Enum.filter(&Map.has_key?(@fields, &1))
    |> Enum.reduce_while({:ok, options}, fn field, {:ok, acc} ->
      case value(field, acc, config) do
        {:ok, path} -> {:cont, {:ok, Map.put(acc, field, path)}}
        :missing -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec config_path() :: String.t()
  def config_path do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([base, "mix_workspace_ops", "config.json"])
  end

  defp value(field, options, config) do
    {environment, config_key} = Map.fetch!(@fields, field)

    cond do
      present?(Map.get(options, field)) ->
        {:ok, Path.expand(Map.fetch!(options, field))}

      present?(System.get_env(environment)) ->
        {:ok, Path.expand(System.fetch_env!(environment))}

      present?(Map.get(config, config_key)) ->
        {:ok, expand_config(Map.fetch!(config, config_key))}

      true ->
        discover(field)
    end
  end

  defp config do
    path = config_path()

    with true <- File.regular?(path),
         {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- StrictJSON.decode(bytes),
         true <- valid_config?(decoded) do
      Map.put(decoded, "__directory__", Path.dirname(path))
    else
      false -> %{}
      {:error, reason} -> %{"__error__" => {:operator_config, path, reason}}
    end
  end

  defp valid_config?(decoded) do
    is_map(decoded) and Map.keys(decoded) -- ~w(registry checkout_root) == [] and
      Enum.all?(decoded, fn {_key, value} -> is_binary(value) and value != "" end)
  end

  defp expand_config(path) do
    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: config() |> Map.fetch!("__directory__") |> Path.join(path) |> Path.expand()
  end

  defp discover(:registry), do: walk_up(File.cwd!(), "registry.json")

  defp discover(:checkout_root) do
    case Git.root(File.cwd!()) do
      {:ok, root} -> {:ok, Path.dirname(root)}
      {:error, _reason} -> :missing
    end
  end

  defp walk_up(directory, name) do
    candidate = Path.join(directory, name)
    parent = Path.dirname(directory)

    cond do
      File.regular?(candidate) -> {:ok, candidate}
      parent == directory -> :missing
      true -> walk_up(parent, name)
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
