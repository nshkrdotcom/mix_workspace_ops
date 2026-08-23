defmodule MixWorkspaceOps.CLI do
  @moduledoc false

  alias MixWorkspaceOps.{
    Command,
    Discovery,
    Doctor,
    Graph,
    Inventory,
    Overlay,
    Registry,
    Report,
    View
  }

  alias MixWorkspaceOps.Release.{Descriptor, LocalAdapter, Transaction}

  @spec main([String.t()]) :: no_return()
  def main(args) do
    args
    |> dispatch()
    |> exit_status()
    |> System.halt()
  end

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

  defp dispatch(["version"]) do
    IO.puts(MixWorkspaceOps.version())
    {:ok, nil}
  end

  defp dispatch(["help"]), do: :usage
  defp dispatch([]), do: :usage

  defp dispatch(["registry", "validate" | args]) do
    with {:ok, options, []} <- registry_options(args),
         :ok <- require_option(options, :registry),
         {:ok, registry} <- Registry.load(options.registry) do
      {:ok,
       %{
         schema: Registry.schema(),
         digest: registry.digest,
         repositories: map_size(registry.repositories),
         projects: map_size(registry.projects),
         applications: map_size(registry.applications)
       }}
    end
  end

  defp dispatch(["registry", "select" | args]) do
    with {:ok, options, []} <- registry_options(args),
         :ok <- require_options(options, [:registry, :view]),
         {:ok, registry} <- Registry.load(options.registry),
         {:ok, view} <- View.load(options.view),
         {:ok, repositories} <- View.select_repositories(registry, view),
         {:ok, projects} <- View.select(registry, view) do
      {:ok,
       %{
         schema: "mix_workspace_ops.selection/v2",
         registry_digest: registry.digest,
         view: view.id,
         view_schema: view.schema,
         view_digest: view.digest,
         repositories: Enum.map(repositories, & &1.id),
         projects: Enum.map(projects, & &1.id)
       }}
    end
  end

  defp dispatch(["registry", "discover" | args]) do
    with {:ok, options, []} <-
           parse_options(args, checkout_root: nil, github_owner: nil, output: nil),
         :ok <- require_options(options, [:checkout_root, :github_owner]),
         {:ok, discovery} <- Discovery.scan(options.checkout_root, options.github_owner),
         :ok <- maybe_write_report(options.output, discovery) do
      {:ok, discovery}
    end
  end

  defp dispatch(["inventory" | args]) do
    with {:ok, options, []} <- registry_options(args, output: nil),
         {:ok, registry} <- load_bound_registry(options),
         {:ok, rows} <- Inventory.scan_registry(registry),
         report = Inventory.summary(rows),
         :ok <- maybe_write_report(options.output, report) do
      {:ok, report}
    end
  end

  defp dispatch(["doctor" | args]) do
    with {:ok, options, []} <- registry_options(args),
         {:ok, registry} <- load_bound_registry(options) do
      report = Doctor.inspect(registry)
      if report.healthy, do: {:ok, report}, else: {:error, {:unhealthy_workspace, report}}
    end
  end

  defp dispatch(["plan" | args]) do
    with {:ok, options, []} <- registry_options(args, project: nil),
         :ok <- require_option(options, :project),
         {:ok, registry} <- load_bound_registry(options),
         :ok <- ensure_project_in_view(registry, options),
         {:ok, resolution} <- Graph.resolve(registry, options.project) do
      {:ok,
       %{
         schema: "mix_workspace_ops.plan/v1",
         target: options.project,
         registry_digest: registry.digest,
         graph_digest: resolution.digest,
         projects: Enum.map(resolution.projects, & &1.id),
         edges: resolution.edges,
         external_dependencies: resolution.external_dependencies
       }}
    end
  end

  defp dispatch(["run" | args]) do
    with {:ok, option_args, command} <- split_command(args),
         {:ok, options, []} <-
           registry_options(option_args, project: nil, mode: "local", mix_state: "managed"),
         :ok <- require_option(options, :project),
         :ok <- require_command(command),
         :ok <- require_safe_run_command(command),
         {:ok, registry} <- load_bound_registry(options),
         :ok <- ensure_project_in_view(registry, options),
         {:ok, mode} <- source_mode(options.mode),
         {:ok, mix_state} <- mix_state(options.mix_state) do
      project_root = Registry.project_root(registry, options.project)

      Overlay.with_activation(
        registry,
        options.project,
        [mode: mode, mix_state: mix_state, state_root: options.state_root],
        fn source_report, env -> run_command(command, project_root, source_report, env) end
      )
    end
  end

  defp dispatch(["release", "publish" | args]) do
    with {:ok, options, []} <-
           parse_options(args, descriptor: nil, state_root: default_state_root()),
         :ok <- require_option(options, :descriptor),
         {:ok, plan} <- Descriptor.load(options.descriptor) do
      Transaction.run(plan, LocalAdapter, state_root: options.state_root)
    end
  end

  defp dispatch(args), do: {:usage_error, "unknown command: #{Enum.join(args, " ")} "}

  defp load_bound_registry(options) do
    with :ok <- require_options(options, [:registry, :checkout_root]),
         {:ok, registry} <- Registry.load(options.registry),
         {:ok, registry} <- restrict_to_view(registry, options.view) do
      Registry.bind(registry, options.checkout_root, binding_file: options.binding)
    end
  end

  defp restrict_to_view(registry, nil), do: {:ok, registry}

  defp restrict_to_view(registry, view_path) do
    with {:ok, view} <- View.load(view_path),
         {:ok, projects} <- View.select(registry, view) do
      {:ok, Registry.restrict(registry, projects)}
    end
  end

  defp ensure_project_in_view(_registry, %{view: nil}), do: :ok

  defp ensure_project_in_view(registry, options) do
    if Map.has_key?(registry.projects, options.project),
      do: :ok,
      else: {:error, {:project_outside_view, options.project, options.view}}
  end

  defp registry_options(args, defaults \\ []) do
    defaults =
      Keyword.merge(
        [
          registry: nil,
          checkout_root: nil,
          binding: nil,
          view: nil,
          state_root: default_state_root()
        ],
        defaults
      )

    parse_options(args, defaults)
  end

  defp parse_options(args, defaults) do
    args
    |> parse_options(Map.new(defaults), [])
    |> normalize_paths()
  end

  defp parse_options([], options, positional), do: {:ok, options, Enum.reverse(positional)}

  defp parse_options(["--" <> option, value | rest], options, positional) do
    with {:ok, key} <- option_key(option),
         false <- String.starts_with?(value, "--") do
      parse_options(rest, Map.put(options, key, value), positional)
    else
      true -> {:usage_error, "option --#{option} requires a value"}
      {:error, reason} -> {:usage_error, reason}
    end
  end

  defp parse_options(["--" <> option], _options, _positional),
    do: {:usage_error, "option --#{option} requires a value"}

  defp parse_options([argument | rest], options, positional),
    do: parse_options(rest, options, [argument | positional])

  defp normalize_paths({:ok, options, rest}) do
    path_keys = [:registry, :checkout_root, :binding, :view, :state_root, :output, :descriptor]

    normalized =
      Enum.reduce(path_keys, options, fn key, acc ->
        Map.update(acc, key, nil, fn
          nil -> nil
          path -> Path.expand(path)
        end)
      end)

    {:ok, normalized, rest}
  end

  defp normalize_paths(error), do: error

  defp split_command(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_options, []} -> {:usage_error, "run requires -- followed by a command"}
      {options, ["--" | command]} -> {:ok, options, command}
    end
  end

  defp option_key("registry"), do: {:ok, :registry}
  defp option_key("checkout-root"), do: {:ok, :checkout_root}
  defp option_key("binding"), do: {:ok, :binding}
  defp option_key("view"), do: {:ok, :view}
  defp option_key("state-root"), do: {:ok, :state_root}
  defp option_key("project"), do: {:ok, :project}
  defp option_key("mode"), do: {:ok, :mode}
  defp option_key("mix-state"), do: {:ok, :mix_state}
  defp option_key("output"), do: {:ok, :output}
  defp option_key("github-owner"), do: {:ok, :github_owner}
  defp option_key("descriptor"), do: {:ok, :descriptor}
  defp option_key(option), do: {:error, "unknown option --#{option}"}

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
  defp require_command([]), do: {:usage_error, "empty command"}
  defp require_command(_command), do: :ok

  defp require_safe_run_command([executable, task | _arguments]) do
    if Path.basename(executable) == "mix" and task in ["hex.publish", "deps.publish_preflight"] do
      {:usage_error, "#{task} is available only through the fail-closed release transaction"}
    else
      :ok
    end
  end

  defp require_safe_run_command(_command), do: :ok

  defp source_mode("local"), do: {:ok, :local}
  defp source_mode("git"), do: {:ok, :git}
  defp source_mode("hex"), do: {:ok, :hex}
  defp source_mode(mode), do: {:usage_error, "invalid source mode #{inspect(mode)}"}

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

  defp format_error({:unhealthy_workspace, report}), do: Report.encode(report)
  defp format_error(reason), do: inspect(reason, pretty: true, limit: :infinity)

  defp default_state_root do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(base, "mix_workspace_ops")
  end

  defp usage(status \\ 0) do
    IO.puts("""
    mix_workspace_ops <command>

      version
      registry validate --registry PATH
      registry select --registry PATH --view PATH
      registry discover --checkout-root PATH --github-owner OWNER [--output PATH]
      inventory --registry PATH --checkout-root PATH [--view PATH] [--binding PATH] [--output PATH]
      doctor --registry PATH --checkout-root PATH [--view PATH] [--binding PATH]
      plan --project ID --registry PATH --checkout-root PATH [--view PATH]
      run --project ID --mode local|git|hex --mix-state managed|delegated \\
        --registry PATH --checkout-root PATH -- COMMAND [ARG ...]
      release publish --descriptor PATH [--state-root PATH]
      help
    """)

    status
  end
end
