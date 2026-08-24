defmodule MixWorkspaceOps.LocalOverridesTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.LocalOverrides

  test "reads atom and string spellings of the same override", context do
    root = temporary_directory!(context)

    write!(root, """
    %{
      deps: %{
        example_core: %{source: :path, path: "/checkouts/example_core"},
        example_edge: %{source: :hex},
        example_forked: %{source: "github", branch: "trial", subdir: "core/forked"}
      }
    }
    """)

    assert {:ok, overrides} = LocalOverrides.load(root)
    assert Map.keys(overrides) == ~w(example_core example_edge example_forked)

    assert overrides["example_core"].source == "local"
    assert overrides["example_core"].requested_source == "path"
    assert overrides["example_core"].path == ["/checkouts/example_core"]
    assert overrides["example_edge"].source == "hex"

    assert overrides["example_forked"].github == %{
             "branch" => "trial",
             "subdir" => "core/forked"
           }
  end

  test "a path may name several candidates", context do
    root = temporary_directory!(context)
    write!(root, ~s|%{deps: %{example_core: %{source: :path, path: ["/a/core", "/b/core"]}}}|)

    assert {:ok, overrides} = LocalOverrides.load(root)
    assert overrides["example_core"].path == ["/a/core", "/b/core"]

    write!(root, ~s|%{deps: %{example_core: %{path: "/a/core"}}}|)
    assert {:ok, overrides} = LocalOverrides.load(root)
    assert overrides["example_core"].path == ["/a/core"]

    write!(root, ~s|%{deps: %{example_core: %{path: []}}}|)

    assert {:error, {:invalid_override_path, _path, "example_core", []}} =
             LocalOverrides.load(root)
  end

  test "a repository with no file has no overrides", context do
    assert {:ok, %{}} == LocalOverrides.load(temporary_directory!(context))
  end

  test "refuses an expression, so an override file cannot run code", context do
    root = temporary_directory!(context)
    write!(root, ~s|%{deps: %{example_core: %{path: System.get_env("HOME")}}}|)

    assert {:error, {:non_literal_override, _path, 1}} = LocalOverrides.load(root)
  end

  test "no name in the file becomes an atom in this process", context do
    root = temporary_directory!(context)
    name = "override_atom_probe_#{System.unique_integer([:positive])}"
    write!(root, "%{deps: %{#{name}: %{source: :hex}}}")

    assert {:ok, overrides} = LocalOverrides.load(root)
    assert Map.has_key?(overrides, name)
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
  end

  test "refuses a key it does not know rather than ignoring it", context do
    root = temporary_directory!(context)
    write!(root, ~s|%{deps: %{example_core: %{sauce: "hex"}}}|)

    assert {:error, {:unknown_override_keys, _path, "example_core", ["sauce"]}} =
             LocalOverrides.load(root)
  end

  test "refuses a source name it does not know", context do
    root = temporary_directory!(context)
    write!(root, ~s|%{deps: %{example_core: %{source: :svn}}}|)

    assert {:error, {:unknown_override_source, _path, "example_core", "svn"}} =
             LocalOverrides.load(root)
  end

  test "refuses two revisions naming two commits", context do
    root = temporary_directory!(context)
    write!(root, ~s|%{deps: %{example_core: %{branch: "main", tag: "v1"}}}|)

    assert {:error, {:conflicting_override_revision, _path, "example_core", ["branch", "tag"]}} =
             LocalOverrides.load(root)
  end

  defp write!(root, contents) do
    File.write!(Path.join(root, LocalOverrides.filename()), contents)
  end
end
