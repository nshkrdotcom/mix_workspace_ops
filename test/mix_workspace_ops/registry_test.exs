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

    restricted = Registry.restrict(registry, [Registry.project!(registry, "alpha")])
    assert {:ok, bound} = Registry.bind(restricted, root)
    assert Map.keys(bound.repositories) == ["alpha"]
    assert Map.keys(bound.bindings) == ["alpha"]
  end

  test "strict JSON refuses oversized input before decoding" do
    assert {:error, {:json_too_large, 7, 4}} =
             MixWorkspaceOps.StrictJSON.decode("{\"a\":1}", maximum_bytes: 4)
  end
end
