defmodule MixWorkspaceOps.RegistryTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Graph, Registry}

  test "allows a non-application workspace root without indexing a fake app", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "workspace"))

    path =
      write_registry!(root, [
        repository("workspace", [
          project("workspace", nil, kind: "workspace_root", app: nil)
        ])
      ])

    assert {:ok, registry} = Registry.load(path)
    assert registry.projects["workspace"].app == nil
    assert registry.applications == %{}
  end

  test "loads, binds, and derives a dependency closure", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "core"))
    initialize_repository!(Path.join(root, "consumer"))

    registry =
      root
      |> write_registry!([
        repository("core", [project("core")]),
        repository("consumer", [project("consumer")])
      ])
      |> Registry.load!()
      |> bind!(root)

    reader = fn item -> {:ok, if(item.id == "consumer", do: ["core"], else: [])} end

    assert {:ok, resolution} = Graph.resolve(registry, "consumer", dependency_reader: reader)
    assert Enum.map(resolution.projects, & &1.id) == ["core", "consumer"]
    assert resolution.edges == [{"consumer", "core"}]
    assert Registry.project_root(registry, "consumer") == Path.join(root, "consumer")
  end

  test "rejects paths that are absolute or escape a repository", context do
    root = temporary_directory!(context)

    absolute = write_registry!(root, [repository("bad", [project("bad", nil, path: "/tmp/bad")])])
    assert {:error, {:absolute_registry_path, "/tmp/bad"}} = Registry.load(absolute)

    escaping = write_registry!(root, [repository("bad", [project("bad", nil, path: "../bad")])])
    assert {:error, {:escaping_registry_path, "../bad"}} = Registry.load(escaping)
  end

  # Mix fetches a dependency with no checkout and resolves that dependency's own
  # dependencies from its own lock. Walking into a checkout that is not there is
  # both impossible and unnecessary, so the edge is recorded and the walk stops.
  test "a dependency with no checkout is a leaf rather than a refusal", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "consumer"))

    registry =
      root
      |> write_catalog!([
        catalog_repository("consumer", projects: [catalog_project("consumer")]),
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("deep", projects: [catalog_project("deep")])
      ])
      |> Registry.load!()
      |> bind!(root)

    assert Registry.absent_repository_ids(registry) == ["core", "deep"]

    reader = fn
      %{id: "consumer"} -> {:ok, ["core"]}
      %{id: id} -> flunk("read the dependencies of #{id}, which has no checkout")
    end

    assert {:ok, resolution} = Graph.resolve(registry, "consumer", dependency_reader: reader)
    assert Enum.map(resolution.projects, & &1.id) == ["core", "consumer"]
    assert resolution.edges == [{"consumer", "core"}]
    assert resolution.external_dependencies == []
  end

  test "records dependencies outside the registry", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "consumer"))

    registry =
      root
      |> write_registry!([repository("consumer", [project("consumer")])])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, resolution} =
             Graph.resolve(registry, "consumer",
               dependency_reader: fn _ -> {:ok, ["external"]} end
             )

    assert resolution.external_dependencies == [{"consumer", "external"}]
  end

  test "rejects generated dependency and build paths", context do
    root = temporary_directory!(context)

    for reserved <- ["deps/pkg", "_build/pkg", ".mix_workspace_ops/pkg"] do
      path = write_registry!(root, [repository("bad", [project("bad", nil, path: reserved)])])
      assert {:error, {:reserved_registry_path, ^reserved}} = Registry.load(path)
    end
  end

  test "binding rejects a checkout with the wrong origin", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "widget"), "[]", "other-org/widget")

    registry =
      root |> write_registry!([repository("widget", [project("widget")])]) |> Registry.load!()

    assert {:error, {:wrong_origin, "widget", "example-org/widget", ["other-org/widget"]}} =
             Registry.bind(registry, root)
  end

  # The safety property, stated as a test rather than as a claim: a checkout may
  # reach its catalogued remote through any of origin's URLs, and a checkout that
  # names a second catalogued repository is refused rather than bound to whichever
  # one the directory happens to be named after.
  test "binding accepts a checkout that reaches its catalogued remote through a push URL",
       context do
    root = temporary_directory!(context)
    checkout = initialize_repository!(Path.join(root, "widget"), "[]", "other-org/widget")
    mirror = Path.join(root, "widget_mirror.git")
    System.cmd("git", ["init", "--bare", "--quiet", mirror])
    System.cmd("git", ["remote", "set-url", "origin", mirror], cd: checkout)

    System.cmd("git", ["remote", "set-url", "--add", "--push", "origin", mirror], cd: checkout)

    System.cmd(
      "git",
      [
        "remote",
        "set-url",
        "--add",
        "--push",
        "origin",
        "https://github.com/example-org/widget.git"
      ],
      cd: checkout
    )

    registry =
      root |> write_registry!([repository("widget", [project("widget")])]) |> Registry.load!()

    assert {:ok, bound} = Registry.bind(registry, root)
    assert bound.bindings == %{"widget" => checkout}
  end

  test "binding refuses a checkout whose origin names two catalogued repositories",
       context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"), "[]", "example-org/alpha")
    impostor = initialize_repository!(Path.join(root, "beta"), "[]", "example-org/alpha")

    System.cmd(
      "git",
      [
        "remote",
        "set-url",
        "--add",
        "--push",
        "origin",
        "https://github.com/example-org/beta.git"
      ],
      cd: impostor
    )

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()

    assert {:error,
            {:ambiguous_origin, "beta", ^impostor, ["example-org/alpha", "example-org/beta"]}} =
             Registry.bind(registry, root)
  end

  test "a local mirror is not an identity, however its directories are laid out",
       context do
    root = temporary_directory!(context)
    checkout = initialize_repository!(Path.join(root, "widget"))
    mirror = Path.join(root, "mirrors/example-org/widget.git")
    File.mkdir_p!(Path.dirname(mirror))
    System.cmd("git", ["init", "--bare", "--quiet", mirror])
    System.cmd("git", ["remote", "set-url", "origin", mirror], cd: checkout)

    registry =
      root |> write_registry!([repository("widget", [project("widget")])]) |> Registry.load!()

    assert {:error, {:wrong_origin, "widget", "example-org/widget", []}} =
             Registry.bind(registry, root)
  end

  test "rejects duplicate JSON keys instead of accepting hidden precedence", context do
    root = temporary_directory!(context)
    path = Path.join(root, "registry.json")

    File.write!(
      path,
      ~s({"schema":"mix_workspace_ops.registry/v1","schema":"other","repositories":[]})
    )

    assert {:error, {:duplicate_json_key, "schema"}} = Registry.load(path)
  end

  test "repository identities may use stable hyphenated names", context do
    root = temporary_directory!(context)

    path =
      write_registry!(root, [
        repository("context-nexus", [
          project("context-nexus.context_nexus", "context_nexus")
        ])
      ])

    assert {:ok, registry} = Registry.load(path)
    assert registry.repositories["context-nexus"].github == "example-org/context-nexus"
  end

  test "a selected view can bind without unrelated checkouts", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"))

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()

    selected = Registry.select(registry, [Registry.project!(registry, "alpha")])
    assert {:ok, bound} = Registry.bind(selected, root)
    assert Map.keys(bound.bindings) == ["alpha"]

    # The catalog is intact and still describes the document its digest names;
    # what narrowed is the selection beside it.
    assert Map.keys(bound.repositories) == ["alpha", "beta"]
    assert bound.digest == registry.digest
    assert Registry.selection(bound).repository_ids == ["alpha"]
    assert Registry.selection(bound).project_ids == ["alpha"]
    assert Enum.map(Registry.selected_repositories(bound), & &1.id) == ["alpha"]
    refute Registry.selected?(bound, "beta")
    assert Registry.selection(bound).digest != registry.digest
  end

  # C9's third set is not distinct data if the second can destroy it. Selecting
  # used to take `bindings` and `absent_checkouts` down to the selection, so a
  # wider re-selection could not see a repository that was on disk the whole
  # time — and `checkout/2` answered `:unknown`, documented as "an id the
  # catalog does not carry", for a catalogued and cloned repository.
  test "a selection scopes what is materialized without destroying it", context do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"))
    beta = initialize_repository!(Path.join(root, "beta"))

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()
      |> bind!(root)

    assert Registry.sets(registry).materialized.repositories == 2

    narrow = Registry.select(registry, [Registry.project!(registry, "alpha")])
    assert Registry.sets(narrow).materialized.repositories == 1
    assert Registry.checkout(narrow, "alpha") == {:bound, alpha}

    wide =
      Registry.select(narrow, [
        Registry.project!(registry, "alpha"),
        Registry.project!(registry, "beta")
      ])

    assert Registry.sets(wide).materialized.repositories == 2
    assert Registry.checkout(wide, "beta") == {:bound, beta}
  end

  # D1: one repository an operator has not cloned used to fail every operation,
  # including the read-only ones. Absence is a fact about a disk, not a
  # contradiction of the catalog, so it is recorded and binding continues.
  test "binding records an absent checkout and binds the rest", context do
    root = temporary_directory!(context)
    alpha = initialize_repository!(Path.join(root, "alpha"))

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")]),
        repository("gamma", [project("gamma")])
      ])
      |> Registry.load!()

    assert {:ok, bound} = Registry.bind(registry, root)
    assert bound.bindings == %{"alpha" => alpha}

    assert bound.absent_checkouts == %{
             "beta" => Path.join(root, "beta"),
             "gamma" => Path.join(root, "gamma")
           }

    assert Registry.bound_repository_ids(bound) == ["alpha"]
    assert Registry.absent_repository_ids(bound) == ["beta", "gamma"]
    assert Registry.checkout(bound, "alpha") == {:bound, alpha}
    assert Registry.checkout(bound, "beta") == {:absent, Path.join(root, "beta")}
    assert Registry.checkout(bound, "delta") == :unknown
  end

  # An invalid checkout still stops binding. A directory that is not a Git root
  # contradicts the catalog rather than describing what an operator has cloned.
  test "binding still refuses an invalid checkout while others are absent", context do
    root = temporary_directory!(context)
    File.mkdir_p!(Path.join(root, "alpha"))

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()

    assert {:error, {:git_root, _reason}} = Registry.bind(registry, root)
  end

  # An operator binding file reaches a checkout outside the conventional root,
  # which is how a repository cloned somewhere else stops being absent.
  test "a binding file resolves a checkout outside the conventional root", context do
    root = temporary_directory!(context)
    elsewhere = temporary_directory!(context)
    beta = initialize_repository!(Path.join(elsewhere, "beta"))
    initialize_repository!(Path.join(root, "alpha"))

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()

    binding_file = Path.join(root, "binding.json")
    File.write!(binding_file, :json.encode(%{"beta" => beta}))

    assert {:ok, bound} = Registry.bind(registry, root, binding_file: binding_file)
    assert bound.absent_checkouts == %{}
    assert bound.bindings["beta"] == beta
  end

  # Item 7: eligibility is what the catalog permits, requirement is what one
  # operation cannot proceed without, and only the second is fatal.
  test "require_bound names the path an absent required repository was sought at", context do
    root = temporary_directory!(context)
    initialize_repository!(Path.join(root, "alpha"))

    registry =
      root
      |> write_registry!([
        repository("alpha", [project("alpha")]),
        repository("beta", [project("beta")])
      ])
      |> Registry.load!()

    assert {:ok, bound} = Registry.bind(registry, root)
    assert Registry.require_bound(bound, ["alpha"]) == :ok
    expected = Path.join(root, "beta")

    assert Registry.require_bound(bound, ["alpha", "beta"]) ==
             {:error, {:absent_required_checkout, "beta", expected}}
  end

  test "strict JSON refuses oversized input before decoding" do
    assert {:error, {:json_too_large, 7, 4}} =
             MixWorkspaceOps.StrictJSON.decode("{\"a\":1}", maximum_bytes: 4)
  end
end
