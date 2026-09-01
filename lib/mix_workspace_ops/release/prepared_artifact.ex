defmodule MixWorkspaceOps.Release.PreparedArtifact do
  @moduledoc """
  Validates the portable handoff emitted by a prepared-artifact owner.

  Loading the handoff never runs the producer or publishes an archive.
  """

  alias MixWorkspaceOps.StrictJSON

  @schema_v2 "mix_workspace_ops.prepared_artifact/v2"
  @digest ~r/^[0-9a-f]{64}$/

  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    with {:ok, bytes} <- File.read(Path.expand(path)),
         {:ok, decoded} <- StrictJSON.decode(bytes, maximum_bytes: 1024 * 1024),
         handoff when is_map(handoff) <- Map.get(decoded, "handoff") do
      parse(handoff)
    else
      nil -> {:error, :missing_prepared_artifact_handoff}
      {:error, reason} -> {:error, reason}
      _value -> {:error, :invalid_prepared_artifact_handoff}
    end
  end

  defp parse(
         %{
           "schema" => @schema_v2,
           "package" => package,
           "version" => version,
           "source_revision" => source_revision,
           "manifest_path" => manifest_path,
           "manifest_sha256" => manifest_sha256,
           "project_path" => project_path,
           "project_sha256" => project_sha256,
           "archive_path" => archive_path,
           "archive_sha256" => archive_sha256
         } = raw
       )
       when map_size(raw) == 10 and is_binary(package) and is_binary(version) and
              is_binary(source_revision) and is_binary(project_path) and
              is_binary(project_sha256) and is_binary(manifest_path) and
              is_binary(manifest_sha256) do
    with :ok <- validate_package(package),
         {:ok, _version} <- Version.parse(version),
         :ok <- validate_revision(source_revision),
         :ok <- validate_relative_path(manifest_path),
         :ok <- validate_digest(manifest_sha256),
         :ok <- validate_relative_path(project_path),
         :ok <- validate_digest(project_sha256),
         {:ok, archive} <- validate_archive(archive_path, archive_sha256) do
      {:ok,
       %{
         package: package,
         version: version,
         source_revision: source_revision,
         manifest_path: manifest_path,
         manifest_sha256: manifest_sha256,
         project_path: project_path,
         project_sha256: project_sha256,
         archive_path: archive.path,
         archive_sha256: archive.sha256
       }}
    else
      :error -> {:error, :invalid_prepared_artifact_version}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse(_raw), do: {:error, :invalid_prepared_artifact_handoff}

  defp validate_package(package) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, package),
      do: :ok,
      else: {:error, :invalid_prepared_artifact_package}
  end

  defp validate_revision(revision) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, revision),
      do: :ok,
      else: {:error, :invalid_prepared_artifact_revision}
  end

  defp validate_relative_path(path) do
    expanded = Path.expand(path, "/artifact")

    if Path.type(path) == :relative and
         (expanded == "/artifact" or String.starts_with?(expanded, "/artifact/")) do
      :ok
    else
      {:error, :invalid_prepared_artifact_path}
    end
  end

  defp validate_digest(digest) do
    if Regex.match?(@digest, digest),
      do: :ok,
      else: {:error, :invalid_prepared_artifact_digest}
  end

  defp validate_archive(archive_path, archive_sha256)
       when archive_path in [nil, :null] and archive_sha256 in [nil, :null],
       do: {:ok, %{path: nil, sha256: nil}}

  defp validate_archive(archive_path, archive_sha256)
       when is_binary(archive_path) and is_binary(archive_sha256) do
    with :ok <- validate_relative_path(archive_path),
         :ok <- validate_digest(archive_sha256) do
      {:ok, %{path: archive_path, sha256: archive_sha256}}
    end
  end

  defp validate_archive(_archive_path, _archive_sha256),
    do: {:error, :invalid_prepared_artifact_archive}
end