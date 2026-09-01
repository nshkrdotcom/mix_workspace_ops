defmodule MixWorkspaceOps.LockfileTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.Lockfile

  test "parses literal lock maps without evaluating expressions" do
    bytes =
      inspect(%{
        alpha: {:hex, :alpha, "1.0.0", "inner", [:mix], [], "hexpm", "outer"},
        beta: {:git, "https://example.invalid/beta.git", String.duplicate("a", 40), [ref: "main"]}
      }) <> "\n"

    assert {:ok, lock} = Lockfile.parse_map(bytes)
    assert Map.has_key?(lock, :alpha)
    assert Map.has_key?(lock, :beta)

    assert {:error, {:lock_literal, _expression}} =
             Lockfile.parse_map(~S|%{alpha: System.cmd("sh", ["-c", "false"])}| <> "\n")
  end

  test "projects only named top-level path applications" do
    bytes =
      inspect(%{
        alpha: {:hex, :alpha, "1.0.0"},
        beta: {:git, "https://example.invalid/beta.git", String.duplicate("a", 40), []}
      }) <> "\n"

    assert {:ok, projected} = Lockfile.project_path_apps(bytes, ["alpha"])
    assert {:ok, lock} = Lockfile.parse_map(projected)
    refute Map.has_key?(lock, :alpha)
    assert Map.has_key?(lock, :beta)

    assert {:ok, ^bytes} = Lockfile.project_path_apps(bytes, [])
  end

  test "projected string keys use map arrows rather than quoted keyword syntax" do
    bytes =
      inspect(%{
        "alpha" => {:hex, :alpha, "1.0.0"},
        "beta" => {:hex, :beta, "2.0.0"}
      }) <> "\n"

    assert {:ok, projected} = Lockfile.project_path_apps(bytes, ["beta"])
    assert projected =~ ~s("alpha" =>)
    refute projected =~ ~s("alpha":)
    assert {:ok, %{"alpha" => {:hex, :alpha, "1.0.0"}}} = Lockfile.parse_map(projected)
  end

  test "digests the exact validated private lock bytes" do
    bytes = "%{}\n"
    expected = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = Lockfile.digest(bytes)
  end
end
