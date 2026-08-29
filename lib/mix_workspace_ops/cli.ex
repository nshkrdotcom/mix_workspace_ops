defmodule MixWorkspaceOps.CLI do
  @moduledoc false

  alias MixWorkspaceOps.{
    Command,
    Discovery,
    Doctor,
    Inventory,
    LocalOverrides,
    OperatorPaths,
    Overlay,
    PublishMode,
    Registry,
    Report,
    Resolution,
    Runtime,
    View
  }

  alias MixWorkspaceOps.Project.ProbeMemo
  alias MixWorkspaceOps.Registry.{Examples, ReleaseChain}
  alias MixWorkspaceOps.Release.{Descriptor, LocalAdapter, Transaction}

  @usage """
  mix_workspace_ops <command>

    version
    registry validate --registry PATH
    registry select --registry PATH --view PATH
    registry workspace --registry PATH [--repository ID]
    registry chain --registry PATH [--package APP]
    registry examples --guide PATH
    registry discover --checkout-root PATH --github-owner OWNER [--output PATH]
    inventory --registry PATH --checkout-root PATH [--view PATH] [--binding PATH] [--output PATH]
    doctor --registry PATH --checkout-root PATH [--view PATH] [--binding PATH]
    plan --project ID --registry PATH --checkout-root PATH [--view PATH] [--binding PATH] \
      [--mix-env ENV] [--mix-target TARGET] \
      [--mode auto|local|git|hex] [--source APP=SOURCE] [--as-publish true|false]
    sources --project ID --registry PATH --checkout-root PATH [--view PATH] [--binding PATH] \
      [--mix-env ENV] [--mix-target TARGET] \
      [--mode auto|local|git|hex] [--source APP=SOURCE] [--as-publish true|false]
    why APP [--project ID] [--registry PATH] [--checkout-root PATH] [--view PATH] [--binding PATH]
    use APP SOURCE [--project ID] [--registry PATH] [--checkout-root PATH] [--view PATH] [--binding PATH]
    use --clear [APP] [--project ID] [--registry PATH] [--checkout-root PATH] [--view PATH] [--binding PATH]
    seam --project ID --registry PATH --checkout-root PATH [--view PATH] [--binding PATH] \
      [--mix-env ENV] [--mix-target TARGET]
    state list [--state-root PATH]
    state gc --older-than N[s|m|h|d] [--dry-run] [--state-root PATH]
    run --project ID [--mode auto|local|git|hex] [--source APP=SOURCE] \
      --mix-state managed|delegated \
      --registry PATH --checkout-root PATH [--view PATH] [--binding PATH] \
      [--mix-env ENV] [--mix-target TARGET] [--allow-lock-mutation] \
      [--state-root PATH] -- COMMAND [ARG ...]
    release publish --descriptor PATH [--state-root PATH]
    help
  """

  # Every option each command accepts, which is every option its usage line
  # documents and no other. One global table would let an option reach a command
  # that has no use for it and would report a documented option as unknown when
  # only the table was missed.
  @accepted %{
    ["registry", "validate"] => [:registry],
    ["registry", "select"] => [:registry, :view],
    ["registry", "workspace"] => [:registry, :repository],
    ["registry", "chain"] => [:registry, :package],
    ["registry", "examples"] => [:guide],
    ["registry", "discover"] => [:checkout_root, :github_owner, :output],
    ["inventory"] => [:registry, :checkout_root, :view, :binding, :output],
    ["doctor"] => [:registry, :checkout_root, :view, :binding],
    ["plan"] => [
      :project,
      :registry,
      :checkout_root,
      :view,
      :binding,
      :mix_env,
      :mix_target,
      :mode,
      :source,
      :as_publish
    ],
    ["sources"] => [
      :project,
      :registry,
      :checkout_root,
      :view,
      :binding,
      :mix_env,
      :mix_target,
      :mode,
      :source,
      :as_publish
    ],
    ["why"] => [:project, :registry, :checkout_root, :view, :binding],
    ["use"] => [:clear, :project, :registry, :checkout_root, :view, :binding],
    ["seam"] => [
      :project,
      :registry,
      :checkout_root,
      :view,
      :binding,
      :mix_env,
      :mix_target
    ],
    ["state", "list"] => [:state_root],
    ["state", "gc"] => [:state_root, :older_than, :dry_run],
    ["run"] => [
      :project,
      :mode,
      :source,
      :mix_state,
      :registry,
      :checkout_root,
      :view,
      :binding,
      :mix_env,
      :mix_target,
      :allow_lock_mutation,
      :state_root
    ],
    ["release", "publish"] => [:descriptor, :state_root]
  }

  @vocabulary @accepted |> Map.values() |> List.flatten() |> Enum.uniq() |> Enum.sort()
  @switch_options [:allow_lock_mutation, :clear, :dry_run]

  # The two tasks that mutate a package registry. `hex.build` is a publish task
  # for resolution and is not refused here: it writes a tarball and nothing else,
  # and building one against a publish overlay is how an operator checks what
  # would be published.
  @refused_run_tasks ~w(hex.publish deps.publish_preflight)

  @spec main([String.t()]) :: no_return()
  def main(args) do
    args
    |> dispatch()
    |> exit_status()
    |> System.halt()
  end

  @doc false
  @spec usage_text() :: String.t()
  def usage_text, do: @usage

  defp exit_status(:usage), do: usage()
  defp exit_status({:ok, nil}), do: 0

  defp exit_status({:ok, value}) do
    IO.puts(Report.encode(value))
    0
  end

  defp exit_status({:error, reason}) do
    IO.puts(:stderr, "ERROR: #{format_error(reason)}")
    1
  end

  defp exit_status({:usage_error, reason}) do
    IO.puts(:stderr, "ERROR: #{reason}")
    usage(64)
  end

  @doc false
  @spec dispatch([String.t()]) ::
          :usage | {:ok, term()} | {:error, term()} | {:usage_error, String.t()}
  def dispatch(["version"]) do
    IO.puts(MixWorkspaceOps.version())
    {:ok, nil}
  end

  def dispatch(["help"]), do: :usage
  def dispatch([]), do: :usage

  def dispatch(["registry", "validate" | args]) do
    with {:ok, options, []} <- options(["registry", "validate"], args),
         :ok <- require_option(options, :registry),
         {:ok, registry} <- Registry.load(options.registry) do
      {:ok,
       %{
         schema: registry.schema,
         digest: registry.digest,
         repositories: map_size(registry.repositories),
         projects: map_size(registry.projects),
         applications: map_size(registry.applications),
         multiply_provided_applications: multiply_provided(registry),
         groups: length(Registry.groups(registry)),
         languages: languages(registry),
         release_packages: length(ReleaseChain.packages(registry))
       }}
    end
  end

  def dispatch(["registry", "chain" | args]) do
    with {:ok, options, []} <- options(["registry", "chain"], args),
         :ok <- require_option(options, :registry),
         {:ok, registry} <- Registry.load(options.registry),
         {:ok, chain} <- ReleaseChain.derive(registry),
         {:ok, order} <- ReleaseChain.order(registry, options.package) do
      {:ok,
       %{
         schema: "mix_workspace_ops.release_chain/v1",
         registry_digest: registry.digest,
         package: options.package,
         order: order,
         prerequisites: chain
       }}
    end
  end

  def dispatch(["registry", "examples" | args]) do
    with {:ok, options, []} <- options(["registry", "examples"], args),
         :ok <- require_option(options, :guide) do
      Examples.validate(options.guide)
    end
  end

  def dispatch(["registry", "workspace" | args]) do
    with {:ok, options, []} <- options(["registry", "workspace"], args),
         :ok <- require_option(options, :registry),
         {:ok, registry} <- Registry.load(options.registry),
         {:ok, workspaces} <- workspaces(registry, options.repository) do
      {:ok,
       %{
         schema: "mix_workspace_ops.workspace/v1",
         registry_digest: registry.digest,
         repository: options.repository,
         workspaces: workspaces
       }}
    end
  end

  def dispatch(["registry", "select" | args]) do
    with {:ok, options, []} <- options(["registry", "select"], args),
         :ok <- require_options(options, [:registry, :view]),
         {:ok, registry} <- Registry.load(options.registry),
         {:ok, view} <- View.load(options.view),
         {:ok, repositories} <- View.select_repositories(registry, view),
         {:ok, projects} <- View.select(registry, view) do
      selected = Registry.select(registry, projects)

      {:ok,
       %{
         schema: "mix_workspace_ops.selection/v2",
         registry_digest: registry.digest,
         selection_digest: Registry.selection_digest(selected),
         view: view.id,
         view_schema: view.schema,
         view_digest: view.digest,
         sets: Registry.sets(selected),
         repositories: Enum.map(repositories, & &1.id),
         projects: Enum.map(projects, & &1.id)
       }}
    end
  end

  def dispatch(["registry", "discover" | args]) do
    with {:ok, options, []} <- options(["registry", "discover"], args),
         :ok <- require_options(options, [:checkout_root, :github_owner]),
         {:ok, discovery} <- Discovery.scan(options.checkout_root, options.github_owner),
         :ok <- maybe_write_report(options.output, discovery) do
      {:ok, discovery}
    end
  end

  def dispatch(["inventory" | args]) do
    with {:ok, options, []} <- options(["inventory"], args),
         {:ok, registry} <- load_bound_registry(options),
         {:ok, rows} <- Inventory.scan_registry(registry),
         report = Inventory.summary(rows),
         :ok <- maybe_write_report(options.output, report) do
      {:ok, report}
    end
  end

  def dispatch(["doctor" | args]) do
    with {:ok, options, []} <- options(["doctor"], args),
         {:ok, registry} <- load_bound_registry(options) do
      report = Doctor.inspect(registry)
      if report.healthy, do: {:ok, report}, else: {:error, {:unhealthy_workspace, report}}
    end
  end

  def dispatch(["plan" | args]) do
    with {:ok, options, []} <- options(["plan"], args),
         {:ok, registry, decided} <- resolve_target(options) do
      resolution = decided.closure

      {:ok,
       %{
         schema: "mix_workspace_ops.plan/v2",
         target: options.project,
         registry_digest: registry.digest,
         selection_digest: Registry.selection_digest(registry),
         graph_digest: resolution.digest,
         mix_env: resolution.mix_env,
         mix_target: resolution.mix_target,
         sets: Registry.sets(registry),
         mode: options.mode,
         publish: decided.publish?,
         projects: Enum.map(resolution.projects, & &1.id),
         edges: resolution.edges,
         dependency_applications: resolution.dependency_applications,
         external_dependencies: resolution.external_dependencies,
         known_unselected: known_unselected(resolution),
         sources: Resolution.sources(decided)
       }}
    end
  end

  def dispatch(["sources" | args]) do
    with {:ok, options, []} <- options(["sources"], args),
         {:ok, registry, decided} <- resolve_target(options) do
      entries = Resolution.sources(decided)

      {:ok,
       %{
         schema: "mix_workspace_ops.sources/v1",
         target: options.project,
         registry_digest: registry.digest,
         selection_digest: Registry.selection_digest(registry),
         sets: Registry.sets(registry),
         mode: options.mode,
         publish: decided.publish?,
         mix_env: decided.mix_env,
         mix_target: decided.mix_target,
         sources: entries,
         report: Resolution.format_sources(entries)
       }}
    end
  end

  def dispatch(["why" | args]) do
    with {:ok, options, [application]} <- options(["why"], args),
         {:ok, registry} <- load_bound_registry(options),
         {:ok, project} <- project_here(registry, options.project),
         :ok <- ensure_project_in_view(registry, %{options | project: project}),
         {:ok, explanation} <-
           Resolution.why(registry, project, application, probe_memo: ProbeMemo.new()) do
      {:ok, explanation}
    else
      {:ok, _options, positional} ->
        {:usage_error, "why expects exactly one application, got #{inspect(positional)}"}

      error ->
        error
    end
  end

  def dispatch(["use" | args]) do
    with {:ok, options, positional} <- options(["use"], args),
         {:ok, registry} <- load_bound_registry(options),
         {:ok, project} <- project_here(registry, options.project),
         project_root <- Registry.project_root(registry, project),
         {:ok, path} <- use_override(project_root, options.clear, positional) do
      {:ok, %{schema: "mix_workspace_ops.use/v1", project: project, path: path}}
    end
  end

  def dispatch(["seam" | args]) do
    with {:ok, options, []} <- options(["seam"], args),
         :ok <- require_option(options, :project),
         {:ok, registry} <- load_bound_registry(options),
         :ok <- ensure_project_in_view(registry, options),
         {:ok, decided} <-
           Resolution.resolve(registry, options.project,
             publish?: true,
             mix_env: options.mix_env,
             mix_target: options.mix_target,
             probe_memo: ProbeMemo.new()
           ),
         {:ok, lines} <- Resolution.seam_lines(decided) do
      {:ok,
       %{
         schema: "mix_workspace_ops.seam/v1",
         target: options.project,
         registry_digest: registry.digest,
         selection_digest: Registry.selection_digest(registry),
         mix_env: decided.mix_env,
         mix_target: decided.mix_target,
         lines: lines,
         report: Resolution.format_seam(lines)
       }}
    end
  end

  def dispatch(["state", "list" | args]) do
    with {:ok, options, []} <- options(["state", "list"], args) do
      Runtime.list(options.state_root)
    else
      {:ok, _options, positional} ->
        {:usage_error, "state list expects no arguments, got #{inspect(positional)}"}

      error ->
        error
    end
  end

  def dispatch(["state", "gc" | args]) do
    with {:ok, options, []} <- options(["state", "gc"], args),
         :ok <- require_option(options, :older_than),
         {:ok, older_than} <- Runtime.parse_age(options.older_than) do
      Runtime.gc(options.state_root, older_than, dry_run: options.dry_run)
    else
      {:ok, _options, positional} ->
        {:usage_error, "state gc expects no arguments, got #{inspect(positional)}"}

      error ->
        error
    end
  end

  def dispatch(["run" | args]) do
    with {:ok, option_args, command} <- split_command(args),
         {:ok, options, []} <- options(["run"], option_args),
         :ok <- require_option(options, :project),
         :ok <- require_command(command),
         :ok <- require_safe_run_command(command),
         {:ok, registry} <- load_bound_registry(options),
         :ok <- ensure_project_in_view(registry, options),
         {:ok, mode} <- source_mode(options.mode),
         {:ok, sources} <- source_overrides(options.source),
         {:ok, mix_state} <- mix_state(options.mix_state) do
      project_root = Registry.project_root(registry, options.project)

      Overlay.with_activation(
        registry,
        options.project,
        [
          mode: mode,
          sources: sources,
          publish?: PublishMode.publish?(PublishMode.task_argv(command)),
          mix_env: options.mix_env,
          mix_target: options.mix_target,
          allow_lock_mutation: options.allow_lock_mutation,
          mix_state: mix_state,
          probe_memo: ProbeMemo.new(),
          state_root: options.state_root
        ],
        fn source_report, env -> run_command(command, project_root, source_report, env) end
      )
    end
  end

  def dispatch(["release", "publish" | args]) do
    with {:ok, options, []} <- options(["release", "publish"], args),
         :ok <- require_option(options, :descriptor),
         {:ok, plan} <- Descriptor.load(options.descriptor) do
      Transaction.run(plan, LocalAdapter, state_root: options.state_root)
    end
  end

  def dispatch(args), do: {:usage_error, "unknown command: #{Enum.join(args, " ")} "}

  # `plan` and `sources` differ in what they project, not in what they decide.
  defp resolve_target(options) do
    with :ok <- require_option(options, :project),
         {:ok, registry} <- load_bound_registry(options),
         :ok <- ensure_project_in_view(registry, options),
         {:ok, mode} <- source_mode(options.mode),
         {:ok, sources} <- source_overrides(options.source),
         {:ok, publish?} <- publish_option(Map.get(options, :as_publish)),
         memo <- ProbeMemo.new(),
         {:ok, decided} <-
           Resolution.resolve(registry, options.project,
             mode: resolution_mode(mode),
             sources: sources,
             publish?: publish?,
             mix_env: options.mix_env,
             mix_target: options.mix_target,
             probe_memo: memo
           ) do
      {:ok, registry, decided}
    end
  end

  defp resolution_mode(:auto), do: nil
  defp resolution_mode(:git), do: "github"
  defp resolution_mode(mode), do: to_string(mode)

  # A projection, not an assertion. Publish mode is read from the command that is
  # about to run and is never something an operator requests; `--as-publish`
  # asks a report what publishing *would* resolve to, which is a different
  # question and now reads like one.
  defp publish_option(nil), do: {:ok, false}
  defp publish_option("true"), do: {:ok, true}
  defp publish_option("false"), do: {:ok, false}

  defp publish_option(value),
    do: {:usage_error, "--as-publish expects true or false, got #{value}"}

  defp load_bound_registry(options) do
    with :ok <- require_options(options, [:registry, :checkout_root]),
         {:ok, registry} <- Registry.load(options.registry),
         {:ok, registry} <- select_view(registry, options.view) do
      Registry.bind(registry, options.checkout_root, binding_file: options.binding)
    end
  end

  defp select_view(registry, nil), do: {:ok, registry}

  defp select_view(registry, view_path) do
    with {:ok, view} <- View.load(view_path),
         {:ok, projects} <- View.select(registry, view) do
      {:ok, Registry.select(registry, projects)}
    end
  end

  defp ensure_project_in_view(_registry, %{view: nil}), do: :ok

  defp ensure_project_in_view(registry, options) do
    if Registry.selected?(registry, options.project),
      do: :ok,
      else: {:error, {:project_outside_view, options.project, options.view}}
  end

  defp project_here(_registry, project) when is_binary(project), do: {:ok, project}

  defp project_here(registry, nil) do
    cwd = File.cwd!()

    registry
    |> Registry.selected_projects()
    |> Enum.flat_map(fn project ->
      case Registry.checkout(registry, project.repository) do
        {:bound, root} -> [{project, root |> Path.join(project.path) |> Path.expand()}]
        _absent -> []
      end
    end)
    |> Enum.filter(fn {_project, root} ->
      cwd == root or String.starts_with?(cwd, root <> "/")
    end)
    |> Enum.max_by(fn {_project, root} -> byte_size(root) end, fn -> nil end)
    |> case do
      {project, _root} -> {:ok, project.id}
      nil -> {:usage_error, "cannot infer the current project; pass --project ID"}
    end
  end

  defp options(command, args) do
    accepted = Map.fetch!(@accepted, command)

    with {:ok, options, positional} <-
           parse_options(
             args,
             command,
             MapSet.new(accepted),
             Map.new(accepted, &{&1, default(&1)}),
             []
           ),
         {:ok, options} <- normalize_paths(options),
         {:ok, options} <- OperatorPaths.resolve(options, accepted) do
      {:ok, options, positional}
    end
  end

  defp default(:mode), do: "auto"
  defp default(:mix_env), do: "dev"
  defp default(:mix_target), do: "host"
  defp default(:source), do: []
  defp default(:mix_state), do: "managed"
  defp default(:state_root), do: default_state_root()
  defp default(:allow_lock_mutation), do: false
  defp default(:clear), do: false
  defp default(:dry_run), do: false
  defp default(_key), do: nil

  defp parse_options([], _command, _accepted, options, positional),
    do: {:ok, options, Enum.reverse(positional)}

  defp parse_options(["--" <> option | rest], command, accepted, options, positional)
       when option in ["allow-lock-mutation", "clear", "dry-run"] do
    with {:ok, key} <- option_key(command, accepted, option),
         true <- key in @switch_options do
      parse_options(rest, command, accepted, Map.put(options, key, true), positional)
    else
      false -> {:usage_error, "option --#{option} requires a value"}
      {:error, reason} -> {:usage_error, reason}
    end
  end

  defp parse_options(["--" <> option, value | rest], command, accepted, options, positional) do
    with {:ok, key} <- option_key(command, accepted, option),
         false <- String.starts_with?(value, "--") do
      parse_options(rest, command, accepted, put_option(options, key, value), positional)
    else
      true -> {:usage_error, "option --#{option} requires a value"}
      {:error, reason} -> {:usage_error, reason}
    end
  end

  defp parse_options(["--" <> option], _command, _accepted, _options, _positional),
    do: {:usage_error, "option --#{option} requires a value"}

  defp parse_options([argument | rest], command, accepted, options, positional),
    do: parse_options(rest, command, accepted, options, [argument | positional])

  # One `--source` names one dependency, so it is the one option a command may
  # carry more than once.
  defp put_option(options, :source, value),
    do: Map.update(options, :source, [value], &(&1 ++ [value]))

  defp put_option(options, key, value), do: Map.put(options, key, value)

  defp normalize_paths(options) do
    path_keys = [
      :registry,
      :checkout_root,
      :binding,
      :view,
      :state_root,
      :output,
      :descriptor,
      :guide
    ]

    normalized =
      Enum.reduce(path_keys, options, fn key, acc ->
        Map.update(acc, key, nil, fn
          nil -> nil
          path -> Path.expand(path)
        end)
      end)

    {:ok, normalized}
  end

  defp split_command(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_options, []} -> {:usage_error, "run requires -- followed by a command"}
      {options, ["--" | command]} -> {:ok, options, command}
    end
  end

  # An option no command takes is unknown; an option another command takes is
  # named against the command that does not.
  defp option_key(command, accepted, option) do
    case Enum.find(@vocabulary, &(option_name(&1) == option)) do
      nil ->
        {:error, "unknown option --#{option}"}

      key ->
        if MapSet.member?(accepted, key),
          do: {:ok, key},
          else: {:error, "#{Enum.join(command, " ")} does not accept --#{option}"}
    end
  end

  defp require_options(options, keys) do
    Enum.reduce_while(keys, :ok, fn key, :ok ->
      case require_option(options, key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp require_option(options, key) do
    if Map.get(options, key), do: :ok, else: {:usage_error, "missing --#{option_name(key)}"}
  end

  defp option_name(key), do: key |> to_string() |> String.replace("_", "-")

  defp workspaces(registry, nil) do
    {:ok, Enum.map(Registry.workspaces(registry), &workspace_row/1)}
  end

  defp workspaces(registry, repository_id) do
    with {:ok, repository} <- fetch_repository(registry, repository_id),
         {:ok, members} <- Registry.workspace_members(registry, repository) do
      {:ok, [workspace_row({repository, members})]}
    end
  end

  defp fetch_repository(registry, repository_id) do
    case Map.fetch(registry.repositories, repository_id) do
      {:ok, repository} -> {:ok, repository}
      :error -> {:error, {:unknown_repository, repository_id}}
    end
  end

  defp workspace_row({repository, members}) do
    %{
      repository: repository.id,
      kind: repository.workspace.kind,
      projects: length(repository.projects),
      members: Enum.map(members, & &1.id),
      include_project_ids: repository.workspace.include_project_ids,
      exclude_project_ids: repository.workspace.exclude_project_ids
    }
  end

  defp known_unselected(resolution) do
    Enum.map(resolution.known_unselected, fn {consumer, application, candidates} ->
      %{consumer: consumer, application: application, candidates: candidates}
    end)
  end

  defp multiply_provided(registry) do
    Enum.count(registry.applications, fn {_app, projects} -> length(projects) > 1 end)
  end

  defp languages(registry) do
    registry.repositories
    |> Map.values()
    |> Enum.flat_map(& &1.languages)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp require_command([]), do: {:usage_error, "empty command"}
  defp require_command(_command), do: :ok

  # A guard reading argv position 2 refused `mix hex.publish` and let
  # `mix do compile, hex.publish` and `elixir -S mix hex.publish` past, while the
  # parser beside it read every one of them correctly. It is the same parser now.
  #
  # This refusal is a user-error check on a task name and not a boundary, because
  # a name is not a capability: publication is kept safe by the seam refusing a
  # development overlay when one is read and by credentials reaching only the
  # release transaction's publishing step.
  defp require_safe_run_command(command) do
    command
    |> PublishMode.task_argv()
    |> PublishMode.task_tokens()
    |> Enum.find(&(&1 in @refused_run_tasks))
    |> case do
      nil -> :ok
      task -> {:usage_error, "#{task} publishes; run it through the release transaction"}
    end
  end

  defp source_mode("auto"), do: {:ok, :auto}
  defp source_mode("local"), do: {:ok, :local}
  defp source_mode("git"), do: {:ok, :git}
  defp source_mode("hex"), do: {:ok, :hex}
  defp source_mode(mode), do: {:usage_error, "invalid source mode #{inspect(mode)}"}

  defp source_overrides(requested) do
    Enum.reduce_while(requested, {:ok, %{}}, fn assignment, {:ok, acc} ->
      case source_override(assignment) do
        {:ok, application, source} -> {:cont, {:ok, Map.put(acc, application, source)}}
        {:usage_error, reason} -> {:halt, {:usage_error, reason}}
      end
    end)
  end

  defp source_override(assignment) do
    case String.split(assignment, "=", parts: 2) do
      [application, source] when application != "" -> named_source(application, source)
      _parts -> {:usage_error, "--source expects APP=SOURCE, got #{inspect(assignment)}"}
    end
  end

  defp named_source(application, source) do
    case source_name(source) do
      {:ok, name} -> {:ok, application, name}
      :error -> {:usage_error, "invalid source #{inspect(source)}"}
    end
  end

  defp use_override(project_root, false, [application, source]) do
    case source_name(source) do
      {:ok, normalized} -> LocalOverrides.put(project_root, application, normalized)
      :error -> {:usage_error, "invalid source #{inspect(source)}"}
    end
  end

  defp use_override(project_root, true, []), do: LocalOverrides.clear(project_root)

  defp use_override(project_root, true, [application]),
    do: LocalOverrides.clear(project_root, application)

  defp use_override(_project_root, clear?, positional),
    do: {:usage_error, "invalid use arguments with clear=#{clear?}: #{inspect(positional)}"}

  defp source_name("local"), do: {:ok, "local"}
  defp source_name("git"), do: {:ok, "github"}
  defp source_name("github"), do: {:ok, "github"}
  defp source_name("hex"), do: {:ok, "hex"}
  defp source_name(_source), do: :error

  defp mix_state("managed"), do: {:ok, :managed}
  defp mix_state("delegated"), do: {:ok, :delegated}
  defp mix_state(mode), do: {:usage_error, "invalid Mix-state ownership #{inspect(mode)}"}

  defp run_command([executable | argv], project_root, source_report, env) do
    case Command.run(executable, argv, cd: project_root, env: env) do
      {:ok, command_result} -> {:ok, %{source: source_report, command: command_result}}
      {:error, command_result} -> {:error, {:command_failed, command_result}}
    end
  end

  defp maybe_write_report(nil, _report), do: :ok
  defp maybe_write_report(path, report), do: Report.write(path, report)

  # A typed error is what one function hands another; a sentence is what an
  # operator reads. Where resolution can say what happened in words, it does, and
  # the tuple follows so nothing is lost for a caller reading the output.
  defp format_error({:unhealthy_workspace, report}), do: Report.encode(report)

  defp format_error(reason) do
    case Resolution.explain(reason) do
      nil -> inspect(reason, pretty: true, limit: :infinity)
      sentence -> sentence <> "\n  " <> inspect(reason, limit: :infinity)
    end
  end

  defp default_state_root do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(base, "mix_workspace_ops")
  end

  defp usage(status \\ 0) do
    IO.puts(@usage)
    status
  end
end
