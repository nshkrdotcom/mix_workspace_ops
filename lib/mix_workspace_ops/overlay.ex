defmodule MixWorkspaceOps.Overlay do
  @moduledoc "Content-addressed, operator-owned source overlays activated only in child processes."

  alias MixWorkspaceOps.{Bootstrap, Git, Graph, Registry, Runtime}

  @env "MIX_WORKSPACE_OPS_OVERLAY"
  @context_env "MIX_WORKSPACE_OPS_CONTEXT_DIGEST"
  @header "mix_workspace_ops.overlay/v1"
  @maximum_bytes 16 * 1024 * 1024

  @type activation :: %{
          path: String.t() | nil,
          env: [{String.t(), String.t() | nil}],
          report: map()
        }

  @spec environment_variable() :: String.t()
  def environment_variable, do: @env

  @doc "Returns the subprocess variable carrying the path-independent source context."
  @spec context_environment_variable() :: String.t()
  def context_environment_variable, do: @context_env

  @spec activate(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, activation()} | {:error, term()}
  def activate(registry, target, opts \\ []) do
    mode = Keyword.get(opts, :mode, :local)
    mix_state = Keyword.get(opts, :mix_state, :managed)
    state_root = Keyword.get_lazy(opts, :state_root, &default_state_root/0)

    with {:ok, resolution} <- Graph.resolve(registry, target),
         {:ok, rows} <- source_rows(registry, resolution.projects, mode),
         target_project <- Registry.project!(registry, target),
         target_root <- Registry.project_root(registry, target_project),
         {:ok, lock_bytes} <- source_lock(target_root),
         context <-
           context_contents(
             registry,
             to_string(target),
             mode,
             resolution,
             rows,
             target_project,
             lock_bytes
           ),
         context_digest <- digest(context),
         contents <-
           contents(
             registry,
             to_string(target),
             mode,
             resolution,
             rows,
             target_root,
             lock_bytes,
             context_digest
           ),
         overlay_digest <- digest(contents),
         {:ok, path} <- materialize(state_root, overlay_digest, contents, mode),
         {:ok, bootstrap_path} <- Bootstrap.materialize(state_root),
         {:ok, runtime} <- prepare_runtime(mix_state, state_root, context_digest, lock_bytes) do
      env =
        [
          {Bootstrap.environment_variable(), bootstrap_path},
          {@env, path},
          {@context_env, context_digest}
          | runtime.env
        ]

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
           overlay_digest: overlay_digest,
           context_digest: context_digest,
           overlay_path: path,
           bootstrap_path: bootstrap_path,
           runtime: runtime.report,
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
         {:ok, stat} <- File.stat(path),
         true <- stat.type == :regular || {:error, :overlay_must_be_regular},
         true <- stat.size <= @maximum_bytes || {:error, :overlay_too_large},
         {:ok, bytes} <- File.read(path),
         :ok <- verify_content_address(path, bytes) do
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
    |> Enum.reject(&is_nil(&1.app))
    |> Enum.map(fn project ->
      path = Registry.project_root(registry, project)

      if File.regular?(Path.join(path, "mix.exs")) do
        {:ok, [project.app, "path", path, Git.head!(path), Git.source_digest(path)]}
      else
        {:error, {:missing_mix_project, project.id, path}}
      end
    end)
    |> collect_rows()
  end

  defp source_rows(registry, projects, :git) do
    projects
    |> Enum.reject(&is_nil(&1.app))
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

  defp contents(
         registry,
         target,
         mode,
         resolution,
         rows,
         target_root,
         lock_bytes,
         context_digest
       ) do
    metadata = [
      @header,
      "registry_digest\t#{registry.digest}",
      "graph_digest\t#{resolution.digest}",
      "context_digest\t#{context_digest}",
      "target\t#{target}",
      "mode\t#{mode}",
      "target_head\t#{Git.head!(target_root)}",
      "target_source_digest\t#{Git.source_digest(target_root)}",
      "lock_digest\t#{digest(lock_bytes)}",
      "toolchain\telixir-#{System.version()}-otp-#{:erlang.system_info(:otp_release)}"
    ]

    (metadata ++ Enum.map(rows, &Enum.join(&1, "\t")))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp context_contents(
         registry,
         target,
         mode,
         resolution,
         rows,
         target_project,
         lock_bytes
       ) do
    target_repository = Registry.repository!(registry, target_project.repository)

    metadata = [
      "mix_workspace_ops.context/v1",
      "graph_digest\t#{resolution.digest}",
      "target\t#{target}",
      "mode\t#{mode}",
      "target_repository\t#{target_repository.github}",
      "target_project_path\t#{target_project.path}",
      "lock_digest\t#{digest(lock_bytes)}",
      "toolchain\telixir-#{System.version()}-otp-#{:erlang.system_info(:otp_release)}"
    ]

    sources =
      Enum.map(rows, fn [app | _rest] = row ->
        {:ok, project} = Registry.project_for_app(registry, app)
        semantic_source(registry, project, row, target_project.repository)
      end)

    (metadata ++ sources)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp semantic_source(registry, project, [app, kind | _rest], target_repository)
       when project.repository == target_repository do
    repository = Registry.repository!(registry, project.repository)
    Enum.join(["source", app, kind, repository.github, project.path, "target-repository"], "\t")
  end

  defp semantic_source(
         registry,
         project,
         [app, "path", _path, revision, source_digest],
         _target_repository
       ) do
    repository = Registry.repository!(registry, project.repository)

    Enum.join(
      ["source", app, "path", repository.github, project.path, revision, source_digest],
      "\t"
    )
  end

  defp semantic_source(
         registry,
         project,
         [app, "git", _url, revision, subdir],
         _target_repository
       ) do
    repository = Registry.repository!(registry, project.repository)
    Enum.join(["source", app, "git", repository.github, project.path, revision, subdir], "\t")
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
        "context_digest\t" <> context_digest,
        "target\t" <> target,
        "mode\t" <> mode,
        "target_head\t" <> target_head,
        "target_source_digest\t" <> target_source_digest,
        "lock_digest\t" <> lock_digest,
        "toolchain\t" <> toolchain | rows
      ]
      when mode in ["local", "git"] ->
        with {:ok, sources} <- parse_rows(rows) do
          {:ok,
           %{
             schema: @header,
             registry_digest: registry_digest,
             graph_digest: graph_digest,
             context_digest: context_digest,
             target: target,
             mode: mode,
             target_head: target_head,
             target_source_digest: target_source_digest,
             lock_digest: lock_digest,
             toolchain: toolchain,
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
      [app, "path", path, revision, source_digest] ->
        {:ok, {app, %{kind: :path, path: path, revision: revision, source_digest: source_digest}}}

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

  defp prepare_runtime(:managed, state_root, digest, lock_bytes),
    do: Runtime.prepare(state_root, digest, lock_bytes)

  defp prepare_runtime(:delegated, _state_root, digest, _lock_bytes),
    do: Runtime.delegated(digest)

  defp prepare_runtime(mode, _state_root, _digest, _lock_bytes),
    do: {:error, {:unsupported_mix_state, mode}}

  defp source_lock(project_root) do
    case File.read(Path.join(project_root, "mix.lock")) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, :enoent} -> {:ok, "%{}\n"}
      {:error, reason} -> {:error, {:source_lock, reason}}
    end
  end

  defp verify_content_address(path, bytes) do
    expected = Path.basename(path, ".tsv")
    actual = digest(bytes)

    if expected == actual, do: :ok, else: {:error, {:overlay_digest_mismatch, expected, actual}}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
