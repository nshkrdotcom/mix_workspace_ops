defmodule MixWorkspaceOps.SourcePreferences do
  @moduledoc """
  Operator-owned source preferences for one consumer project and dependency.

  Preferences live outside managed repositories. They select only one of the
  source modes already declared by the portable registry; local checkout paths
  and Git coordinates are deliberately not part of this file.
  """

  alias MixWorkspaceOps.StrictJSON

  @schema "mix_workspace_ops.source_preferences/v1"
  @maximum_bytes 1024 * 1024
  @modes ~w(local git hex)
  @project_identifier ~r/^[a-z][a-z0-9_.-]*$/
  @application_identifier ~r/^[a-z][a-z0-9_]*$/

  @type mode :: "local" | "git" | "hex"
  @type t :: %{String.t() => %{String.t() => mode()}}

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec default_path() :: String.t()
  def default_path do
    base = System.get_env("XDG_CONFIG_HOME") || Path.join(System.user_home!(), ".config")
    Path.join([base, "mix_workspace_ops", "source_preferences.json"])
  end

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(path \\ default_path()) do
    path = Path.expand(path)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, %{}}

      {:ok, %{type: :regular} = stat} ->
        with :ok <- bounded(path, stat),
             {:ok, bytes} <- File.read(path),
             {:ok, decoded} <- StrictJSON.decode(bytes, maximum_bytes: @maximum_bytes),
             {:ok, projects} <- validate_document(path, decoded) do
          {:ok, projects}
        end

      {:ok, %{type: type}} ->
        {:error, {:source_preferences_not_regular, path, type}}

      {:error, reason} ->
        {:error, {:source_preferences_read, path, reason}}
    end
  end

  @spec project(t(), String.t()) :: %{String.t() => mode()}
  def project(preferences, project_id) when is_map(preferences) and is_binary(project_id),
    do: Map.get(preferences, project_id, %{})

  @spec get(t(), String.t(), String.t()) :: mode() | nil
  def get(preferences, project_id, application),
    do: preferences |> project(project_id) |> Map.get(application)

  @spec put(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def put(path, project_id, application, source) do
    path = Path.expand(path)

    with :ok <- identifier(:project, project_id),
         :ok <- identifier(:application, application),
         {:ok, mode} <- normalize_mode(source),
         {:ok, preferences} <- load(path) do
      updated =
        Map.update(preferences, project_id, %{application => mode}, fn project ->
          Map.put(project, application, mode)
        end)

      write(path, updated)
    end
  end

  @spec clear(String.t(), String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def clear(path, project_id, application \\ nil) do
    path = Path.expand(path)

    with :ok <- identifier(:project, project_id),
         :ok <- maybe_application(application),
         {:ok, preferences} <- load(path) do
      updated =
        case application do
          nil ->
            Map.delete(preferences, project_id)

          app ->
            case Map.get(preferences, project_id) do
              nil -> preferences
              project -> put_project(preferences, project_id, Map.delete(project, app))
            end
        end

      write(path, updated)
    end
  end

  @spec normalize_mode(String.t()) :: {:ok, mode()} | {:error, term()}
  def normalize_mode("local"), do: {:ok, "local"}
  def normalize_mode("git"), do: {:ok, "git"}
  def normalize_mode("hex"), do: {:ok, "hex"}
  def normalize_mode(source), do: {:error, {:invalid_source_preference, source}}

  @doc "Converts the compact operator vocabulary to Resolution's internal source name."
  @spec resolution_mode(mode() | nil) :: String.t() | nil
  def resolution_mode("git"), do: "github"
  def resolution_mode(mode) when mode in ["local", "hex"], do: mode
  def resolution_mode(nil), do: nil

  defp bounded(_path, %{type: :regular, size: size}) when size <= @maximum_bytes, do: :ok
  defp bounded(path, %{type: :regular}), do: {:error, {:source_preferences_too_large, path}}
  defp bounded(path, %{type: type}), do: {:error, {:source_preferences_not_regular, path, type}}

  defp validate_document(path, %{"schema" => @schema, "projects" => projects} = document)
       when map_size(document) == 2 and is_map(projects) do
    validate_projects(path, projects)
  end

  defp validate_document(path, %{"schema" => schema}) when is_binary(schema),
    do: {:error, {:source_preferences_schema, path, schema}}

  defp validate_document(path, _document), do: {:error, {:invalid_source_preferences, path}}

  defp validate_projects(path, projects) do
    Enum.reduce_while(projects, {:ok, %{}}, fn {project_id, dependencies}, {:ok, acc} ->
      with :ok <- identifier(:project, project_id),
           true <- is_map(dependencies) || {:error, {:invalid_source_preferences_project, project_id}},
           {:ok, normalized} <- validate_dependencies(project_id, dependencies) do
        {:cont, {:ok, Map.put(acc, project_id, normalized)}}
      else
        {:error, reason} -> {:halt, {:error, {:source_preferences, path, reason}}}
        false -> {:halt, {:error, {:source_preferences, path, :invalid_project}}}
      end
    end)
  end

  defp validate_dependencies(project_id, dependencies) do
    Enum.reduce_while(dependencies, {:ok, %{}}, fn {application, source}, {:ok, acc} ->
      with :ok <- identifier(:application, application),
           true <- source in @modes || {:error, {:invalid_source_preference_mode, source}} do
        {:cont, {:ok, Map.put(acc, application, source)}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_source_preference, project_id, application, reason}}}
      end
    end)
  end

  defp identifier(:project, value) when is_binary(value) do
    if Regex.match?(@project_identifier, value),
      do: :ok,
      else: {:error, {:invalid_source_preference_identifier, :project, value}}
  end

  defp identifier(:application, value) when is_binary(value) do
    if Regex.match?(@application_identifier, value),
      do: :ok,
      else: {:error, {:invalid_source_preference_identifier, :application, value}}
  end

  defp identifier(kind, value), do: {:error, {:invalid_source_preference_identifier, kind, value}}
  defp maybe_application(nil), do: :ok
  defp maybe_application(value), do: identifier(:application, value)

  defp put_project(preferences, project_id, project) when map_size(project) == 0,
    do: Map.delete(preferences, project_id)

  defp put_project(preferences, project_id, project), do: Map.put(preferences, project_id, project)

  defp write(path, preferences) do
    directory = Path.dirname(path)
    temporary = Path.join(directory, ".#{Path.basename(path)}.tmp.#{unique_suffix()}")
    bytes = encode(preferences)

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, io} <- File.open(temporary, [:write, :binary, :exclusive]),
         :ok <- write_sync(io, bytes),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      {:ok, path}
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, {:write_source_preferences, path, reason}}
    end
  end

  defp write_sync(io, bytes) do
    result = IO.binwrite(io, bytes)
    sync_result = if result == :ok, do: :file.sync(io), else: result
    close_result = File.close(io)

    cond do
      result != :ok -> result
      sync_result != :ok -> sync_result
      close_result != :ok -> close_result
      true -> :ok
    end
  end

  defp encode(preferences) do
    %{
      "schema" => @schema,
      "projects" =>
        preferences
        |> Enum.sort_by(&elem(&1, 0))
        |> Map.new(fn {project, dependencies} ->
          {project, dependencies |> Enum.sort_by(&elem(&1, 0)) |> Map.new()}
        end)
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
    |> Kernel.<>("\n")
  end

  defp unique_suffix,
    do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
