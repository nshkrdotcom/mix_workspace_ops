defmodule MixWorkspaceOps do
  @moduledoc """
  Portfolio development and release control plane around ordinary Mix projects.

  This project is distributed as an escript and is not a Hex package.
  """

  @version Mix.Project.config()[:version]

  @doc "Returns the operator tool version."
  @spec version() :: String.t()
  def version, do: @version
end
