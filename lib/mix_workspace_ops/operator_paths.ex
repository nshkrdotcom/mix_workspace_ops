defmodule MixWorkspaceOps.OperatorPaths do
  @moduledoc """
  Resolves operator-owned paths in one documented order.

  An explicit flag wins, followed by the matching environment variable, then
  `${XDG_CONFIG_HOME:-~/.config}/mix_workspace_ops/config.json`, then discovery
  by walking upward from the working directory or by a conventional XDG default
  where the path is inherently operator-owned. The configuration document may
  carry `registry`, `checkout_root`, `ledger`, and `source_preferences`; all
  paths are expanded when read.
  """

  alias MixWorkspaceOps.{Git, OperatorLedger, SourcePreferences, StrictJSON}

  @fields %{
    registry: {"MIX_WORKSPACE_OPS_REGISTRY", "registry"},
    checkout_root: {"MIX_WORKSPACE_OPS_CHECKOUT_ROOT", "checkout_root"},
    ledger: {"MIX_WORKSPACE_OPS_LEDGER", "ledger"},
    source_preferences: {nil, "source_preferences"}
  }

  @spec resolve(map(), [atom()]) :: {:ok, map()} | {:error, term()}
  def resolve(options, fields) do
    with {:ok, config} <- config() do
      resolve_fields(fields, options, config)
    end
  end

  defp resolve_fields(fields, options, config) do
    fields
    |> Enum.filter(&Map.has_key?(@fields, &1))
    |> Enum.reduce_while({:ok, options}, &resolve_field(&1, &2, config))
  end

  defp resolve_field(field, {:ok, options}, config) do
    case value(field, options, config) do
      {:ok, path} -> {:cont, {:ok, Map.put(options, field, path)}}
      :missing -> {:cont, {:ok, options}}
    end
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

      is_binary(environment) and present?(System.get_env(environment)) ->
        {:ok, Path.expand(System.fetch_env!(environment))}

      present?(Map.get(config, config_key)) ->
        {:ok, expand_config(Map.fetch!(config, config_key), Map.fetch!(config, "__directory__"))}

      true ->
        discover(field)
    end
  end

  defp config do
    path = config_path()

    if File.regular?(path) do
      with {:ok, bytes} <- read_config(path),
           {:ok, decoded} <- decode_config(path, bytes),
           :ok <- validate_config(path, decoded) do
        {:ok, Map.put(decoded, "__directory__", Path.dirname(path))}
      end
    else
      {:ok, %{}}
    end
  end

  defp read_config(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, reason} -> {:error, {:operator_config, path, {:read, reason}}}
    end
  end

  defp decode_config(path, bytes) do
    case StrictJSON.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:operator_config, path, {:invalid_json, reason}}}
    end
  end

  defp validate_config(path, decoded) when is_map(decoded) do
    unknown = Map.keys(decoded) -- ~w(registry checkout_root ledger source_preferences)
    invalid = Enum.reject(decoded, fn {_key, value} -> is_binary(value) and value != "" end)

    cond do
      unknown != [] -> {:error, {:operator_config, path, {:unknown_keys, Enum.sort(unknown)}}}
      invalid != [] -> {:error, {:operator_config, path, :paths_must_be_non_empty_strings}}
      true -> :ok
    end
  end

  defp validate_config(path, _decoded),
    do: {:error, {:operator_config, path, :expected_object}}

  defp expand_config(path, directory) do
    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: directory |> Path.join(path) |> Path.expand()
  end

  defp discover(:registry), do: walk_up(File.cwd!(), "registry.json")

  defp discover(:checkout_root) do
    case Git.root(File.cwd!()) do
      {:ok, root} -> {:ok, Path.dirname(root)}
      {:error, _reason} -> :missing
    end
  end

  defp discover(:ledger) do
    path = OperatorLedger.default_path()
    if File.regular?(path), do: {:ok, path}, else: :missing
  end

  defp discover(:source_preferences), do: {:ok, SourcePreferences.default_path()}

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
