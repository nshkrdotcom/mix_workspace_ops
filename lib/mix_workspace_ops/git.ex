defmodule MixWorkspaceOps.Git do
  @moduledoc "Fail-closed Git repository inspection and mutation primitives."

  alias MixWorkspaceOps.Command

  @spec root(String.t()) :: {:ok, String.t()} | {:error, term()}
  def root(path) do
    case Command.run("git", ["rev-parse", "--show-toplevel"], cd: path) do
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

  @spec head!(String.t()) :: String.t()
  def head!(repo), do: output!(repo, ["rev-parse", "HEAD"])

  @spec upstream_head!(String.t()) :: String.t()
  def upstream_head!(repo), do: output!(repo, ["rev-parse", "@{u}"])

  @spec branch!(String.t()) :: String.t()
  def branch!(repo), do: output!(repo, ["branch", "--show-current"])

  @spec remote_url!(String.t()) :: String.t()
  def remote_url!(repo), do: output!(repo, ["remote", "get-url", "origin"])

  @spec clean?(String.t()) :: boolean()
  def clean?(repo), do: output!(repo, ["status", "--porcelain"]) == ""

  @spec source_digest(String.t()) :: String.t()
  def source_digest(repo) do
    root = root!(repo)
    status = output_binary!(root, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
    diff = output_binary!(root, ["diff", "--binary", "--no-ext-diff", "HEAD", "--"])
    untracked = output_binary!(root, ["ls-files", "--others", "--exclude-standard", "-z"])

    untracked_digests =
      untracked
      |> :binary.split(<<0>>, [:global, :trim_all])
      |> Enum.sort()
      |> Enum.map(fn relative ->
        path = Path.join(root, relative)
        [relative, <<0>>, file_kind(path), <<0>>, content_digest(path), <<0>>]
      end)

    :crypto.hash(
      :sha256,
      ["status\0", status, "diff\0", diff, "untracked\0", untracked_digests]
    )
    |> Base.encode16(case: :lower)
  end

  @spec tag_exists?(String.t(), String.t()) :: boolean()
  def tag_exists?(repo, tag) do
    case Command.run("git", ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"], cd: repo) do
      {:ok, _result} -> true
      {:error, %{exit_code: 1}} -> false
      {:error, result} -> raise MixWorkspaceOps.CommandError, result: result
    end
  end

  @spec output!(String.t(), [String.t()]) :: String.t()
  def output!(repo, args) do
    "git"
    |> Command.run!(args, cd: repo)
    |> Map.fetch!(:output)
    |> String.trim()
  end

  defp root!(repo) do
    case root(repo) do
      {:ok, root} -> root
      {:error, reason} -> raise "cannot resolve Git root: #{inspect(reason)}"
    end
  end

  defp output_binary!(repo, args) do
    "git" |> Command.run!(args, cd: repo) |> Map.fetch!(:output)
  end

  defp file_kind(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> "symlink"
      {:ok, %{type: :regular}} -> "file"
      {:ok, %{type: type}} -> to_string(type)
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
