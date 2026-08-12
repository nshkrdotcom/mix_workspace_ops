defmodule MixWorkspaceOps.WorkspaceCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  using do
    quote do
      import MixWorkspaceOps.WorkspaceCase
    end
  end

  @spec temporary_directory!(ExUnit.Callbacks.t()) :: String.t()
  def temporary_directory!(context) do
    path =
      Path.join(
        System.tmp_dir!(),
        "mix_workspace_ops_#{context.test}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  @spec initialize_repository!(String.t(), String.t(), String.t()) :: String.t()
  def initialize_repository!(path, deps \\ "[]", github \\ nil) do
    File.mkdir_p!(path)
    run!("git", ["init", "--quiet", "--initial-branch=main"], path)
    run!("git", ["config", "user.email", "test@example.invalid"], path)
    run!("git", ["config", "user.name", "Test Operator"], path)
    app = path |> Path.basename() |> String.replace(~r/[^a-z0-9_]/, "_")
    github = github || "example-org/#{Path.basename(path)}"
    module = app |> String.split("_", trim: true) |> Enum.map_join(&String.capitalize/1)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project, do: [app: :#{app}, version: "0.1.0", deps: #{deps}]
    end
    """)

    run!("git", ["remote", "add", "origin", "https://github.com/#{github}.git"], path)
    run!("git", ["add", "mix.exs"], path)
    run!("git", ["commit", "--quiet", "-m", "fixture"], path)
    path
  end

  @spec write_registry!(String.t(), [map()]) :: String.t()
  def write_registry!(root, repositories) do
    path = Path.join(root, "registry.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.registry/v1",
        "repositories" => repositories
      })
    )

    path
  end

  @spec bind!(MixWorkspaceOps.Registry.t(), String.t()) :: MixWorkspaceOps.Registry.t()
  def bind!(registry, checkout_root) do
    {:ok, registry} = MixWorkspaceOps.Registry.bind(registry, checkout_root)
    registry
  end

  def repository(id, projects, github \\ nil) do
    %{
      "id" => id,
      "github" => github || "example-org/#{id}",
      "default_branch" => "main",
      "projects" => projects
    }
  end

  def project(id, app \\ nil, opts \\ []) do
    %{
      "id" => id,
      "app" => app || id,
      "path" => Keyword.get(opts, :path, "."),
      "kind" => Keyword.get(opts, :kind, "standalone"),
      "tags" => Keyword.get(opts, :tags, ["fixture"]),
      "profile" => Keyword.get(opts, :profile, "default")
    }
  end

  defp run!(executable, args, cwd) do
    {output, 0} = System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
