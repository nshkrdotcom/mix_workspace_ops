defmodule MixWorkspaceOps.Release.Descriptor do
  @moduledoc "Strict operator-owned input for a concrete release transaction."

  @schema "mix_workspace_ops.release/v1"
  @chain_schema "mix_workspace_ops.release_descriptor/v2"
  @digest ~r/^[0-9a-f]{64}$/

  alias MixWorkspaceOps.StrictJSON

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, bytes} <- File.read(Path.expand(path)),
         {:ok, decoded} <- decode(bytes) do
      parse(decoded)
    end
  end

  @doc "Loads the strict operator-owned descriptor for a catalogued release chain."
  @spec load_chain(String.t()) :: {:ok, map()} | {:error, term()}
  def load_chain(path) do
    with {:ok, bytes} <- File.read(Path.expand(path)),
         {:ok, decoded} <- decode(bytes) do
      parse_chain(decoded)
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
         :ok <- require_publisher_prefix(publisher_prefix),
         :ok <- reject_embedded_credentials(gates),
         :ok <- reject_embedded_credentials(publisher_prefix) do
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

  defp parse_chain(
         %{
           "schema" => @chain_schema,
           "release_plan_digest" => plan_digest,
           "registry_digest" => registry_digest,
           "publisher_prefix" => publisher_prefix,
           "packages" => packages
         } = raw
       )
       when map_size(raw) == 5 and is_binary(plan_digest) and is_binary(registry_digest) and
              is_list(publisher_prefix) and is_map(packages) do
    with :ok <- require_digest(plan_digest, :invalid_release_plan_digest),
         :ok <- require_digest(registry_digest, :invalid_release_registry_digest),
         :ok <- require_publisher_prefix(publisher_prefix),
         :ok <- reject_embedded_credentials(publisher_prefix),
         {:ok, parsed} <- parse_packages(packages) do
      {:ok,
       %{
         schema: @chain_schema,
         release_plan_digest: plan_digest,
         registry_digest: registry_digest,
         publisher_prefix: publisher_prefix,
         packages: parsed
       }}
    end
  end

  defp parse_chain(_decoded), do: {:error, :invalid_release_chain_descriptor}

  defp parse_packages(packages) when map_size(packages) > 0 do
    packages
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {package, raw}, {:ok, acc} ->
      with :ok <- require_identifier(package),
           {:ok, parsed} <- parse_package(package, raw) do
        {:cont, {:ok, Map.put(acc, package, parsed)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp parse_packages(_packages), do: {:error, :empty_release_packages}

  defp parse_package(
         package,
         %{
           "version" => version,
           "tag" => tag,
           "gates" => gates,
           "prepared_artifact" => prepared
         } = raw
       )
       when map_size(raw) == 4 and is_binary(version) and is_binary(tag) and is_list(gates) do
    with :ok <- require_version(version),
         :ok <- require_tag(tag, package, version),
         :ok <- require_argv_list(gates, :gates),
         :ok <- reject_embedded_credentials(gates),
         {:ok, prepared_artifact} <- parse_prepared_artifact(prepared) do
      {:ok, %{version: version, tag: tag, gates: gates, prepared_artifact: prepared_artifact}}
    end
  end

  defp parse_package(package, _raw), do: {:error, {:invalid_release_package_descriptor, package}}

  defp parse_prepared_artifact(nil), do: {:ok, nil}

  defp parse_prepared_artifact(
         %{
           "expected_handoff" => expected,
           "prepare" => prepare,
           "rebuilt_handoff" => rebuilt
         } = raw
       )
       when map_size(raw) == 3 and is_binary(expected) and is_list(prepare) and
              is_binary(rebuilt) do
    with true <- Path.type(expected) == :absolute || {:error, :expected_handoff_must_be_absolute},
         :ok <- require_argv(prepare, :prepared_artifact),
         :ok <- require_relative_project(rebuilt),
         :ok <- reject_embedded_credentials(prepare) do
      {:ok,
       %{expected_handoff: Path.expand(expected), prepare: prepare, rebuilt_handoff: rebuilt}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_prepared_artifact(_raw), do: {:error, :invalid_prepared_artifact_descriptor}

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

  defp require_digest(value, reason) do
    if Regex.match?(@digest, value), do: :ok, else: {:error, reason}
  end

  defp reject_embedded_credentials(argv) do
    arguments =
      case argv do
        [[_executable | _arguments] | _rest] ->
          Enum.flat_map(argv, fn [_executable | arguments] -> arguments end)

        [_executable | arguments] ->
          arguments

        other ->
          List.flatten(other)
      end

    if Enum.any?(arguments, &credential_argument?/1),
      do: {:error, :credential_embedded_in_descriptor},
      else: :ok
  end

  defp credential_argument?(argument) when is_binary(argument) do
    normalized = String.downcase(argument)

    Enum.any?(
      ~w(hex_api_key api-key api_key authorization password token secret),
      &String.contains?(normalized, &1)
    )
  end

  defp credential_argument?(_argument), do: false

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
