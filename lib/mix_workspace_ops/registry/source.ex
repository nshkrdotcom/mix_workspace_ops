defmodule MixWorkspaceOps.Registry.Source do
  @moduledoc """
  Per-dependency source declarations: candidate sources, resolution order, and
  the Mix options carried into the emitted dependency tuple.

  A declaration names the sources a dependency can resolve from and the order in
  which they are tried. The common case declares no order at all and inherits
  `local -> github -> hex`. A publish command uses `publish_order`, which
  defaults to `hex` alone but may name another source for a dependency that has
  no published release and never will.

  `local` carries no path. It is derived from the catalog identity of the project
  that provides the application, joined to the operator's checkout of that
  project's repository, so no machine-local path is ever recorded.
  """

  @sources ~w(local github hex)
  @default_order ~w(local github hex)
  @default_publish_order ~w(hex)
  @github_optional ~w(repo branch ref tag subdir)
  @github_revisions ~w(branch ref tag)
  @boolean_options ~w(override runtime optional)
  @list_options ~w(only targets)

  # `only` and `targets` name Mix environments and Mix targets. JSON has no
  # atoms, so the emitter converts their values back to atoms, and an atom is
  # never collected. The bound is what stops catalog content from minting an
  # unbounded number of them: at most eight values, each at most 32 bytes, on
  # top of the identifier grammar every value already has to satisfy. Eight
  # covers Mix's three standard environments and a handful of custom ones with
  # room to spare, and 32 bytes is longer than any environment or target name
  # anyone writes; both sit well above real use and well below the point where
  # a hostile document could exhaust the atom table.
  @maximum_option_values 8
  @maximum_option_value_bytes 32

  @type github :: %{
          repo: String.t() | nil,
          branch: String.t() | nil,
          ref: String.t() | nil,
          tag: String.t() | nil,
          subdir: String.t() | nil
        }
  @type t :: %{
          github: github() | nil,
          hex: String.t() | nil,
          hex_package: String.t() | nil,
          provider: String.t() | nil,
          order: [String.t()],
          publish_order: [String.t()],
          opts: %{String.t() => term()}
        }

  @spec sources() :: [String.t()]
  def sources, do: @sources

  @spec default_order() :: [String.t()]
  def default_order, do: @default_order

  @spec default_publish_order() :: [String.t()]
  def default_publish_order, do: @default_publish_order

  @doc "The most values an option naming environments or targets may carry."
  @spec maximum_option_values() :: pos_integer()
  def maximum_option_values, do: @maximum_option_values

  @doc "The most bytes one such value may carry."
  @spec maximum_option_value_bytes() :: pos_integer()
  def maximum_option_value_bytes, do: @maximum_option_value_bytes

  @doc """
  True when `value` is a lowercase Elixir identifier.

  This is the grammar every application name, environment name and target name
  in the catalog satisfies, and it is what keeps the conversion to atoms to a
  countable set of names rather than to arbitrary bytes. Every reader that
  converts one of those names has to apply it, or one reader accepts what
  another refuses.
  """
  @spec identifier?(term()) :: boolean()
  def identifier?(value) when is_binary(value),
    do: Regex.match?(~r/^[a-z][a-z0-9_]*$/, value)

  def identifier?(_value), do: false

  @doc """
  Parses a map of application name to source declaration.

  Returns the declarations keyed by application name, or the first error.
  """
  @spec parse_table(term(), String.t()) :: {:ok, %{String.t() => t()}} | {:error, term()}
  def parse_table(raw, scope) when is_map(raw) do
    raw
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {app, declaration}, {:ok, acc} ->
      with :ok <- validate_application_name(app, scope),
           {:ok, parsed} <- parse(declaration, scope, app) do
        {:cont, {:ok, Map.put(acc, app, parsed)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def parse_table(raw, scope), do: {:error, {:invalid_dependency_sources, scope, raw}}

  @doc "Parses one source declaration for `app` within `scope`."
  @spec parse(term(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def parse(raw, scope, app) when is_map(raw) do
    where = {scope, app}

    with :ok <- reject_unknown_keys(raw, where),
         {:ok, github} <- parse_github(Map.get(raw, "github"), where),
         {:ok, {hex, hex_package}} <- parse_hex(Map.get(raw, "hex"), where),
         {:ok, provider} <- parse_provider(Map.get(raw, "provider"), where),
         {:ok, order} <- parse_order(Map.get(raw, "order"), @default_order, where, :order),
         {:ok, publish_order} <-
           parse_order(
             Map.get(raw, "publish_order"),
             @default_publish_order,
             where,
             :publish_order
           ),
         {:ok, opts} <- parse_opts(Map.get(raw, "opts"), where),
         declaration = %{
           github: github,
           hex: hex,
           hex_package: hex_package,
           provider: provider,
           order: order,
           publish_order: publish_order,
           opts: opts
         },
         :ok <- validate_order(declaration, raw, "order", order, where, :order),
         :ok <-
           validate_order(declaration, raw, "publish_order", publish_order, where, :publish_order) do
      {:ok, declaration}
    end
  end

  def parse(raw, scope, app), do: {:error, {:invalid_dependency_source, {scope, app}, raw}}

  @doc "True when the declaration can reach `source` in ordinary resolution."
  @spec reaches?(t(), String.t()) :: boolean()
  def reaches?(declaration, source), do: source in declaration.order

  @doc "True when the declaration can reach `source` while publishing."
  @spec reaches_while_publishing?(t(), String.t()) :: boolean()
  def reaches_while_publishing?(declaration, source), do: source in declaration.publish_order

  defp reject_unknown_keys(raw, where) do
    case Map.keys(raw) -- ~w(github hex provider order publish_order opts) do
      [] -> :ok
      unknown -> {:error, {:unknown_dependency_source_keys, where, Enum.sort(unknown)}}
    end
  end

  defp parse_github(nil, _where), do: {:ok, nil}
  defp parse_github(true, _where), do: {:ok, empty_github()}

  defp parse_github(raw, where) when is_map(raw) do
    with :ok <- github_keys(raw, where),
         :ok <- github_repo(Map.get(raw, "repo"), where),
         :ok <- github_strings(raw, where),
         :ok <- github_single_revision(raw, where) do
      {:ok,
       %{
         repo: optional(raw, "repo"),
         branch: optional(raw, "branch"),
         ref: optional(raw, "ref"),
         tag: optional(raw, "tag"),
         subdir: optional(raw, "subdir")
       }}
    end
  end

  defp parse_github(raw, where), do: {:error, {:invalid_github_source, where, raw}}

  defp github_keys(raw, where) do
    keys = Map.keys(raw)
    unknown = keys -- @github_optional

    if unknown == [],
      do: :ok,
      else: {:error, {:unknown_github_source_keys, where, Enum.sort(unknown)}}
  end

  defp github_repo(repo, where) when is_binary(repo) do
    if Regex.match?(~r{^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$}, repo),
      do: :ok,
      else: {:error, {:invalid_github_identity, where, repo}}
  end

  defp github_repo(nil, _where), do: :ok
  defp github_repo(repo, where), do: {:error, {:invalid_github_identity, where, repo}}

  defp github_strings(raw, where) do
    invalid =
      for key <- @github_optional,
          value = Map.get(raw, key),
          not is_nil(value),
          not (is_binary(value) and value != ""),
          do: key

    if invalid == [], do: :ok, else: {:error, {:invalid_github_source, where, Enum.sort(invalid)}}
  end

  defp github_single_revision(raw, where) do
    case Enum.filter(@github_revisions, &(not is_nil(Map.get(raw, &1)))) do
      [] -> :ok
      [_one] -> :ok
      several -> {:error, {:conflicting_github_revision, where, Enum.sort(several)}}
    end
  end

  defp parse_hex(nil, _where), do: {:ok, {nil, nil}}

  defp parse_hex(requirement, where) when is_binary(requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, _parsed} -> {:ok, {requirement, nil}}
      :error -> {:error, {:invalid_hex_requirement, where, requirement}}
    end
  end

  defp parse_hex(%{"requirement" => requirement, "package" => package} = raw, where)
       when map_size(raw) == 2 do
    with true <- identifier?(package) || {:error, {:invalid_hex_package, where, package}},
         {:ok, {parsed, nil}} <- parse_hex(requirement, where) do
      {:ok, {parsed, package}}
    end
  end

  defp parse_hex(requirement, where), do: {:error, {:invalid_hex_requirement, where, requirement}}

  defp parse_provider(nil, _where), do: {:ok, nil}
  defp parse_provider(provider, _where) when is_binary(provider), do: {:ok, provider}
  defp parse_provider(provider, where), do: {:error, {:invalid_provider, where, provider}}

  defp parse_order(nil, default, _where, _field), do: {:ok, default}

  defp parse_order(order, _default, where, field) when is_list(order) do
    cond do
      order == [] -> {:error, {:empty_source_order, where, field}}
      Enum.any?(order, &(&1 not in @sources)) -> {:error, {:unknown_source, where, field, order}}
      order != Enum.uniq(order) -> {:error, {:duplicate_source, where, field, order}}
      true -> {:ok, order}
    end
  end

  defp parse_order(order, _default, where, field),
    do: {:error, {:invalid_source_order, where, field, order}}

  defp parse_opts(nil, _where), do: {:ok, %{}}

  defp parse_opts(raw, where) when is_map(raw) do
    raw
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case parse_option(key, value, where) do
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, key, parsed)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_opts(raw, where), do: {:error, {:invalid_dependency_options, where, raw}}

  defp parse_option(key, value, _where) when key in @boolean_options and is_boolean(value),
    do: {:ok, value}

  defp parse_option(key, value, where) when key in @list_options do
    cond do
      not (is_list(value) and value != [] and Enum.all?(value, &identifier?/1)) ->
        {:error, {:invalid_dependency_option, where, key, value}}

      length(value) > @maximum_option_values ->
        {:error, {:dependency_option_too_long, where, key, @maximum_option_values}}

      Enum.any?(value, &(byte_size(&1) > @maximum_option_value_bytes)) ->
        {:error, {:dependency_option_value_too_long, where, key, @maximum_option_value_bytes}}

      true ->
        {:ok, value}
    end
  end

  defp parse_option(key, value, where) when key in @boolean_options,
    do: {:error, {:invalid_dependency_option, where, key, value}}

  defp parse_option(key, _value, where), do: {:error, {:unknown_dependency_option, where, key}}

  # An explicit order states intent, so every source it names must be declared.
  # The inherited default states no intent, so it simply falls through a source
  # the declaration does not carry, exactly as the copied helper did. Ordinary
  # resolution always runs, so an inherited order that can reach nothing is an
  # error; publishing is a separate act, and an unpublishable dependency surfaces
  # there rather than here.
  defp validate_order(declaration, raw, key, order, where, field) do
    cond do
      Map.has_key?(raw, key) -> declared(declaration, order, where, field)
      field == :order -> reachable(declaration, order, where, field)
      true -> :ok
    end
  end

  defp declared(declaration, order, where, field) do
    case Enum.filter(order, &undeclared?(declaration, &1)) do
      [] -> :ok
      missing -> {:error, {:undeclared_source, where, field, Enum.sort(missing)}}
    end
  end

  defp reachable(declaration, order, where, field) do
    if Enum.any?(order, &(not undeclared?(declaration, &1))),
      do: :ok,
      else: {:error, {:unreachable_source_order, where, field}}
  end

  defp undeclared?(declaration, "github"), do: is_nil(declaration.github)
  defp undeclared?(declaration, "hex"), do: is_nil(declaration.hex)
  defp undeclared?(_declaration, "local"), do: false

  defp validate_application_name(app, scope) when is_binary(app) do
    if identifier?(app), do: :ok, else: {:error, {:invalid_application, scope, app}}
  end

  defp validate_application_name(app, scope), do: {:error, {:invalid_application, scope, app}}

  defp optional(raw, key) do
    case Map.get(raw, key) do
      nil -> nil
      value -> value
    end
  end

  defp empty_github,
    do: %{repo: nil, branch: nil, ref: nil, tag: nil, subdir: nil}
end
