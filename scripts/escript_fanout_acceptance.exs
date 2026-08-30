defmodule MixWorkspaceOps.EscriptFanoutAcceptance do
  @moduledoc false

  def main([escript]) do
    root =
      Path.join(
        System.tmp_dir!(),
        "mix_workspace_ops_escript_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    try do
      for name <- ~w(alpha beta), do: repository!(root, name)

      registry = Path.join(root, "registry.json")
      view = Path.join(root, "view.json")
      state = Path.join(root, "state")
      outside = Path.join(root, "outside")
      File.mkdir_p!(outside)

      File.write!(
        registry,
        :json.encode(%{
          "schema" => "portfolio_registry.registry/v2",
          "repositories" => Enum.map(~w(alpha beta), &catalog_repository/1)
        })
      )

      File.write!(
        view,
        :json.encode(%{
          "schema" => "portfolio_registry.view/v2",
          "id" => "all",
          "description" => "All synthetic repositories.",
          "selector" => %{}
        })
      )

      args = [
        "run",
        "--registry",
        registry,
        "--checkout-root",
        root,
        "--view",
        view,
        "--state-root",
        state,
        "--max-concurrency",
        "2",
        "--",
        "sh",
        "-c",
        "touch escript-fanout-ran"
      ]

      {output, status} =
        System.cmd(Path.expand(escript), args, cd: outside, stderr_to_stdout: true)

      assert!(status == 0, "escript failed with #{status}:\n#{output}")
      report = output |> final_line() |> :json.decode()

      assert!(report["schema"] == "mix_workspace_ops.run/v1", "unexpected run schema")
      assert!(report["status"] == "passed", "fan-out did not pass")
      assert!(report["binding"]["schema"] == "mix_workspace_ops.binding/v1", "missing binding")

      assert!(
        Enum.map(report["results"], &{&1["id"], &1["status"]}) ==
          [{"alpha", "passed"}, {"beta", "passed"}],
        "unexpected unit results"
      )

      for name <- ~w(alpha beta) do
        assert!(
          File.exists?(Path.join([root, name, "escript-fanout-ran"])),
          "#{name} did not run"
        )

        File.rm!(Path.join([root, name, "escript-fanout-ran"]))
      end

      failure_script =
        "if [ \"$(basename \"$PWD\")\" = alpha ]; then exit 9; else touch continued; fi"

      {failure_output, failure_status} =
        System.cmd(
          Path.expand(escript),
          List.replace_at(args, -1, failure_script),
          cd: outside,
          stderr_to_stdout: true
        )

      assert!(failure_status == 1, "failed fan-out exited #{failure_status}")
      failed = failure_output |> final_line() |> :json.decode()
      assert!(failed["status"] == "failed", "failed fan-out omitted failure status")

      assert!(
        Enum.map(failed["results"], &{&1["id"], &1["status"]}) ==
          [{"alpha", "failed"}, {"beta", "passed"}],
        "failed fan-out omitted complete results"
      )

      assert!(File.exists?(Path.join([root, "beta", "continued"])), "continue policy stopped")

      IO.puts("standalone escript fan-out passed")
    after
      File.rm_rf!(root)
    end
  end

  def main(_args), do: raise("usage: elixir escript_fanout_acceptance.exs PATH_TO_ESCRIPT")

  defp repository!(root, name) do
    path = Path.join(root, name)
    File.mkdir_p!(path)
    git!(path, ["init", "--quiet", "--initial-branch=main"])
    git!(path, ["config", "user.email", "test@example.invalid"])
    git!(path, ["config", "user.name", "Test Operator"])

    module = String.capitalize(name)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{module}.MixProject do
      use Mix.Project
      def project, do: [app: :#{name}, version: "0.1.0", deps: []]
    end
    """)

    git!(path, ["remote", "add", "origin", "https://github.com/example-org/#{name}.git"])
    git!(path, ["add", "mix.exs"])
    git!(path, ["commit", "--quiet", "-m", "fixture"])
  end

  defp catalog_repository(name) do
    %{
      "id" => name,
      "github" => "example-org/#{name}",
      "default_branch" => "main",
      "languages" => ["elixir"],
      "lifecycle" => "active",
      "disposition" => "tracked",
      "visibility" => "public",
      "roles" => [],
      "groups" => ["fixture.#{name}"],
      "agent_scope" => "eligible",
      "mix" => %{
        "projects" => [
          %{"id" => name, "app" => name, "path" => ".", "kind" => "standalone"}
        ]
      }
    }
  end

  defp final_line(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
  end

  defp git!(path, args) do
    {output, 0} = System.cmd("git", args, cd: path, stderr_to_stdout: true)
    output
  end

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
end

MixWorkspaceOps.EscriptFanoutAcceptance.main(System.argv())
