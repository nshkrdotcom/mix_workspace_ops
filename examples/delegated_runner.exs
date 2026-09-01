defmodule MixWorkspaceOps.Examples.DelegatedRunner do
  @moduledoc false

  def main([project, state_root, executable | arguments]) do
    context = System.fetch_env!("MIX_WORKSPACE_OPS_CONTEXT_DIGEST")
    receipt = Path.join([state_root, "contexts", context])
    reused? = File.regular?(receipt)

    run!(project, executable, arguments)
    File.mkdir_p!(Path.dirname(receipt))
    File.write!(receipt, "seen\n", [:sync])
    IO.puts(if(reused?, do: "REUSED_CONTEXT #{context}", else: "NEW_CONTEXT #{context}"))
  end

  def main(_arguments) do
    raise "usage: elixir delegated_runner.exs PROJECT STATE_ROOT EXECUTABLE [ARG ...]"
  end

  defp run!(project, executable, arguments) do
    case System.cmd(executable, arguments,
           cd: project,
           stderr_to_stdout: true,
           into: IO.stream()
         ) do
      {_output, 0} -> :ok
      {_output, status} -> raise "delegated child exited with status #{status}"
    end
  end


end

MixWorkspaceOps.Examples.DelegatedRunner.main(System.argv())