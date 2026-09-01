defmodule MixWorkspaceOps.OperationPlan do
  @moduledoc """
  Portable, frozen semantic plans for repository and Mix-project operations.

  A plan carries identities and expected source state, never the paths or
  environment values that bind those identities on one machine. `build/4`
  reads current state; `load/1` verifies a strict saved document; `replay/5`
  rebuilds from the recorded intent and reports named drift.
  """

  alias MixWorkspaceOps.{Binding, Command, DependencyIndex, Git, Project, Registry, Report, Resolution, Selection, StrictJSON}
  alias MixWorkspaceOps.Project.ProbeMemo

  @schema "mix_workspace_ops.plan/v2"
  @policy_version "mix_workspace_ops.command_policy/v1"
  @maximum_bytes 16 * 1024 * 1024
  @top_keys ~w(schema digest registry view selection_digest sets scope dependency_index command policy toolchain units)
  @unit_kinds [:project, :repository]
  @dirty_policies [:require_clean, :allow_recorded]
  @failure_policies [:continue, :fail_fast]

  @type plan :: map()

  @doc "Builds one portable plan without executing its requested command."
  @spec build(Registry.t(), struct() | nil, [String.t()], keyword()) ::
          {:ok, plan()} | {:error, term()}
  def build(registry, view, command, opts \\ []) do
    with {:ok, normalized} <- normalize_options(opts),
         :ok <- portable_command(command),
         {:ok, normalized, scope, dependency_index} <- prepare_scope(registry, view, normalized),
         {:ok, units} <- units(registry, normalized),
         base <- %{
           schema: @schema,
           registry: %{schema: registry.schema, digest: registry.digest},
           view: view_record(view),
           selection_digest: Registry.selection_digest(registry),
           sets: portable_sets(Registry.sets(registry)),
           scope: scope,
           dependency_index: dependency_index,
           command: command_record(command),
           policy: policy_record(normalized),
           toolchain: toolchain(),
           units: units
         },
         :ok <- portable_document(base) do
      {:ok, Map.put(base, :digest, document_digest(base))}
    end
  end

  @doc "Loads and verifies a strict, self-digested semantic plan."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    path = Path.expand(path)

    with {:ok, stat} <- File.stat(path),
         :ok <- regular_and_bounded(stat),
         {:ok, bytes} <- File.read(path),
         {:ok, decoded} <- StrictJSON.decode(bytes, maximum_bytes: @maximum_bytes),
         decoded <- normalize_null(decoded),
         :ok <- validate_loaded(decoded),
         :ok <- verify_document_digest(decoded) do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:operation_plan, path, reason}}
    end
  end

  @doc "Writes a semantic plan using the same canonical bytes emitted to stdout."
  @spec write(String.t(), map()) :: :ok | {:error, term()}
  def write(path, plan), do: Report.write(path, plan)

  @doc "Rebuilds a saved plan from current state and rejects every named drift."
  @spec replay(map(), Registry.t(), struct() | nil, keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def replay(recorded, registry, view, build_opts, compare_opts \\ []) do
    command = command_argv(recorded)
    intent = recorded_options(recorded, build_opts)

    with :ok <- requested_policy_matches(recorded, compare_opts),
         {:ok, actual} <- build(registry, view, command, intent),
         [] <- drift(recorded, actual) do
      {:ok, actual}
    else
      drifts when is_list(drifts) -> {:error, {:plan_drift, drifts}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the exact command vector frozen in a plan."
  @spec command_argv(map()) :: [String.t()]
  def command_argv(plan) do
    command = field(plan, :command)
    [field(command, :executable) | field(command, :args)]
  end

  @doc "Gets a known field from either a freshly built or JSON-loaded plan map."
  @spec field(map(), atom()) :: term()
  def field(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  @doc "Current versions frozen in every semantic plan."
  @spec toolchain() :: map()
  def toolchain do
    %{
      mix_workspace_ops: MixWorkspaceOps.version(),
      blitz: application_version(:blitz),
      elixir: System.version(),
      otp: List.to_string(:erlang.system_info(:otp_release)),
      mix: mix_version()
    }
  end

  defp normalize_options(opts) do
    values = %{
      unit_kind: Keyword.get(opts, :unit_kind, :project),
      dirty_policy: Keyword.get(opts, :dirty_policy, :require_clean),
      failure_policy: Keyword.get(opts, :failure_policy, :continue),
      mode: Keyword.get(opts, :mode, :auto),
      sources: Keyword.get(opts, :sources, %{}),
      mix_env: Keyword.get(opts, :mix_env, "dev"),
      mix_target: Keyword.get(opts, :mix_target, "host"),
      project: Keyword.get(opts, :project),
      affected: Keyword.get(opts, :affected),
      project_ids: Keyword.get(opts, :project_ids),
      probe_memo: Keyword.get(opts, :probe_memo, ProbeMemo.new()),
      observe_dirty: Keyword.get(opts, :observe_dirty, false)
    }

    with true <-
           values.unit_kind in @unit_kinds || {:error, {:invalid_unit_kind, values.unit_kind}},
         true <-
           values.dirty_policy in @dirty_policies ||
             {:error, {:invalid_dirty_policy, values.dirty_policy}},
         true <-
           values.failure_policy in @failure_policies ||
             {:error, {:invalid_failure_policy, values.failure_policy}},
         true <- is_map(values.sources) || {:error, :invalid_source_overrides} do
      {:ok, values}
    end
  end

  defp prepare_scope(registry, view, %{affected: target} = opts) when is_binary(target) do
    cond do
      opts.unit_kind != :project ->
        {:error, :affected_scope_requires_project_units}

      not is_nil(opts.project) ->
        {:error, :affected_scope_conflicts_with_project}

      is_nil(view) ->
        {:error, :affected_scope_requires_view}

      true ->
        index_opts = [
          mix_env: opts.mix_env,
          mix_target: opts.mix_target,
          probe_memo: opts.probe_memo
        ]

        with {:ok, index} <- DependencyIndex.build(registry, index_opts),
             {:ok, selection} <- Selection.affected(registry, index, target) do
          portable_index = DependencyIndex.portable(index)
          portable_coverage = %{
            complete: portable_index.complete,
            selected_project_count: length(portable_index.selected_projects),
            probed_project_count: length(portable_index.probed_projects),
            absent_projects: portable_index.absent_projects,
            failed_projects: portable_index.failed_projects
          }

          scope = %{
            kind: :affected,
            requested_target: target,
            target: selection.target,
            base_projects: selection.base_projects,
            selected_projects: selection.projects,
            impact_complete: selection.impact_complete,
            fallback_to_full_scope: selection.fallback_to_full_scope,
            fallback_reason: selection.fallback_reason,
            coverage: portable_coverage,
            dependency_index_digest: index.digest
          }

          {:ok, %{opts | project_ids: selection.projects}, scope, portable_index}
        end
    end
  end

  defp prepare_scope(registry, view, opts) do
    kind =
      cond do
        is_binary(opts.project) -> :project
        is_nil(view) -> :selection
        true -> :view
      end

    selected_projects =
      if is_binary(opts.project),
        do: [opts.project],
        else: Enum.map(Registry.selected_projects(registry), & &1.id)

    scope = %{
      kind: kind,
      requested_target: nil,
      target: nil,
      base_projects: Enum.map(Registry.selected_projects(registry), & &1.id),
      selected_projects: selected_projects,
      impact_complete: nil,
      fallback_to_full_scope: false,
      fallback_reason: nil,
      coverage: nil,
      dependency_index_digest: nil
    }

    {:ok, opts, scope, nil}
  end

  defp units(registry, %{unit_kind: :repository} = opts) do
    if opts.project || opts.project_ids do
      {:error, :repository_units_do_not_accept_project}
    else
      registry
      |> Registry.selected_repositories()
      |> repository_states(registry, inspection_dirty_policy(opts))
    end
  end

  defp units(registry, %{unit_kind: :project} = opts) do
    with {:ok, projects} <- selected_projects(registry, opts),
         :ok <- prewarm_projects(registry, projects, opts),
         {:ok, states} <-
           project_repository_states(registry, projects, inspection_dirty_policy(opts)) do
      map_project_units(registry, projects, states, opts)
    end
  end

  defp selected_projects(registry, %{project_ids: ids}) when is_list(ids) do
    projects = Enum.map(ids, &Registry.project!(registry, &1))

    if Enum.all?(projects, &Registry.selected?(registry, &1.id)),
      do: {:ok, projects},
      else: {:error, :affected_project_outside_view}
  end

  defp selected_projects(registry, %{project: nil}), do: {:ok, Registry.selected_projects(registry)}

  defp selected_projects(registry, %{project: project_id}) do
    project = Registry.project!(registry, project_id)

    if Registry.selected?(registry, project.id),
      do: {:ok, [project]},
      else: {:error, {:project_outside_view, project.id}}
  end

  defp prewarm_projects(registry, projects, opts) do
    bound =
      Enum.filter(projects, &match?({:bound, _}, Registry.checkout(registry, &1.repository)))

    Project.prewarm(registry, bound, opts.probe_memo,
      mix_env: opts.mix_env,
      mix_target: opts.mix_target
    )

    :ok
  end

  defp project_repository_states(registry, projects, dirty_policy) do
    projects
    |> Enum.map(& &1.repository)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&Registry.repository!(registry, &1))
    |> repository_states(registry, dirty_policy)
    |> case do
      {:ok, units} -> {:ok, Map.new(units, &{&1.identity, &1})}
      error -> error
    end
  end

  defp repository_states(repositories, registry, dirty_policy) do
    Enum.reduce_while(repositories, {:ok, []}, fn repository, {:ok, acc} ->
      case repository_unit(registry, repository, dirty_policy) do
        {:ok, unit} -> {:cont, {:ok, [unit | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp repository_unit(registry, repository, dirty_policy) do
    identity = repository_identity(repository)

    case Registry.checkout(registry, repository.id) do
      {:absent, _expected} ->
        {:ok,
         %{
           id: repository.id,
           kind: :repository,
           identity: repository.id,
           repository: identity,
           status: :absent,
           expected: nil,
           graph_digest: nil,
           sources: []
         }}

      {:bound, root} ->
        expected = expected_state(root)

        with :ok <- acceptable_dirty(repository.id, expected, dirty_policy) do
          {:ok,
           %{
             id: repository.id,
             kind: :repository,
             identity: repository.id,
             repository: identity,
             status: :planned,
             expected: expected,
             graph_digest: nil,
             sources: []
           }}
        end

      :unknown ->
        {:error, {:unbound_plan_repository, repository.id}}
    end
  end

  defp map_project_units(registry, projects, states, opts) do
    Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, acc} ->
      repository = Registry.repository!(registry, project.repository)
      state = Map.fetch!(states, repository.id)

      case project_unit(registry, project, repository, state, opts) do
        {:ok, unit} -> {:cont, {:ok, [unit | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp project_unit(_registry, project, repository, %{status: :absent}, _opts) do
    {:ok,
     %{
       id: project.id,
       kind: :project,
       identity: project.id,
       repository: repository_identity(repository),
       project: project_identity(project),
       status: :absent,
       expected: nil,
       graph_digest: nil,
       sources: []
     }}
  end

  defp project_unit(registry, project, repository, state, opts) do
    resolution_opts = [
      mode: resolution_mode(opts.mode),
      sources: opts.sources,
      mix_env: opts.mix_env,
      mix_target: opts.mix_target,
      probe_memo: opts.probe_memo
    ]

    with {:ok, resolved} <- Resolution.resolve(registry, project.id, resolution_opts),
         {:ok, sources} <-
           portable_sources(registry, resolved.decisions, inspection_dirty_policy(opts)) do
      {:ok,
       %{
         id: project.id,
         kind: :project,
         identity: project.id,
         repository: repository_identity(repository),
         project: project_identity(project),
         status: :planned,
         expected: state.expected,
         graph_digest: resolved.closure.digest,
         sources: sources
       }}
    end
  end

  defp portable_sources(registry, decisions, dirty_policy) do
    Enum.reduce_while(decisions, {:ok, []}, fn decision, {:ok, acc} ->
      case portable_source(registry, decision, dirty_policy) do
        {:ok, source} -> {:cont, {:ok, [source | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok()
  end

  defp portable_source(
         _registry,
         %{source: "local", provider_project_id: nil} = decision,
         _dirty_policy
       ),
       do: {:error, {:nonportable_local_source, decision.application}}

  defp portable_source(registry, %{source: "local"} = decision, dirty_policy) do
    provider = Registry.project!(registry, decision.provider_project_id)
    repository = Registry.repository!(registry, provider.repository)

    portable_local_checkout(decision, provider, repository, dirty_policy)
  end

  defp portable_source(_registry, %{source: "github"} = decision, _dirty_policy) do
    {:ok,
     source_record(decision, Map.take(decision.location, [:repo, :branch, :ref, :tag, :subdir]))}
  end

  defp portable_source(_registry, %{source: "hex"} = decision, _dirty_policy) do
    package =
      case Keyword.get(decision.opts, :hex) do
        nil -> decision.application
        value -> to_string(value)
      end

    {:ok, source_record(decision, %{package: package, requirement: decision.location})}
  end

  defp portable_local_checkout(decision, provider, repository, dirty_policy) do
    with {:ok, root} <- Git.root(decision.location),
         :ok <- local_project_identity(decision.location, root, provider, repository),
         expected = expected_state(root),
         :ok <- acceptable_dirty(repository.id, expected, dirty_policy) do
      {:ok,
       source_record(decision, %{
         provider: project_identity(provider),
         repository: repository_identity(repository),
         expected: expected
       })}
    end
  end

  defp local_project_identity(location, root, provider, repository) do
    expected_path = root |> Path.join(provider.path) |> Path.expand()
    identities = Binding.github_identities(root)

    cond do
      Path.expand(location) != expected_path ->
        {:error, {:local_source_project_path_mismatch, provider.id}}

      identities != [repository.github] ->
        {:error, {:local_source_repository_mismatch, repository.id, identities}}

      true ->
        :ok
    end
  end

  defp source_record(decision, coordinates) do
    %{
      application: decision.application,
      classification: decision.classification,
      provider: decision.provider_project_id,
      source: decision.source,
      reason: decision.reason,
      considered: decision.considered,
      declared_by: decision.declared_by,
      opts: Enum.map(decision.opts, fn {key, value} -> %{key: key, value: value} end),
      coordinates: coordinates
    }
  end

  defp repository_identity(repository) do
    %{
      id: repository.id,
      github: repository.github,
      default_branch: repository.default_branch
    }
  end

  defp project_identity(project) do
    %{
      id: project.id,
      repository: project.repository,
      path: project.path,
      applications: project.provides
    }
  end

  defp expected_state(root) do
    %{head: Git.head!(root), source_digest: Git.source_digest(root), clean: Git.clean?(root)}
  end

  defp acceptable_dirty(_identity, %{clean: true}, _policy), do: :ok
  defp acceptable_dirty(_identity, _expected, :allow_recorded), do: :ok

  defp acceptable_dirty(identity, _expected, :require_clean),
    do: {:error, {:dirty_plan_unit, identity}}

  defp policy_record(opts) do
    %{
      version: @policy_version,
      unit_kind: opts.unit_kind,
      dirty_state: opts.dirty_policy,
      failure: opts.failure_policy,
      source_mode: opts.mode,
      source_overrides: opts.sources,
      mix_env: opts.mix_env,
      mix_target: opts.mix_target,
      project: opts.project
    }
  end

  defp command_record([executable | args]), do: %{executable: executable, args: args}

  defp portable_command([]), do: {:error, :empty_plan_command}

  defp portable_command(command) do
    case Enum.find(command, &nonportable_segment?/1) do
      nil -> :ok
      segment -> {:error, {:nonportable_command_segment, segment}}
    end
  end

  defp nonportable_segment?(segment) do
    Path.type(segment) == :absolute or
      segment
      |> String.split("=", parts: 2)
      |> List.last()
      |> Path.type()
      |> Kernel.==(:absolute)
  end

  defp view_record(nil), do: nil

  defp view_record(view) do
    %{schema: view.schema, id: view.id, digest: view.digest}
  end

  defp portable_sets(sets) do
    put_in(sets, [:materialized, :absent_repositories], sets.materialized.absent_repositories)
  end

  defp document_digest(document), do: document |> Report.encode() |> sha256()

  defp validate_loaded(decoded) when is_map(decoded) do
    with :ok <- exact_keys(decoded, @top_keys),
         true <- decoded["schema"] == @schema || {:error, :unsupported_operation_plan_schema},
         :ok <- digest_value(decoded["digest"], :invalid_operation_plan_digest),
         :ok <- validate_registry_record(decoded["registry"]),
         :ok <- validate_view_record(decoded["view"]),
         :ok <- digest_or_nil(decoded["selection_digest"], :invalid_selection_digest),
         :ok <- validate_sets(decoded["sets"]),
         :ok <- validate_scope(decoded["scope"]),
         :ok <- validate_dependency_index(decoded["dependency_index"]),
         :ok <- validate_command(decoded["command"]),
         :ok <- validate_policy(decoded["policy"]),
         :ok <- validate_toolchain(decoded["toolchain"]),
         :ok <- validate_units(decoded["units"]),
         :ok <- portable_command(command_argv(decoded)),
         do: portable_document(decoded)
  end

  defp validate_loaded(_decoded), do: {:error, :invalid_operation_plan}

  defp regular_and_bounded(%{type: type}) when type != :regular,
    do: {:error, {:not_regular, type}}

  defp regular_and_bounded(%{size: size}) when size > @maximum_bytes,
    do: {:error, :too_large}

  defp regular_and_bounded(%{type: :regular}), do: :ok

  defp exact_keys(map, expected) do
    actual = Map.keys(map) |> Enum.sort()
    expected = Enum.sort(expected)

    if actual == expected,
      do: :ok,
      else: {:error, {:operation_plan_keys, expected, actual}}
  end

  defp validate_registry_record(record) when is_map(record) do
    with :ok <- exact_keys(record, ~w(schema digest)),
         true <- is_binary(record["schema"]) || {:error, :invalid_operation_plan_registry},
         do: digest_value(record["digest"], :invalid_operation_plan_registry)
  end

  defp validate_registry_record(_record), do: {:error, :invalid_operation_plan_registry}

  defp validate_view_record(nil), do: :ok

  defp validate_view_record(record) when is_map(record) do
    with :ok <- exact_keys(record, ~w(schema id digest)),
         true <-
           Enum.all?(~w(schema id), &is_binary(record[&1])) ||
             {:error, :invalid_operation_plan_view},
         do: digest_value(record["digest"], :invalid_operation_plan_view)
  end

  defp validate_view_record(_record), do: {:error, :invalid_operation_plan_view}

  defp validate_sets(sets) when is_map(sets) do
    with :ok <- exact_keys(sets, ~w(catalogued selected materialized)),
         :ok <- validate_catalogued_set(sets["catalogued"]),
         :ok <- validate_selected_set(sets["selected"]),
         do: validate_materialized_set(sets["materialized"])
  end

  defp validate_sets(_sets), do: {:error, :invalid_operation_plan_sets}

  defp validate_catalogued_set(set) when is_map(set) do
    with :ok <- exact_keys(set, ~w(digest repositories projects applications)),
         :ok <- digest_value(set["digest"], :invalid_operation_plan_sets),
         true <-
           counts?(set, ~w(repositories projects applications)) ||
             {:error, :invalid_operation_plan_sets} do
      :ok
    end
  end

  defp validate_catalogued_set(_set), do: {:error, :invalid_operation_plan_sets}

  defp validate_selected_set(set) when is_map(set) do
    with :ok <-
           exact_keys(
             set,
             ~w(digest repositories projects applications unselected_applications)
           ),
         :ok <- digest_or_nil(set["digest"], :invalid_operation_plan_sets),
         true <-
           counts?(set, ~w(repositories projects applications)) ||
             {:error, :invalid_operation_plan_sets},
         true <-
           string_list?(set["unselected_applications"]) ||
             {:error, :invalid_operation_plan_sets} do
      :ok
    end
  end

  defp validate_selected_set(_set), do: {:error, :invalid_operation_plan_sets}

  defp validate_materialized_set(set) when is_map(set) do
    with :ok <- exact_keys(set, ~w(repositories absent absent_repositories)),
         true <- counts?(set, ~w(repositories absent)) || {:error, :invalid_operation_plan_sets},
         true <-
           string_list?(set["absent_repositories"]) ||
             {:error, :invalid_operation_plan_sets} do
      :ok
    end
  end

  defp validate_materialized_set(_set), do: {:error, :invalid_operation_plan_sets}

  defp validate_scope(scope) when is_map(scope) do
    required = ~w(kind requested_target target base_projects selected_projects impact_complete fallback_to_full_scope fallback_reason coverage dependency_index_digest)

    with :ok <- exact_keys(scope, required),
         true <- scope["kind"] in ~w(affected project selection view) || {:error, :invalid_operation_plan_scope},
         true <- string_list?(scope["base_projects"]) || {:error, :invalid_operation_plan_scope},
         true <- string_list?(scope["selected_projects"]) || {:error, :invalid_operation_plan_scope},
         true <- is_boolean(scope["fallback_to_full_scope"]) || {:error, :invalid_operation_plan_scope} do
      :ok
    end
  end

  defp validate_scope(_scope), do: {:error, :invalid_operation_plan_scope}

  defp validate_dependency_index(nil), do: :ok

  defp validate_dependency_index(index) when is_map(index) do
    required = ~w(mix_env mix_target selected_projects probed_projects absent_projects failed_projects edges complete digest)

    with :ok <- exact_keys(index, required),
         true <- is_binary(index["mix_env"]) and is_binary(index["mix_target"]) || {:error, :invalid_operation_plan_dependency_index},
         true <- string_list?(index["selected_projects"]) || {:error, :invalid_operation_plan_dependency_index},
         true <- string_list?(index["probed_projects"]) || {:error, :invalid_operation_plan_dependency_index},
         true <- string_list?(index["absent_projects"]) || {:error, :invalid_operation_plan_dependency_index},
         true <- is_list(index["failed_projects"]) and is_list(index["edges"]) || {:error, :invalid_operation_plan_dependency_index},
         true <- is_boolean(index["complete"]) || {:error, :invalid_operation_plan_dependency_index},
         :ok <- digest_value(index["digest"], :invalid_operation_plan_dependency_index) do
      :ok
    end
  end

  defp validate_dependency_index(_index), do: {:error, :invalid_operation_plan_dependency_index}

  defp validate_command(command) when is_map(command) do
    with :ok <- exact_keys(command, ~w(executable args)),
         true <- is_binary(command["executable"]) || {:error, :invalid_operation_plan_command},
         true <- string_list?(command["args"]) || {:error, :invalid_operation_plan_command} do
      :ok
    end
  end

  defp validate_command(_command), do: {:error, :invalid_operation_plan_command}

  defp validate_policy(policy) when is_map(policy) do
    keys =
      ~w(version unit_kind dirty_state failure source_mode source_overrides mix_env mix_target project)

    with :ok <- exact_keys(policy, keys),
         true <- policy["version"] == @policy_version || {:error, :unsupported_command_policy},
         :ok <- validate_policy_enums(policy),
         do: validate_policy_values(policy)
  end

  defp validate_policy(_policy), do: {:error, :invalid_operation_plan_policy}

  defp validate_policy_enums(policy) do
    valid? =
      policy["unit_kind"] in ~w(project repository) and
        policy["dirty_state"] in ~w(require_clean allow_recorded) and
        policy["failure"] in ~w(continue fail_fast) and
        policy["source_mode"] in ~w(auto local git hex)

    if valid?, do: :ok, else: {:error, :invalid_operation_plan_policy}
  end

  defp validate_policy_values(policy) do
    valid? =
      source_overrides?(policy["source_overrides"]) and
        Enum.all?(~w(mix_env mix_target), &is_binary(policy[&1])) and
        (is_nil(policy["project"]) or is_binary(policy["project"]))

    if valid?, do: :ok, else: {:error, :invalid_operation_plan_policy}
  end

  defp validate_toolchain(toolchain) when is_map(toolchain) do
    with :ok <- exact_keys(toolchain, ~w(mix_workspace_ops blitz elixir otp mix)),
         true <-
           Enum.all?(Map.values(toolchain), &is_binary/1) ||
             {:error, :invalid_operation_plan_toolchain} do
      :ok
    end
  end

  defp validate_toolchain(_toolchain), do: {:error, :invalid_operation_plan_toolchain}

  defp validate_units(units) when is_list(units) do
    with true <-
           Enum.all?(units, &(validate_unit(&1) == :ok)) ||
             {:error, :invalid_operation_plan_units},
         ids = Enum.map(units, & &1["id"]),
         true <- length(ids) == length(Enum.uniq(ids)) || {:error, :duplicate_operation_units} do
      :ok
    end
  end

  defp validate_units(_units), do: {:error, :invalid_operation_plan_units}

  defp validate_unit(%{"kind" => "repository"} = unit) do
    with :ok <-
           exact_keys(
             unit,
             ~w(id kind identity repository status expected graph_digest sources)
           ),
         :ok <- validate_unit_common(unit),
         true <- unit["identity"] == unit["id"] || {:error, :invalid_operation_plan_unit},
         true <-
           (is_nil(unit["graph_digest"]) and unit["sources"] == []) ||
             {:error, :invalid_operation_plan_unit} do
      :ok
    end
  end

  defp validate_unit(%{"kind" => "project"} = unit) do
    with :ok <-
           exact_keys(
             unit,
             ~w(id kind identity repository project status expected graph_digest sources)
           ),
         :ok <- validate_unit_common(unit),
         true <- unit["identity"] == unit["id"] || {:error, :invalid_operation_plan_unit},
         :ok <- validate_project_identity(unit["project"]),
         do: validate_project_state(unit)
  end

  defp validate_unit(_unit), do: {:error, :invalid_operation_plan_unit}

  defp validate_unit_common(unit) do
    with true <- is_binary(unit["id"]) || {:error, :invalid_operation_plan_unit},
         true <- unit["status"] in ~w(planned absent) || {:error, :invalid_operation_plan_unit},
         :ok <- validate_repository_identity(unit["repository"]),
         :ok <- validate_expected_for_status(unit["status"], unit["expected"]),
         true <- is_list(unit["sources"]) || {:error, :invalid_operation_plan_unit} do
      :ok
    end
  end

  defp validate_project_state(%{"status" => "absent"} = unit) do
    if is_nil(unit["graph_digest"]) and unit["sources"] == [],
      do: :ok,
      else: {:error, :invalid_operation_plan_unit}
  end

  defp validate_project_state(%{"status" => "planned"} = unit) do
    with :ok <- digest_value(unit["graph_digest"], :invalid_operation_plan_unit),
         true <-
           Enum.all?(unit["sources"], &(validate_source(&1) == :ok)) ||
             {:error, :invalid_operation_plan_unit} do
      :ok
    end
  end

  defp validate_repository_identity(identity) when is_map(identity) do
    with :ok <- exact_keys(identity, ~w(id github default_branch)),
         true <-
           Enum.all?(Map.values(identity), &is_binary/1) ||
             {:error, :invalid_operation_plan_repository} do
      :ok
    end
  end

  defp validate_repository_identity(_identity),
    do: {:error, :invalid_operation_plan_repository}

  defp validate_project_identity(identity) when is_map(identity) do
    with :ok <- exact_keys(identity, ~w(id repository path applications)),
         true <-
           Enum.all?(~w(id repository path), &is_binary(identity[&1])) ||
             {:error, :invalid_operation_plan_project},
         true <-
           string_list?(identity["applications"]) ||
             {:error, :invalid_operation_plan_project} do
      :ok
    end
  end

  defp validate_project_identity(_identity), do: {:error, :invalid_operation_plan_project}

  defp validate_expected_for_status("absent", nil), do: :ok
  defp validate_expected_for_status("planned", expected), do: validate_expected(expected)
  defp validate_expected_for_status(_status, _expected), do: {:error, :invalid_expected_state}

  defp validate_expected(expected) when is_map(expected) do
    with :ok <- exact_keys(expected, ~w(head source_digest clean)),
         true <- head_digest?(expected["head"]) || {:error, :invalid_expected_state},
         :ok <- digest_value(expected["source_digest"], :invalid_expected_state),
         true <- is_boolean(expected["clean"]) || {:error, :invalid_expected_state} do
      :ok
    end
  end

  defp validate_expected(_expected), do: {:error, :invalid_expected_state}

  defp validate_source(source) when is_map(source) do
    keys =
      ~w(application classification provider source reason considered declared_by opts coordinates)

    with :ok <- exact_keys(source, keys),
         :ok <- validate_source_identity(source),
         :ok <- validate_source_evidence(source),
         do: validate_coordinates(source["source"], source["coordinates"])
  end

  defp validate_source(_source), do: {:error, :invalid_operation_plan_source}

  defp validate_source_identity(source) do
    valid? =
      is_binary(source["application"]) and
        source["classification"] in ~w(managed known_unselected external) and
        (is_nil(source["provider"]) or is_binary(source["provider"])) and
        source["source"] in ~w(local github hex) and
        is_binary(source["reason"])

    if valid?, do: :ok, else: {:error, :invalid_operation_plan_source}
  end

  defp validate_source_evidence(source) do
    valid? =
      candidates?(source["considered"]) and string_list?(source["declared_by"]) and
        options?(source["opts"])

    if valid?, do: :ok, else: {:error, :invalid_operation_plan_source}
  end

  defp validate_coordinates("local", coordinates) when is_map(coordinates) do
    with :ok <- exact_keys(coordinates, ~w(provider repository expected)),
         :ok <- validate_project_identity(coordinates["provider"]),
         :ok <- validate_repository_identity(coordinates["repository"]),
         do: validate_expected(coordinates["expected"])
  end

  defp validate_coordinates("github", coordinates) when is_map(coordinates) do
    allowed = ~w(repo branch ref tag subdir)

    with true <-
           Enum.all?(Map.keys(coordinates), &(&1 in allowed)) ||
             {:error, :invalid_operation_plan_coordinates},
         true <-
           Map.has_key?(coordinates, "repo") ||
             {:error, :invalid_operation_plan_coordinates},
         true <-
           Enum.all?(Map.values(coordinates), &(is_nil(&1) or is_binary(&1))) ||
             {:error, :invalid_operation_plan_coordinates} do
      :ok
    end
  end

  defp validate_coordinates("hex", coordinates) when is_map(coordinates) do
    with :ok <- exact_keys(coordinates, ~w(package requirement)),
         true <-
           Enum.all?(Map.values(coordinates), &is_binary/1) ||
             {:error, :invalid_operation_plan_coordinates} do
      :ok
    end
  end

  defp validate_coordinates(_source, _coordinates),
    do: {:error, :invalid_operation_plan_coordinates}

  defp candidates?(values) when is_list(values) do
    Enum.all?(values, fn
      %{"source" => source, "outcome" => outcome} = candidate when map_size(candidate) == 2 ->
        source in ~w(local github hex) and is_binary(outcome)

      _candidate ->
        false
    end)
  end

  defp candidates?(_values), do: false

  defp options?(values) when is_list(values) do
    Enum.all?(values, fn
      %{"key" => key, "value" => value} = option when map_size(option) == 2 ->
        is_binary(key) and option_value?(value)

      _option ->
        false
    end)
  end

  defp options?(_values), do: false

  defp option_value?(value) when is_binary(value) or is_boolean(value), do: true
  defp option_value?(value) when is_list(value), do: Enum.all?(value, &is_binary/1)
  defp option_value?(_value), do: false

  defp source_overrides?(value) when is_map(value) do
    Enum.all?(value, fn {application, source} ->
      is_binary(application) and source in ~w(local github hex)
    end)
  end

  defp source_overrides?(_value), do: false

  defp counts?(map, keys),
    do: Enum.all?(keys, &(is_integer(map[&1]) and map[&1] >= 0))

  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp digest_value(value, error) do
    if digest?(value), do: :ok, else: {:error, error}
  end

  defp digest_or_nil(nil, _error), do: :ok
  defp digest_or_nil(value, error), do: digest_value(value, error)

  defp digest?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{64}$/, value)
  defp digest?(_value), do: false

  defp head_digest?(value) when is_binary(value), do: Regex.match?(~r/^[0-9a-f]{40,64}$/, value)
  defp head_digest?(_value), do: false

  defp portable_document(value) do
    case find_absolute_string(value) do
      nil -> :ok
      absolute -> {:error, {:nonportable_plan_value, absolute}}
    end
  end

  defp find_absolute_string(value) when is_binary(value) do
    if Path.type(value) == :absolute, do: value, else: nil
  end

  defp find_absolute_string(value) when is_list(value),
    do: Enum.find_value(value, &find_absolute_string/1)

  defp find_absolute_string(value) when is_map(value),
    do: value |> Map.values() |> Enum.find_value(&find_absolute_string/1)

  defp find_absolute_string(_value), do: nil

  defp verify_document_digest(plan) do
    expected = plan["digest"]
    actual = plan |> Map.delete("digest") |> document_digest()

    if expected == actual,
      do: :ok,
      else: {:error, {:operation_plan_digest_mismatch, expected, actual}}
  end

  defp recorded_options(recorded, build_opts) do
    policy = field(recorded, :policy)

    [
      unit_kind: existing_atom(field(policy, :unit_kind), @unit_kinds),
      dirty_policy: existing_atom(field(policy, :dirty_state), @dirty_policies),
      failure_policy: existing_atom(field(policy, :failure), @failure_policies),
      mode: source_mode(field(policy, :source_mode)),
      sources: field(policy, :source_overrides),
      mix_env: field(policy, :mix_env),
      mix_target: field(policy, :mix_target),
      project: field(policy, :project),
      affected: field(field(recorded, :scope), :requested_target),
      observe_dirty: true,
      probe_memo: Keyword.get(build_opts, :probe_memo, ProbeMemo.new())
    ]
  end

  defp requested_policy_matches(recorded, opts) do
    policy = field(recorded, :policy)

    comparisons = [
      {:failure_policy, field(policy, :failure), Keyword.get(opts, :failure_policy)},
      {:dirty_policy, field(policy, :dirty_state), Keyword.get(opts, :dirty_policy)},
      {:unit_kind, field(policy, :unit_kind), Keyword.get(opts, :unit_kind)}
    ]

    drifts =
      Enum.flat_map(comparisons, fn
        {_field, _recorded, nil} ->
          []

        {field, recorded_value, requested} ->
          actual = to_string(requested)

          if actual == recorded_value,
            do: [],
            else: [%{field: field, expected: recorded_value, actual: actual}]
      end)

    if drifts == [], do: :ok, else: {:error, {:plan_drift, drifts}}
  end

  defp drift(recorded, actual) do
    dimensions = [
      {:registry, [:registry]},
      {:view, [:view]},
      {:selection, [:selection_digest]},
      {:scope, [:scope]},
      {:dependency_index, [:dependency_index]},
      {:command, [:command]},
      {:command_policy, [:policy]},
      {:toolchain, [:toolchain]}
    ]

    document_drifts =
      Enum.flat_map(dimensions, fn {field_name, path} ->
        expected = get_path(recorded, path)
        found = get_path(actual, path)

        if canonical(expected) == canonical(found),
          do: [],
          else: [%{field: field_name, expected: expected, actual: found}]
      end)

    document_drifts ++ unit_drifts(field(recorded, :units), field(actual, :units))
  end

  defp unit_drifts(recorded, actual) do
    recorded_identity = Enum.map(recorded, &unit_identity/1)
    actual_identity = Enum.map(actual, &unit_identity/1)

    identity_drifts =
      if canonical(recorded_identity) == canonical(actual_identity),
        do: [],
        else: [%{field: :selected_units, expected: recorded_identity, actual: actual_identity}]

    recorded_by_id = Map.new(recorded, &{field(&1, :id), &1})
    actual_by_id = Map.new(actual, &{field(&1, :id), &1})

    common =
      Map.keys(recorded_by_id) |> Enum.filter(&Map.has_key?(actual_by_id, &1)) |> Enum.sort()

    identity_drifts ++
      Enum.flat_map(common, fn id ->
        unit_dimension_drifts(id, Map.fetch!(recorded_by_id, id), Map.fetch!(actual_by_id, id))
      end)
  end

  defp unit_identity(unit) do
    %{id: field(unit, :id), kind: field(unit, :kind), status: field(unit, :status)}
  end

  defp unit_dimension_drifts(id, recorded, actual) do
    comparisons = [
      {:repository_identity, [:repository]},
      {:project_identity, [:project]},
      {:repository_head, [:expected, :head]},
      {:source_digest, [:expected, :source_digest]},
      {:dirty_state, [:expected, :clean]},
      {:dependency_graph, [:graph_digest]},
      {:dependency_sources, [:sources]}
    ]

    Enum.flat_map(comparisons, fn {dimension, path} ->
      expected = optional_path(recorded, path)
      found = optional_path(actual, path)

      if canonical(expected) == canonical(found),
        do: [],
        else: [%{field: dimension, unit: id, expected: expected, actual: found}]
    end)
  end

  defp optional_path(nil, _path), do: nil
  defp optional_path(value, []), do: value

  defp optional_path(value, [key | rest]) do
    optional_path(field(value, key), rest)
  end

  defp get_path(value, []), do: value
  defp get_path(value, [key | rest]), do: get_path(field(value, key), rest)

  defp canonical(value), do: Report.encode(value)

  defp existing_atom(value, allowed) do
    Enum.find(allowed, &(Atom.to_string(&1) == to_string(value)))
  end

  defp source_mode(value) when is_atom(value), do: value
  defp source_mode("auto"), do: :auto
  defp source_mode("local"), do: :local
  defp source_mode("git"), do: :git
  defp source_mode("hex"), do: :hex

  defp resolution_mode(:auto), do: nil
  defp resolution_mode(:git), do: "github"
  defp resolution_mode(mode), do: to_string(mode)

  defp reverse_ok({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_ok(error), do: error

  defp inspection_dirty_policy(%{observe_dirty: true}), do: :allow_recorded
  defp inspection_dirty_policy(opts), do: opts.dirty_policy

  defp application_version(app), do: app |> Application.spec(:vsn) |> to_string()

  defp mix_version do
    case Application.spec(:mix, :vsn) do
      nil -> external_mix_version()
      version -> to_string(version)
    end
  end

  defp external_mix_version do
    case Command.run("mix", ["--version"]) do
      {:ok, %{output: output}} ->
        case Regex.run(~r/^Mix ([^\s]+)$/m, output) do
          [_, version] -> version
          _other -> "unavailable"
        end

      {:error, _reason} ->
        "unavailable"
    end
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp normalize_null(:null), do: nil
  defp normalize_null(values) when is_list(values), do: Enum.map(values, &normalize_null/1)

  defp normalize_null(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, normalize_null(item)} end)

  defp normalize_null(value), do: value
end