defmodule MixWorkspaceOps.Release.Adapter do
  @moduledoc "Adapter boundary for a fail-closed release transaction."

  @type transition ::
          :preflight | :checkout | :gates | :archive | :publish | :verify | :tag | :push_tag
  @type context :: map()

  @callback transition(transition(), context()) :: {:ok, context()} | {:error, term()}
end
