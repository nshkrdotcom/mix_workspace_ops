defmodule MixWorkspaceOps.DependencyLock do
  @moduledoc """
  Safe literal parsing and normalization of exact dependency objects in `mix.lock`.

  A lockfile is parsed as Elixir syntax but never evaluated. Only maps, tuples,
  lists and primitive literals are accepted, which is sufficient for Mix lock
  entries and refuses calls, aliases, interpolation and executable forms.
  """

  alias MixWorkspaceOps.Report

  @hex_pattern ~r/^[0-9a-f]{64}$/
  @git_pattern ~r/^[0-9a-f]{40,64}$/

  @type hex_object :: %{
          app: String.t(),
          repository: String.t(),
          package: String.t(),
          version: String.t(),
          inner_checksum: String.t(),
          outer_checksum: String.t(),
          managers: [atom()],
          identity: String.t()
        }

  @type git_object :: %{
          app: String.t(),
          remote: String.t(),
          commit: String.t(),
          options: keyword(),
          identity: String.t()
        }

  @spec parse(binary()) :: {:ok, %{hex: [hex_object()], git: [git_object()]}} | {:error, term()}
  def parse(bytes) when is_binary(bytes) do
    with {:ok, lock} <- decode(bytes), do: normalize(lock)
  end

  def parse(value), do: {:error, {:lock_bytes, value}}

  @doc "Projects a source lock into an operational lock by omitting path-backed applications."
  @spec project(binary(), [String.t() | atom()]) :: {:ok, binary()} | {:error, term()}
  def project(bytes, applications) when is_binary(bytes) and is_list(applications) do
    dropped = applications |> Enum.map(&to_string/1) |> MapSet.new()

    if MapSet.size(dropped) == 0 do
      {:ok, bytes}
    else
      project_decoded_lock(bytes, dropped)
    end
  end

  def project(bytes, applications), do: {:error, {:lock_projection, bytes, applications}}

  defp project_decoded_lock(bytes, dropped) do
    with {:ok, lock} <- decode(bytes) do
      projected =
        Map.reject(lock, fn {app, _entry} -> MapSet.member?(dropped, to_string(app)) end)

      {:ok,
       inspect(projected,
         pretty: true,
         limit: :infinity,
         printable_limit: :infinity,
         width: 98
       ) <> "\n"}
    end
  end

  @doc "Returns a deterministic digest of the literal lock terms, independent of formatting."
  @spec semantic_digest(binary()) :: {:ok, String.t()} | {:error, term()}
  def semantic_digest(bytes) when is_binary(bytes) do
    with {:ok, lock} <- decode(bytes),
         {:ok, canonical} <- canonical_lock(lock) do
      digest =
        canonical
        |> :erlang.term_to_binary([:deterministic])
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:ok, digest}
    end
  end

  def semantic_digest(bytes), do: {:error, {:lock_bytes, bytes}}

  defp canonical_lock(lock) do
    Enum.reduce_while(lock, {:ok, %{}}, fn {app, entry}, {:ok, canonical} ->
      app = to_string(app)

      if Map.has_key?(canonical, app),
        do: {:halt, {:error, {:duplicate_lock_application, app}}},
        else: {:cont, {:ok, Map.put(canonical, app, entry)}}
    end)
  end

  defp decode(bytes) do
    with {:ok, quoted} <-
           Code.string_to_quoted(bytes, file: "mix.lock", emit_warnings: false),
         {:ok, lock} <- literal(quoted),
         true <- is_map(lock) || {:error, {:lock_literal, :root_not_map}} do
      {:ok, lock}
    else
      {:error, {line, error, token}} ->
        {:error,
         {:lock_syntax, line, Exception.format_file_line("mix.lock", line_number(line)), error,
          token}}

      {:error, _reason} = error ->
        error
    end
  end

  defp line_number(metadata) when is_list(metadata), do: Keyword.get(metadata, :line)

  defp normalize(lock) do
    lock
    |> Enum.sort_by(fn {app, _entry} -> to_string(app) end)
    |> Enum.reduce_while({:ok, %{hex: [], git: []}}, &normalize_entry/2)
    |> case do
      {:ok, objects} ->
        {:ok, %{hex: Enum.reverse(objects.hex), git: Enum.reverse(objects.git)}}

      error ->
        error
    end
  end

  defp normalize_entry({app, entry}, {:ok, objects}) when is_binary(app) or is_atom(app) do
    case dependency_object(to_string(app), entry) do
      {:ok, nil} -> {:cont, {:ok, objects}}
      {:ok, {:hex, object}} -> {:cont, {:ok, update_in(objects.hex, &[object | &1])}}
      {:ok, {:git, object}} -> {:cont, {:ok, update_in(objects.git, &[object | &1])}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_entry({app, _entry}, _acc), do: {:halt, {:error, {:lock_application, app}}}

  defp dependency_object(app, entry) when is_tuple(entry) do
    case Tuple.to_list(entry) do
      [:hex, package, version, inner, managers, _dependencies, repository, outer | _rest] ->
        hex_object(app, package, version, inner, managers, repository, outer)

      [:git, remote, commit, options] ->
        git_object(app, remote, commit, options)

      _other ->
        {:ok, nil}
    end
  end

  defp dependency_object(_app, _entry), do: {:ok, nil}

  defp hex_object(app, package, version, inner, managers, repository, outer) do
    repository = repository || "hexpm"

    with :ok <- hex_application(app),
         true <- is_atom(package) || is_binary(package) || {:error, {:hex_package, app, package}},
         package = to_string(package),
         true <-
           Regex.match?(~r/^[a-z][a-z0-9_]*$/, package) ||
             {:error, {:hex_package, app, package}},
         true <- is_binary(version) || {:error, {:hex_version, app, version}},
         true <-
           match?({:ok, _version}, Version.parse(version)) ||
             {:error, {:hex_version, app, version}},
         :ok <- checksum(:inner, app, inner),
         :ok <- checksum(:outer, app, outer),
         true <- is_list(managers) || {:error, {:hex_managers, app, managers}},
         true <- is_binary(repository) || {:error, {:hex_repository, app, repository}} do
      canonical = %{
        repository: repository,
        package: package,
        version: version,
        inner_checksum: inner,
        outer_checksum: outer
      }

      {:ok,
       {:hex,
        Map.merge(canonical, %{
          app: app,
          managers: managers,
          identity: digest(canonical)
        })}}
    end
  end

  defp git_object(app, remote, commit, options) do
    with :ok <- dependency_application(app),
         true <- is_binary(remote) || {:error, {:git_remote, app, remote}},
         true <-
           (is_binary(commit) and Regex.match?(@git_pattern, String.downcase(commit))) ||
             {:error, {:git_commit, app, commit}},
         true <- Keyword.keyword?(options) || {:error, {:git_options, app, options}} do
      canonical = %{remote: remote, commit: String.downcase(commit), options: options}
      {:ok, {:git, Map.merge(canonical, %{app: app, identity: digest(canonical)})}}
    end
  end

  defp checksum(kind, app, value)
       when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(@hex_pattern, String.downcase(value)),
      do: :ok,
      else: {:error, {:hex_checksum, kind, app, value}}
  end

  defp checksum(kind, app, value), do: {:error, {:hex_checksum, kind, app, value}}

  defp dependency_application(app) do
    if safe_component?(app),
      do: :ok,
      else: {:error, {:dependency_application, app}}
  end

  defp hex_application(app) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, app),
      do: :ok,
      else: {:error, {:dependency_application, app}}
  end

  defp safe_component?(value) when is_binary(value) do
    value not in ["", ".", ".."] and Path.basename(value) == value and
      not String.contains?(value, ["/", "\\", "\0", "\n", "\r", "\t"])
  end

  defp literal(value)
       when is_atom(value) or is_binary(value) or is_integer(value) or is_float(value),
       do: {:ok, value}

  defp literal(values) when is_list(values), do: literal_list(values, [])

  defp literal({:%{}, _meta, entries}) when is_list(entries) do
    with {:ok, pairs} <- literal_list(entries, []), do: {:ok, Map.new(pairs)}
  end

  defp literal({:{}, _meta, entries}) when is_list(entries) do
    with {:ok, values} <- literal_list(entries, []), do: {:ok, List.to_tuple(values)}
  end

  defp literal({left, right}) do
    with {:ok, left} <- literal(left), {:ok, right} <- literal(right), do: {:ok, {left, right}}
  end

  defp literal(other), do: {:error, {:lock_literal, Macro.to_string(other)}}

  defp literal_list([], acc), do: {:ok, Enum.reverse(acc)}

  defp literal_list([value | rest], acc) do
    case literal(value) do
      {:ok, decoded} -> literal_list(rest, [decoded | acc])
      {:error, _reason} = error -> error
    end
  end

  defp digest(value) do
    value
    |> Report.encode()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
