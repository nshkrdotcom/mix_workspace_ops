defmodule MixWorkspaceOps do
  @moduledoc """
  Operator tooling for explicit Elixir workspace source overlays and releases.

  This project is distributed as an escript and is not a Hex package.
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the operator tool version."
  @spec version() :: String.t()
  def version, do: @version
end
