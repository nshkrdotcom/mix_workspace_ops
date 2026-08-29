defmodule MixWorkspaceOpsBootstrap do
  @moduledoc false

  # The Mix-load seam. A `mix.exs` loads this file by path and calls `dep/4`
  # for each cross-repository dependency. It has no access to Mix Workspace Ops
  # and reads nothing but the two variables the launching process sets, so the
  # tables and the parsers below are deliberate duplicates of
  # `MixWorkspaceOps.PublishMode` and `MixWorkspaceOps.Overlay`. Tests hold each
  # pair to one shared table so they cannot drift.

  @schema_header "mix_workspace_ops.overlay/v2"
  @maximum_mix_bytes 1024 * 1024
  @overlay_env "MIX_WORKSPACE_OPS_OVERLAY"
  @lockfile_env "MIX_WORKSPACE_OPS_LOCKFILE"
  @maximum_overlay_bytes 16 * 1024 * 1024
  @modes ["auto", "local", "git", "hex"]
  @absent "-"

  @publish_tasks ["hex.publish", "hex.build", "deps.publish_preflight"]
  @quiet_tasks [
    "run",
    "eval",
    "cmd",
    "app.start",
    "app.config",
    "escript.build",
    "deps.sources",
    "deps.publish_preflight"
  ]

  @option_keys %{
    "only" => :only,
    "hex" => :hex,
    "optional" => :optional,
    "override" => :override,
    "runtime" => :runtime,
    "targets" => :targets
  }
  @list_options ["only", "targets"]
  @name_options ["hex"]
  @maximum_option_values 8
  @maximum_option_value_bytes 32
  @revision_keys ["branch", "ref", "tag"]

  @doc """
  The dependency tuple for `app`.

  `committed_default` is what this repository resolves to with no overlay
  active — a binary is a Hex requirement, and a keyword list is committed git
  coordinates such as `[github: "example-org/example_core", branch: "main"]`.
  A dependency with no Hex release needs the second form, or a fresh clone and
  a consumer of the published package have nowhere to resolve it from.

  With an overlay carrying the application, the overlay row decides.
  """
  def dep(app, committed_default, project_root, extra_opts \\ []) when is_atom(app) do
    overlay = overlay()
    notify_local_paths(project_root, overlay)

    tuple =
      case overlay_source(overlay, Atom.to_string(app)) do
        nil -> committed_tuple(app, committed_default, extra_opts)
        source -> overlay_tuple(app, source, extra_opts)
      end

    record_source(project_root, tuple)
    tuple
  end

  @doc """
  Every dependency this `mix.exs` resolved, in the order an operator reads.

  `mix deps.sources` reports what the seam actually emitted rather than
  re-deriving it, so what is printed is what Mix was given.
  """
  def recorded_sources(project_root) do
    sources_key(project_root)
    |> :persistent_term.get(%{})
    |> Map.values()
    |> Enum.sort_by(& &1.app)
  end

  def format_sources([]), do: "dependency sources: (no managed dependencies)"

  def format_sources(entries) when is_list(entries) do
    lines =
      Enum.map(entries, fn entry ->
        "  #{entry.app} -> #{entry.source} (#{entry.location}) -> #{entry.version || "unknown"}"
      end)

    Enum.join(["dependency sources:" | lines], "\n")
  end

  # The version a Mix project declares, read by parsing and never evaluating.
  # This is the same rule and the same two shapes as
  # `MixWorkspaceOps.Project.declared_version/1`, which a test holds it to; the
  # duplication is deliberate, because this file runs with none of Mix Workspace
  # Ops on the code path.
  def declared_version(project_root) do
    path = project_root |> Path.expand() |> Path.join("mix.exs")

    with {:ok, %{type: :regular, size: size}} when size <= @maximum_mix_bytes <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, quoted} <- Code.string_to_quoted(bytes, file: path) do
      version_literal(quoted)
    else
      _unreadable -> nil
    end
  end

  defp sources_key(project_root), do: {__MODULE__, :sources, Path.expand(project_root)}

  defp record_source(project_root, tuple) do
    key = sources_key(project_root)
    entry = source_entry(tuple)
    :persistent_term.put(key, Map.put(:persistent_term.get(key, %{}), entry.app, entry))
    :ok
  end

  defp source_entry({app, requirement}) when is_binary(requirement),
    do: %{app: app, source: "hex", location: "hex", version: requirement}

  defp source_entry({app, requirement, _opts}) when is_binary(requirement),
    do: %{app: app, source: "hex", location: "hex", version: requirement}

  defp source_entry({app, opts}) when is_list(opts) do
    cond do
      path = Keyword.get(opts, :path) ->
        %{app: app, source: "local", location: path, version: declared_version(path)}

      repo = Keyword.get(opts, :github) ->
        %{app: app, source: "github", location: repo, version: revision_label(opts)}

      true ->
        %{app: app, source: "unknown", location: "?", version: nil}
    end
  end

  defp revision_label(opts) do
    Enum.find_value([:ref, :tag, :branch], fn key ->
      case Keyword.get(opts, key) do
        nil -> nil
        value -> "#{key} #{value}"
      end
    end)
  end

  defp version_literal(quoted) do
    {_quoted, attributes} =
      Macro.prewalk(quoted, %{}, fn
        {:@, _meta, [{name, _name_meta, [value]}]} = node, acc when is_atom(name) ->
          if is_binary(value), do: {node, Map.put_new(acc, name, value)}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    {_quoted, version} =
      Macro.prewalk(quoted, nil, fn
        {:version, value} = node, nil -> {node, version_value(value, attributes)}
        node, acc -> {node, acc}
      end)

    version
  end

  defp version_value(value, _attributes) when is_binary(value), do: value

  defp version_value({:@, _meta, [{name, _name_meta, nil}]}, attributes) when is_atom(name),
    do: Map.get(attributes, name)

  defp version_value(_value, _attributes), do: nil

  defp overlay_source(nil, _app), do: nil
  defp overlay_source(overlay, app), do: Map.get(overlay.sources, app)

  def active?(_project_root \\ nil), do: not is_nil(overlay_path())

  def project_options(_project_root \\ nil) do
    case System.get_env(@lockfile_env) do
      nil -> []
      "" -> []
      path -> [lockfile: validate_lockfile!(path)]
    end
  end

  def source(_project_root, app) do
    case overlay() do
      nil -> nil
      overlay -> Map.get(overlay.sources, to_string(app))
    end
  end

  # Task position only: `mix do compile, hex.publish` publishes and
  # `mix run --arg hex.publish` does not.
  def publish_mode?(argv) when is_list(argv) do
    argv |> task_tokens() |> Enum.any?(&(&1 in @publish_tasks))
  end

  # Tasks whose standard output is the product itself never carry the local
  # path notice, so nothing reading `mix` output has a line injected into it.
  def quiet_task?(argv) when is_list(argv) do
    argv |> task_tokens() |> Enum.any?(&(&1 in @quiet_tasks))
  end

  def task_tokens(["do" | argv]), do: argv |> collect_tasks([], true) |> Enum.reverse()
  def task_tokens([task | _arguments]) when task != "", do: [task]
  def task_tokens(argv) when is_list(argv), do: []

  def decode_options(@absent), do: []

  def decode_options(field) do
    field
    |> String.split(",")
    |> Enum.map(&decode_option!/1)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp committed_tuple(app, requirement, extra_opts) when is_binary(requirement) do
    case extra_opts do
      [] -> {app, requirement}
      opts -> {app, requirement, opts}
    end
  end

  defp committed_tuple(app, coordinates, extra_opts) when is_list(coordinates) do
    unless Keyword.keyword?(coordinates) and Keyword.has_key?(coordinates, :github) do
      raise "committed git coordinates for #{app} must be a keyword list carrying :github"
    end

    {app, Keyword.merge(coordinates, extra_opts)}
  end

  defp committed_tuple(app, other, _extra_opts) do
    raise "committed default for #{app} must be a Hex requirement or git coordinates, got: " <>
            inspect(other)
  end

  defp overlay_tuple(app, %{kind: :local, path: path, opts: opts}, extra_opts) do
    {app, Keyword.merge([path: path], Keyword.merge(opts, extra_opts))}
  end

  defp overlay_tuple(app, %{kind: :github} = source, extra_opts) do
    coordinates =
      [github: source.repo] ++
        revision_option(source.revision_kind, source.revision) ++
        subdir_option(source.subdir)

    {app, Keyword.merge(coordinates, Keyword.merge(source.opts, extra_opts))}
  end

  defp overlay_tuple(app, %{kind: :hex, requirement: requirement, opts: opts}, extra_opts) do
    case Keyword.merge(opts, extra_opts) do
      [] -> {app, requirement}
      merged -> {app, requirement, merged}
    end
  end

  # The revision key, then the subdirectory. The order the tuples this seam
  # replaces carried was whatever iterating a map of their keys produced, which
  # is not specified: it depends on the key type and on the map's internal
  # layout, so the same file yields one order for atom keys and another for
  # string keys. Nothing here can match an unspecified order, and parity with
  # those tuples is compared without regard to keyword order for that reason.
  defp revision_option(@absent, _value), do: []
  defp revision_option("branch", value), do: [branch: value]
  defp revision_option("ref", value), do: [ref: value]
  defp revision_option("tag", value), do: [tag: value]

  defp subdir_option(nil), do: []
  defp subdir_option(subdir), do: [subdir: subdir]

  defp notify_local_paths(project_root, overlay) do
    key = {__MODULE__, :local_path_notice, project_root}

    if not is_nil(overlay) and not quiet_task?(System.argv()) and
         :persistent_term.get(key, nil) == nil do
      :persistent_term.put(key, true)
      emit_local_path_notice(overlay)
    end

    :ok
  end

  defp emit_local_path_notice(overlay) do
    case local_applications(overlay) do
      [] ->
        :ok

      applications ->
        message =
          "[mix_workspace_ops] local path source in use for: " <> Enum.join(applications, ", ")

        if Code.ensure_loaded?(Mix),
          do: Mix.shell().info(message),
          else: IO.puts(:stderr, message)
    end
  end

  defp local_applications(overlay) do
    overlay.sources
    |> Enum.filter(fn {_app, source} -> source.kind == :local end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp overlay do
    case overlay_path() do
      nil -> nil
      path -> path |> parse_overlay!() |> refuse_development_overlay_while_publishing!()
    end
  end

  defp overlay_path do
    case System.get_env(@overlay_env) do
      nil -> nil
      "" -> nil
      path -> validate_overlay_path!(path)
    end
  end

  defp validate_overlay_path!(path) do
    unless Path.type(path) == :absolute do
      raise "#{@overlay_env} must contain an absolute path"
    end

    unless File.regular?(path) do
      raise "#{@overlay_env} points to a missing overlay: #{path}"
    end

    if File.stat!(path).size > @maximum_overlay_bytes do
      raise "#{@overlay_env} points to an oversized overlay"
    end

    verify_content_address!(path)
  end

  # An overlay decided for ordinary development says where a developer's
  # checkouts are. Publishing from under one would put a local path or a
  # development ref into a released package, so it is refused; an overlay
  # decided under publish resolution is exactly what publication should use.
  defp refuse_development_overlay_while_publishing!(overlay) do
    if publish_mode?(System.argv()) and not overlay.publish do
      raise "a Mix Workspace Ops overlay decided for development is active; " <>
              "rerun publication against an overlay resolved in publish mode, " <>
              "or without #{@overlay_env}"
    end

    overlay
  end

  defp validate_lockfile!(path) do
    unless Path.type(path) == :absolute do
      raise "#{@lockfile_env} must contain an absolute path"
    end

    unless File.regular?(path) do
      raise "#{@lockfile_env} points to a missing lockfile: #{path}"
    end

    path
  end

  defp parse_overlay!(path) do
    case path |> File.read!() |> String.split("\n", trim: true) do
      [
        @schema_header,
        "registry_digest\t" <> _registry_digest,
        "selection_digest\t" <> _selection_digest,
        "graph_digest\t" <> _graph_digest,
        "context_digest\t" <> _context_digest,
        "target\t" <> _target,
        "mode\t" <> mode,
        "publish\t" <> publish,
        "target_head\t" <> _target_head,
        "target_source_digest\t" <> _target_source_digest,
        "lock_digest\t" <> _lock_digest,
        "toolchain\t" <> _toolchain | rows
      ]
      when mode in @modes and publish in ["true", "false"] ->
        %{mode: mode, publish: publish == "true", sources: parse_rows!(rows)}

      _lines ->
        raise "invalid Mix Workspace Ops overlay at #{path}"
    end
  end

  defp parse_rows!(rows) do
    Enum.reduce(rows, %{}, fn row, sources ->
      {app, source} = parse_row!(row)

      if Map.has_key?(sources, app) do
        raise "duplicate Mix Workspace Ops source for #{app}"
      end

      Map.put(sources, app, source)
    end)
  end

  defp parse_row!(row) do
    case String.split(row, "\t") do
      [app, "local", path, revision, source_digest, opts] ->
        unless Path.type(path) == :absolute and File.regular?(Path.join(path, "mix.exs")) do
          raise "local Mix dependency #{app} has no absolute Mix project at #{path}"
        end

        {app,
         %{
           kind: :local,
           path: path,
           revision: revision,
           source_digest: source_digest,
           opts: decode_options(opts)
         }}

      [app, "github", repo, kind, value, subdir, opts] ->
        unless (kind == @absent and value == @absent) or
                 (kind in @revision_keys and value != @absent) do
          raise "invalid Mix Workspace Ops revision for #{app}: #{kind} #{value}"
        end

        {app,
         %{
           kind: :github,
           repo: repo,
           revision_kind: kind,
           revision: value,
           subdir: if(subdir == @absent, do: nil, else: subdir),
           opts: decode_options(opts)
         }}

      [app, "hex", requirement, opts] ->
        {app, %{kind: :hex, requirement: requirement, opts: decode_options(opts)}}

      _parts ->
        raise "invalid Mix Workspace Ops overlay row: #{inspect(row)}"
    end
  end

  defp decode_option!(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> decode_option!(key, value)
      _parts -> raise "invalid Mix Workspace Ops dependency option: #{inspect(pair)}"
    end
  end

  defp decode_option!(key, value) do
    case Map.fetch(@option_keys, key) do
      {:ok, option} when key in @list_options -> {option, decode_names!(option, value)}
      {:ok, option} when key in @name_options -> {option, decode_name!(option, value)}
      {:ok, option} -> {option, decode_boolean!(option, value)}
      :error -> raise "unknown Mix Workspace Ops dependency option: #{inspect(key)}"
    end
  end

  defp decode_name!(option, value) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value),
      do: String.to_atom(value),
      else: raise("invalid Mix Workspace Ops option #{option}: #{inspect(value)}")
  end

  defp decode_boolean!(_option, "true"), do: true
  defp decode_boolean!(_option, "false"), do: false

  defp decode_boolean!(option, value),
    do: raise("invalid Mix Workspace Ops option #{option}: #{inspect(value)}")

  # `only` and `targets` name Mix environments and targets, which have to be
  # atoms and which JSON cannot carry as atoms. Converting them mints atoms
  # from file content, so the count and the length are bounded: eight values of
  # at most 32 bytes is far more than Mix's three standard environments and a
  # handful of custom ones, and far below anything that could exhaust the atom
  # table.
  defp decode_names!(option, value) do
    names = String.split(value, "|")

    if names == [] or Enum.any?(names, &(&1 == "")) or
         length(names) > @maximum_option_values or
         Enum.any?(names, &(byte_size(&1) > @maximum_option_value_bytes)) or
         Enum.any?(names, &(not Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1))) do
      raise "invalid Mix Workspace Ops option #{option}: #{inspect(value)}"
    end

    Enum.map(names, &String.to_atom/1)
  end

  defp collect_tasks([], acc, _task?), do: acc

  defp collect_tasks([token | rest], acc, _task?) when token in [",", "+"],
    do: collect_tasks(rest, acc, true)

  defp collect_tasks(["" | rest], acc, true), do: collect_tasks(rest, acc, true)

  defp collect_tasks([token | rest], acc, true) do
    if String.ends_with?(token, ",") do
      task = String.trim_trailing(token, ",")
      collect_tasks(rest, if(task == "", do: acc, else: [task | acc]), true)
    else
      collect_tasks(rest, [token | acc], false)
    end
  end

  defp collect_tasks([token | rest], acc, false) do
    collect_tasks(rest, acc, String.ends_with?(token, ","))
  end

  defp verify_content_address!(path) do
    bytes = File.read!(path)
    expected = Path.basename(path, ".tsv")
    actual = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    if expected == actual do
      path
    else
      raise "Mix Workspace Ops overlay digest mismatch at #{path}"
    end
  end
end

# The Mix task the file this seam replaces defined, at zero cost in repository
# files: this bootstrap is already loaded into the Mix process by path, so the
# task is defined where the sources were recorded and nothing is installed into
# a managed repository to make it available.
if Code.ensure_loaded?(Mix.Task) and not Code.ensure_loaded?(Mix.Tasks.Deps.Sources) do
  defmodule Mix.Tasks.Deps.Sources do
    @moduledoc false
    @shortdoc "Prints the resolved source of every managed dependency"

    use Mix.Task

    @impl Mix.Task
    def run(_args) do
      Mix.Project.project_file()
      |> Path.dirname()
      |> MixWorkspaceOpsBootstrap.recorded_sources()
      |> MixWorkspaceOpsBootstrap.format_sources()
      |> Mix.shell().info()
    end
  end
end
