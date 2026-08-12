defmodule MixWorkspaceOps.Overlay do
  @moduledoc "Content-addressed, operator-owned source overlays activated only in child processes."

  alias MixWorkspaceOps.{Git, Graph, Registry}

  @env "MIX_WORKSPACE_OPS_OVERLAY"
  @header "mix_workspace_ops.overlay/v1"

  @type activation :: %{
          path: String.t() | nil,
          env: [{String.t(), String.t() | nil}],
          report: map()
        }

  @spec environment_variable() :: String.t()
  def environment_variable, do: @env

  @spec activate(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, activation()} | {:error, term()}
  def activate(registry, target, opts \\ []) do
    mode = Keyword.get(opts, :mode, :local)
    state_root = Keyword.get_lazy(opts, :state_root, &default_state_root/0)

    with {:ok, resolution} <- Graph.resolve(registry, target),
         {:ok, rows} <- source_rows(registry, resolution.projects, mode),
         contents <- contents(registry, to_string(target), mode, resolution, rows),
         digest <- digest(contents),
         {:ok, path} <- materialize(state_root, digest, contents, mode) do
      env = [{@env, path}]

      {:ok,
       %{
         path: path,
         env: env,
         report: %{
           schema: @header,
           target: to_string(target),
           mode: mode,
           registry_digest: registry.digest,
           graph_digest: resolution.digest,
           overlay_digest: digest,
           overlay_path: path,
           projects: Enum.map(resolution.projects, & &1.id),
           edges: resolution.edges,
           external_dependencies: resolution.external_dependencies,
           rows: rows
         }
       }}
    end
  end

  @spec with_activation(Registry.t(), String.t() | atom(), keyword(), (map(), list() -> result)) ::
          result
        when result: term()
  def with_activation(registry, target, opts \\ [], function) when is_function(function, 2) do
    case activate(registry, target, opts) do
      {:ok, activation} -> function.(activation.report, activation.env)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(path) do
    with true <- Path.type(path) == :absolute || {:error, :overlay_path_must_be_absolute},
         {:ok, bytes} <- File.read(path) do
      parse(bytes)
    end
  end

  @spec active() :: {:ok, map()} | :inactive | {:error, term()}
  def active do
    case System.get_env(@env) do
      nil -> :inactive
      "" -> :inactive
      path -> read(path)
    end
  end

  defp source_rows(registry, projects, :local) do
    projects
    |> Enum.map(fn project ->
      path = Registry.project_root(registry, project)

      if File.regular?(Path.join(path, "mix.exs")) do
        {:ok, [project.app, "path", path, Git.head!(path)]}
      else
        {:error, {:missing_mix_project, project.id, path}}
      end
    end)
    |> collect_rows()
  end

  defp source_rows(registry, projects, :git) do
    projects
    |> Enum.map(fn project ->
      repository = Registry.repository!(registry, project.repository)
      root = Registry.repository_root(registry, repository.id)
      url = "https://github.com/#{repository.github}.git"
      {:ok, [project.app, "git", url, Git.head!(root), project.path]}
    end)
    |> collect_rows()
  end

  defp source_rows(_registry, _projects, :hex), do: {:ok, []}
  defp source_rows(_registry, _projects, mode), do: {:error, {:unsupported_source_mode, mode}}

  defp collect_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      {:ok, row}, {:ok, acc} -> {:cont, {:ok, [row | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> then(fn
      {:ok, collected} -> {:ok, Enum.reverse(collected)}
      error -> error
    end)
  end

  defp contents(registry, target, mode, resolution, rows) do
    metadata = [
      @header,
      "registry_digest\t#{registry.digest}",
      "graph_digest\t#{resolution.digest}",
      "target\t#{target}",
      "mode\t#{mode}"
    ]

    (metadata ++ Enum.map(rows, &Enum.join(&1, "\t")))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp materialize(_state_root, _digest, _contents, :hex), do: {:ok, nil}

  defp materialize(state_root, digest, contents, _mode) do
    directory = state_root |> Path.expand() |> Path.join("overlays")
    path = Path.join(directory, digest <> ".tsv")
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         :ok <- write_if_absent(path, temporary, contents),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    end
  end

  defp write_if_absent(path, temporary, contents) do
    case File.read(path) do
      {:ok, ^contents} -> :ok
      {:ok, _other} -> {:error, {:overlay_digest_collision, path}}
      {:error, :enoent} -> atomic_write(path, temporary, contents)
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_write(path, temporary, contents) do
    with :ok <- File.write(temporary, contents, [:sync]) do
      File.rename(temporary, path)
    end
  end

  defp parse(bytes) do
    case String.split(bytes, "\n", trim: true) do
      [
        @header,
        "registry_digest\t" <> registry_digest,
        "graph_digest\t" <> graph_digest,
        "target\t" <> target,
        "mode\t" <> mode | rows
      ]
      when mode in ["local", "git"] ->
        with {:ok, sources} <- parse_rows(rows) do
          {:ok,
           %{
             schema: @header,
             registry_digest: registry_digest,
             graph_digest: graph_digest,
             target: target,
             mode: mode,
             digest: digest(bytes),
             sources: sources
           }}
        end

      _lines ->
        {:error, :invalid_overlay}
    end
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, %{}}, fn row, {:ok, sources} ->
      case parse_row(row) do
        {:ok, {app, source}} when not is_map_key(sources, app) ->
          {:cont, {:ok, Map.put(sources, app, source)}}

        {:ok, {app, _source}} ->
          {:halt, {:error, {:duplicate_overlay_application, app}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_row(row) do
    case String.split(row, "\t") do
      [app, "path", path, revision] ->
        {:ok, {app, %{kind: :path, path: path, revision: revision}}}

      [app, "git", url, revision, subdir] ->
        {:ok, {app, %{kind: :git, url: url, revision: revision, subdir: subdir}}}

      _parts ->
        {:error, {:invalid_overlay_row, row}}
    end
  end

  defp default_state_root do
    base = System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state")
    Path.join(base, "mix_workspace_ops")
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
