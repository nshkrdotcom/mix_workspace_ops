defmodule MixWorkspaceOps.DependencyLockTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.DependencyLock

  @inner String.duplicate("a", 64)
  @outer String.duplicate("b", 64)
  @commit String.duplicate("c", 40)

  test "normalizes exact Hex and Git objects without evaluating the lock" do
    lock = """
    %{
      "renamed_app" => {:hex, :package_name, "1.2.3", "#{@inner}", [:mix], [], "hexpm", "#{@outer}"},
      "git_app" => {:git, "https://example.invalid/repo.git", "#{@commit}", [branch: "main", subdir: "apps/git_app"]},
      "path_app" => {:path, "../path_app"}
    }
    """

    assert {:ok, objects} = DependencyLock.parse(lock)

    assert [hex] = objects.hex
    assert hex.app == "renamed_app"
    assert hex.package == "package_name"
    assert hex.version == "1.2.3"
    assert hex.inner_checksum == @inner
    assert hex.outer_checksum == @outer
    assert hex.repository == "hexpm"
    assert Regex.match?(~r/^[0-9a-f]{64}$/, hex.identity)

    assert [git] = objects.git
    assert git.app == "git_app"
    assert git.remote == "https://example.invalid/repo.git"
    assert git.commit == @commit
    assert git.options == [branch: "main", subdir: "apps/git_app"]
    assert Regex.match?(~r/^[0-9a-f]{64}$/, git.identity)
  end

  test "refuses executable syntax" do
    sentinel = Path.join(System.tmp_dir!(), "mwo-lock-sentinel-#{System.unique_integer()}")
    bytes = ~s|File.write!(#{inspect(sentinel)}, "executed")|

    assert {:error, {:lock_literal, _form}} = DependencyLock.parse(bytes)
    assert {:error, {:lock_literal, _form}} = DependencyLock.project(bytes, ["unsafe"])
    refute File.exists?(sentinel)
  end

  test "refuses dependency application names that are not one path component" do
    lock =
      inspect(%{
        :"../escape" => {:hex, :jason, "1.4.5", @inner, [:mix], [], "hexpm", @outer}
      })

    assert DependencyLock.parse(lock) == {:error, {:dependency_application, "../escape"}}
  end

  test "projects path-backed applications without evaluating or changing the others" do
    lock = """
    %{
      "hex_app" => {:hex, :hex_app, "1.0.0", "#{@inner}", [:mix], [], "hexpm", "#{@outer}"},
      "git_app" => {:git, "https://example.invalid/repo.git", "#{@commit}", [ref: "#{@commit}"]}
    }
    """

    assert {:ok, projected} = DependencyLock.project(lock, [:hex_app])
    assert {:ok, objects} = DependencyLock.parse(projected)
    assert objects.hex == []
    assert [%{app: "git_app", commit: @commit}] = objects.git
    refute projected =~ "hex_app"

    assert DependencyLock.project(lock, []) == {:ok, lock}
  end

  test "semantic lock digests ignore formatting and atom-versus-string app keys" do
    first = ~s|%{"git_app" => {:git, "https://example.invalid/repo.git", "#{@commit}", []}}|
    second = ~s|%{git_app: {:git, "https://example.invalid/repo.git", "#{@commit}", []}}\n|

    assert {:ok, digest} = DependencyLock.semantic_digest(first)
    assert DependencyLock.semantic_digest(second) == {:ok, digest}

    duplicate =
      ~s|%{"git_app" => {:git, "a", "#{@commit}", []}, git_app: {:git, "b", "#{@commit}", []}}|

    assert DependencyLock.semantic_digest(duplicate) ==
             {:error, {:duplicate_lock_application, "git_app"}}
  end

  test "names malformed exact identities" do
    lock = ~s|%{"bad" => {:hex, :bad, "1.0.0", "short", [], [], "hexpm", "#{@outer}"}}|
    assert DependencyLock.parse(lock) == {:error, {:hex_checksum, :inner, "bad", "short"}}

    invalid = String.duplicate("z", 64)
    lock = ~s|%{"bad" => {:hex, :bad, "1.0.0", "#{invalid}", [], [], "hexpm", "#{@outer}"}}|

    assert DependencyLock.parse(lock) ==
             {:error, {:hex_checksum, :inner, "bad", invalid}}
  end
end
