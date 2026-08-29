defmodule MixWorkspaceOps.ProbeContainmentTest do
  use MixWorkspaceOps.WorkspaceCase, async: false

  alias MixWorkspaceOps.Project
  alias MixWorkspaceOps.Project.{ProbeMemo, ProbeTree}

  @sensitive_environment ~w(
    AWS_SECRET_ACCESS_KEY
    CODEX_HOME
    GITHUB_TOKEN
    HEX_API_KEY
    SSH_AUTH_SOCK
  )

  setup do
    previous = Map.new(["HOME", "HEX_HOME" | @sensitive_environment], &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
    :ok
  end

  test "a relative helper is available and changes invalidate the invocation memo", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "plane"))
    project = Path.join(repository, "apps/alpha")
    helper = Path.join(repository, "support/metadata.exs")
    File.mkdir_p!(project)
    File.mkdir_p!(Path.dirname(helper))
    File.write!(helper, "defmodule ProbeMetadata, do: def(version, do: \"0.1.0\")\n")
    File.write!(Path.join(project, "mix.exs"), relative_helper_mix())
    memo = ProbeMemo.new()

    assert {:ok, %{app: "alpha", version: "0.1.0"}} =
             Project.metadata_at(project, probe_memo: memo)

    File.write!(helper, "defmodule ProbeMetadata, do: def(version, do: \"0.2.0\")\n")

    assert {:ok, %{app: "alpha", version: "0.2.0"}} =
             Project.metadata_at(project, probe_memo: memo)
  end

  test "the probe receives replacement state and writes only in its disposable tree", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    operator_home = Path.join(root, "operator-home")
    operator_hex = Path.join(root, "operator-hex")
    observer = Path.join(root, "staged-path")
    File.mkdir_p!(operator_home)
    File.mkdir_p!(operator_hex)
    File.write!(Path.join(operator_home, "credential"), "operator home secret")
    File.write!(Path.join(operator_hex, "credential"), "operator hex secret")
    File.write!(Path.join(repository, ".env"), "SECRET=operator-file-secret\n")
    File.mkdir_p!(Path.join(repository, "deps/fetched"))
    File.mkdir_p!(Path.join(repository, "_build/dev"))

    System.put_env("HOME", operator_home)
    System.put_env("HEX_HOME", operator_hex)
    Enum.each(@sensitive_environment, &System.put_env(&1, "operator-secret"))

    File.write!(Path.join(repository, "mix.exs"), containment_mix(observer))

    assert {:ok, %{app: "alpha", version: "clean"}} = Project.metadata_at(repository)

    refute File.exists?(Path.join(repository, "probe-side-effect"))
    staged_project = File.read!(observer)
    refute staged_project == repository
    refute File.exists?(staged_project)
  end

  test "internal symlinks are remapped into the disposable tree", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    helper = Path.join(repository, "helper")
    File.write!(helper, "original")
    File.ln_s!(helper, Path.join(repository, "linked_helper"))
    File.write!(Path.join(repository, "mix.exs"), symlink_mix())

    assert {:ok, %{app: "alpha", version: "changed"}} = Project.metadata_at(repository)
    assert File.read!(helper) == "original"

    File.rm!(Path.join(repository, "linked_helper"))
    File.ln_s!("helper", Path.join(repository, "linked_helper"))

    assert {:ok, %{app: "alpha", version: "changed"}} = Project.metadata_at(repository)
    assert File.read!(helper) == "original"
  end

  test "the disposable source tree has a private parent", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    assert {:ok, stage} = ProbeTree.stage(repository)
    on_exit(fn -> ProbeTree.cleanup(stage) end)

    assert Bitwise.band(File.stat!(stage.root).mode, 0o777) == 0o700
  end

  test "permission-only source changes invalidate the invocation memo", context do
    root = temporary_directory!(context)
    repository = initialize_repository!(Path.join(root, "alpha"))
    helper = Path.join(repository, "helper")
    File.write!(helper, "same bytes")
    File.chmod!(helper, 0o600)
    File.write!(Path.join(repository, "mix.exs"), permission_mix())
    memo = ProbeMemo.new()

    assert {:ok, %{version: "plain"}} = Project.metadata_at(repository, probe_memo: memo)
    File.chmod!(helper, 0o700)

    assert {:ok, %{version: "executable"}} =
             Project.metadata_at(repository, probe_memo: memo)
  end

  @tag timeout: 25_000
  test "a hanging contained probe exits 124 at the existing boundary", context do
    root = temporary_directory!(context)
    repository = Path.join(root, "alpha")
    File.mkdir_p!(repository)

    File.write!(Path.join(repository, "mix.exs"), """
    Process.sleep(:infinity)
    """)

    assert {:error, {:command_failed, 124, _output}} = Project.metadata_at(repository)
  end

  defp relative_helper_mix do
    """
    Code.require_file("../../support/metadata.exs", __DIR__)

    defmodule Alpha.MixProject do
      use Mix.Project
      def project, do: [app: :alpha, version: ProbeMetadata.version(), deps: []]
    end
    """
  end

  defp containment_mix(observer) do
    """
    File.write!(Path.join(__DIR__, "probe-side-effect"), "disposable")
    File.write!(#{inspect(observer)}, __DIR__)

    defmodule Alpha.MixProject do
      use Mix.Project

      def project do
        leaked_environment =
          #{inspect(@sensitive_environment)}
          |> Enum.any?(&(System.get_env(&1) == "operator-secret"))

        leaked_state =
          File.exists?(Path.join(System.fetch_env!("HOME"), "credential")) or
            File.exists?(Path.join(System.fetch_env!("HEX_HOME"), "credential"))

        copied_state =
          Enum.any?(~w(.git deps _build .env), &File.exists?(Path.join(__DIR__, &1)))

        leaked = leaked_environment or leaked_state or copied_state
        [app: :alpha, version: if(leaked, do: "leaked", else: "clean"), deps: []]
      end
    end
    """
  end

  defp symlink_mix do
    """
    defmodule Alpha.MixProject do
      use Mix.Project

      def project do
        File.write!("linked_helper", "changed")
        [app: :alpha, version: File.read!("linked_helper"), deps: []]
      end
    end
    """
  end

  defp permission_mix do
    """
    defmodule Alpha.MixProject do
      use Mix.Project

      def project do
        executable? = Bitwise.band(File.stat!("helper").mode, 0o100) != 0
        [app: :alpha, version: if(executable?, do: "executable", else: "plain"), deps: []]
      end
    end
    """
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
