defmodule MixWorkspaceOps.Inventory do
  @moduledoc "Read-only discovery of copied dependency-source helpers and their Git identity."

  alias MixWorkspaceOps.{Command, Git}

  @helper_name "dependency_sources.exs"
  @config_name "dependency_sources.config.exs"
  @excluded_segments ~w(.git _build deps doc cover node_modules priv_plts)
  @pruned_names ~w(.git .worktrees _build deps doc cover dist node_modules souleqRepo temp)

  @type row :: %{
          repository_root: String.t(),
          git_common_dir: String.t(),
          remote: String.t(),
          head: String.t(),
          clean: boolean(),
          helper_path: String.t(),
          helper_sha256: String.t(),
          config_path: String.t() | nil,
          config_sha256: String.t() | nil,
          project_path: String.t() | nil,
          application: String.t() | nil,
          canonical: boolean()
        }

  @spec scan(String.t()) :: {:ok, [row()]} | {:error, term()}
  def scan(root) do
    root = Path.expand(root)

    with {:ok, result} <- Command.run("find", find_arguments(root)) do
      rows =
        result.output
        |> String.split("\n", trim: true)
        |> Enum.reject(&excluded?/1)
        |> Enum.map(&inspect_helper/1)
        |> Enum.filter(&nshkr_remote?(&1.remote))
        |> Enum.sort_by(&{&1.repository_root, &1.helper_path})

      {:ok, rows}
    end
  end

  defp find_arguments(root) do
    prunes =
      @pruned_names
      |> Enum.flat_map(&["-name", &1, "-o"])
      |> Enum.drop(-1)

    [root, "("] ++ prunes ++ [")", "-prune", "-o", "-type", "f", "-name", @helper_name, "-print"]
  end

  @spec summary([row()]) :: map()
  def summary(rows) do
    canonical = Enum.count(rows, & &1.canonical)
    repositories = rows |> Enum.map(& &1.git_common_dir) |> Enum.uniq() |> length()

    %{
      schema: 1,
      helper_files: length(rows),
      canonical_files: canonical,
      noncanonical_files: length(rows) - canonical,
      unique_git_repositories: repositories,
      rows: rows
    }
  end

  defp inspect_helper(helper_path) do
    project_path = helper_path |> Path.dirname() |> Path.dirname()
    {:ok, repository_root} = Git.root(project_path)
    {:ok, common_dir} = Git.common_dir(project_path)
    remote = Git.remote_url!(repository_root)
    config_path = Path.join(Path.dirname(helper_path), @config_name)

    %{
      repository_root: repository_root,
      git_common_dir: common_dir,
      remote: remote,
      head: Git.head!(repository_root),
      clean: Git.clean?(repository_root),
      helper_path: helper_path,
      helper_sha256: digest_file(helper_path),
      config_path: present_path(config_path),
      config_sha256: digest_optional(config_path),
      project_path: present_path(Path.join(project_path, "mix.exs")) && project_path,
      application: application(project_path),
      canonical: canonical_checkout?(repository_root, common_dir, remote)
    }
  end

  defp application(project_path) do
    with {:ok, contents} <- File.read(Path.join(project_path, "mix.exs")),
         [_, app] <- Regex.run(~r/\bapp:\s*:([a-z][a-z0-9_]*)\b/, contents) do
      app
    else
      _reason -> nil
    end
  end

  defp excluded?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in @excluded_segments))
  end

  defp canonical_checkout?(repository_root, common_dir, remote) do
    repository_name =
      remote
      |> String.replace_suffix(".git", "")
      |> String.split(["/", ":"])
      |> List.last()

    common_dir == Path.join(repository_root, ".git") and
      Path.basename(repository_root) == repository_name
  end

  defp nshkr_remote?(remote), do: String.contains?(remote, "nshkrdotcom/")

  defp present_path(path), do: if(File.regular?(path), do: path)
  defp digest_optional(path), do: if(File.regular?(path), do: digest_file(path))

  defp digest_file(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
