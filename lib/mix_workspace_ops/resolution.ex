defmodule MixWorkspaceOps.Resolution do
  @moduledoc """
  Decides the source every catalogued application in a target's closure
  resolves from.

  Resolution walks an ordered list of candidate sources and takes the first one
  that is *available*. The default order is `local -> github -> hex` and needs
  no configuration; a declaration names a different order only where a
  dependency genuinely differs. An unavailable candidate falls through, so the
  same catalog resolves local on a machine holding the sibling checkout and
  GitHub on one that does not, with no edit anywhere.

  Availability is a property of the declaration and of the operator's disk:

    * `local` is available when a catalogued project provides the application,
      its repository has a checkout, the derived path exists, and that path is
      not inside a Mix `deps/` directory the consumer is itself running out of.
    * `github` is available when the declaration carries GitHub coordinates.
    * `hex` is available when the declaration carries a published requirement.

  Nothing available is an error naming the application and the order that was
  walked, because a dependency that resolves from nowhere cannot be built.

  The local path is derived, never configured: the checkout root of the
  repository holding the catalogued provider, joined to that project's path
  inside the repository. A declared `provider` selects among several catalogued
  providers, so the catalog holds no machine-local path and no per-repository
  override is needed to express which of two forks a consumer means.

  ## Which applications are decided

  One decision per application anything in the closure depends on: every
  application provided by a project another closure project depends on, plus
  every application outside the catalog that a closure project's
  dependency-source table declares. The second set is what carries a
  third-party GitHub dependency that will never have a Hex release. A seed
  project's own application is not decided — it is what is being built, not
  something being sourced.

  Where several closure projects declare the same application, the target
  project's declaration wins; otherwise the declaration of the lowest project
  id wins and every declaring project is recorded in `declared_by`, so a
  disagreement is visible rather than silently resolved.
  """

  alias MixWorkspaceOps.{Graph, Registry}
  alias MixWorkspaceOps.Registry.Source

  @local "local"
  @github "github"
  @hex "hex"

  # The Mix option keys the catalog carries, converted through a fixed table so
  # no catalog content can name an option key that does not already exist.
  @option_keys %{
    "only" => :only,
    "optional" => :optional,
    "override" => :override,
    "runtime" => :runtime,
    "targets" => :targets
  }
  @list_options ~w(only targets)

  @type decision :: %{
          application: String.t(),
          source: String.t(),
          reason: atom(),
          provider_project_id: String.t() | nil,
          location: term(),
          opts: keyword(),
          declared_by: [String.t()]
        }
  @type report :: %{
          target: String.t(),
          consumer_root: String.t(),
          closure: Graph.resolution(),
          decisions: [decision()]
        }

  @doc "The candidate sources a declaration may name."
  @spec sources() :: [String.t()]
  def sources, do: [@local, @github, @hex]

  @doc """
  Resolves every catalogued application the target's closure depends on.

  `:closure` supplies an already-computed `MixWorkspaceOps.Graph` resolution;
  without it the closure is derived here. `:consumer_root` is the checkout root
  of the project doing the resolving and defaults to the target's own checkout;
  the Mix `deps/` test is relative to it.
  """
  @spec resolve(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def resolve(registry, target, opts \\ []) do
    target = to_string(target)

    with {:ok, closure} <- closure(registry, target, opts),
         {:ok, consumer_root} <- consumer_root(registry, target, opts),
         opts = Keyword.put(opts, :consumer_root, consumer_root),
         {:ok, decisions} <- decide_all(registry, target, closure, opts) do
      {:ok,
       %{target: target, consumer_root: consumer_root, closure: closure, decisions: decisions}}
    end
  end

  @doc """
  Decides one application against one declaration.

  This is the whole of the resolution rule; `resolve/3` is it applied to a
  closure.
  """
  @spec decide(Registry.t(), String.t(), Source.t(), keyword()) ::
          {:ok, decision()} | {:error, term()}
  def decide(registry, app, declaration, opts \\ []) do
    with {:ok, {source, reason}} <- select(registry, app, declaration, opts) do
      build(registry, app, declaration, source, reason, opts)
    end
  end

  @doc "The declaration an application inherits when nothing declares it."
  @spec default_declaration() :: Source.t()
  def default_declaration do
    %{
      github: nil,
      hex: nil,
      provider: nil,
      order: Source.default_order(),
      publish_order: Source.default_publish_order(),
      opts: %{}
    }
  end

  @doc """
  The Mix options a declaration carries, as a keyword list.

  Keys convert through a fixed table. `only` and `targets` name environments
  and targets, which are atoms in Mix and strings in JSON, so their values are
  converted back — under the count and length bound `MixWorkspaceOps.Registry.Source`
  holds them to, which is what keeps catalog content from minting unbounded atoms.
  """
  @spec options(Source.t()) :: keyword()
  def options(declaration) do
    declaration.opts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {key, value} ->
      case Map.fetch(@option_keys, key) do
        {:ok, option} -> [{option, option_value(key, value)}]
        :error -> []
      end
    end)
  end

  @doc """
  True when a derived local path is a developer checkout.

  A path that exists but resolves inside the Mix `deps/` directory the consumer
  is running out of is another Mix-fetched dependency, not a sibling checkout.
  Without this test, `mix deps.get` from a fresh clone materializes siblings
  under `deps/`, resolution running as `<parent>/deps/<child>` mistakes one for
  a developer checkout, picks `local`, and Mix refuses with "overriding a child
  dependency".
  """
  @spec usable_sibling_path?(String.t(), String.t() | nil) :: boolean()
  def usable_sibling_path?(path, consumer_root) do
    absolute = Path.expand(path)
    File.exists?(absolute) and not under_mix_deps_dir?(consumer_root, absolute)
  end

  @doc "True when `absolute` sits under the Mix `deps/` directory `consumer_root` runs out of."
  @spec under_mix_deps_dir?(String.t() | nil, String.t()) :: boolean()
  def under_mix_deps_dir?(nil, _absolute), do: false

  def under_mix_deps_dir?(consumer_root, absolute) do
    case mix_deps_ancestor(consumer_root) do
      nil -> false
      deps_dir -> String.starts_with?(absolute <> "/", deps_dir <> "/")
    end
  end

  @doc """
  The Mix `deps/` directory a checkout root is itself inside, or `nil`.

  When `consumer_root` sits under a path segment named `deps`, that segment is
  the parent project's dependency directory.
  """
  @spec mix_deps_ancestor(String.t()) :: String.t() | nil
  def mix_deps_ancestor(consumer_root) do
    segments = consumer_root |> Path.expand() |> Path.split()

    case segments |> Enum.reverse() |> Enum.find_index(&(&1 == "deps")) do
      nil -> nil
      index -> segments |> Enum.take(length(segments) - index) |> Path.join()
    end
  end

  defp select(registry, app, declaration, opts) do
    from_order(registry, app, declaration, declaration.order, :order, opts)
  end

  defp from_order(registry, app, declaration, order, reason, opts) do
    case Enum.find(order, &available?(registry, app, declaration, &1, opts)) do
      nil -> {:error, {:no_available_source, app, order}}
      source -> {:ok, {source, reason}}
    end
  end

  defp available?(registry, app, declaration, @local, opts),
    do: match?({:ok, _path, _provider}, local_source(registry, app, declaration, opts))

  defp available?(_registry, _app, declaration, @github, _opts),
    do: not is_nil(declaration.github)

  defp available?(_registry, _app, declaration, @hex, _opts), do: not is_nil(declaration.hex)
  defp available?(_registry, _app, _declaration, _source, _opts), do: false

  defp local_source(registry, app, declaration, opts) do
    with {:ok, project} <- provider(registry, app, declaration),
         {:bound, root} <- Registry.checkout(registry, project.repository),
         path = root |> Path.join(project.path) |> Path.expand(),
         true <- usable_sibling_path?(path, Keyword.get(opts, :consumer_root)) do
      {:ok, path, project.id}
    else
      _unavailable -> :unavailable
    end
  end

  defp provider(registry, app, declaration) do
    case Registry.resolve_dependency(registry, app, declaration.provider) do
      {:ok, project} -> {:ok, project}
      _other -> :unavailable
    end
  end

  defp build(registry, app, declaration, @local, reason, opts) do
    case local_source(registry, app, declaration, opts) do
      {:ok, path, provider_id} ->
        {:ok, decision(app, @local, reason, provider_id, path, declaration)}

      :unavailable ->
        {:error, {:unavailable_source, app, @local, reason}}
    end
  end

  defp build(_registry, app, %{github: nil}, @github, reason, _opts),
    do: {:error, {:unavailable_source, app, @github, reason}}

  defp build(_registry, app, declaration, @github, reason, _opts),
    do: {:ok, decision(app, @github, reason, nil, declaration.github, declaration)}

  defp build(_registry, app, %{hex: nil}, @hex, reason, _opts),
    do: {:error, {:unavailable_source, app, @hex, reason}}

  defp build(_registry, app, declaration, @hex, reason, _opts),
    do: {:ok, decision(app, @hex, reason, nil, declaration.hex, declaration)}

  defp decision(app, source, reason, provider_id, location, declaration) do
    %{
      application: app,
      source: source,
      reason: reason,
      provider_project_id: provider_id,
      location: location,
      opts: options(declaration),
      declared_by: []
    }
  end

  defp option_value(key, value) when key in @list_options,
    do: Enum.map(value, &String.to_atom/1)

  defp option_value(_key, value), do: value

  defp closure(registry, target, opts) do
    case Keyword.get(opts, :closure) do
      nil -> Graph.resolve(registry, target, opts)
      closure -> {:ok, closure}
    end
  end

  defp consumer_root(registry, target, opts) do
    case Keyword.get(opts, :consumer_root) do
      nil -> target_root(registry, target)
      root -> {:ok, Path.expand(root)}
    end
  end

  defp target_root(registry, target) do
    project = Registry.project!(registry, target)

    case Registry.checkout(registry, project.repository) do
      {:bound, root} -> {:ok, root}
      {:absent, expected} -> {:error, {:absent_required_checkout, project.repository, expected}}
      :unknown -> {:error, {:unknown_repository, project.repository}}
    end
  end

  defp decide_all(registry, target, closure, opts) do
    declarations = declarations(registry, target, closure)

    registry
    |> applications(closure, declarations)
    |> Enum.reduce_while({:ok, []}, fn app, {:ok, acc} ->
      {declaration, declared_by} = Map.get(declarations, app, {default_declaration(), []})

      case decide(registry, app, declaration, opts) do
        {:ok, decision} -> {:cont, {:ok, [%{decision | declared_by: declared_by} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decisions} -> {:ok, Enum.reverse(decisions)}
      error -> error
    end
  end

  # An application is decided when something in the closure depends on it: a
  # catalogued project another project depends on, or an application outside
  # the catalog that a closure project declares a source for. A seed is not
  # decided unless a sibling depends on it.
  defp applications(_registry, closure, declarations) do
    projects = Map.new(closure.projects, &{&1.id, &1})

    depended =
      closure.edges
      |> Enum.flat_map(fn {_consumer, dependency_id} ->
        case Map.fetch(projects, dependency_id) do
          {:ok, project} -> project.provides
          :error -> []
        end
      end)

    declared =
      closure.external_dependencies
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&Map.has_key?(declarations, &1))

    (depended ++ declared) |> Enum.uniq() |> Enum.sort()
  end

  defp declarations(registry, target, closure) do
    base =
      closure.projects
      |> Enum.reject(&(&1.id == target))
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce(%{}, &collect_declarations(registry, &1, &2, false))

    case Map.fetch(registry.projects, target) do
      {:ok, project} -> collect_declarations(registry, project, base, true)
      :error -> base
    end
  end

  defp collect_declarations(registry, project, acc, replace?) do
    registry
    |> Registry.dependency_sources(project)
    |> Enum.reduce(acc, fn {app, declaration}, inner ->
      Map.update(inner, app, {declaration, [project.id]}, fn {chosen, ids} ->
        {if(replace?, do: declaration, else: chosen), Enum.sort(Enum.uniq([project.id | ids]))}
      end)
    end)
  end
end
