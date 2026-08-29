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
      its repository has a checkout, the derived path exists, and the consumer
      is not itself running out of a Mix `deps/` directory that contains it.
    * `github` is available when the declaration carries GitHub coordinates.
    * `hex` is available when the declaration carries a published requirement.

  Nothing available is an error naming the application, the order that was
  walked, and what each candidate in it was rejected for, because a dependency
  that resolves from nowhere cannot be built and the remedy depends on which
  candidate failed and why.

  Every decision records the candidates the walk considered alongside the rule
  that fired. A `reason` says which rule decided; the candidates say what fell
  through, which is the whole diagnostic value of an ordered walk.

  A `local` candidate is unavailable — and resolution falls through — when no
  catalogued project provides the application, when the providing repository has
  no checkout, when the derived path is missing or sits inside the consumer's
  Mix `deps/`, or when the selection excludes every provider. Two outcomes are
  errors instead: an application several catalogued projects provide with no
  `provider` to choose between them, and a `provider` naming a project that does
  not provide the application. Both say the catalog cannot answer, and answering
  from GitHub instead would answer a question nobody asked.

  ## Overrides

  An operator switching sources while working needs a gesture, not a config
  edit. Three exist, and they are tried in this order:

    1. `:sources` — one application, for this run.
    2. the operator's `.dependency_sources.local.exs` `source:` — one
       application, kept across runs.
    3. `:mode` — the whole closure, for this run.

  All three name a source outright and bypass the declared order entirely; a
  source that cannot be built from is a typed error rather than a silent
  fall-through, because an operator who named a source meant it. The override
  file also replaces the derived local path, replaces the published
  requirement, and merges GitHub coordinates, so a checkout outside the
  conventional root is reachable without touching the catalog.

  Publishing takes precedence over every other rule. A publishing command
  resolves through `publish_order`, which is `hex` alone unless a declaration
  names otherwise, so a published package never carries a local path. A
  declaration that names another source there is honoured rather than refused:
  a dependency with no Hex release and no prospect of one still has to resolve
  from somewhere while its dependent publishes, and refusing it would make
  every such package unpublishable. An *override* asking for a non-Hex source
  while publishing is a different thing and is an error: the declaration says
  what a package needs in order to be published, and an override says what one
  operator wants right now.

  The local path is derived, never configured: the checkout root of the
  repository holding the catalogued provider, joined to that project's path
  inside the repository. A declared `provider` selects among several catalogued
  providers, so the catalog holds no machine-local path and no per-repository
  override is needed to express which of two forks a consumer means.

  ## Which applications are decided

  One decision per application that something in the closure depends on **and**
  some closure project's dependency-source table declares. Both halves are
  needed: the table is what says how an application resolves, and the closure is
  what says the application is wanted here. An application no table declares
  keeps whatever its `mix.exs` call site committed to, which is what a
  dependency outside this catalog's business should do.

  A seed project's own application is not decided — it is what is being built,
  not something being sourced.

  Where several closure projects declare the same application, the target
  project's declaration wins; otherwise the declaration of the lowest project
  id wins and every declaring project is recorded in `declared_by`, so a
  disagreement is visible rather than silently resolved.
  """

  alias MixWorkspaceOps.{Git, Graph, LocalOverrides, Project, Registry}
  alias MixWorkspaceOps.Registry.Source

  @local "local"
  @github "github"
  @hex "hex"

  # The two gestures in which an operator names a source outright for a whole
  # run or for one dependency. Both override the declaration's intent, which is
  # what makes falling back to catalogued identity right for them and wrong for
  # an order walk.
  @explicit_gestures [:run_mode, :dependency_override]

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

  @type candidate :: %{source: String.t(), outcome: atom()}
  @type decision :: %{
          application: String.t(),
          source: String.t(),
          reason: atom(),
          considered: [candidate()],
          provider_project_id: String.t() | nil,
          location: term(),
          opts: keyword(),
          declared_by: [String.t()]
        }
  @type report :: %{
          target: String.t(),
          consumer_root: String.t(),
          direct_dependencies: [String.t()],
          closure: Graph.resolution(),
          decisions: [decision()],
          overrides: %{String.t() => LocalOverrides.override()},
          publish?: boolean(),
          mode: String.t() | nil
        }

  @type source_entry :: %{
          application: String.t(),
          source: String.t(),
          reason: atom(),
          considered: [candidate()],
          provider: String.t() | nil,
          location: String.t(),
          version: String.t() | nil,
          opts: keyword()
        }

  @doc "The candidate sources a declaration may name."
  @spec sources() :: [String.t()]
  def sources, do: [@local, @github, @hex]

  @doc """
  Resolves every catalogued application the target's closure depends on.

  `:closure` supplies an already-computed `MixWorkspaceOps.Graph` resolution;
  without it the closure is derived here. `:consumer_root` is the Mix project
  root of the project doing the resolving and defaults to the target's own —
  its repository checkout joined to its path inside it, which for a project at
  the repository root is the same directory. The override file is read from
  there and the Mix `deps/` test is relative to it, because both are facts about
  the directory a Mix command actually runs in, and ten of the live installs
  this replaces sit in subprojects. `:publish?` says the command about to
  run publishes, and defaults to false. `:mode` overrides the source for the
  whole closure, `:sources` overrides one application, and `:overrides` carries
  the parsed override file; without `:overrides` the file is read from
  `:consumer_root`.
  """
  @spec resolve(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def resolve(registry, target, opts \\ []) do
    target = to_string(target)

    with {:ok, closure} <- closure(registry, target, opts),
         {:ok, direct_dependencies} <- direct_dependencies(registry, target, opts),
         {:ok, consumer_root} <- consumer_root(registry, target, opts),
         {:ok, overrides} <- overrides(consumer_root, opts),
         opts =
           opts
           |> Keyword.put(:consumer_root, consumer_root)
           |> Keyword.put(:overrides, overrides),
         {:ok, decisions} <- decide_all(registry, target, closure, opts) do
      {:ok,
       %{
         target: target,
         consumer_root: consumer_root,
         direct_dependencies: direct_dependencies,
         closure: closure,
         decisions: decisions,
         overrides: overrides,
         publish?: Keyword.get(opts, :publish?, false),
         mode: Keyword.get(opts, :mode)
       }}
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
    with {:ok, {source, reason, considered}} <- select(registry, app, declaration, opts) do
      build(registry, app, declaration, source, reason, considered, opts)
    end
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

  The test is on the **consumer**: where its own root sits under a path segment
  named `deps`, it was fetched by Mix rather than cloned by an operator, and
  everything beside it under that same directory was too. A candidate there is
  another Mix-fetched dependency, not a sibling checkout. Where the consumer is
  not under such a directory, nothing is rejected on this ground — including a
  candidate that happens to sit in the consumer's own `deps/`, which is a
  different directory from the one the consumer is running out of.

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

  @doc """
  True when `consumer_root` is itself under a Mix `deps/` directory that also
  contains `absolute`.
  """
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

  @doc """
  What each dependency resolved to, in the shape an operator reads.

  `location` is where it comes from and `version` is what is there: the version
  a local checkout declares, the revision a GitHub coordinate names, or the
  requirement a Hex source carries. A local version that cannot be read is
  `nil` rather than an error — the source resolved, and a report is not the
  place to refuse over an unreadable `mix.exs`.
  """
  @spec sources(report()) :: [source_entry()]
  def sources(report), do: Enum.map(report.decisions, &source_entry/1)

  @doc """
  The `mix.exs` seam call for each of a project's managed dependencies.

  **The committed default is the tuple publish resolution would produce, options
  included.** That is what a committed default is for: a fresh clone and a
  consumer of the published package both have to resolve without this tool, from
  Hex, or from git where there is no Hex release — which is exactly what publish
  resolution decides. Writing the line by hand leaves two authorities for one
  requirement with nothing comparing them; deriving it makes them checkable
  against each other.

  `only`, `optional`, `runtime` and `targets` decide whether a dependency exists
  at the call site, so they are emitted as the call's own options. `override` is
  a resolution fact and stays with the catalog.

  A publish order that resolves to a local checkout has no committed default —
  a path cannot be published — and is refused by name.
  """
  @spec seam_lines(report()) :: {:ok, [String.t()]} | {:error, term()}
  def seam_lines(report) do
    direct = MapSet.new(report.direct_dependencies)

    report.decisions
    |> Enum.filter(fn decision ->
      MapSet.member?(direct, decision.application) and report.target in decision.declared_by
    end)
    |> Enum.reduce_while({:ok, []}, fn decision, {:ok, acc} ->
      case committed_default(decision) do
        {:ok, default} -> {:cont, {:ok, [seam_line(decision, default) | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, lines} -> {:ok, Enum.reverse(lines)}
      error -> error
    end
  end

  @doc "The seam lines as the `deps/0` an operator pastes into a `mix.exs`."
  @spec format_seam([String.t()]) :: String.t()
  def format_seam([]), do: "defp deps, do: []"

  def format_seam(lines) when is_list(lines) do
    Enum.join(["defp deps do", "  [", "    " <> Enum.join(lines, ",\n    "), "  ]", "end"], "\n")
  end

  defp seam_line(decision, default) do
    case call_site_options(decision.opts) do
      [] -> "workspace_dep(:#{decision.application}, #{default})"
      opts -> "workspace_dep(:#{decision.application}, #{default}, #{render_options(opts)})"
    end
  end

  defp committed_default(%{source: @hex, location: requirement}), do: {:ok, inspect(requirement)}

  defp committed_default(%{source: @github, location: coordinates}),
    do: {:ok, inspect(github_coordinates(coordinates))}

  defp committed_default(%{source: @local, application: app}),
    do: {:error, {:local_committed_default, app}}

  defp github_coordinates(coordinates) do
    revision =
      Enum.find_value([:branch, :ref, :tag], [], fn key ->
        case Map.get(coordinates, key) do
          nil -> nil
          value -> [{key, value}]
        end
      end)

    subdir = if coordinates.subdir, do: [subdir: coordinates.subdir], else: []
    [github: coordinates.repo] ++ revision ++ subdir
  end

  defp call_site_options(opts),
    do: Keyword.take(opts, [:hex, :only, :optional, :runtime, :targets])

  defp render_options(opts),
    do: Enum.map_join(opts, ", ", fn {key, value} -> "#{key}: #{inspect(value)}" end)

  @doc """
  A resolution error as a sentence an operator can act on.

  Returns `nil` for anything `resolve/3` does not produce, so a caller can fall
  back to its own rendering. A typed error is the right thing to carry between
  functions and the wrong thing to put on a terminal: an operator reading
  `{:no_available_source, "weld", ["hex"]}` has to know what an order is, and
  cannot see which candidates were tried or why each was refused.
  """
  @spec explain(term()) :: String.t() | nil
  def explain({:no_available_source, app, _order, considered}) do
    "nothing can supply #{app}. Tried " <>
      Enum.map_join(considered, ", ", &rejection/1) <>
      ". " <> remedy_for_considered(app, considered)
  end

  def explain({:unavailable_source, app, source, reason}) do
    "#{gesture(reason)} asked for #{source} for #{app}, and there is nothing to build it from. " <>
      source_remedy(app, source)
  end

  def explain({:unavailable_run_mode, mode, applications}) do
    "#{run_mode(mode)} cannot serve #{Enum.join(applications, ", ")}. " <>
      "Add that source to each named declaration, or override only the applications that can use it."
  end

  def explain({:unknown_source, app, source, reason}) do
    "#{gesture(reason)} asked for #{inspect(source)} for #{app}, which is not a source. " <>
      "Choose local, git, or hex."
  end

  def explain({:unpublishable_local_override, app, requested}) do
    "publish mode follows the declared publish order; " <>
      "the local override for #{app} requests :#{requested}."
  end

  def explain({:unpublishable_source_override, app, requested}) do
    "publish mode follows the declared publish order; " <>
      "--source #{app}=#{requested} requests another source."
  end

  def explain({:unpublishable_run_mode, mode}) do
    "publish mode follows the declared publish order; #{run_mode(mode)} requests another source."
  end

  def explain({:ambiguous_application, app, candidates}) do
    "#{format_candidates(candidates)} #{provider_verb(candidates)} #{app}. " <>
      "Set `#{app}: %{provider: \"PROJECT_ID\"}` in the consumer's dependency-source " <>
      "declaration, choosing one of those project ids."
  end

  def explain({:ambiguous_application, app, candidates, consumer}) do
    explain({:ambiguous_application, app, candidates}) <> " Reached from #{consumer}."
  end

  def explain({:unknown_provider, app, provider, candidates}) do
    "the declaration for #{app} names #{provider} as its provider, and #{provider} " <>
      "does not provide #{app}. #{Enum.join(candidates, ", ")} do. " <>
      "Set `#{app}: %{provider: \"PROJECT_ID\"}` to one of those project ids."
  end

  def explain({:absent_required_checkout, repository, expected}) do
    "the repository #{repository} has no checkout at #{expected}. Clone it there, " <>
      "or record where it is in a binding file."
  end

  def explain({:unknown_repository, repository}) do
    "the catalog carries no repository #{repository}."
  end

  def explain({:override_path_without_consumer_root, app}) do
    "the override for #{app} names a path and nothing said which project is resolving, " <>
      "so there is nothing to expand it against."
  end

  def explain({:local_committed_default, app}) do
    "#{app} resolves to a local checkout while publishing, so it has no committed " <>
      "default: a path cannot be published. Give it a hex requirement or GitHub " <>
      "coordinates in its publish order."
  end

  def explain(_other), do: nil

  defp rejection(%{source: source, outcome: outcome}),
    do: "#{source} (#{outcome_reason(outcome)})"

  defp outcome_reason(:no_catalogued_provider), do: "no catalogued project provides it"
  defp outcome_reason(:absent_checkout), do: "the provider's repository has no checkout"
  defp outcome_reason(:unbound_repository), do: "the provider's repository is not bound"
  defp outcome_reason(:missing_path), do: "the derived path is not there"

  defp outcome_reason(:inside_mix_deps),
    do: "it is inside the Mix deps directory this project runs out of"

  defp outcome_reason(:known_unselected), do: "every provider is outside the selection"
  defp outcome_reason(:no_github_coordinates), do: "the declaration carries no GitHub coordinates"
  defp outcome_reason(:no_hex_requirement), do: "the declaration carries no hex requirement"
  defp outcome_reason(:unknown_source), do: "the order names something that is not a source"
  defp outcome_reason(:not_reached), do: "not reached"
  defp outcome_reason(:chosen), do: "chosen"

  defp format_candidates(candidates) do
    Enum.map_join(candidates, " and ", fn
      %{project: project, repository: repository} -> "#{project} (repository #{repository})"
      project -> to_string(project)
    end)
  end

  defp provider_verb([_, _]), do: "both provide"
  defp provider_verb(_candidates), do: "provide"

  defp remedy_for_considered(app, considered) do
    outcomes = MapSet.new(considered, & &1.outcome)

    cond do
      MapSet.member?(outcomes, :no_hex_requirement) ->
        "Add a valid `hex` requirement for #{app}, or remove hex from its order."

      MapSet.member?(outcomes, :no_github_coordinates) ->
        "Add `github: %{}` for #{app} to opt into derived GitHub coordinates."

      MapSet.member?(outcomes, :known_unselected) ->
        "Choose a view that includes a provider of #{app}."

      true ->
        "Clone or bind a provider checkout, or choose another declared source."
    end
  end

  defp source_remedy(app, @github),
    do: "Add `github: %{}` for #{app}, or choose a catalogued provider."

  defp source_remedy(app, @hex), do: "Add a valid `hex` requirement for #{app}."

  defp source_remedy(_app, @local),
    do: "Clone or bind the provider repository outside Mix's deps directory."

  defp source_remedy(_app, _source), do: "Choose local, git, or hex."

  defp gesture(:run_mode), do: "--mode"
  defp gesture(:dependency_override), do: "--source"
  defp gesture(:local_override), do: "the override file"
  defp gesture(:publish), do: "the declared publish order"
  defp gesture(_order), do: "the declared order"

  # `git` is what the command line calls the source the catalog calls `github`.
  defp run_mode(@github), do: "--mode git"
  defp run_mode(mode), do: "--mode #{mode}"

  @doc "The one-screen form of `sources/1`."
  @spec format_sources([source_entry()]) :: String.t()
  def format_sources([]), do: "dependency sources: (no managed dependencies)"

  def format_sources(entries) when is_list(entries) do
    lines =
      Enum.map(entries, fn entry ->
        "  #{entry.application} -> #{entry.source} (#{entry.location}) -> " <>
          "#{entry.version || "unknown"}"
      end)

    Enum.join(["dependency sources:" | lines], "\n")
  end

  @doc "Explains one managed application in the context of a target project."
  @spec why(Registry.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def why(registry, target, application, opts \\ []) do
    application = to_string(application)
    target = to_string(target)

    with target_project <- Registry.project!(registry, target),
         {:ok, declaration} <- fetch_declaration(registry, target, application),
         {:ok, root} <- target_root(registry, target),
         {:ok, overrides} <- overrides(root, opts),
         {:ok, decision} <-
           decide(
             registry,
             application,
             declaration,
             Keyword.merge(opts,
               consumer_root: root,
               consumer_repository: target_project.repository,
               overrides: overrides
             )
           ) do
      candidates = Registry.providers(registry, application)
      rule = identity_rule(registry, target_project, application, candidates)

      {:ok,
       %{
         schema: "mix_workspace_ops.why/v1",
         target: target,
         application: application,
         source: decision.source,
         location: decision.location,
         provider: decision.provider_project_id,
         identity_rule: rule,
         considered: decision.considered,
         change: change_gesture(application, decision, rule),
         report: format_why(application, decision, rule, candidates)
       }}
    end
  end

  defp fetch_declaration(registry, target, application) do
    case Map.fetch(Registry.dependency_sources(registry, target), application) do
      {:ok, declaration} -> {:ok, declaration}
      :error -> {:error, {:unmanaged_application, application, target}}
    end
  end

  defp identity_rule(registry, target, application, candidates) do
    declaration = Map.get(Registry.dependency_sources(registry, target), application)

    cond do
      declaration && declaration.provider -> :declared_provider
      Enum.any?(candidates, &(&1.repository == target.repository)) -> :consumer_repository
      Enum.any?(candidates, & &1.current) -> :current_provider
      length(candidates) == 1 -> :only_provider
      true -> :uncatalogued
    end
  end

  defp change_gesture(application, decision, rule) do
    identity =
      if rule in [:current_provider, :only_provider],
        do: "set `#{application}: %{provider: \"PROJECT_ID\"}` in the durable declaration",
        else: "change the declaration's provider"

    source = "run `mwo use #{application} local|git|hex` for a machine-local source override"
    "To change identity, #{identity}; to change only #{decision.source}, #{source}."
  end

  defp format_why(application, decision, rule, candidates) do
    considered = Enum.map_join(decision.considered, ", ", &rejection/1)

    "#{application} -> #{decision.source} at #{format_location(decision.location)}\n" <>
      "identity: #{rule} selected #{decision.provider_project_id || "no catalogued provider"}\n" <>
      "candidates: #{format_candidates(Enum.map(candidates, &%{project: &1.id, repository: &1.repository}))}\n" <>
      "sources considered: #{considered}\n" <>
      change_gesture(application, decision, rule)
  end

  defp format_location(location) when is_binary(location), do: location
  defp format_location(location), do: inspect(location)

  defp source_entry(%{source: @local} = decision) do
    entry(decision, decision.location, declared_version(decision.location))
  end

  defp source_entry(%{source: @github, location: coordinates} = decision) do
    entry(decision, coordinates.repo, revision(coordinates))
  end

  defp source_entry(%{source: @hex} = decision) do
    entry(decision, @hex, decision.location)
  end

  defp entry(decision, location, version) do
    %{
      application: decision.application,
      source: decision.source,
      reason: decision.reason,
      considered: decision.considered,
      provider: decision.provider_project_id,
      location: location,
      version: version,
      opts: decision.opts
    }
  end

  defp declared_version(path) do
    case Project.declared_version(path) do
      {:ok, version} -> version
      {:error, _reason} -> nil
    end
  end

  defp revision(coordinates) do
    Enum.find_value([:ref, :tag, :branch], fn key ->
      case Map.get(coordinates, key) do
        nil -> nil
        value -> "#{key} #{value}"
      end
    end)
  end

  defp select(registry, app, declaration, opts) do
    override = override(opts, app)
    requested = opts |> Keyword.get(:sources, %{}) |> Map.get(app)
    mode = Keyword.get(opts, :mode)

    cond do
      Keyword.get(opts, :publish?, false) ->
        with :ok <- publishable(app, override, requested, mode) do
          from_order(registry, app, declaration, declaration.publish_order, :publish, opts)
        end

      not is_nil(requested) ->
        {:ok, {requested, :dependency_override, chosen(requested)}}

      not is_nil(override.source) ->
        {:ok, {override.source, :local_override, chosen(override.source)}}

      not is_nil(mode) ->
        {:ok, {mode, :run_mode, chosen(mode)}}

      true ->
        from_order(registry, app, declaration, declaration.order, :order, opts)
    end
  end

  # Publishing refuses an override that would resolve to a non-Hex source, and
  # names which of the three gestures asked for it. A configured
  # `publish_order` is not an override and is never refused here.
  defp publishable(app, override, requested, mode) do
    cond do
      not is_nil(override.source) and override.source != @hex ->
        {:error,
         {:unpublishable_local_override, app, override.requested_source || override.source}}

      not is_nil(requested) and requested != @hex ->
        {:error, {:unpublishable_source_override, app, requested}}

      not is_nil(mode) and mode != @hex ->
        {:error, {:unpublishable_run_mode, mode}}

      true ->
        :ok
    end
  end

  defp override(opts, app) do
    opts |> Keyword.get(:overrides, %{}) |> Map.get(app, LocalOverrides.empty())
  end

  defp overrides(consumer_root, opts) do
    case Keyword.fetch(opts, :overrides) do
      {:ok, overrides} -> {:ok, overrides}
      :error -> LocalOverrides.load(consumer_root)
    end
  end

  # An ordered walk that records only which rule fired cannot tell an operator
  # whether `hex` was first or whether `local` and `github` were tried and
  # rejected, which is the whole diagnostic value of an order. Every candidate
  # the walk looked at is recorded with what it found, and the ones after the
  # winner are recorded as never reached.
  defp from_order(registry, app, declaration, order, reason, opts) do
    case walk(order, registry, app, declaration, opts, []) do
      {:ok, source, considered} -> {:ok, {source, reason, considered}}
      {:exhausted, considered} -> {:error, {:no_available_source, app, order, considered}}
      {:error, error} -> {:error, error}
    end
  end

  defp walk([], _registry, _app, _declaration, _opts, considered),
    do: {:exhausted, Enum.reverse(considered)}

  defp walk([source | rest], registry, app, declaration, opts, considered) do
    case availability(registry, app, declaration, source, opts) do
      :available ->
        {:ok, source, Enum.reverse([candidate(source, :chosen) | considered]) ++ unreached(rest)}

      {:error, error} ->
        {:error, error}

      outcome ->
        walk(rest, registry, app, declaration, opts, [candidate(source, outcome) | considered])
    end
  end

  defp candidate(source, outcome), do: %{source: source, outcome: outcome}
  defp chosen(source), do: [candidate(source, :chosen)]
  defp unreached(sources), do: Enum.map(sources, &candidate(&1, :not_reached))

  # `:available`, an error the walk must not swallow, or the reason this
  # candidate was rejected.
  defp availability(registry, app, declaration, @local, opts) do
    case local_source(registry, app, declaration, opts) do
      {:ok, _path, _provider} -> :available
      {:error, error} -> {:error, error}
      outcome -> outcome
    end
  end

  defp availability(_registry, _app, declaration, @github, _opts),
    do: if(is_nil(declaration.github), do: :no_github_coordinates, else: :available)

  defp availability(_registry, _app, declaration, @hex, _opts),
    do: if(is_nil(declaration.hex), do: :no_hex_requirement, else: :available)

  defp availability(_registry, _app, _declaration, _source, _opts), do: :unknown_source

  defp local_source(registry, app, declaration, opts) do
    case override(opts, app).path do
      nil -> derived_local(registry, app, declaration, opts)
      candidates -> overridden_local(registry, app, declaration, candidates, opts)
    end
  end

  defp derived_local(registry, app, declaration, opts) do
    case provider(registry, app, declaration, opts) do
      {:ok, project} -> provider_path(registry, project, opts)
      outcome -> outcome
    end
  end

  defp provider_path(registry, project, opts) do
    case Registry.checkout(registry, project.repository) do
      {:bound, root} ->
        path = root |> Path.join(project.path) |> Path.expand()
        sibling(path, project.id, Keyword.get(opts, :consumer_root))

      {:absent, _expected} ->
        :absent_checkout

      :unknown ->
        :unbound_repository
    end
  end

  defp sibling(path, provider_id, consumer_root) do
    cond do
      not File.exists?(path) -> :missing_path
      under_mix_deps_dir?(consumer_root, path) -> :inside_mix_deps
      true -> {:ok, path, provider_id}
    end
  end

  # An override path is the operator saying where the checkout is, so it stands
  # in for the derived one both in the order walk and in the emitted location.
  # Several candidates may be named and the first usable one wins, which is how
  # one override file serves two machines. Every candidate is still held to the
  # sibling test: a candidate is rejected where the consumer's own checkout root
  # sits under a Mix `deps/` directory, because everything beside it there was
  # fetched by Mix rather than cloned by an operator.
  #
  # The provider is only the label this path is reported under. Where the
  # catalog cannot name one the operator has already settled the question by
  # naming the path, so the label is absent rather than the resolution refused.
  defp overridden_local(registry, app, declaration, candidates, opts) do
    case Keyword.get(opts, :consumer_root) do
      nil ->
        {:error, {:override_path_without_consumer_root, app}}

      consumer_root ->
        candidates
        |> Enum.map(&Path.expand(&1, consumer_root))
        |> Enum.find(&usable_sibling_path?(&1, consumer_root))
        |> case do
          nil -> :missing_path
          absolute -> {:ok, absolute, provider_id(registry, app, declaration, opts)}
        end
    end
  end

  defp provider_id(registry, app, declaration, opts) do
    case provider(registry, app, declaration, opts) do
      {:ok, project} -> project.id
      _unnamed -> nil
    end
  end

  # `Registry.resolve_dependency/3` distinguishes four outcomes its own
  # documentation says a caller must not conflate, and each means something
  # different here. No catalogued provider, an absent checkout and a provider
  # the selection leaves out all make `local` unavailable, so resolution falls
  # through to the next candidate. An ambiguous application and a provider
  # naming a project that does not provide it are errors: they say the catalog
  # cannot answer, and falling through to GitHub answers a question nobody
  # asked — and answers it differently from `MixWorkspaceOps.Graph`, which
  # refuses the same input.
  defp provider(registry, app, declaration, opts) do
    consumer_repository = Keyword.get(opts, :consumer_repository)

    case Registry.resolve_dependency(registry, app, declaration.provider, consumer_repository) do
      {:ok, project} -> {:ok, project}
      {:known_unselected, _project_ids} -> :known_unselected
      :unknown -> :no_catalogued_provider
      {:error, reason} -> {:error, reason}
    end
  end

  defp build(registry, app, declaration, @local, reason, considered, opts) do
    case local_source(registry, app, declaration, opts) do
      {:ok, path, provider_id} ->
        {:ok, decision(app, @local, reason, considered, provider_id, path, declaration)}

      {:error, error} ->
        {:error, error}

      _unavailable ->
        {:error, {:unavailable_source, app, @local, reason}}
    end
  end

  defp build(registry, app, declaration, @github, reason, considered, opts) do
    case github(registry, app, declaration, reason, override(opts, app), opts) do
      %{repo: repo} = coordinates when is_binary(repo) ->
        {:ok,
         decision(
           app,
           @github,
           reason,
           considered,
           provider_id(registry, app, declaration, opts),
           coordinates,
           declaration
         )}

      _incomplete ->
        {:error, {:unavailable_source, app, @github, reason}}
    end
  end

  defp build(_registry, app, declaration, @hex, reason, considered, opts) do
    case requirement(declaration, override(opts, app)) do
      nil -> {:error, {:unavailable_source, app, @hex, reason}}
      requirement -> {:ok, decision(app, @hex, reason, considered, nil, requirement, declaration)}
    end
  end

  defp build(_registry, app, _declaration, source, reason, _considered, _opts),
    do: {:error, {:unknown_source, app, source, reason}}

  defp requirement(declaration, override), do: override.hex || declaration.hex

  # The override merges into the declaration's coordinates rather than
  # replacing them, so an operator can move one branch without restating the
  # repository.
  #
  # Where the declaration carries no GitHub block at all, an explicit request
  # falls back to the catalogued provider's own repository identity, which the
  # catalog has held the whole time. An order walk does not: an order states the
  # declaration's intent, and making `github` universally available there would
  # change how a declaration that names no GitHub coordinates resolves in
  # ordinary development. An explicit gesture is the operator overriding that
  # intent, which is a different thing.
  defp github(registry, app, declaration, reason, override, opts) do
    base =
      cond do
        not is_nil(declaration.github) ->
          declared_coordinates(registry, app, declaration, reason, opts)

        reason in @explicit_gestures ->
          catalogued_coordinates(registry, app, declaration, opts)

        true ->
          nil
      end

    base
    |> merge_github(declaration.github || %{})
    |> merge_github(override)
  end

  defp declared_coordinates(registry, app, declaration, reason, opts) do
    coordinates = catalogued_coordinates(registry, app, declaration, false, opts)

    if reason in @explicit_gestures,
      do: maybe_pin(coordinates, registry, app, declaration, opts),
      else: coordinates
  end

  defp catalogued_coordinates(registry, app, declaration, opts) do
    catalogued_coordinates(registry, app, declaration, true, opts)
  end

  defp catalogued_coordinates(registry, app, declaration, pin?, opts) do
    with {:ok, project} <- provider(registry, app, declaration, opts),
         repository = Registry.repository!(registry, project.repository),
         true <- is_binary(repository.github) do
      coordinates = %{
        repo: repository.github,
        branch: repository.default_branch,
        ref: nil,
        tag: nil,
        subdir: subdirectory(project.path)
      }

      if pin?, do: pin(coordinates, registry, repository), else: coordinates
    else
      _uncatalogued -> nil
    end
  end

  defp maybe_pin(nil, _registry, _app, _declaration, _opts), do: nil

  defp maybe_pin(coordinates, registry, app, declaration, opts) do
    case provider(registry, app, declaration, opts) do
      {:ok, project} ->
        pin(coordinates, registry, Registry.repository!(registry, project.repository))

      _unavailable ->
        coordinates
    end
  end

  # An explicit `--mode git` run has to be reproducible, so the coordinate is
  # pinned to the revision the operator's checkout is at. Where there is no
  # checkout to read there is nothing to pin to, and the repository's own
  # default branch is what remains.
  defp pin(coordinates, registry, repository) do
    with {:bound, root} <- Registry.checkout(registry, repository.id),
         {:ok, revision} <- Git.head(root) do
      %{coordinates | ref: revision, branch: nil, tag: nil}
    else
      _unpinnable -> %{coordinates | branch: repository.default_branch}
    end
  end

  defp subdirectory("."), do: nil
  defp subdirectory(path), do: path

  defp merge_github(nil, override),
    do: merge_github(%{repo: nil, branch: nil, ref: nil, tag: nil, subdir: nil}, override)

  defp merge_github(base, %{github: override}), do: merge_github(base, override)

  defp merge_github(base, override) do
    Enum.reduce(override, base, fn {key, value}, acc -> merge_coordinate(acc, key, value) end)
  end

  defp merge_coordinate(coordinates, _key, nil), do: coordinates

  defp merge_coordinate(coordinates, key, value) when key in [:repo, "repo"],
    do: %{coordinates | repo: value}

  defp merge_coordinate(coordinates, key, value) when key in [:branch, "branch"],
    do: %{coordinates | branch: value, ref: nil, tag: nil}

  defp merge_coordinate(coordinates, key, value) when key in [:ref, "ref"],
    do: %{coordinates | ref: value, branch: nil, tag: nil}

  defp merge_coordinate(coordinates, key, value) when key in [:tag, "tag"],
    do: %{coordinates | tag: value, branch: nil, ref: nil}

  defp merge_coordinate(coordinates, key, value) when key in [:subdir, "subdir"],
    do: %{coordinates | subdir: value}

  defp decision(app, source, reason, considered, provider_id, location, declaration) do
    opts = options(declaration) ++ hex_package_option(app, source, declaration)

    %{
      application: app,
      source: source,
      reason: reason,
      considered: considered,
      provider_project_id: provider_id,
      location: location,
      opts: opts,
      declared_by: []
    }
  end

  defp hex_package_option(app, @hex, declaration) do
    case Map.get(declaration, :hex_package) do
      nil -> []
      ^app -> []
      package -> [hex: String.to_atom(package)]
    end
  end

  defp hex_package_option(_app, _source, _declaration), do: []

  defp option_value(key, value) when key in @list_options,
    do: Enum.map(value, &String.to_atom/1)

  defp option_value(_key, value), do: value

  defp closure(registry, target, opts) do
    case Keyword.get(opts, :closure) do
      nil -> Graph.resolve(registry, target, opts)
      closure -> {:ok, closure}
    end
  end

  defp direct_dependencies(registry, target, opts) do
    project = Registry.project!(registry, target)
    reader = Keyword.get(opts, :dependency_reader, &Project.dependencies(registry, &1, opts))
    reader.(project)
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
      {:bound, root} ->
        {:ok, root |> Path.join(project.path) |> Path.expand()}

      {:absent, expected} ->
        {:error, {:absent_required_checkout, project.repository, expected}}

      :unknown ->
        {:error, {:unknown_repository, project.repository}}
    end
  end

  defp decide_all(registry, target, closure, opts) do
    declarations = declarations(registry, target, closure)

    declarations
    |> applications(closure)
    |> Enum.map(fn app ->
      {declaration, declared_by, consumer_repository} = Map.fetch!(declarations, app)

      case decide(
             registry,
             app,
             declaration,
             Keyword.put(opts, :consumer_repository, consumer_repository)
           ) do
        {:ok, decision} -> {:ok, %{decision | declared_by: declared_by}}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> collect(Keyword.get(opts, :mode))
  end

  # A whole-closure mode is one gesture over many applications, so reporting the
  # first application it cannot serve tells an operator to fix one of them and
  # find the next. Every application that cannot serve the requested source is
  # named at once. An order walk is per dependency and still halts on the first
  # error, which is the failure of that dependency and not of a gesture.
  defp collect(results, mode) do
    case Enum.split_with(results, &match?({:ok, _decision}, &1)) do
      {decided, []} -> {:ok, Enum.map(decided, &elem(&1, 1))}
      {_decided, errors} -> {:error, refusal(Enum.map(errors, &elem(&1, 1)), mode)}
    end
  end

  defp refusal(errors, mode) when is_binary(mode) do
    unavailable =
      Enum.flat_map(errors, fn
        {:unavailable_source, app, ^mode, :run_mode} -> [app]
        _other -> []
      end)

    if length(unavailable) == length(errors),
      do: {:unavailable_run_mode, mode, Enum.sort(unavailable)},
      else: hd(errors)
  end

  defp refusal(errors, _mode), do: hd(errors)

  # An application is decided when something in the closure depends on it *and*
  # some closure project's dependency-source table declares it. The table says
  # how an application resolves; without an entry there is nothing to resolve
  # through, and inventing one produced a decision for two applications in five
  # that nothing would ever consume — and a publish order of `hex` with no
  # requirement, which can never complete.
  defp applications(declarations, closure) do
    projects = Map.new(closure.projects, &{&1.id, &1})

    depended =
      closure.edges
      |> Enum.flat_map(fn {_consumer, dependency_id} ->
        case Map.fetch(projects, dependency_id) do
          {:ok, project} -> project.provides
          :error -> []
        end
      end)

    external = Enum.map(closure.external_dependencies, &elem(&1, 1))

    (depended ++ external)
    |> Enum.filter(&Map.has_key?(declarations, &1))
    |> Enum.uniq()
    |> Enum.sort()
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
      Map.update(inner, app, {declaration, [project.id], project.repository}, fn
        {chosen, ids, consumer_repository} ->
          if replace? do
            {declaration, Enum.sort(Enum.uniq([project.id | ids])), project.repository}
          else
            {chosen, Enum.sort(Enum.uniq([project.id | ids])), consumer_repository}
          end
      end)
    end)
  end
end
