defmodule MixWorkspaceOps.MixInputs do
  @moduledoc """
  Explicit Mix environment and target inputs for dependency questions.

  Graph-producing code never consults ambient `MIX_ENV` or `MIX_TARGET`.
  Callers may omit the options only to select the stable defaults `dev` and
  `host`; the normalized values are then carried as ordinary plan inputs.
  """

  alias MixWorkspaceOps.Registry.Source

  @type t :: %{mix_env: String.t(), mix_target: String.t()}

  @spec normalize(keyword()) :: {:ok, t()} | {:error, term()}
  def normalize(opts) do
    mix_env = Keyword.get(opts, :mix_env, "dev")
    mix_target = Keyword.get(opts, :mix_target, "host")

    with :ok <- name(:mix_env, mix_env),
         :ok <- name(:mix_target, mix_target) do
      {:ok, %{mix_env: mix_env, mix_target: mix_target}}
    end
  end

  @spec put(keyword(), t()) :: keyword()
  def put(opts, inputs) do
    opts
    |> Keyword.put(:mix_env, inputs.mix_env)
    |> Keyword.put(:mix_target, inputs.mix_target)
  end

  defp name(_field, value) when is_binary(value) do
    if Source.identifier?(value), do: :ok, else: {:error, {:invalid_mix_input, value}}
  end

  defp name(field, value), do: {:error, {:invalid_mix_input, field, value}}
end
