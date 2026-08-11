defmodule MixWorkspaceOps.CLI do
  @moduledoc false

  alias MixWorkspaceOps.{Bootstrap, Catalog, Command, Doctor, Graph, Inventory, Overlay, Report}

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

  defp dispatch(["inventory" | args]) do
    with {:ok, options, []} <- parse_options(args, root: "/home/home/p/g/n", output: nil),
         {:ok, rows} <- Inventory.scan(options.root),
         report = Inventory.summary(rows),
         :ok <- maybe_write_report(options.output, report) do
      {:ok, report}
    end
  end

  defp dispatch(["doctor" | args]) do
    with {:ok, options, []} <- catalog_options(args),
         {:ok, catalog} <- Catalog.load(options.catalog, root: options.root) do
      report = Doctor.inspect(catalog)
      if report.healthy, do: {:ok, report}, else: {:error, {:unhealthy_workspace, report}}
    end
  end

  defp dispatch(["plan" | args]) do
    with {:ok, options, []} <- catalog_options(args, project: nil),
         :ok <- require_option(options, :project),
         {:ok, catalog} <- Catalog.load(options.catalog, root: options.root) do
      projects = Graph.closure(catalog, options.project)

      {:ok,
       %{
         schema: 1,
         target: options.project,
         catalog_digest: catalog.digest,
         projects: Enum.map(projects, & &1.app),
         edges: Graph.edges(catalog)
       }}
    end
  end

  defp dispatch(["run" | args]) do
    with {:ok, option_args, command} <- split_command(args),
         {:ok, options, []} <- catalog_options(option_args, project: nil, mode: "local"),
         :ok <- require_option(options, :project),
         :ok <- require_command(command),
         {:ok, catalog} <- Catalog.load(options.catalog, root: options.root),
         {:ok, mode} <- source_mode(options.mode) do
      project_root = Catalog.project_root(catalog, options.project)

      result =
        Overlay.with_activation(catalog, options.project, [mode: mode], fn source_report ->
          run_command(command, project_root, source_report)
        end)

      result
    end
  end

  defp dispatch(["bootstrap", "install" | args]) do
    with {:ok, options, []} <- catalog_options(args, project: nil),
         :ok <- require_option(options, :project),
         {:ok, catalog} <- Catalog.load(options.catalog, root: options.root),
         project_root = Catalog.project_root(catalog, options.project),
         {:ok, path} <- Bootstrap.install(project_root) do
      {:ok, %{schema: 1, project: options.project, path: path, status: :current}}
    end
  end

  defp dispatch(args), do: {:usage_error, "unknown command: #{Enum.join(args, " ")}"}

  defp catalog_options(args, defaults \\ []) do
    defaults = Keyword.merge([catalog: "workspace.json", root: "/home/home/p/g/n"], defaults)
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
    options =
      options
      |> Map.update(:root, nil, &Path.expand/1)
      |> Map.update(:catalog, nil, fn path -> Path.expand(path, options.root) end)

    {:ok, options, rest}
  end

  defp normalize_paths(error), do: error

  defp split_command(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {_options, []} -> {:usage_error, "run requires -- followed by a command"}
      {options, ["--" | command]} -> {:ok, options, command}
    end
  end

  defp option_key("root"), do: {:ok, :root}
  defp option_key("catalog"), do: {:ok, :catalog}
  defp option_key("project"), do: {:ok, :project}
  defp option_key("mode"), do: {:ok, :mode}
  defp option_key("output"), do: {:ok, :output}
  defp option_key(option), do: {:error, "unknown option --#{option}"}

  defp require_option(options, key) do
    if Map.get(options, key), do: :ok, else: {:usage_error, "missing --#{key}"}
  end

  defp require_command([]), do: {:usage_error, "empty command"}
  defp require_command(_command), do: :ok

  defp source_mode("local"), do: {:ok, :local}
  defp source_mode("git"), do: {:ok, :git}
  defp source_mode("hex"), do: {:ok, :hex}
  defp source_mode(mode), do: {:usage_error, "invalid source mode #{inspect(mode)}"}

  defp run_command([executable | argv], project_root, source_report) do
    case Command.run(executable, argv, cd: project_root) do
      {:ok, command_result} -> {:ok, %{source: source_report, command: command_result}}
      {:error, command_result} -> {:error, {:command_failed, command_result}}
    end
  end

  defp maybe_write_report(nil, _report), do: :ok
  defp maybe_write_report(path, report), do: Report.write(path, report)

  defp format_error({:unhealthy_workspace, report}), do: Report.encode(report)
  defp format_error(reason), do: inspect(reason, pretty: true, limit: :infinity)

  defp usage(status \\ 0) do
    IO.puts("""
    mix_workspace_ops <command>

      version
      inventory [--root PATH] [--output PATH]
      doctor [--catalog PATH] [--root PATH]
      plan --project APP [--catalog PATH] [--root PATH]
      bootstrap install --project APP [--catalog PATH] [--root PATH]
      run --project APP [--mode local|git|hex] [--catalog PATH] [--root PATH] -- COMMAND [ARG ...]
      help
    """)

    status
  end
end
