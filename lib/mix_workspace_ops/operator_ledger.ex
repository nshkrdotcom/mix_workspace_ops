defmodule MixWorkspaceOps.OperatorLedger do
  @moduledoc """
  Strict operator-local bindings and checkout-ignore observations.

  The ledger deliberately carries machine paths and exact local remote URLs. It is never
  catalog data and never belongs in an application repository.
  """

  alias MixWorkspaceOps.{Registry, StrictJSON}

  @schema "mix_workspace_ops.operator_ledger/v1"
  @top_keys ~w(schema bindings ignores)
  @binding_keys ~w(repository path remotes)
  @ignore_keys ~w(path remotes reason)

  @enforce_keys [:path, :digest, :bindings, :ignores]
  defstruct @enforce_keys

  @type binding :: %{repository: String.t(), path: String.t(), remotes: [String.t()]}
  @type ignore :: %{path: String.t(), remotes: [String.t()], reason: String.t()}
  @type t :: %__MODULE__{
          path: String.t() | nil,
          digest: String.t() | nil,
          bindings: %{String.t() => binding()},
          ignores: %{String.t() => ignore()}
        }

  @doc "Conventional operator-owned ledger path."
  @spec default_path() :: String.t()
  def default_path do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([base, "mix_workspace_ops", "operator_ledger.json"])
  end

  @doc "An empty ledger for commands that were not given operator-local evidence."
  @spec empty() :: t()
  def empty, do: %__MODULE__{path: nil, digest: nil, bindings: %{}, ignores: %{}}

  @doc "Loads and validates one exact ledger against a portable registry."
  @spec load(String.t() | nil, Registry.t()) :: {:ok, t()} | {:error, term()}
  def load(nil, %Registry{}), do: {:ok, empty()}

  def load(path, %Registry{} = registry) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- StrictJSON.decode(bytes, maximum_bytes: 8 * 1024 * 1024),
         {:ok, bindings, ignores} <- parse(decoded, registry) do
      {:ok,
       %__MODULE__{
         path: path,
         digest: sha256(bytes),
         bindings: bindings,
         ignores: ignores
       }}
    else
      {:error, reason} -> {:error, {:operator_ledger, path, reason}}
    end
  end

  @doc "Legacy binding-map shape or the binding paths in a versioned ledger."
  @spec binding_overrides(t()) :: %{String.t() => binding()}
  def binding_overrides(%__MODULE__{bindings: bindings}), do: bindings

  defp parse(decoded, registry) when is_map(decoded) do
    with :ok <- exact_keys(decoded, @top_keys, :ledger),
         true <-
           decoded["schema"] == @schema || {:error, {:unsupported_schema, decoded["schema"]}},
         {:ok, bindings} <- parse_bindings(decoded["bindings"], registry),
         {:ok, ignores} <- parse_ignores(decoded["ignores"]),
         :ok <- disjoint_paths(bindings, ignores) do
      {:ok, bindings, ignores}
    end
  end

  defp parse(_decoded, _registry), do: {:error, :expected_object}

  defp parse_bindings(rows, registry) when is_list(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {row, index}, {:ok, acc, paths} ->
      with {:ok, binding} <- parse_binding(row, index, registry),
           :ok <-
             absent_key(
               acc,
               binding.repository,
               {:duplicate_binding_repository, binding.repository}
             ),
           :ok <-
             absent_member(paths, binding.path, {:duplicate_binding_path, binding.path}) do
        {:cont, {:ok, Map.put(acc, binding.repository, binding), MapSet.put(paths, binding.path)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, bindings, _paths} -> {:ok, bindings}
      error -> error
    end
  end

  defp parse_bindings(_rows, _registry), do: {:error, :bindings_must_be_a_list}

  defp parse_binding(row, index, registry) when is_map(row) do
    with :ok <- exact_keys(row, @binding_keys, {:binding, index}),
         {:ok, repository} <- non_empty(row["repository"], {:binding_repository, index}),
         true <-
           Map.has_key?(registry.repositories, repository) ||
             {:error, {:unknown_binding_repository, repository}},
         {:ok, path} <- absolute_path(row["path"], {:binding_path, index}),
         {:ok, remotes} <- remotes(row["remotes"], {:binding_remotes, index}) do
      {:ok, %{repository: repository, path: path, remotes: remotes}}
    end
  end

  defp parse_binding(_row, index, _registry), do: {:error, {:binding_must_be_object, index}}

  defp parse_ignores(rows) when is_list(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn {row, index}, {:ok, acc, signatures} ->
      with {:ok, ignore} <- parse_ignore(row, index),
           :ok <- absent_key(acc, ignore.path, {:duplicate_ignore_path, ignore.path}),
           signature = ignore.remotes,
           :ok <-
             absent_member(signatures, signature, {:duplicate_ignore_identity, signature}) do
        {:cont, {:ok, Map.put(acc, ignore.path, ignore), MapSet.put(signatures, signature)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ignores, _signatures} -> {:ok, ignores}
      error -> error
    end
  end

  defp parse_ignores(_rows), do: {:error, :ignores_must_be_a_list}

  defp parse_ignore(row, index) when is_map(row) do
    with :ok <- exact_keys(row, @ignore_keys, {:ignore, index}),
         {:ok, path} <- absolute_path(row["path"], {:ignore_path, index}),
         {:ok, remotes} <- remotes(row["remotes"], {:ignore_remotes, index}),
         {:ok, reason} <- non_empty(row["reason"], {:ignore_reason, index}) do
      {:ok, %{path: path, remotes: remotes, reason: reason}}
    end
  end

  defp parse_ignore(_row, index), do: {:error, {:ignore_must_be_object, index}}

  defp exact_keys(map, expected, subject) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(expected)

    if actual == expected,
      do: :ok,
      else: {:error, {:invalid_keys, subject, expected, actual}}
  end

  defp non_empty(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty(_value, field), do: {:error, {field, :must_be_non_empty_string}}

  defp absolute_path(value, field) when is_binary(value) and value != "" do
    if Path.type(value) == :absolute,
      do: {:ok, Path.expand(value)},
      else: {:error, {field, :must_be_absolute}}
  end

  defp absolute_path(_value, field), do: {:error, {field, :must_be_absolute}}

  defp remotes(values, field) when is_list(values) and values != [] do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) and Enum.uniq(values) == values do
      {:ok, Enum.sort(values)}
    else
      {:error, {field, :must_be_unique_non_empty_strings}}
    end
  end

  defp remotes(_values, field), do: {:error, {field, :must_be_unique_non_empty_strings}}

  defp disjoint_paths(bindings, ignores) do
    binding_paths = bindings |> Map.values() |> MapSet.new(& &1.path)
    overlap = ignores |> Map.keys() |> Enum.filter(&MapSet.member?(binding_paths, &1))

    if overlap == [], do: :ok, else: {:error, {:binding_ignore_path_overlap, Enum.sort(overlap)}}
  end

  defp absent_key(map, key, reason) do
    if Map.has_key?(map, key), do: {:error, reason}, else: :ok
  end

  defp absent_member(set, value, reason) do
    if MapSet.member?(set, value), do: {:error, reason}, else: :ok
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
