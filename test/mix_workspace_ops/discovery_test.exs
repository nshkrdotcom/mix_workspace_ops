defmodule MixWorkspaceOps.DiscoveryTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Discovery

  test "discovers only canonical checkouts for the requested owner", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    initialize_repository!(Path.join(root, "foreign"), "[]", "other-org/foreign")
    initialize_repository!(Path.join(root, "wrong-name"), "[]", "example-org/different")

    assert {:ok, discovery} = Discovery.scan(root, "example-org")

    assert [%{"github" => "example-org/alpha", "projects" => [project]}] =
             discovery.registry.repositories

    assert project["app"] == "alpha"
    assert project["id"] == "alpha"
    assert discovery.snapshot.repositories == 1
    assert discovery.snapshot.projects == 1
    assert discovery.snapshot.unresolved == []
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
end
