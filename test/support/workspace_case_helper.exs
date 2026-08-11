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

  @spec initialize_repository!(String.t()) :: String.t()
  def initialize_repository!(path) do
    File.mkdir_p!(path)
    run!("git", ["init", "--quiet", "--initial-branch=main"], path)
    run!("git", ["config", "user.email", "test@example.com"], path)
    run!("git", ["config", "user.name", "Test Operator"], path)
    File.write!(Path.join(path, "mix.exs"), "defmodule Fixture.MixProject do\nend\n")
    run!("git", ["add", "mix.exs"], path)
    run!("git", ["commit", "--quiet", "-m", "fixture"], path)
    path
  end

  @spec write_catalog!(String.t(), [map()]) :: String.t()
  def write_catalog!(root, repositories) do
    path = Path.join(root, "workspace.json")
    File.write!(path, :json.encode(%{"schema" => 1, "repositories" => repositories}))
    path
  end

  defp run!(executable, args, cwd) do
    {output, 0} = System.cmd(executable, args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
