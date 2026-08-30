defmodule MixWorkspaceOps.Release.PreflightTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.Registry
  alias MixWorkspaceOps.Release.Preflight

  test "preserves the six structured blocker messages" do
    path = "/operator/core"

    stale = Preflight.evaluate("core", "~> 1.1.0", {:ok, "1.2.3", path})
    missing = Preflight.evaluate("core", nil, {:ok, "1.2.3", path})
    invalid = Preflight.evaluate("core", "not valid", {:ok, "1.2.3", path})
    unreadable = Preflight.evaluate("core", "~> 1.2", {:error, path})

    registry_missing =
      Preflight.evaluate("core", "~> 1.2", {:ok, "1.2.3", path})
      |> Map.merge(%{status: :blocked, reason: :hex_release_missing})

    release_missing = %{
      app: "core",
      package: "client",
      status: :blocked,
      reason: :missing_release_prerequisite,
      hex: nil,
      sibling_version: nil,
      sibling_path: nil,
      required: nil
    }

    assert Preflight.format_blockers([stale]) ==
             "publish preflight refused:\n" <>
               "  core: committed hex constraint \"~> 1.1.0\" does not admit sibling version " <>
               "1.2.3; bump it to \"~> 1.2.0\""

    assert Preflight.format_blockers([missing]) =~
             "core: no committed hex constraint; publishing requires one " <>
               "(\"~> 1.2.0\" admits the sibling version)"

    assert Preflight.format_blockers([invalid]) =~
             "core: committed hex constraint \"not valid\" is not a valid requirement"

    assert Preflight.format_blockers([unreadable]) =~
             "core: sibling checkout /operator/core has no readable mix.exs version"

    assert Preflight.format_blockers([registry_missing]) =~
             "core: sibling version 1.2.3 is not published on Hex"

    assert Preflight.format_blockers([release_missing]) =~
             "core: release prerequisite of client is absent from the portfolio registry"
  end

  test "checks only dependencies declared by this project and leaves non-Hex publish alone",
       context do
    root = temporary_directory!(context)
    client = project!(root, "client", "0.2.0")
    core = project!(root, "core", "1.2.3")

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("unrelated", projects: [catalog_project("unrelated")]),
        catalog_repository("client",
          projects: [catalog_project("client")],
          dependency_sources: %{
            "core" => %{"hex" => "~> 1.1.0"},
            "unrelated" => %{"hex" => "~> 9.0"},
            "source_only" => %{
              "github" => %{"repo" => "third-party/source_only"},
              "order" => ["github"],
              "publish_order" => ["github"]
            }
          },
          release_chain: %{"client" => []}
        )
      ])
      |> Registry.load!()
      |> bind(%{"client" => client, "core" => core})

    assert {:error, [blocker]} =
             Preflight.check(registry, "client", dependencies: ["core", "source_only"])

    assert blocker.app == "core"
    assert blocker.reason == :hex_constraint_stale

    registry = put_in(registry.repositories["client"].dependency_sources["core"].hex, "~> 1.2")

    assert {:ok, entries} =
             Preflight.check(registry, "client", dependencies: ["core", "source_only"])

    assert Enum.map(entries, & &1.app) == ["core", "source_only"]
    assert Enum.find(entries, &(&1.app == "source_only")).publish_source == "github"
    refute Enum.any?(entries, &(&1.app == "unrelated"))
  end

  test "registry absence differs from an unverified transport", context do
    root = temporary_directory!(context)
    client = project!(root, "client", "0.2.0")
    core = project!(root, "core", "1.2.3")

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("client",
          projects: [catalog_project("client")],
          dependency_sources: %{"core" => %{"hex" => "~> 1.2"}},
          release_chain: %{"client" => []}
        )
      ])
      |> Registry.load!()
      |> bind(%{"client" => client, "core" => core})

    assert {:error, [%{reason: :hex_release_missing}]} =
             Preflight.check(registry, "client",
               dependencies: ["core"],
               check_registry?: true,
               registry_lookup: fn "core", "1.2.3" -> :missing end
             )

    assert {:ok, [%{registry: {:unverified, :offline}}]} =
             Preflight.check(registry, "client",
               dependencies: ["core"],
               check_registry?: true,
               registry_lookup: fn "core", "1.2.3" -> {:unverified, :offline} end
             )
  end

  test "an absent provider checkout is unverified rather than unreadable", context do
    root = temporary_directory!(context)
    client = project!(root, "client", "0.2.0")

    registry =
      root
      |> write_catalog!([
        catalog_repository("core", projects: [catalog_project("core")]),
        catalog_repository("client",
          projects: [catalog_project("client")],
          dependency_sources: %{"core" => %{"hex" => "~> 1.2"}},
          release_chain: %{"client" => []}
        )
      ])
      |> Registry.load!()
      |> then(
        &%{&1 | bindings: %{"client" => client}, absent_checkouts: %{"core" => "/absent/core"}}
      )

    assert {:ok, [%{app: "core", status: :unverified, sibling_path: "/absent/core"}]} =
             Preflight.check(registry, "client", dependencies: ["core"])
  end

  defp bind(registry, bindings), do: %{registry | bindings: bindings, absent_checkouts: %{}}

  defp project!(root, app, version) do
    path = Path.join(root, app)
    File.mkdir_p!(path)

    File.write!(
      Path.join(path, "mix.exs"),
      """
      defmodule #{Macro.camelize(app)}.MixProject do
        use Mix.Project
        def project, do: [app: :#{app}, version: \"#{version}\"]
      end
      """
    )

    path
  end
end
