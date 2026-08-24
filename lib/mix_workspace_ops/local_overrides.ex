defmodule MixWorkspaceOps.LocalOverrides do
  @moduledoc """
  The operator's `.dependency_sources.local.exs`, read from a repository root.

  This is the one gesture for a source switch an operator wants to keep across
  runs, and the one place a machine-local absolute path belongs: the catalog
  carries portable remote facts, and this file carries what is true of one
  disk.

  ## It is a literal term and nothing else

  The file is parsed, never evaluated, and it is parsed with a static atom
  encoder, so no name in it becomes an atom in this process. An override file
  that could execute code would be a way to run arbitrary code during
  dependency resolution, and one that could mint atoms would be a way to
  exhaust the atom table. Every scalar is read as text; `source: :path` and
  `"source" => "path"` are the same override.

  ## Keys are catalog identity

      %{deps: %{example_core: %{source: :path, path: "/checkouts/example_core"}}}

  An override applies to the catalogued application it names, wherever the
  catalog provides it. It does not apply to a declaration, so it still works
  where the catalogued declaration is Hex-only and names no provider — which is
  the shape the load-bearing files have.

  ## What each key does

    * `source` — chosen outright, bypassing the declared order entirely.
      `path` is accepted as a name for `local`, which is what the file this
      replaces called it.
    * `path` — replaces the derived local path, and is what makes a checkout
      outside the conventional root reachable.
    * `hex` — replaces the published requirement.
    * `repo`, `branch`, `ref`, `tag`, `subdir` — merge into the declaration's
      GitHub coordinates, so one branch moves without restating the
      repository. At most one of `branch`, `ref` and `tag`, because two of
      them name two different commits.

  A key outside that set is refused by name rather than ignored, so a typo is a
  message instead of a source that quietly did not change.
  """

  @filename ".dependency_sources.local.exs"
  @maximum_bytes 1024 * 1024
  @source_names %{
    "local" => "local",
    "path" => "local",
    "github" => "github",
    "git" => "github",
    "hex" => "hex"
  }
  @github_keys ~w(repo branch ref tag subdir)
  @revision_keys ~w(branch ref tag)
  @keys ~w(source path hex) ++ @github_keys

  @type override :: %{
          source: String.t() | nil,
          requested_source: String.t() | nil,
          path: String.t() | nil,
          hex: String.t() | nil,
          github: %{String.t() => String.t()}
        }

  @doc "The file an operator writes at a repository root."
  @spec filename() :: String.t()
  def filename, do: @filename

  @doc "An override with nothing set."
  @spec empty() :: override()
  def empty, do: %{source: nil, requested_source: nil, path: nil, hex: nil, github: %{}}

  @doc """
  Reads the override file at `consumer_root`.

  A repository with no such file has no overrides, which is the ordinary case.
  """
  @spec load(String.t()) :: {:ok, %{String.t() => override()}} | {:error, term()}
  def load(consumer_root) do
    path = consumer_root |> Path.expand() |> Path.join(@filename)

    if File.regular?(path), do: read(path), else: {:ok, %{}}
  end

  @doc "Reads one override file by path, whatever it is named."
  @spec read(String.t()) :: {:ok, %{String.t() => override()}} | {:error, term()}
  def read(path) do
    with :ok <- within_size(path),
         {:ok, bytes} <- File.read(path),
         {:ok, quoted} <- parse(bytes, path),
         {:ok, term} <- literal(quoted, path) do
      deps(term, path)
    end
  end

  defp within_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size <= @maximum_bytes -> :ok
      {:ok, _stat} -> {:error, {:override_file_too_large, path, @maximum_bytes}}
      {:error, reason} -> {:error, {:override_file, path, reason}}
    end
  end

  defp parse(bytes, path) do
    case Code.string_to_quoted(bytes, file: path, static_atoms_encoder: &encode_atom/2) do
      {:ok, quoted} -> {:ok, quoted}
      {:error, reason} -> {:error, {:unparsable_override_file, path, reason}}
    end
  end

  defp encode_atom(token, _meta), do: {:ok, {:__name__, token}}

  defp literal({:__name__, name}, _path), do: {:ok, name}
  defp literal(value, _path) when is_binary(value) or is_number(value), do: {:ok, value}

  defp literal({:%{}, _meta, pairs}, path) do
    with {:ok, entries} <- collect(pairs, path, &pair/2), do: {:ok, Map.new(entries)}
  end

  defp literal(values, path) when is_list(values), do: collect(values, path, &literal/2)

  defp literal(other, path), do: non_literal(other, path)

  defp pair({key, value}, path) do
    with {:ok, decoded_key} <- literal(key, path),
         {:ok, decoded_value} <- literal(value, path) do
      {:ok, {decoded_key, decoded_value}}
    end
  end

  defp pair(other, path), do: non_literal(other, path)

  # The file is refused, and the line is what an operator needs to fix it. The
  # expression itself is not echoed: it is the thing that was rejected for not
  # being a literal, and rendering it back is how a rejected input reaches an
  # operator's terminal.
  defp non_literal(node, path), do: {:error, {:non_literal_override, path, line(node)}}

  defp line({_form, meta, _arguments}) when is_list(meta), do: Keyword.get(meta, :line)
  defp line({left, _right}), do: line(left)
  defp line(_node), do: nil

  defp collect(values, path, decoder) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case decoder.(value, path) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp deps(%{"deps" => deps}, path) when is_map(deps) do
    deps
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {app, raw}, {:ok, acc} ->
      case override(app, raw, path) do
        {:ok, override} -> {:cont, {:ok, Map.put(acc, app, override)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp deps(%{} = term, path) when not is_map_key(term, "deps"), do: deps(%{"deps" => %{}}, path)
  defp deps(term, path), do: {:error, {:invalid_override_file, path, term}}

  defp override(app, raw, path) when is_map(raw) do
    with :ok <- known_keys(app, raw, path),
         :ok <- single_revision(app, raw, path),
         {:ok, source, requested} <- source(app, Map.get(raw, "source"), path) do
      {:ok,
       %{
         source: source,
         requested_source: requested,
         path: Map.get(raw, "path"),
         hex: Map.get(raw, "hex"),
         github: Map.take(raw, @github_keys)
       }}
    end
  end

  defp override(app, raw, path), do: {:error, {:invalid_override, path, app, raw}}

  defp known_keys(app, raw, path) do
    case Map.keys(raw) -- @keys do
      [] -> :ok
      unknown -> {:error, {:unknown_override_keys, path, app, Enum.sort(unknown)}}
    end
  end

  defp single_revision(app, raw, path) do
    case Enum.filter(@revision_keys, &Map.has_key?(raw, &1)) do
      [] -> :ok
      [_one] -> :ok
      several -> {:error, {:conflicting_override_revision, path, app, Enum.sort(several)}}
    end
  end

  defp source(_app, nil, _path), do: {:ok, nil, nil}

  defp source(app, requested, path) do
    case Map.fetch(@source_names, requested) do
      {:ok, source} -> {:ok, source, requested}
      :error -> {:error, {:unknown_override_source, path, app, requested}}
    end
  end
end
