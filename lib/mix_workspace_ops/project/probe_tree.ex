defmodule MixWorkspaceOps.Project.ProbeTree do
  @moduledoc """
  A disposable source tree for evaluating one Mix project.

  The whole Git worktree is staged so subprojects may read repository-relative
  source, including dirty and untracked files. Build output, fetched
  dependencies, Git metadata, operator state, and common credential files are
  excluded. Symlinks are reproduced only when they remain inside the staged
  source surface.
  """

  alias MixWorkspaceOps.Git

  @excluded_directories ~w(.git _build deps .mix_workspace_ops .hex .mix .ssh .aws .config .codex)
  @excluded_files ~w(.dependency_sources.local.exs .env credentials)
  @excluded_extensions ~w(.key .pem)

  @enforce_keys [:root, :project_root, :source_digest]
  defstruct [:root, :project_root, :source_digest]

  @type t :: %__MODULE__{
          root: String.t(),
          project_root: String.t(),
          source_digest: String.t()
        }

  @spec stage(String.t()) :: {:ok, t()} | {:error, term()}
  def stage(project_root) do
    project_root = Path.expand(project_root)
    source_root = source_root(project_root)
    relative_project = Path.relative_to(project_root, source_root)
    temporary = temporary_root()
    destination = Path.join(temporary, "source")

    with :ok <- File.mkdir_p(destination),
         {:ok, digest_parts} <- copy_directory(source_root, destination, source_root, []),
         staged_project <- Path.expand(relative_project, destination),
         true <- inside?(staged_project, destination) || {:error, :probe_project_outside_source},
         true <-
           File.regular?(Path.join(staged_project, "mix.exs")) ||
             {:error, {:missing_staged_mix_exs, staged_project}} do
      digest = digest_parts |> Enum.reverse() |> hash()
      {:ok, %__MODULE__{root: temporary, project_root: staged_project, source_digest: digest}}
    else
      error ->
        File.rm_rf(temporary)
        error
    end
  end

  @spec cleanup(t()) :: :ok
  def cleanup(stage) do
    File.rm_rf(stage.root)
    :ok
  end

  @spec excluded_directories() :: [String.t()]
  def excluded_directories, do: @excluded_directories

  defp source_root(project_root) do
    case Git.root(project_root) do
      {:ok, root} -> root
      {:error, _reason} -> project_root
    end
  end

  defp temporary_root do
    Path.join(
      System.tmp_dir!(),
      "mix_workspace_ops_probe_#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp copy_directory(source, destination, source_root, digest_parts) do
    with {:ok, names} <- File.ls(source) do
      names
      |> Enum.sort()
      |> Enum.reduce_while(
        {:ok, digest_parts},
        &copy_named_entry(&1, source, destination, source_root, &2)
      )
    end
  end

  defp copy_named_entry(name, source, destination, source_root, {:ok, parts}) do
    relative = source |> Path.join(name) |> Path.relative_to(source_root)

    if excluded?(relative) do
      {:cont, {:ok, parts}}
    else
      result =
        copy_entry(
          Path.join(source, name),
          Path.join(destination, name),
          relative,
          source_root,
          parts
        )

      continue_copy(result)
    end
  end

  defp continue_copy({:ok, next}), do: {:cont, {:ok, next}}
  defp continue_copy({:error, reason}), do: {:halt, {:error, reason}}

  defp copy_entry(source, destination, relative, source_root, digest_parts) do
    case File.lstat(source) do
      {:ok, %{type: :directory}} ->
        with :ok <- File.mkdir(destination),
             {:ok, parts} <- copy_directory(source, destination, source_root, digest_parts) do
          {:ok, [["directory\0", relative, <<0>>] | parts]}
        end

      {:ok, %{type: :regular, mode: mode}} ->
        with {:ok, bytes} <- File.read(source),
             :ok <- File.write(destination, bytes),
             :ok <- File.chmod(destination, Bitwise.band(mode, 0o777)) do
          {:ok, [["file\0", relative, <<0>>, bytes, <<0>>] | digest_parts]}
        end

      {:ok, %{type: :symlink}} ->
        copy_symlink(source, destination, relative, source_root, digest_parts)

      {:ok, %{type: type}} ->
        {:error, {:unsupported_probe_file, relative, type}}

      {:error, reason} ->
        {:error, {:probe_file_stat, relative, reason}}
    end
  end

  defp copy_symlink(source, destination, relative, source_root, digest_parts) do
    with {:ok, target} <- File.read_link(source),
         expanded <- Path.expand(target, Path.dirname(source)),
         true <- inside?(expanded, source_root) || {:error, {:external_probe_symlink, relative}},
         target_relative <- Path.relative_to(expanded, source_root),
         :ok <- included_symlink(target_relative, relative),
         :ok <- File.ln_s(target, destination) do
      {:ok, [["symlink\0", relative, <<0>>, target, <<0>>] | digest_parts]}
    end
  end

  defp included_symlink(target_relative, relative) do
    if excluded?(target_relative),
      do: {:error, {:excluded_probe_symlink, relative}},
      else: :ok
  end

  defp excluded?(relative) do
    basename = Path.basename(relative)

    basename in @excluded_directories or
      basename in @excluded_files or
      String.starts_with?(basename, ".env.") or
      String.starts_with?(basename, "credentials.") or
      Path.extname(basename) in @excluded_extensions
  end

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp hash(parts),
    do: :crypto.hash(:sha256, parts) |> Base.encode16(case: :lower)
end
