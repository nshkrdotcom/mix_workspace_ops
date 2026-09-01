defmodule MixWorkspaceOps.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mix_workspace_ops,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: MixWorkspaceOps.CLI],
      deps: deps(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:blitz, :mix]]
    ]
  end

  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :mix, :ssl],
      included_applications: [:blitz]
    ]
  end

  defp deps do
    [
      {:blitz, "== 0.4.1", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/architecture.md",
        "guides/operator_ledger_and_drift.md",
        "guides/dependency_impact.md",
        "guides/release_transaction.md",
        "examples/contract_examples.md"
      ]
    ]
  end
end
