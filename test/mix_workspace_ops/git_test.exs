defmodule MixWorkspaceOps.GitTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Git
  alias MixWorkspaceOps.Project.ProbeTree

  test "an invocation snapshot is stable while an uncached inspection observes change", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "sample"))
    nested = Path.join(repository, "apps/child")
    File.mkdir_p!(nested)
    memo = :ets.new(__MODULE__, [:set, :public])

    first = Git.state(repository, memo)
    File.write!(Path.join(repository, "untracked"), "new source\n")

    assert Git.state(nested, memo) == first

    changed = Git.state(repository)
    refute changed.source_digest == first.source_digest
    refute changed.clean
  end

  test "source state includes non-secret ignored source but excludes operational and secret files",
       context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "sample"))

    File.write!(Path.join(repository, ".gitignore"), "local.flag\n.env\n_build/\n")
    git_ok!(repository, ["add", ".gitignore"])
    git_ok!(repository, ["commit", "--quiet", "-m", "declare ignored paths"])

    File.write!(Path.join(repository, "local.flag"), "first")
    File.write!(Path.join(repository, ".env"), "first secret")
    File.mkdir_p!(Path.join(repository, "_build/dev"))
    File.write!(Path.join(repository, "_build/dev/cache"), "first build")
    first = Git.state(repository)

    File.write!(Path.join(repository, "local.flag"), "second")
    second = Git.state(repository)
    refute second.source_digest == first.source_digest
    assert second.clean

    File.write!(Path.join(repository, ".env"), "second secret")
    File.write!(Path.join(repository, "_build/dev/cache"), "second build")
    assert Git.state(repository) == second
  end

  test "ignored-source pathspecs prune excluded trees before Git emits their contents", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "sample"))

    File.write!(Path.join(repository, ".gitignore"), "ignored/\n_build/\ndeps/\n.env\n*.pem\n")
    git_ok!(repository, ["add", ".gitignore"])
    git_ok!(repository, ["commit", "--quiet", "-m", "ignore generated trees"])

    for {path, bytes} <- [
          {"ignored/source.txt", "source"},
          {"_build/dev/generated", "build"},
          {"deps/package/generated", "dependency"},
          {".env", "secret"},
          {"private.pem", "secret"}
        ] do
      destination = Path.join(repository, path)
      File.mkdir_p!(Path.dirname(destination))
      File.write!(destination, bytes)
    end

    {output, 0} =
      System.cmd(
        "git",
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"] ++
          ProbeTree.ignored_source_pathspecs(),
        cd: repository
      )

    assert :binary.split(output, <<0>>, [:global, :trim_all]) == ["ignored/source.txt"]
  end

  defp git_ok!(repository, args) do
    assert {_output, 0} = System.cmd("git", args, cd: repository, stderr_to_stdout: true)
  end
end
