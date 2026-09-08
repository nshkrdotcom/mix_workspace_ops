defmodule MixWorkspaceOps.DependencyRequirementTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.DependencyRequirement

  test "a populated Hex selection is checked against every original requirement", context do
    root = temporary_directory!(context)
    lockfile = Path.join(root, "mix.lock")

    File.write!(
      lockfile,
      inspect(%{leaf: {:hex, :leaf, "1.4.2", "inner", [:mix], [], "hexpm", checksum("leaf")}})
    )

    report = %{
      dependency_applications: [
        %{application: "leaf", consumer: "middle", requirement: string_requirement("~> 2.0")}
      ],
      decisions: [%{application: "leaf", source: "hex", provider: nil, location: "~> 1.0"}]
    }

    assert {:error,
            {:dependency_requirement_mismatch, "leaf", "middle", "~> 2.0", "hex", "1.4.2"}} =
             DependencyRequirement.validate_runtime(report, lockfile, Path.join(root, "deps"))
  end

  test "a populated Git subdirectory is validated from authoritative contained metadata",
       context do
    root = temporary_directory!(context)
    leaf = Path.join([root, "deps", "leaf", "apps", "leaf"])
    File.mkdir_p!(leaf)

    File.write!(Path.join(leaf, "mix.exs"), """
    defmodule Leaf.MixProject do
      use Mix.Project
      def project, do: [app: :leaf, version: File.read!("version.txt")]
    end
    """)

    File.write!(Path.join(leaf, "version.txt"), "2.3.0")

    lockfile = Path.join(root, "mix.lock")
    File.write!(lockfile, "%{}\n")

    report = %{
      dependency_applications: [
        %{application: "leaf", consumer: "middle", requirement: string_requirement("~> 2.0")}
      ],
      decisions: [
        %{
          application: "leaf",
          source: "github",
          provider: "leaf",
          location: %{repo: "example/leaf", subdir: "apps/leaf"}
        }
      ]
    }

    assert :ok = DependencyRequirement.validate_runtime(report, lockfile, Path.join(root, "deps"))
  end

  test "regular-expression requirements remain authoritative" do
    uses = [
      %{consumer: "middle", requirement: %{kind: "regex", value: "^3\\.", opts: ""}}
    ]

    assert :ok = DependencyRequirement.validate_version("leaf", "leaf", "3.2.1", uses)

    assert {:error,
            {:dependency_requirement_mismatch, "leaf", "middle", "~r/^3\\./", "leaf", "4.0.0"}} =
             DependencyRequirement.validate_version("leaf", "leaf", "4.0.0", uses)
  end

  defp string_requirement(value), do: %{kind: "string", value: value}

  defp checksum(bytes),
    do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
