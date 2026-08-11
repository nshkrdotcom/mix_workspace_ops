defmodule MixWorkspaceOps.CLITest do
  use ExUnit.Case, async: true

  test "version is the Mix project version" do
    assert MixWorkspaceOps.version() == "0.1.0"
  end
end
