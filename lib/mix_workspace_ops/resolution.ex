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

  ## Operator and command source choices

  An operator switching sources while working needs a gesture, not a repository
  edit. Command-local choices take precedence over persistent operator state:

    1. `:sources` — one application, for this run.
    2. `:mode` — the whole closure, for this run.
    3. XDG `SourcePreferences` — one consumer/application choice, kept across
       runs.

  All three name an eligible declared source outright and bypass the automatic
  order; a
  source that cannot be built from is a typed error rather than a silent
  fall-through, because an operator who named a source meant it. Preferences
  never carry arbitrary checkout paths, Hex requirements, or Git coordinates.
  Those facts remain owned by verified bindings and the portable registry.

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

  alias MixWorkspaceOps.{Graph, MixInputs, OperatorPaths, Project, Registry, SourcePreferences}
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

  @type candidate :: %{source: String.t(), outcome: atom()}
  @type decision :: %{
          application: String.t(),
          classification: :managed | :known_unselected | :external,
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
          preferences: %{String.t() => String.t()},
          publish?: boolean(),
          mode: String.t() | nil,
          mix_env: String.t(),
          mix_target: String.t()
        }

  @type source_entry :: %{
          application: String.t(),
          classification: :managed | :known_unselected | :external,
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
  root of the project doing the resolving and defaults to the target's own; the
  Mix `deps/` sibling test is relative to it. `:publish?` says the command about
  to run publishes, and defaults to false. `:mode` overrides the source for the
  whole closure, `:sources` overrides one application, and `:preferences`
  supplies an already-loaded project preference map. Without `:preferences`,
  the project's XDG SourcePreferences are loaded from `:source_preferences` or
  their conventional default path.
  """
  @spec resolve(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def resolve(registry, target, opts \\ []) do
    target = to_string(target)

    with {:ok, inputs} <- MixInputs.normalize(opts),
         opts = MixInputs.put(opts, inputs),
         {:ok, closure} <- closure(registry, target, opts),
         :ok <- same_inputs(closure, inputs),
         :ok <- one_identity_per_application(closure),
         {:ok, direct_dependencies} <- direct_dependencies(registry, target, opts),
         {:ok, consumer_root} <- consumer_root(registry, target, opts),
         {:ok, preferences} <- preferences(target, opts),
         opts =
           opts
           |> Keyword.put(:consumer_root, consumer_root)
           |> Keyword.put(:preferences, preferences),
         {:ok, decisions} <- decide_all(registry, target, closure, opts) do
      {:ok,
       %{
         target: target,
         consumer_root: consumer_root,
         direct_dependencies: direct_dependencies,
         closure: closure,
         decisions: decisions,
         preferences: preferences,
         publish?: Keyword.get(opts, :publish?, false),
         mode: Keyword.get(opts, :mode),
         mix_env: inputs.mix_env,
         mix_target: inputs.mix_target
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
    with {:ok, opts} <- normalize_decide_preferences(opts),
         {:ok, {source, reason, considered}} <- select(registry, app, declaration, opts) do
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
        {:ok, committed} -> {:cont, {:ok, [seam_line(committed) | acc]}}
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

  defp seam_line(committed), do: "workspace_dep(#{committed})"

  defp committed_default(%{source: @hex} = decision) do
    tuple =
      case call_site_options(decision.opts) do
        [] ->
          "{:#{decision.application}, #{inspect(decision.location)}}"

        opts ->
          "{:#{decision.application}, #{inspect(decision.location)}, #{render_options(opts)}}"
      end

    {:ok, tuple}
  end

  defp committed_default(%{source: @github} = decision) do
    options = github_coordinates(decision.location) ++ call_site_options(decision.opts)
    {:ok, "{:#{decision.application}, #{inspect(options)}}"}
  end

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
    {origin, detail} = source_failure_reason(reason)

    "#{gesture(origin)} asked for #{source} for #{app}, and it is unavailable" <>
      availability_detail(detail) <> ". " <> source_remedy(app, source)
  end

  def explain({:ineligible_source, app, source, reason}) do
    "#{gesture(reason)} asked for #{source} for #{app}, but that source is not an eligible " <>
      "candidate in the registry declaration. Change the declaration or choose an eligible source."
  end

  def explain({:unavailable_run_mode, mode, applications}) do
    "#{run_mode(mode)} cannot serve #{Enum.join(applications, ", ")}. " <>
      "Add that source to each named declaration, or override only the applications that can use it."
  end

  def explain({:unknown_source, app, source, reason}) do
    "#{gesture(reason)} asked for #{inspect(source)} for #{app}, which is not a source. " <>
      "Choose local, git, or hex."
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

  def explain({:local_committed_default, app}) do
    "#{app} resolves to a local checkout while publishing, so it has no committed " <>
      "default: a path cannot be published. Give it a hex requirement or GitHub " <>
      "coordinates in its publish order."
  end

  def explain({:known_unselected_local, app, providers}) do
    "local source was requested for #{app}, but its catalog identity " <>
      "(#{Enum.join(providers, ", ")}) is outside this selection. " <>
      "Choose a view that includes that provider and compute a new plan."
  end

  def explain({:conflicting_dependency_identities, app, uses}) do
    rendered =
      Enum.map_join(uses, ", ", fn use ->
        provider = use.provider || "external"
        "#{use.consumer}=#{provider} (#{use.classification})"
      end)

    "dependency #{app} has conflicting catalog identities in one graph: #{rendered}. " <>
      "One Mix application can have only one source; align the provider declarations."
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
  defp gesture(:source_preference), do: "the persisted source preference"
  defp gesture(:publish), do: "the declared publish order"
  defp gesture(_order), do: "the declared order"

  defp source_failure_reason({origin, detail}) when is_atom(origin), do: {origin, detail}
  defp source_failure_reason(origin), do: {origin, nil}

  defp availability_detail(nil), do: ""
  defp availability_detail(detail), do: " (#{outcome_reason(detail)})"

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
         {:ok, preferences} <- preferences(target, opts),
         {:ok, decision} <-
           decide(
             registry,
             application,
             declaration,
             Keyword.merge(opts,
               consumer_root: root,
               consumer_repository: target_project.repository,
               preferences: preferences
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
         operator_preference: Map.get(preferences, application),
         command_source: opts |> Keyword.get(:sources, %{}) |> Map.get(application),
         command_mode: Keyword.get(opts, :mode),
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
      classification: decision.classification,
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
    requested = opts |> Keyword.get(:sources, %{}) |> Map.get(app)
    mode = Keyword.get(opts, :mode)
    preferred = preference(opts, app)

    cond do
      Keyword.get(opts, :publish?, false) ->
        with :ok <- publishable(app, requested, mode) do
          from_order(registry, app, declaration, declaration.publish_order, :publish, opts)
        end

      not is_nil(requested) ->
        explicit(registry, app, declaration, requested, :dependency_override, opts)

      not is_nil(mode) ->
        explicit(registry, app, declaration, mode, :run_mode, opts)

      not is_nil(preferred) ->
        explicit(registry, app, declaration, preferred, :source_preference, opts)

      true ->
        from_order(registry, app, declaration, declaration.order, :order, opts)
    end
  end

  defp explicit(registry, app, declaration, source, reason, opts) do
    cond do
      source not in sources() ->
        {:error, {:unknown_source, app, source, reason}}

      not eligible_source?(declaration, source) ->
        {:error, {:ineligible_source, app, source, reason}}

      true ->
        case availability(registry, app, declaration, source, opts) do
          :available ->
            {:ok, {source, reason, chosen(source)}}

          {:known_unselected, project} ->
            {:error, {:known_unselected_local, app, [project.id]}}

          {:error, error} ->
            {:error, error}

          outcome ->
            {:error, {:unavailable_source, app, source, {reason, outcome}}}
        end
    end
  end

  defp eligible_source?(declaration, @local), do: @local in declaration.order

  defp eligible_source?(declaration, @github),
    do: @github in declaration.order and not is_nil(declaration.github)

  defp eligible_source?(declaration, @hex),
    do: @hex in declaration.order and not is_nil(declaration.hex)

  defp eligible_source?(_declaration, _source), do: false

  # Publishing refuses an override that would resolve to a non-Hex source, and
  # names which of the three gestures asked for it. A configured
  # `publish_order` is not an override and is never refused here.
  defp publishable(app, requested, mode) do
    cond do
      not is_nil(requested) and requested != @hex ->
        {:error, {:unpublishable_source_override, app, requested}}

      not is_nil(mode) and mode != @hex ->
        {:error, {:unpublishable_run_mode, mode}}

      true ->
        :ok
    end
  end

  defp preference(opts, app) do
    opts |> Keyword.get(:preferences, %{}) |> Map.get(app)
  end

  defp preferences(project_id, opts) do
    case Keyword.fetch(opts, :preferences) do
      {:ok, preferences} when is_map(preferences) ->
        normalize_preferences(preferences)

      {:ok, other} ->
        {:error, {:invalid_source_preferences, other}}

      :error ->
        with {:ok, paths} <-
               OperatorPaths.resolve(
                 %{source_preferences: Keyword.get(opts, :source_preferences)},
                 [:source_preferences]
               ),
             path <- Map.get(paths, :source_preferences, SourcePreferences.default_path()),
             {:ok, all} <- SourcePreferences.load(path) do
          all |> SourcePreferences.project(project_id) |> normalize_preferences()
        end
    end
  end

  defp normalize_preferences(preferences) do
    Enum.reduce_while(preferences, {:ok, %{}}, fn {app, source}, {:ok, acc} ->
      case SourcePreferences.normalize_mode(source) do
        {:ok, mode} ->
          {:cont, {:ok, Map.put(acc, app, SourcePreferences.resolution_mode(mode))}}

        {:error, reason} ->
          {:halt, {:error, {:source_preference, app, reason}}}
      end
    end)
  end

  defp normalize_decide_preferences(opts) do
    case Keyword.fetch(opts, :preferences) do
      :error ->
        {:ok, opts}

      {:ok, preferences} when is_map(preferences) ->
        preferences
        |> Enum.reduce_while({:ok, %{}}, &normalize_decide_preference_entry/2)
        |> case do
          {:ok, normalized} -> {:ok, Keyword.put(opts, :preferences, normalized)}
          error -> error
        end

      {:ok, other} ->
        {:error, {:invalid_source_preferences, other}}
    end
  end

  defp normalize_decide_preference_entry({app, source}, {:ok, preferences}) do
    case normalize_decide_preference(source) do
      {:ok, normalized} -> {:cont, {:ok, Map.put(preferences, app, normalized)}}
      {:error, reason} -> {:halt, {:error, {:source_preference, app, reason}}}
    end
  end

  defp normalize_decide_preference("github"), do: {:ok, "github"}

  defp normalize_decide_preference(source) do
    with {:ok, mode} <- SourcePreferences.normalize_mode(source) do
      {:ok, SourcePreferences.resolution_mode(mode)}
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
      {:known_unselected, project} -> {:known_unselected, project}
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
    derived_local(registry, app, declaration, opts)
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

  defp provider_id(registry, app, declaration, opts) do
    case provider(registry, app, declaration, opts) do
      {:ok, project} -> project.id
      {:known_unselected, project} -> project.id
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
      {:ok, project} ->
        {:ok, project}

      {:known_unselected, [project_id]} ->
        {:known_unselected, Registry.project!(registry, project_id)}

      :unknown ->
        :no_catalogued_provider

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build(registry, app, declaration, @local, reason, considered, opts) do
    case local_source(registry, app, declaration, opts) do
      {:ok, path, provider_id} ->
        {:ok, decision(app, @local, reason, considered, provider_id, path, declaration)}

      {:error, error} ->
        {:error, error}

      {:known_unselected, project} ->
        {:error, {:known_unselected_local, app, [project.id]}}

      _unavailable ->
        {:error, {:unavailable_source, app, @local, reason}}
    end
  end

  defp build(registry, app, declaration, @github, reason, considered, opts) do
    case github(registry, app, declaration, opts) do
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

  defp build(_registry, app, declaration, @hex, reason, considered, _opts) do
    case declaration.hex do
      nil -> {:error, {:unavailable_source, app, @hex, reason}}
      requirement -> {:ok, decision(app, @hex, reason, considered, nil, requirement, declaration)}
    end
  end

  defp build(_registry, app, _declaration, source, reason, _considered, _opts),
    do: {:error, {:unknown_source, app, source, reason}}

  defp github(registry, app, declaration, opts) do
    if declaration.github do
      registry
      |> declared_coordinates(app, declaration, opts)
      |> merge_github(declaration.github)
    end
  end

  defp declared_coordinates(registry, app, declaration, opts) do
    catalogued_coordinates(registry, app, declaration, opts)
  end

  defp catalogued_coordinates(registry, app, declaration, opts) do
    with {:ok, project} <- provider_project(provider(registry, app, declaration, opts)),
         repository = Registry.repository!(registry, project.repository),
         true <- is_binary(repository.github) do
      %{
        repo: repository.github,
        branch: repository.default_branch,
        ref: nil,
        tag: nil,
        subdir: subdirectory(project.path)
      }
    else
      _uncatalogued -> nil
    end
  end

  defp provider_project({:ok, project}), do: {:ok, project}
  defp provider_project({:known_unselected, project}), do: {:ok, project}
  defp provider_project(_outcome), do: :unavailable

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
      classification: :managed,
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

  defp same_inputs(%{mix_env: mix_env, mix_target: mix_target}, %{
         mix_env: mix_env,
         mix_target: mix_target
       }),
       do: :ok

  defp same_inputs(closure, inputs) do
    {:error,
     {:graph_input_mismatch, {closure.mix_env, closure.mix_target},
      {inputs.mix_env, inputs.mix_target}}}
  end

  defp one_identity_per_application(closure) do
    conflict =
      closure.dependency_applications
      |> Enum.group_by(& &1.application)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find(fn {_app, uses} ->
        uses
        |> Enum.map(&{&1.provider, &1.classification})
        |> Enum.uniq()
        |> length() > 1
      end)

    case conflict do
      nil ->
        :ok

      {app, uses} ->
        reported =
          uses
          |> Enum.map(&Map.take(&1, [:consumer, :provider, :classification]))
          |> Enum.sort_by(&{&1.consumer, &1.provider || "", &1.classification})

        {:error, {:conflicting_dependency_identities, app, reported}}
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
        {:ok, decision} ->
          classification = dependency_classification(closure, app)
          {:ok, %{decision | declared_by: declared_by, classification: classification}}

        {:error, reason} ->
          {:error, reason}
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
        {:unavailable_source, app, ^mode, {:run_mode, _detail}} -> [app]
        {:ineligible_source, app, ^mode, :run_mode} -> [app]
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
    closure.dependency_applications
    |> Enum.map(& &1.application)
    |> Enum.filter(&Map.has_key?(declarations, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dependency_classification(closure, app) do
    closure.dependency_applications
    |> Enum.find(&(&1.application == app))
    |> Map.fetch!(:classification)
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
      initial = {declaration, [project.id], project.repository}
      Map.update(inner, app, initial, &merge_declaration(&1, declaration, project, replace?))
    end)
  end

  defp merge_declaration({_chosen, ids, _repository}, declaration, project, true),
    do: {declaration, declared_by(ids, project.id), project.repository}

  defp merge_declaration({chosen, ids, repository}, _declaration, project, false),
    do: {chosen, declared_by(ids, project.id), repository}

  defp declared_by(ids, project_id), do: Enum.sort(Enum.uniq([project_id | ids]))
end
