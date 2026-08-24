defmodule MixWorkspaceOps.Overlay do
  @moduledoc """
  Content-addressed, operator-owned source overlays activated only in child
  processes.

  An overlay carries one row per application, and each row states the source
  that application resolved to and everything the seam needs to emit its Mix
  dependency tuple. `mix_workspace_ops.overlay/v2` replaces the whole-run
  `local | git` mode of v1: resolution is per dependency, so one mode for the
  whole run could not describe it. The header keeps a `mode` line for the run
  mode the operator *requested* — `auto` where they requested nothing — and
  adds a `publish` line, because whether an overlay was decided for publication
  changes what the seam may do with it.

      app \\t local  \\t <absolute path>  \\t <revision> \\t <source digest> \\t <opts>
      app \\t github \\t <owner/repo>     \\t <branch|ref|tag|-> \\t <value|-> \\t <subdir|-> \\t <opts>
      app \\t hex    \\t <requirement>    \\t <opts>

  The header names both digests the rows were decided under. The document digest
  says which catalog was read; the selection digest says which view of it was in
  force. Two views over one catalog decide different rows, so an artifact
  attesting only to the document would give two different overlays one identity.

  `<opts>` is `-` when there are none, and otherwise `key=value` pairs joined
  by `,`, keys in alphabetical order. A boolean value is `true` or `false`; the
  value of `only` or `targets` is its names joined by `|`. Keys convert through
  a fixed table on the way back, and the names under `only` and `targets`
  convert to atoms under the bound `MixWorkspaceOps.Registry.Source` holds them
  to, so no overlay can mint an unbounded number of atoms in a process that
  reads one.
  """

  alias MixWorkspaceOps.{Bootstrap, Git, Graph, Registry, Resolution, Runtime}

  @env "MIX_WORKSPACE_OPS_OVERLAY"
  @context_env "MIX_WORKSPACE_OPS_CONTEXT_DIGEST"
  @header "mix_workspace_ops.overlay/v2"
  @context_header "mix_workspace_ops.context/v2"
  @maximum_bytes 16 * 1024 * 1024
  @modes ~w(auto local git hex)
  @absent "-"

  @option_keys %{
    "only" => :only,
    "optional" => :optional,
    "override" => :override,
    "runtime" => :runtime,
    "targets" => :targets
  }
  @list_options ~w(only targets)
  @revision_keys ~w(branch ref tag)

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

  @doc "The schema identifier this version writes."
  @spec schema() :: String.t()
  def schema, do: @header

  @spec activate(Registry.t(), String.t() | atom(), keyword()) ::
          {:ok, activation()} | {:error, term()}
  def activate(registry, target, opts \\ []) do
    mode = Keyword.get(opts, :mode, :auto)
    mix_state = Keyword.get(opts, :mix_state, :managed)
    state_root = Keyword.get_lazy(opts, :state_root, &default_state_root/0)

    with :ok <- known_mode(mode),
         {:ok, resolution} <- Graph.resolve(registry, target),
         {:ok, decided} <- decide(registry, target, resolution, mode, opts),
         {:ok, attributed} <- source_rows(decided),
         rows <- Enum.map(attributed, &elem(&1, 1)),
         :ok <- printable(rows),
         target_project <- Registry.project!(registry, target),
         target_root <- Registry.project_root(registry, target_project),
         {:ok, lock_bytes} <- source_lock(target_root),
         context <-
           context_contents(registry, decided, target_project, attributed, lock_bytes),
         context_digest <- digest(context),
         contents <-
           contents(
             registry,
             decided,
             mode,
             resolution,
             rows,
             target_root,
             lock_bytes,
             context_digest
           ),
         overlay_digest <- digest(contents),
         {:ok, path} <- materialize(state_root, overlay_digest, contents),
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
           publish: decided.publish?,
           registry_digest: registry.digest,
           selection_digest: Registry.selection_digest(registry),
           graph_digest: resolution.digest,
           sets: Registry.sets(registry),
           overlay_digest: overlay_digest,
           context_digest: context_digest,
           overlay_path: path,
           bootstrap_path: bootstrap_path,
           runtime: runtime.report,
           projects: Enum.map(resolution.projects, & &1.id),
           edges: resolution.edges,
           external_dependencies: resolution.external_dependencies,
           known_unselected: resolution.known_unselected,
           decisions: Enum.map(decided.decisions, &reported_decision/1),
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

  @doc "Encodes a dependency's Mix options into one overlay field."
  @spec encode_options(keyword()) :: String.t()
  def encode_options([]), do: @absent

  def encode_options(opts) do
    opts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, value} -> "#{key}=#{encode_option_value(value)}" end)
  end

  @doc "Reads one overlay options field back into a keyword list."
  @spec decode_options(String.t()) :: {:ok, keyword()} | {:error, term()}
  def decode_options(@absent), do: {:ok, []}

  def decode_options(field) do
    field
    |> String.split(",")
    |> Enum.reduce_while({:ok, []}, fn pair, {:ok, acc} ->
      case decode_option(pair) do
        {:ok, option} -> {:cont, {:ok, [option | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, options} -> {:ok, options |> Enum.reverse() |> Enum.sort_by(&elem(&1, 0))}
      error -> error
    end
  end

  defp known_mode(mode) when is_atom(mode) do
    if to_string(mode) in @modes, do: :ok, else: {:error, {:unsupported_source_mode, mode}}
  end

  defp known_mode(mode), do: {:error, {:unsupported_source_mode, mode}}

  defp decide(registry, target, resolution, mode, opts) do
    Resolution.resolve(registry, target,
      closure: resolution,
      mode: resolution_mode(mode),
      sources: Keyword.get(opts, :sources, %{}),
      publish?: Keyword.get(opts, :publish?, false)
    )
  end

  # `git` is what the command line calls the source the catalog calls `github`.
  defp resolution_mode(:auto), do: nil
  defp resolution_mode(:git), do: "github"
  defp resolution_mode(mode), do: to_string(mode)

  defp source_rows(decided) do
    decided.decisions
    |> Enum.map(&source_row/1)
    |> collect_rows()
  end

  defp source_row(%{source: "local", location: path} = decision) do
    if File.regular?(Path.join(path, "mix.exs")) do
      {:ok,
       {decision,
        [
          decision.application,
          "local",
          path,
          Git.head!(path),
          Git.source_digest(path),
          encode_options(decision.opts)
        ]}}
    else
      {:error, {:missing_mix_project, decision.application, path}}
    end
  end

  defp source_row(%{source: "github", location: coordinates} = decision) do
    {kind, value} = revision(coordinates)

    {:ok,
     {decision,
      [
        decision.application,
        "github",
        coordinates.repo,
        kind,
        value,
        coordinates.subdir || @absent,
        encode_options(decision.opts)
      ]}}
  end

  defp source_row(%{source: "hex", location: requirement} = decision) do
    {:ok, {decision, [decision.application, "hex", requirement, encode_options(decision.opts)]}}
  end

  defp revision(coordinates) do
    Enum.find_value(@revision_keys, {@absent, @absent}, fn key ->
      case Map.get(coordinates, String.to_existing_atom(key)) do
        nil -> nil
        value -> {key, value}
      end
    end)
  end

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

  # Rows are tab-separated lines, so a field carrying a tab or a newline would
  # produce an overlay that parses back into something other than what was
  # written.
  defp printable(rows) do
    rows
    |> List.flatten()
    |> Enum.find(&String.contains?(&1, ["\t", "\n"]))
    |> case do
      nil -> :ok
      field -> {:error, {:unprintable_overlay_field, field}}
    end
  end

  defp contents(
         registry,
         decided,
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
      "selection_digest\t#{selection_digest(registry)}",
      "graph_digest\t#{resolution.digest}",
      "context_digest\t#{context_digest}",
      "target\t#{decided.target}",
      "mode\t#{mode}",
      "publish\t#{decided.publish?}",
      "target_head\t#{Git.head!(target_root)}",
      "target_source_digest\t#{Git.source_digest(target_root)}",
      "lock_digest\t#{digest(lock_bytes)}",
      "toolchain\telixir-#{System.version()}-otp-#{:erlang.system_info(:otp_release)}"
    ]

    (metadata ++ Enum.map(rows, &Enum.join(&1, "\t")))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp context_contents(registry, decided, target_project, attributed, lock_bytes) do
    target_repository = Registry.repository!(registry, target_project.repository)

    metadata = [
      @context_header,
      "selection_digest\t#{selection_digest(registry)}",
      "graph_digest\t#{decided.closure.digest}",
      "target\t#{decided.target}",
      "publish\t#{decided.publish?}",
      "target_repository\t#{target_repository.github}",
      "target_project_path\t#{target_project.path}",
      "lock_digest\t#{digest(lock_bytes)}",
      "toolchain\telixir-#{System.version()}-otp-#{:erlang.system_info(:otp_release)}"
    ]

    sources =
      Enum.map(attributed, fn {decision, row} ->
        semantic_source(registry, decision, row, target_project.repository)
      end)

    (metadata ++ sources)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  # A local source in the target's own repository is identified by where it
  # sits in that repository, never by its revision: the target's own dirt is
  # already covered by the overlay digest, and folding it in here would make
  # the context digest change for every uncommitted edit to the thing being
  # built.
  defp semantic_source(
         registry,
         decision,
         [app, "local", _path, revision, source_digest, opts],
         target_repository
       ) do
    {repository, project_path} = provider_coordinates(registry, decision)

    if repository == target_repository do
      join(["source", app, "local", github(registry, repository), project_path, opts])
    else
      join([
        "source",
        app,
        "local",
        github(registry, repository),
        project_path,
        revision,
        source_digest,
        opts
      ])
    end
  end

  defp semantic_source(
         _registry,
         _decision,
         [app, "github", repo, kind, value, subdir, opts],
         _t
       ),
       do: join(["source", app, "github", repo, kind, value, subdir, opts])

  defp semantic_source(_registry, _decision, [app, "hex", requirement, opts], _target_repository),
    do: join(["source", app, "hex", requirement, opts])

  defp provider_coordinates(_registry, %{provider_project_id: nil}), do: {nil, "?"}

  defp provider_coordinates(registry, %{provider_project_id: project_id}) do
    project = Registry.project!(registry, project_id)
    {project.repository, project.path}
  end

  defp github(_registry, nil), do: "?"
  defp github(registry, repository_id), do: Registry.repository!(registry, repository_id).github

  defp join(parts), do: Enum.join(parts, "\t")

  # A catalog read under no view has no selection to attest to, and `-` is what
  # every other absent field in this format is written as.
  defp selection_digest(registry), do: Registry.selection_digest(registry) || @absent

  defp reported_decision(decision) do
    %{
      application: decision.application,
      source: decision.source,
      reason: decision.reason,
      considered: decision.considered,
      provider: decision.provider_project_id,
      location: reported_location(decision),
      declared_by: decision.declared_by
    }
  end

  defp reported_location(%{source: "github", location: coordinates}) do
    coordinates |> Map.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp reported_location(decision), do: decision.location

  defp materialize(state_root, digest, contents) do
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
        "selection_digest\t" <> selection_digest,
        "graph_digest\t" <> graph_digest,
        "context_digest\t" <> context_digest,
        "target\t" <> target,
        "mode\t" <> mode,
        "publish\t" <> publish,
        "target_head\t" <> target_head,
        "target_source_digest\t" <> target_source_digest,
        "lock_digest\t" <> lock_digest,
        "toolchain\t" <> toolchain | rows
      ]
      when mode in @modes and publish in ["true", "false"] ->
        with {:ok, sources} <- parse_rows(rows) do
          {:ok,
           %{
             schema: @header,
             registry_digest: registry_digest,
             selection_digest: absent(selection_digest),
             graph_digest: graph_digest,
             context_digest: context_digest,
             target: target,
             mode: mode,
             publish: publish == "true",
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
      [app, "local", path, revision, source_digest, opts] ->
        with {:ok, options} <- decode_options(opts) do
          {:ok,
           {app,
            %{
              kind: :local,
              path: path,
              revision: revision,
              source_digest: source_digest,
              opts: options
            }}}
        end

      [app, "github", repo, kind, value, subdir, opts] ->
        with :ok <- known_revision(kind, value),
             {:ok, options} <- decode_options(opts) do
          {:ok,
           {app,
            %{
              kind: :github,
              repo: repo,
              revision_kind: kind,
              revision: value,
              subdir: absent(subdir),
              opts: options
            }}}
        end

      [app, "hex", requirement, opts] ->
        with {:ok, options} <- decode_options(opts) do
          {:ok, {app, %{kind: :hex, requirement: requirement, opts: options}}}
        end

      _parts ->
        {:error, {:invalid_overlay_row, row}}
    end
  end

  defp known_revision(@absent, @absent), do: :ok
  defp known_revision(kind, value) when kind in @revision_keys and value != @absent, do: :ok
  defp known_revision(kind, value), do: {:error, {:invalid_overlay_revision, kind, value}}

  defp absent(@absent), do: nil
  defp absent(value), do: value

  defp encode_option_value(value) when is_boolean(value), do: to_string(value)
  defp encode_option_value(values) when is_list(values), do: Enum.join(values, "|")

  defp decode_option(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> decode_option(key, value)
      _parts -> {:error, {:invalid_overlay_option, pair}}
    end
  end

  defp decode_option(key, value) do
    case Map.fetch(@option_keys, key) do
      {:ok, option} when key in @list_options -> decode_list_option(option, value)
      {:ok, option} -> decode_boolean_option(option, value)
      :error -> {:error, {:unknown_overlay_option, key}}
    end
  end

  defp decode_boolean_option(option, "true"), do: {:ok, {option, true}}
  defp decode_boolean_option(option, "false"), do: {:ok, {option, false}}

  defp decode_boolean_option(option, value),
    do: {:error, {:invalid_overlay_option, option, value}}

  # The count and the length are not the whole bound. A name that is not an
  # identifier is not a Mix environment or target whatever its length, and
  # accepting one here would mint an atom from arbitrary bytes in the reader the
  # catalog's own validator and the seam both refuse it in.
  defp decode_list_option(option, value) do
    names = String.split(value, "|")

    cond do
      length(names) > Registry.Source.maximum_option_values() ->
        {:error, {:overlay_option_too_long, option}}

      Enum.any?(names, &(byte_size(&1) > Registry.Source.maximum_option_value_bytes())) ->
        {:error, {:overlay_option_value_too_long, option}}

      not Enum.all?(names, &Registry.Source.identifier?/1) ->
        {:error, {:invalid_overlay_option, option, value}}

      true ->
        {:ok, {option, Enum.map(names, &String.to_atom(&1))}}
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
