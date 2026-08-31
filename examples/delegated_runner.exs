defmodule MixWorkspaceOps.Examples.DelegatedRunner do
  @moduledoc false

  def main([project, state_root, executable | arguments]) do
    context = System.fetch_env!("MIX_WORKSPACE_OPS_CONTEXT_DIGEST")
    command_digest = digest([context, project, executable | arguments])
    receipt = Path.join([state_root, "receipts", command_digest])

    if File.regular?(receipt) do
      IO.puts("REUSED #{command_digest}")
    else
      run!(project, executable, arguments)
      File.mkdir_p!(Path.dirname(receipt))
      File.write!(receipt, "ok\n", [:sync])
      IO.puts("EXECUTED #{command_digest}")
    end
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

  defp digest(parts) do
    parts
    |> Enum.map_join("\0", &to_string/1)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

MixWorkspaceOps.Examples.DelegatedRunner.main(System.argv())
