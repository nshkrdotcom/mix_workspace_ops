defmodule MixWorkspaceOps.PublishModeTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.PublishMode

  # One table, read by both implementations. The bootstrap is a standalone
  # script a `mix.exs` loads without Mix Workspace Ops on the code path, so its
  # copy of the parser is deliberate duplication; this table is what stops the
  # two from drifting apart.
  @argv_cases [
    {["hex.publish"], true},
    {["hex.build"], true},
    {["deps.publish_preflight"], true},
    {["compile"], false},
    {["hex.info"], false},
    {["hex.outdated"], false},
    {["run", "--arg", "hex.publish"], false},
    {["run", "-e", "IO.puts(\"hex.build\")"], false},
    {["do", "compile,", "hex.publish"], true},
    {["do", "compile", "+", "hex.publish"], true},
    {["do", "compile,hex.publish"], true},
    {["do", "compile", ",", "hex.publish"], true},
    {["do", "run", "--arg", "x", "+", "hex.build"], true},
    {["do", "run", "--arg", "hex.publish"], false},
    {["deps.get"], false},
    {[], false}
  ]

  test "reads task position, not raw argv membership" do
    for {argv, publish?} <- @argv_cases do
      assert PublishMode.publish?(argv) == publish?,
             "#{inspect(argv)} should #{if publish?, do: "publish", else: "not publish"}"
    end
  end

  test "the standalone bootstrap agrees with the module on every case" do
    for {argv, publish?} <- @argv_cases do
      assert MixWorkspaceOpsBootstrap.publish_mode?(argv) == publish?
      assert MixWorkspaceOpsBootstrap.task_tokens(argv) == PublishMode.task_tokens(argv)
      assert MixWorkspaceOpsBootstrap.quiet_task?(argv) == PublishMode.quiet?(argv)
    end
  end

  test "reading the registry is not publishing" do
    refute PublishMode.publish?(["hex.info", "example_core"])
    refute PublishMode.publish?(["hex.outdated"])
    assert "hex.info" in PublishMode.task_tokens(["hex.info", "example_core"])
  end

  test "the tasks whose output is the product carry no notice" do
    assert PublishMode.quiet?(["run", "-e", ":ok"])
    assert PublishMode.quiet?(["do", "compile", "+", "escript.build"])
    refute PublishMode.quiet?(["compile"])
    refute PublishMode.quiet?(["deps.get"])
  end

  test "a command that does not run mix names no task" do
    assert PublishMode.task_argv(["mix", "hex.publish"]) == ["hex.publish"]
    assert PublishMode.task_argv(["/usr/local/bin/mix", "compile"]) == ["compile"]
    assert PublishMode.task_argv(["echo", "hex.publish"]) == []
    assert PublishMode.task_argv([]) == []
    assert PublishMode.publish?(PublishMode.task_argv(["mix", "hex.publish"]))
    refute PublishMode.publish?(PublishMode.task_argv(["echo", "hex.publish"]))
  end

  test "the publish tasks are exactly the three that mutate the registry" do
    assert Enum.sort(PublishMode.publish_tasks()) ==
             Enum.sort(~w(hex.publish hex.build deps.publish_preflight))
  end
end
