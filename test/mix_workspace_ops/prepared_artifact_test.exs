defmodule MixWorkspaceOps.PreparedArtifactTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.Release.PreparedArtifact

  test "loads the portable handoff without producer coupling", context do
    path = Path.join(System.tmp_dir!(), "mwo-handoff-#{context.test}.json")

    File.write!(path, """
    {"producer":"fixture","handoff":{
      "schema":"mix_workspace_ops.prepared_artifact/v2",
      "package":"sample_package","version":"1.2.0",
      "source_revision":"#{String.duplicate("a", 40)}",
      "manifest_path":"packaging/weld/sample.exs",
      "manifest_sha256":"#{String.duplicate("d", 64)}",
      "project_path":"project","project_sha256":"#{String.duplicate("b", 64)}",
      "archive_path":"sample_package-1.2.0.tar",
      "archive_sha256":"#{String.duplicate("c", 64)}"
    }}
    """)

    assert {:ok, handoff} = PreparedArtifact.load(path)
    assert handoff.package == "sample_package"
    assert handoff.manifest_path == "packaging/weld/sample.exs"
    assert handoff.manifest_sha256 == String.duplicate("d", 64)
    assert handoff.project_path == "project"
    assert handoff.archive_path == "sample_package-1.2.0.tar"
  end

  test "accepts an internal artifact without an archive", context do
    path = Path.join(System.tmp_dir!(), "mwo-internal-handoff-#{context.test}.json")

    File.write!(path, """
    {"handoff":{
      "schema":"mix_workspace_ops.prepared_artifact/v2",
      "package":"internal_artifact","version":"0.1.0",
      "source_revision":"#{String.duplicate("d", 40)}",
      "manifest_path":"packaging/weld/internal.exs",
      "manifest_sha256":"#{String.duplicate("f", 64)}",
      "project_path":"project","project_sha256":"#{String.duplicate("e", 64)}",
      "archive_path":null,"archive_sha256":null
    }}
    """)

    assert {:ok, %{archive_path: nil, archive_sha256: nil}} = PreparedArtifact.load(path)
  end

  test "rejects the removed v1 handoff schema", context do
    path = Path.join(System.tmp_dir!(), "mwo-v1-handoff-#{context.test}.json")

    File.write!(path, """
    {"handoff":{
      "schema":"mix_workspace_ops.prepared_artifact/v1",
      "package":"sample_package","version":"1.2.0",
      "source_revision":"#{String.duplicate("a", 40)}",
      "project_path":"project","project_sha256":"#{String.duplicate("b", 64)}",
      "archive_path":"sample_package-1.2.0.tar",
      "archive_sha256":"#{String.duplicate("c", 64)}"
    }}
    """)

    assert {:error, :invalid_prepared_artifact_handoff} = PreparedArtifact.load(path)
  end
end
