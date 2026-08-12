defmodule MixWorkspaceOps.Release.Descriptor do
  @moduledoc "Strict operator-owned input for a concrete release transaction."

  @schema "mix_workspace_ops.release/v1"

  alias MixWorkspaceOps.StrictJSON

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, bytes} <- File.read(Path.expand(path)),
         {:ok, decoded} <- decode(bytes) do
      parse(decoded)
    end
  end

  defp parse(
         %{
           "schema" => @schema,
           "repository" => repository,
           "project_path" => project_path,
           "package" => package,
           "version" => version,
           "tag" => tag,
           "default_branch" => default_branch,
           "gates" => gates,
           "publisher_prefix" => publisher_prefix
         } = raw
       )
       when map_size(raw) == 9 and is_binary(repository) and is_binary(project_path) and
              is_binary(package) and is_binary(version) and is_binary(tag) and
              is_binary(default_branch) and is_list(gates) and is_list(publisher_prefix) do
    with :ok <- require_absolute_repository(repository),
         :ok <- require_relative_project(project_path),
         :ok <- require_identifier(package),
         :ok <- require_version(version),
         :ok <- require_tag(tag, package, version),
         :ok <- require_branch(default_branch),
         :ok <- require_argv_list(gates, :gates),
         :ok <- require_publisher_prefix(publisher_prefix) do
      {:ok,
       %{
         repository: Path.expand(repository),
         project_path: project_path,
         package: package,
         version: version,
         tag: tag,
         default_branch: default_branch,
         gates: gates,
         publisher_prefix: publisher_prefix
       }}
    end
  end

  defp parse(_decoded), do: {:error, :invalid_release_descriptor}

  defp decode(bytes) do
    StrictJSON.decode(bytes, maximum_bytes: 1024 * 1024)
  end

  defp require_absolute_repository(path) do
    if Path.type(path) == :absolute, do: :ok, else: {:error, :repository_must_be_absolute}
  end

  defp require_relative_project(path) do
    expanded = Path.expand(path, "/repository")
    segments = Path.split(path)

    if Path.type(path) == :relative and
         (expanded == "/repository" or String.starts_with?(expanded, "/repository/")) and
         not Enum.any?(segments, &(&1 in [".git", "_build", "deps"])) do
      :ok
    else
      {:error, :invalid_project_path}
    end
  end

  defp require_identifier(value) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, value), do: :ok, else: {:error, :invalid_package}
  end

  defp require_version(value) do
    case Version.parse(value) do
      {:ok, _version} -> :ok
      :error -> {:error, :invalid_version}
    end
  end

  defp require_tag(tag, package, version) do
    if tag in ["v#{version}", "#{package}-v#{version}"],
      do: :ok,
      else: {:error, :tag_must_match_version}
  end

  defp require_branch(branch) do
    if branch != "" and not String.contains?(branch, ["..", " ", "~", "^", ":"]),
      do: :ok,
      else: {:error, :invalid_default_branch}
  end

  defp require_argv_list([_first | _rest] = values, label) do
    if Enum.all?(values, &(require_argv(&1, label) == :ok)),
      do: :ok,
      else: {:error, {:invalid_argv_list, label}}
  end

  defp require_argv_list(_values, label), do: {:error, {:invalid_argv_list, label}}

  defp require_publisher_prefix([executable | _arguments] = prefix) do
    with :ok <- require_argv(prefix, :publisher_prefix),
         true <- Path.type(executable) == :absolute do
      :ok
    else
      false -> {:error, :publisher_executable_must_be_absolute}
      error -> error
    end
  end

  defp require_publisher_prefix(_prefix), do: {:error, {:invalid_argv, :publisher_prefix}}

  defp require_argv([executable | arguments], _label)
       when is_binary(executable) and executable != "" do
    if Enum.all?(arguments, &is_binary/1), do: :ok, else: {:error, :invalid_argv}
  end

  defp require_argv(_argv, label), do: {:error, {:invalid_argv, label}}
end
