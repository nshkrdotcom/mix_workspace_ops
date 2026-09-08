defmodule MixWorkspaceOps.Git do
  @moduledoc "Fail-closed Git repository inspection and mutation primitives."

  alias Mix.Sync.Lock, as: SyncLock
  alias MixWorkspaceOps.Command
  alias MixWorkspaceOps.Project.ProbeTree

  @doc "Returns one repository-state snapshot, coalesced by root when an invocation memo is given."
  @spec state(String.t(), :ets.tid() | nil) :: map()
  def state(repo, memo \\ nil)

  def state(repo, nil), do: repo |> root!([]) |> read_state()

  def state(repo, memo) do
    root = root!(repo, [])
    key = {:repository_state, root}

    case :ets.lookup(memo, key) do
      [{^key, state}] ->
        state

      [] ->
        locked_state(root, memo, key)
    end
  end

  defp locked_state(root, memo, key) do
    SyncLock.with_lock("mix_workspace_ops:repository-state:" <> root, fn ->
      case :ets.lookup(memo, key) do
        [{^key, state}] -> state
        [] -> read_state(root) |> tap(&:ets.insert(memo, {key, &1}))
      end
    end)
  end

  @spec root(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def root(path, opts \\ []) do
    case Command.run("git", ["rev-parse", "--show-toplevel"], Keyword.put(opts, :cd, path)) do
      {:ok, result} -> {:ok, String.trim(result.output)}
      {:error, result} -> {:error, {:git_root, result.output}}
    end
  end

  @spec common_dir(String.t()) :: {:ok, String.t()} | {:error, term()}
  def common_dir(path) do
    case Command.run("git", ["rev-parse", "--git-common-dir"], cd: path) do
      {:ok, result} -> {:ok, Path.expand(String.trim(result.output), path)}
      {:error, result} -> {:error, {:git_common_dir, result.output}}
    end
  end

  @spec head!(String.t(), keyword()) :: String.t()
  def head!(repo, opts \\ []), do: output!(repo, ["rev-parse", "HEAD"], opts)

  @doc """
  The revision `repo` is at, or why it could not be read.

  A caller pinning a coordinate to a checkout has something else to do when the
  checkout cannot answer, so it asks rather than being raised at.
  """
  @spec head(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def head(repo, opts \\ []) do
    case Command.run("git", ["rev-parse", "HEAD"], Keyword.put(opts, :cd, repo)) do
      {:ok, result} -> {:ok, String.trim(result.output)}
      {:error, result} -> {:error, {:git_head, result.output}}
    end
  end

  @spec upstream_head!(String.t()) :: String.t()
  def upstream_head!(repo), do: output!(repo, ["rev-parse", "@{u}"])

  @spec branch!(String.t()) :: String.t()
  def branch!(repo), do: output!(repo, ["branch", "--show-current"])

  @spec remote_url!(String.t()) :: String.t()
  def remote_url!(repo), do: output!(repo, ["remote", "get-url", "origin"])

  @doc """
  Every URL configured for `origin`, fetch and push.

  A checkout may fetch from a local mirror and push to the remote it belongs
  to. Both are the same repository, so identity is read from the whole set
  rather than from the fetch URL alone.
  """
  @spec remote_urls!(String.t()) :: [String.t()]
  def remote_urls!(repo) do
    case remote_urls(repo) do
      {:ok, urls} -> urls
      {:error, reason} -> raise "cannot read Git origin URLs: #{inspect(reason)}"
    end
  end

  @doc "Every origin fetch/push URL, or typed command evidence when it cannot be read."
  @spec remote_urls(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def remote_urls(repo) do
    with {:ok, fetch} <- urls(repo, ["remote", "get-url", "--all", "origin"]),
         {:ok, push} <- urls(repo, ["remote", "get-url", "--all", "--push", "origin"]),
         urls when urls != [] <- Enum.uniq(fetch ++ push) do
      {:ok, Enum.sort(urls)}
    else
      [] -> {:error, :missing_origin_urls}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec clean?(String.t(), keyword()) :: boolean()
  def clean?(repo, opts \\ []), do: output!(repo, ["status", "--porcelain"], opts) == ""

  @spec source_digest(String.t(), keyword()) :: String.t()
  def source_digest(repo, opts \\ []) do
    root = root!(repo, opts)
    {digest, _clean?} = source_state(root, opts)
    digest
  end

  defp source_state(root, opts) do
    status =
      output_binary!(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"], opts)

    diff = output_binary!(root, ["diff", "--binary", "--no-ext-diff", "HEAD", "--"], opts)
    untracked = output_binary!(root, ["ls-files", "--others", "--exclude-standard", "-z"], opts)

    ignored =
      output_binary!(
        root,
        ["ls-files", "--others", "--ignored", "--exclude-standard", "-z", "--"] ++
          ProbeTree.ignored_source_pathspecs(),
        opts
      )

    untracked_digests =
      source_digests(root, untracked |> null_paths() |> Enum.filter(&ProbeTree.source_path?/1))

    ignored_digests =
      source_digests(root, ignored |> null_paths() |> Enum.filter(&ProbeTree.source_path?/1))

    digest =
      :crypto.hash(
        :sha256,
        [
          "status\0",
          status,
          "diff\0",
          diff,
          "untracked\0",
          untracked_digests,
          "ignored\0",
          ignored_digests
        ]
      )
      |> Base.encode16(case: :lower)

    {digest, status == ""}
  end

  defp null_paths(bytes), do: :binary.split(bytes, <<0>>, [:global, :trim_all])

  defp source_digests(root, relative_paths) do
    relative_paths
    |> Enum.sort()
    |> Enum.map(fn relative ->
      path = Path.join(root, relative)

      [
        relative,
        <<0>>,
        file_kind(path),
        <<0>>,
        file_mode(path),
        <<0>>,
        content_digest(path),
        <<0>>
      ]
    end)
  end

  defp read_state(repo) do
    head = output!(repo, ["rev-parse", "HEAD"])
    {source_digest, clean?} = source_state(repo, [])
    %{head: head, source_digest: source_digest, clean: clean?}
  end

  @spec tag_exists?(String.t(), String.t()) :: boolean()
  def tag_exists?(repo, tag) do
    case Command.run("git", ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"], cd: repo) do
      {:ok, _result} -> true
      {:error, %{exit_code: 1}} -> false
      {:error, result} -> raise MixWorkspaceOps.CommandError, result: result
    end
  end

  @spec output!(String.t(), [String.t()], keyword()) :: String.t()
  def output!(repo, args, opts \\ []) do
    "git"
    |> Command.run!(args, Keyword.put(opts, :cd, repo))
    |> Map.fetch!(:output)
    |> String.trim()
  end

  defp urls(repo, args) do
    case Command.run("git", args, cd: repo) do
      {:ok, result} ->
        {:ok,
         result.output
         |> String.split("\n", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))}

      {:error, result} ->
        {:error, {:git_remote_urls, args, result.exit_code, result.output}}
    end
  end

  defp root!(repo, opts) do
    case root(repo, opts) do
      {:ok, root} -> root
      {:error, reason} -> raise "cannot resolve Git root: #{inspect(reason)}"
    end
  end

  defp output_binary!(repo, args, opts) do
    "git" |> Command.run!(args, Keyword.put(opts, :cd, repo)) |> Map.fetch!(:output)
  end

  defp file_kind(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> "symlink"
      {:ok, %{type: :regular}} -> "file"
      {:ok, %{type: type}} -> to_string(type)
      {:error, reason} -> "error:#{reason}"
    end
  end

  defp file_mode(path) do
    case File.lstat(path) do
      {:ok, stat} -> stat.mode |> Bitwise.band(0o777) |> Integer.to_string(8)
      {:error, reason} -> "error:#{reason}"
    end
  end

  defp content_digest(path) do
    bytes =
      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> path |> File.read_link!() |> IO.iodata_to_binary()
        {:ok, %{type: :regular}} -> File.read!(path)
        _other -> <<>>
      end

    :crypto.hash(:sha256, bytes)
  end
end
