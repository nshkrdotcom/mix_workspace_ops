defmodule MixWorkspaceOps.CLITest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.Command

  test "version is the Mix project version" do
    assert MixWorkspaceOps.version() == "0.1.0"
  end

  test "a missing executable is a structured command failure" do
    assert {:error, result} = Command.run("definitely_missing_mix_workspace_ops_command", [])
    assert result.exit_code == 127
    assert result.output != ""
  end

  test "the operator tool has no Hex package metadata" do
    refute Keyword.has_key?(Mix.Project.config(), :package)
    refute Keyword.has_key?(Mix.Project.config(), :description)
  end
end
