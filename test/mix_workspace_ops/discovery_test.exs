defmodule MixWorkspaceOps.DiscoveryTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Discovery

  test "inventories non-Elixir repositories and ordinary directories with an injected date",
       context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    beta = initialize_repository!(Path.join(root, "beta"), "[]", "example-org/beta")
    File.rm!(Path.join(beta, "mix.exs"))
    File.write!(Path.join(beta, "README.md"), "non-Elixir fixture\n")
    git!(beta, ["add", "-A"])
    git!(beta, ["commit", "--quiet", "-m", "replace Mix project"])
    File.mkdir_p!(Path.join(root, "ordinary"))

    assert {:ok, inventory} =
             Discovery.inventory(root, clock: fn -> ~D[2031-02-03] end)

    assert inventory.observed_on == "2031-02-03"
    assert Enum.map(inventory.entries, & &1["name"]) == ["alpha", "beta", "ordinary"]

    assert %{"status" => "discovered", "mix_files" => ["mix.exs"]} =
             Enum.find(inventory.entries, &(&1["name"] == "alpha"))

    assert %{"status" => "discovered", "mix_files" => []} =
             Enum.find(inventory.entries, &(&1["name"] == "beta"))

    assert %{"status" => "not_a_repository"} =
             Enum.find(inventory.entries, &(&1["name"] == "ordinary"))
  end

  test "inspector failure remains typed while a successful peer remains visible", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    initialize_repository!(Path.join(root, "beta"), "[]", "example-org/beta")

    inspector = fn path ->
      if Path.basename(path) == "beta", do: {:error, :broken_inspector}, else: {:ok, []}
    end

    assert {:ok, inventory} = Discovery.inventory(root, mix_inspector: inspector)
    assert Enum.find(inventory.entries, &(&1["name"] == "alpha"))["status"] == "discovered"

    beta = Enum.find(inventory.entries, &(&1["name"] == "beta"))
    assert beta["status"] == "failed"
    assert beta["reason"] =~ "broken_inspector"
    assert inventory.summary["failed"] == 1
  end

  test "permission and task failures are evidence rather than skips", context do
    root = temporary_directory!(context)
    denied = initialize_repository!(Path.join(root, "denied"), "[]", "example-org/denied")
    initialize_repository!(Path.join(root, "killed"), "[]", "example-org/killed")
    File.chmod!(denied, 0o000)
    on_exit(fn -> File.chmod(denied, 0o755) end)

    inspector = fn path ->
      if Path.basename(path) == "killed", do: Process.exit(self(), :kill), else: {:ok, []}
    end

    assert {:ok, inventory} = Discovery.inventory(root, mix_inspector: inspector)
    assert inventory.summary["failed"] == 2

    denied_entry = Enum.find(inventory.entries, &(&1["name"] == "denied"))
    assert denied_entry["status"] == "failed"
    assert denied_entry["reason"] =~ "git_marker"
    assert denied_entry["reason"] =~ "eacces"

    killed_entry = Enum.find(inventory.entries, &(&1["name"] == "killed"))
    assert killed_entry["status"] == "failed"
    assert killed_entry["reason"] =~ "task_exit"
    assert killed_entry["reason"] =~ "killed"
  end

  test "production observation date comes from the command clock", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert discovery.snapshot.observed_on == Date.to_iso8601(Date.utc_today())
    refute discovery.snapshot.observed_on == "2026-08-11"

    assert {:error, {:invalid_observation_clock, :forged}} =
             Discovery.inventory(root, clock: fn -> :forged end)
  end

  test "discovers only canonical checkouts for the requested owner", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    initialize_repository!(Path.join(root, "foreign"), "[]", "other-org/foreign")
    initialize_repository!(Path.join(root, "wrong-name"), "[]", "example-org/different")

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert discovery.schema == "mix_workspace_ops.discovery/v1"
    assert discovery.registry.schema == "mix_workspace_ops.discovery_candidates/v1"

    assert [%{"github" => "example-org/alpha", "projects" => [project]}] =
             discovery.registry.repositories

    assert project["app"] == "alpha"
    assert project["id"] == "alpha"
    assert discovery.snapshot.repositories == 1
    assert discovery.snapshot.projects == 1
    assert discovery.snapshot.unresolved == []
  end

  test "inventory observes a local-only origin but registration does not invent its identity",
       context do
    base = temporary_directory!(context)
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    alpha = initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    local_origin = Path.join(base, "mirrors/alpha.git")
    File.mkdir_p!(Path.dirname(local_origin))
    {_, 0} = System.cmd("git", ["clone", "--quiet", "--bare", alpha, local_origin])
    git!(alpha, ["remote", "set-url", "origin", local_origin])

    assert {:ok, inventory} = Discovery.inventory(root)

    assert [%{"status" => "discovered", "identities" => [], "remotes" => [^local_origin]}] =
             inventory.entries

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert discovery.registry.repositories == []
  end

  test "malformed hosted identity remains failed evidence", context do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    malformed = "https://github.com/example-org/alpha/extra"
    git!(alpha, ["remote", "set-url", "origin", malformed])

    assert {:ok, inventory} = Discovery.inventory(root)
    assert [%{"status" => "failed", "reason" => reason}] = inventory.entries
    assert reason =~ "remote_identity"
    assert reason =~ malformed
  end

  test "linked worktrees are inventory evidence but never registration candidates", context do
    base = temporary_directory!(context)
    source = initialize_repository!(Path.join(base, "source"), "[]", "example-org/alpha")
    root = Path.join(base, "checkouts")
    File.mkdir_p!(root)
    worktree = Path.join(root, "alpha")

    git!(source, ["worktree", "add", "--quiet", "-b", "registration-proof", worktree])

    assert {:ok, inventory} = Discovery.inventory(root)
    assert [%{"status" => "discovered", "kind" => "worktree"}] = inventory.entries

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert discovery.registry.repositories == []
    assert [%{"kind" => "worktree"}] = discovery.snapshot.entries
  end

  test "keeps an exact standalone application and records shadowed copies", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    initialize_repository!(Path.join(root, "beta"), "[]", "example-org/beta")
    beta_mix = Path.join(root, "beta/mix.exs")
    File.write!(beta_mix, String.replace(File.read!(beta_mix), "app: :beta", "app: :alpha"))

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert [%{"id" => "alpha"}] = discovery.registry.repositories
    assert [%{"reason" => "shadowed_application:alpha:alpha"}] = discovery.snapshot.unresolved
  end

  test "moves genuinely ambiguous application identities to unresolved evidence", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    initialize_repository!(Path.join(root, "beta"), "[]", "example-org/beta")

    for repository <- ~w(alpha beta) do
      mix_file = Path.join([root, repository, "mix.exs"])
      File.write!(mix_file, String.replace(File.read!(mix_file), ~r/app: :\w+/, "app: :shared"))
    end

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert discovery.registry.repositories == []

    assert Enum.all?(
             discovery.snapshot.unresolved,
             &(&1["reason"] == "duplicate_application:shared")
           )
  end

  test "does not treat archived dependency trees as live projects", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "alpha")
    initialize_repository!(repository, "[]", "example-org/alpha")
    archived = Path.join(repository, "_legacy/deps_legacy_20260302/copied")
    File.mkdir_p!(archived)

    File.write!(Path.join(archived, "mix.exs"), """
    defmodule Copied.MixProject do
      use Mix.Project

      def project, do: [app: :copied, version: "0.1.0"]
    end
    """)

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert [%{"projects" => [%{"app" => "alpha"}]}] = discovery.registry.repositories
  end

  test "falls back to the remote main branch instead of a current feature branch", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")

    {_, 0} =
      System.cmd("git", ["update-ref", "refs/remotes/origin/main", "HEAD"], cd: repository)

    {_, 0} = System.cmd("git", ["switch", "--quiet", "-c", "feature/work"], cd: repository)

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert [%{"default_branch" => "main"}] = discovery.registry.repositories
  end

  test "keeps a non-application umbrella root as a workspace target", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "umbrella"), "[]", "example-org/umbrella")
    File.mkdir_p!(Path.join(repository, "apps/child"))

    File.write!(Path.join(repository, "mix.exs"), """
    defmodule Umbrella.MixProject do
      use Mix.Project
      def project, do: [apps_path: "apps", version: "0.1.0"]
    end
    """)

    File.write!(Path.join(repository, "apps/child/mix.exs"), """
    defmodule Child.MixProject do
      use Mix.Project
      def project, do: [app: :child, version: "0.1.0"]
    end
    """)

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert [%{"projects" => projects}] = discovery.registry.repositories
    assert Enum.any?(projects, &(&1["id"] == "umbrella" and is_nil(&1["app"])))
    assert Enum.any?(projects, &(&1["app"] == "child"))
  end

  test "does not discard a real project merely because it lives under examples", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "lab"), "[]", "example-org/lab")
    File.mkdir_p!(Path.join(repository, "sandbox/examples/proof"))

    File.write!(Path.join(repository, "sandbox/examples/proof/mix.exs"), """
    defmodule Proof.MixProject do
      use Mix.Project
      def project, do: [app: :proof, version: "0.1.0"]
    end
    """)

    assert {:ok, discovery} = Discovery.scan(root, "example-org")
    assert [%{"projects" => projects}] = discovery.registry.repositories
    assert Enum.any?(projects, &(&1["id"] == "lab" and &1["kind"] == "standalone"))
    assert Enum.any?(projects, &(&1["app"] == "proof"))
  end

  defp git!(repository, args) do
    {output, 0} = System.cmd("git", args, cd: repository, stderr_to_stdout: true)
    output
  end
end