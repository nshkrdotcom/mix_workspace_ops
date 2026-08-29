defmodule MixWorkspaceOps.Project.ProbeMemo do
  @moduledoc """
  Invocation-scoped memo for isolated `mix.exs` metadata probes.

  The table is deliberately owned by the caller and has no persistent or
  application-global name. Sharing the value shares answers for one invocation;
  dropping it drops every answer.
  """

  @enforce_keys [:table]
  defstruct [:table]

  @type t :: %__MODULE__{table: :ets.tid()}

  @spec new() :: t()
  def new do
    %__MODULE__{
      table:
        :ets.new(__MODULE__, [
          :set,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])
    }
  end

  @spec fetch(t(), term(), (-> value)) :: value when value: term()
  def fetch(%__MODULE__{table: table}, key, miss) when is_function(miss, 0) do
    case :ets.lookup(table, key) do
      [{^key, value}] ->
        value

      [] ->
        # Pre-warm workers can encounter the same project. The lock makes a
        # cache miss one subprocess question, not merely one stored answer.
        :global.trans({{__MODULE__, table, key}, self()}, fn ->
          case :ets.lookup(table, key) do
            [{^key, value}] -> value
            [] -> miss.() |> tap(&:ets.insert(table, {key, &1}))
          end
        end)
    end
  end
end
