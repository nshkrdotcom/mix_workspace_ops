defmodule MixWorkspaceOps.DocumentedSeamTest do
  @moduledoc """
  The seam every migrating repository copies, executed exactly as the
  documentation prints it.

  A seam transcribed into a test by hand can drift from the seam the
  documentation prints, and it did: both documents printed a `workspace_dep/3`
  whose only test was whether `MixWorkspaceOpsBootstrap` was already loaded,
  while the two lines that load it existed only inside test fixtures. The tests
  exercised a `mix.exs` the documentation did not print and the documentation
  printed a `mix.exs` no test exercised. Extracting the block is what closes
  that, because an extracted seam cannot drift from its source.
  """

  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.{Command, Overlay, Registry}

  @documents ~w(README.md guides/architecture.md)
  @project_root Path.expand("../..", __DIR__)
  @deps_expression """
  Mix.start()
  Code.compile_file("mix.exs")
  IO.puts(inspect(Mix.Project.config()[:deps], limit: :infinity))
  """

  test "every document prints the same seam" do
    [first | rest] = Enum.map(@documents, &seam/1)

    for {document, block} <- Enum.zip(tl(@documents), rest) do
      assert block == first, "#{document} prints a different seam from #{hd(@documents)}"
    end

    assert first =~ "MIX_WORKSPACE_OPS_BOOTSTRAP"
    assert first =~ "workspace_dep"
  end

  test "the seam resolves through a real overlay and keeps its call-site options", context do
    %{core: core, consumer: consumer, activation: activation} = activated(context)

    # The overlay decides, and the options the call site gave survive it.
    assert deps(consumer, activation.env) == [
             {:example_core, [path: core]},
             {:example_edge,
              [github: "example-org/example_edge", branch: "main", only: [:dev, :test]]}
           ]

    # With no bootstrap the committed default stands — and still carries the
    # call-site options, which the printed fallback used to drop entirely.
    assert deps(consumer, inactive()) == [
             {:example_core, "~> 1.0"},
             {:example_edge,
              [github: "example-org/example_edge", branch: "main", only: [:dev, :test]]}
           ]
  end

  test "the documented seam supports an explicit whole-table comprehension", context do
    %{core: core, consumer: consumer, activation: activation} = activated(context)
    File.write!(Path.join(consumer, "mix.exs"), mixfile(whole_table_seam(seam(hd(@documents)))))

    assert deps(consumer, activation.env) == [
             {:example_core, [path: core]},
             {:example_edge,
              [github: "example-org/example_edge", branch: "main", only: [:dev, :test]]}
           ]

    assert deps(consumer, inactive()) == [
             {:example_core, "~> 1.0"},
             {:example_edge,
              [github: "example-org/example_edge", branch: "main", only: [:dev, :test]]}
           ]
  end

  # The Mix task the file this seam replaces defined, restored where it always
  # belonged: inside the process that loaded the seam, with nothing installed in
  # the repository to make it available.
  test "mix deps.sources reports what the seam emitted", context do
    %{consumer: consumer, core: core, activation: activation} = activated(context)

    assert {:ok, result} =
             Command.run("mix", ["deps.sources"], cd: consumer, env: activation.env)

    assert result.output =~ "dependency sources:"
    assert result.output =~ "example_core -> local (#{core}) -> 0.1.0"
    assert result.output =~ "example_edge -> github (example-org/example_edge) -> branch main"
  end

  defp deps(project_root, env) do
    result = Command.run!("elixir", ["-e", @deps_expression], cd: project_root, env: env)

    {value, _bindings} =
      result.output
      |> String.split("\n", trim: true)
      |> List.last()
      |> Code.eval_string()

    value
  end

  defp inactive do
    for variable <- ~w(MIX_WORKSPACE_OPS_BOOTSTRAP MIX_WORKSPACE_OPS_OVERLAY
                       MIX_WORKSPACE_OPS_CONTEXT_DIGEST MIX_WORKSPACE_OPS_LOCKFILE),
        do: {variable, nil}
  end

  defp activated(context) do
    root = temporary_directory!(context)
    core = initialize_repository!(Path.join(root, "example_core"))
    consumer = initialize_repository!(Path.join(root, "consumer"))
    File.write!(Path.join(consumer, "mix.exs"), mixfile(seam(hd(@documents))))

    registry =
      root
      |> write_catalog!([
        catalog_repository("example_core", projects: [catalog_project("example_core")]),
        catalog_repository("consumer",
          projects: [catalog_project("consumer")],
          dependency_sources: %{
            "example_core" => %{"hex" => "~> 1.0"},
            "example_edge" => %{
              "github" => %{"repo" => "example-org/example_edge", "branch" => "main"},
              "order" => ["github"],
              "publish_order" => ["github"]
            }
          }
        )
      ])
      |> Registry.load!()
      |> bind!(root)

    assert {:ok, activation} =
             Overlay.activate(registry, "consumer", state_root: Path.join(root, "state"))

    %{root: root, core: core, consumer: consumer, activation: activation}
  end

  # The block's first line is the prologue, which goes above the module; the
  # rest are the module's own functions. That is exactly what the prose beside
  # each block tells a reader to do with it.
  defp mixfile(block) do
    [prologue | body] = String.split(block, "\n")

    """
    #{prologue}

    defmodule Consumer.MixProject do
      use Mix.Project

      def project, do: [app: :consumer, version: "0.1.0", deps: deps()]
    #{Enum.join(body, "\n")}
    end
    """
  end

  defp seam(document) do
    @project_root
    |> Path.join(document)
    |> File.read!()
    |> String.split("```")
    |> Enum.find_value(&elixir_block/1)
    |> case do
      nil -> flunk("#{document} prints no elixir block defining workspace_dep")
      block -> block
    end
  end

  defp whole_table_seam(block) do
    replacement = """
    defp deps do
      for {app, committed_default, extra_opts} <- [
            {:example_core, "~> 1.0", []},
            {:example_edge, [github: "example-org/example_edge", branch: "main"],
             [only: [:dev, :test]]}
          ] do
        workspace_dep(app, committed_default, extra_opts)
      end
    end
    """

    Regex.replace(~r/defp deps do\n.*?^end\n/ms, block, replacement, global: false)
  end

  defp elixir_block("elixir\n" <> body) do
    if String.contains?(body, "workspace_dep"), do: String.trim(body)
  end

  defp elixir_block(_fenced), do: nil
end
