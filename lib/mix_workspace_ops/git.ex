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
end
