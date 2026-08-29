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

  @doc "Writes a `portfolio_registry.registry/v2` document."
  @spec write_catalog!(String.t(), [map()], keyword()) :: String.t()
  def write_catalog!(root, repositories, opts \\ []) do
    path = Path.join(root, Keyword.get(opts, :name, "registry.json"))

    File.write!(
      path,
      :json.encode(%{
        "schema" => "portfolio_registry.registry/v2",
        "repositories" => repositories
      })
    )

    path
  end

  @doc "A v2 repository record with sensible synthetic defaults."
  @spec catalog_repository(String.t(), keyword()) :: map()
  def catalog_repository(id, opts \\ []) do
    record = %{
      "id" => id,
      "github" => Keyword.get(opts, :github, "example-org/#{id}"),
      "default_branch" => Keyword.get(opts, :default_branch, "main"),
      "languages" => Keyword.get(opts, :languages, ["elixir"]),
      "lifecycle" => Keyword.get(opts, :lifecycle, "active"),
      "disposition" => Keyword.get(opts, :disposition, "tracked"),
      "visibility" => Keyword.get(opts, :visibility, "public"),
      "roles" => Keyword.get(opts, :roles, []),
      "groups" => Keyword.get(opts, :groups, ["fixture.#{id}"]),
      "agent_scope" => Keyword.get(opts, :agent_scope, "eligible")
    }

    record
    |> maybe_put("mix", catalog_mix(opts))
    |> maybe_put("dependency_sources", Keyword.get(opts, :dependency_sources))
    |> maybe_put("release_chain", Keyword.get(opts, :release_chain))
  end

  @doc "A v2 Mix project record."
  @spec catalog_project(String.t(), keyword()) :: map()
  def catalog_project(id, opts \\ []) do
    app = Keyword.get(opts, :app, id)

    %{
      "id" => id,
      "path" => Keyword.get(opts, :path, "."),
      "kind" => Keyword.get(opts, :kind, "standalone")
    }
    |> maybe_put("app", if(is_nil(app), do: :null, else: app))
    |> maybe_put("provides", Keyword.get(opts, :provides))
    |> maybe_put("current", Keyword.get(opts, :current))
    |> maybe_put("lineage", Keyword.get(opts, :lineage))
    |> maybe_put("dependency_sources", Keyword.get(opts, :dependency_sources))
  end

  @doc "Writes a `portfolio_registry.view/v2` document."
  @spec write_catalog_view!(String.t(), String.t(), map()) :: String.t()
  def write_catalog_view!(root, id, selector) do
    path = Path.join(root, "view_#{id}.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "portfolio_registry.view/v2",
        "id" => id,
        "description" => "Fixture view #{id}.",
        "selector" => selector
      })
    )

    path
  end

  @doc "Writes a `mix_workspace_ops.view/v1` document."
  @spec write_legacy_view!(String.t(), String.t(), map()) :: String.t()
  def write_legacy_view!(root, id, selector) do
    path = Path.join(root, "legacy_view_#{id}.json")

    File.write!(
      path,
      :json.encode(%{
        "schema" => "mix_workspace_ops.view/v1",
        "id" => id,
        "description" => "Fixture view #{id}.",
        "selector" =>
          Map.merge(
            %{
              "tags_any" => [],
              "tags_all" => [],
              "project_ids" => [],
              "exclude_project_ids" => []
            },
            selector
          )
      })
    )

    path
  end

  defp catalog_mix(opts) do
    projects = Keyword.get(opts, :projects)
    workspace = Keyword.get(opts, :workspace)

    cond do
      is_nil(projects) and is_nil(workspace) -> nil
      is_nil(workspace) -> %{"projects" => projects || []}
      true -> %{"projects" => projects || [], "workspace" => workspace}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  def project(id, app \\ nil, opts \\ []) do
    application = Keyword.get(opts, :app, app || id)

    %{
      "id" => id,
      "app" => if(is_nil(application), do: :null, else: application),
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
