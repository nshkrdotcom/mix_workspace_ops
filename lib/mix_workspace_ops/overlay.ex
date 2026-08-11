defmodule MixWorkspaceOps.Overlay do
  @moduledoc "Explicit operator-owned local/Git source overlay materialization."

  alias MixWorkspaceOps.{Catalog, Git, Graph}

  @relative_path ".mix_workspace_ops/sources.tsv"
  @header "mix_workspace_ops\t1"

  @type activation :: %{files: %{String.t() => :absent | {:present, binary()}}, report: map()}

  @spec relative_path() :: String.t()
  def relative_path, do: @relative_path

  @spec activate(Catalog.t(), String.t() | atom(), keyword()) ::
          {:ok, activation()} | {:error, term()}
  def activate(catalog, target, opts \\ []) do
    mode = Keyword.get(opts, :mode, :local)
    projects = Graph.closure(catalog, target)
    repositories = repositories_for(catalog, projects)

    with {:ok, rows} <- source_rows(catalog, projects, mode),
         contents <- contents(catalog, to_string(target), mode, rows),
         {:ok, files} <- change_repositories(repositories, contents, mode) do
      {:ok,
       %{
         files: files,
         report: %{
           target: to_string(target),
           mode: mode,
           catalog_digest: catalog.digest,
           projects: Enum.map(projects, & &1.app),
           repositories: repositories,
           rows: rows
         }
       }}
    end
  end

  @spec restore(activation()) :: :ok | {:error, term()}
  def restore(%{files: files}) do
    Enum.reduce_while(files, :ok, fn {path, previous}, :ok ->
      result =
        case previous do
          :absent -> remove_generated(path)
          {:present, bytes} -> atomic_write(path, bytes)
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  @spec with_activation(Catalog.t(), String.t() | atom(), keyword(), (map() -> result)) :: result
        when result: term()
  def with_activation(catalog, target, opts \\ [], function) when is_function(function, 1) do
    {:ok, activation} = activate(catalog, target, opts)

    try do
      function.(activation.report)
    after
      :ok = restore(activation)
    end
  end

  @spec read(String.t()) :: {:ok, map()} | {:error, term()}
  def read(project_root) do
    path = Path.join(project_root, @relative_path)

    with {:ok, bytes} <- File.read(path) do
      parse(bytes)
    end
  end

  defp repositories_for(catalog, projects) do
    projects
    |> Enum.map(&Catalog.repository_root(catalog, &1.repository))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp source_rows(catalog, projects, :local) do
    rows =
      Enum.map(projects, fn project ->
        path = Catalog.project_root(catalog, project)

        if File.regular?(Path.join(path, "mix.exs")) do
          {:ok, [project.app, "path", path, Git.head!(path)]}
        else
          {:error, {:missing_mix_project, project.app, path}}
        end
      end)

    collect_rows(rows)
  end

  defp source_rows(catalog, projects, :git) do
    rows =
      Enum.map(projects, fn project ->
        repository = Catalog.repository!(catalog, project.repository)
        root = Catalog.repository_root(catalog, repository.id)
        url = "https://github.com/#{repository.github}.git"
        {:ok, [project.app, "git", url, Git.head!(root), project.path]}
      end)

    collect_rows(rows)
  end

  defp source_rows(_catalog, _projects, :hex), do: {:ok, []}

  defp source_rows(_catalog, _projects, mode), do: {:error, {:unsupported_source_mode, mode}}

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

  defp contents(catalog, target, mode, rows) do
    metadata = [
      @header,
      "catalog_digest\t#{catalog.digest}",
      "target\t#{target}",
      "mode\t#{mode}"
    ]

    (metadata ++ Enum.map(rows, &Enum.join(&1, "\t")))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp write_repositories(repositories, contents) do
    Enum.reduce_while(repositories, {:ok, %{}}, fn repository, {:ok, previous} ->
      path = Path.join(repository, @relative_path)

      case write_repository(path, contents) do
        {:ok, old_state} -> {:cont, {:ok, Map.put(previous, path, old_state)}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp change_repositories(repositories, _contents, :hex) do
    remove_repositories(repositories)
  end

  defp change_repositories(repositories, contents, _mode) do
    write_repositories(repositories, contents)
  end

  defp remove_repositories(repositories) do
    Enum.reduce_while(repositories, {:ok, %{}}, fn repository, {:ok, previous} ->
      path = Path.join(repository, @relative_path)

      case remove_repository(path) do
        {:ok, old_state} -> {:cont, {:ok, Map.put(previous, path, old_state)}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp remove_repository(path) do
    case File.read(path) do
      {:ok, bytes} -> remove_known_overlay(path, bytes)
      {:error, :enoent} -> {:ok, :absent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_known_overlay(path, bytes) do
    if String.starts_with?(bytes, @header <> "\n") do
      case File.rm(path) do
        :ok -> {:ok, {:present, bytes}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :refuse_to_remove_unrecognized_overlay}
    end
  end

  defp write_repository(path, contents) do
    with {:ok, previous} <- previous_contents(path),
         :ok <- atomic_write(path, contents) do
      {:ok, previous}
    end
  end

  defp previous_contents(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, {:present, bytes}}
      {:error, :enoent} -> {:ok, :absent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp atomic_write(path, contents) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary, contents, [:sync]) do
      File.rename(temporary, path)
    end
  end

  defp remove_generated(path) do
    case File.read(path) do
      {:ok, bytes} when is_binary(bytes) ->
        if String.starts_with?(bytes, @header <> "\n") do
          File.rm(path)
        else
          {:error, :refuse_to_remove_unrecognized_overlay}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse(bytes) do
    lines = String.split(bytes, "\n", trim: true)

    case lines do
      [@header, "catalog_digest\t" <> digest, "target\t" <> target, "mode\t" <> mode | rows] ->
        {:ok,
         %{
           catalog_digest: digest,
           target: target,
           mode: mode,
           sources: Map.new(rows, &parse_row!/1)
         }}

      _ ->
        {:error, :invalid_overlay}
    end
  end

  defp parse_row!(row) do
    case String.split(row, "\t") do
      [app, "path", path, revision] ->
        {app, %{kind: :path, path: path, revision: revision}}

      [app, "git", url, revision, subdir] ->
        {app, %{kind: :git, url: url, revision: revision, subdir: subdir}}

      _ ->
        raise ArgumentError, "invalid overlay row: #{inspect(row)}"
    end
  end
end
