defmodule MixWorkspaceOps.CLI do
  @moduledoc false

  @spec main([String.t()]) :: no_return()
  def main(["version"]) do
    IO.puts(MixWorkspaceOps.version())
    System.halt(0)
  end

  def main(["help"]), do: usage(0)
  def main([]), do: usage(0)

  def main(args) do
    IO.puts(:stderr, "unknown command: #{Enum.join(args, " ")}")
    usage(64)
  end

  defp usage(status) do
    IO.puts("""
    mix_workspace_ops <command>

      version   Print the tool version
      help      Show this help
    """)

    System.halt(status)
  end
end
