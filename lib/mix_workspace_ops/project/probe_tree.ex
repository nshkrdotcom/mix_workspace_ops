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
  @temporary_attempts 10

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

    with {:ok, temporary} <- temporary_root() do
      stage_in(temporary, source_root, relative_project)
    end
  end

  defp stage_in(temporary, source_root, relative_project) do
    destination = Path.join(temporary, "source")

    result =
      with :ok <- File.mkdir(destination),
           {:ok, digest_parts} <-
             copy_directory(source_root, destination, source_root, destination, []),
           staged_project <- Path.expand(relative_project, destination),
           true <- inside?(staged_project, destination) || {:error, :probe_project_outside_source},
           true <-
             File.regular?(Path.join(staged_project, "mix.exs")) ||
               {:error, {:missing_staged_mix_exs, staged_project}} do
        digest = digest_parts |> Enum.reverse() |> hash()
        {:ok, %__MODULE__{root: temporary, project_root: staged_project, source_digest: digest}}
      end

    case result do
      {:ok, _stage} = ok ->
        ok

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

  defp source_root(project_root) do
    case Git.root(project_root) do
      {:ok, root} -> root
      {:error, _reason} -> project_root
    end
  end

  defp temporary_root(attempts \\ @temporary_attempts)

  defp temporary_root(attempts) when attempts > 0 do
    token = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    path = Path.join(System.tmp_dir!(), "mix_workspace_ops_probe_#{token}")

    case File.mkdir(path) do
      :ok ->
        case File.chmod(path, 0o700) do
          :ok ->
            {:ok, path}

          {:error, reason} ->
            File.rm_rf(path)
            {:error, {:probe_temporary_permissions, reason}}
        end

      {:error, :eexist} ->
        temporary_root(attempts - 1)

      {:error, reason} ->
        {:error, {:probe_temporary_directory, reason}}
    end
  end

  defp temporary_root(0), do: {:error, :probe_temporary_collision}

  defp copy_directory(source, destination, source_root, destination_root, digest_parts) do
    with {:ok, %{type: :directory, mode: mode}} <- File.stat(source),
         {:ok, names} <- File.ls(source),
         {:ok, parts} <-
           names
           |> Enum.sort()
           |> Enum.reduce_while(
             {:ok, digest_parts},
             &copy_named_entry(
               &1,
               source,
               destination,
               source_root,
               destination_root,
               &2
             )
           ),
         :ok <- File.chmod(destination, permissions(mode)) do
      relative = Path.relative_to(source, source_root)
      {:ok, [["directory\0", relative, <<0>>, mode_token(mode), <<0>>] | parts]}
    end
  end

  defp copy_named_entry(
         name,
         source,
         destination,
         source_root,
         destination_root,
         {:ok, parts}
       ) do
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
          destination_root,
          parts
        )

      continue_copy(result)
    end
  end

  defp continue_copy({:ok, next}), do: {:cont, {:ok, next}}
  defp continue_copy({:error, reason}), do: {:halt, {:error, reason}}

  defp copy_entry(source, destination, relative, source_root, destination_root, digest_parts) do
    case File.lstat(source) do
      {:ok, %{type: :directory}} ->
        with :ok <- File.mkdir(destination),
             {:ok, parts} <-
               copy_directory(source, destination, source_root, destination_root, digest_parts),
             do: {:ok, parts}

      {:ok, %{type: :regular, mode: mode}} ->
        with {:ok, bytes} <- File.read(source),
             :ok <- File.write(destination, bytes),
             :ok <- File.chmod(destination, permissions(mode)) do
          {:ok,
           [["file\0", relative, <<0>>, mode_token(mode), <<0>>, bytes, <<0>>] | digest_parts]}
        end

      {:ok, %{type: :symlink}} ->
        copy_symlink(
          source,
          destination,
          relative,
          source_root,
          destination_root,
          digest_parts
        )

      {:ok, %{type: type}} ->
        {:error, {:unsupported_probe_file, relative, type}}

      {:error, reason} ->
        {:error, {:probe_file_stat, relative, reason}}
    end
  end

  defp copy_symlink(
         source,
         destination,
         relative,
         source_root,
         destination_root,
         digest_parts
       ) do
    with {:ok, target} <- File.read_link(source),
         expanded <- Path.expand(target, Path.dirname(source)),
         true <- inside?(expanded, source_root) || {:error, {:external_probe_symlink, relative}},
         target_relative <- Path.relative_to(expanded, source_root),
         :ok <- included_symlink(target_relative, relative),
         staged_target <- Path.join(destination_root, target_relative),
         staged_link <- Path.relative_to(staged_target, Path.dirname(destination)),
         :ok <- File.ln_s(staged_link, destination) do
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
    segments = Path.split(relative)

    Enum.any?(segments, &(&1 in @excluded_directories)) or
      basename in @excluded_files or
      String.starts_with?(basename, ".env.") or
      String.starts_with?(basename, "credentials.") or
      Path.extname(basename) in @excluded_extensions
  end

  defp permissions(mode), do: Bitwise.band(mode, 0o7777)
  defp mode_token(mode), do: mode |> permissions() |> Integer.to_string(8)

  defp inside?(path, root) do
    path = Path.expand(path)
    root = Path.expand(root)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp hash(parts),
    do: :crypto.hash(:sha256, parts) |> Base.encode16(case: :lower)
end
