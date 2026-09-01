defmodule MixWorkspaceOps.SourcePreferencesTest do
  use MixWorkspaceOps.WorkspaceCase, async: true

  alias MixWorkspaceOps.SourcePreferences

  test "persists only compact source modes outside repositories", context do
    root = temporary_directory!(context)
    path = Path.join(root, "operator/source_preferences.json")

    assert {:ok, ^path} = SourcePreferences.put(path, "consumer", "core", "git")
    assert {:ok, ^path} = SourcePreferences.put(path, "consumer", "other", "hex")
    assert {:ok, preferences} = SourcePreferences.load(path)
    assert preferences == %{"consumer" => %{"core" => "git", "other" => "hex"}}
    assert SourcePreferences.project(preferences, "consumer")["core"] == "git"

    {:ok, stat} = File.stat(path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    decoded = path |> File.read!() |> :json.decode()
    assert decoded["schema"] == "mix_workspace_ops.source_preferences/v1"
    refute inspect(decoded) =~ root
    refute inspect(decoded) =~ "github.com"
  end

  test "clear removes one preference or the project entry", context do
    root = temporary_directory!(context)
    path = Path.join(root, "source_preferences.json")

    assert {:ok, _} = SourcePreferences.put(path, "consumer", "core", "local")
    assert {:ok, _} = SourcePreferences.put(path, "consumer", "extra", "hex")
    assert {:ok, _} = SourcePreferences.clear(path, "consumer", "core")
    assert {:ok, %{"consumer" => %{"extra" => "hex"}}} = SourcePreferences.load(path)

    assert {:ok, _} = SourcePreferences.clear(path, "consumer")
    assert {:ok, %{}} = SourcePreferences.load(path)
  end

  test "rejects coordinate-shaped or unknown preference values", context do
    root = temporary_directory!(context)
    path = Path.join(root, "source_preferences.json")

    assert {:error, {:invalid_source_preference, "/checkouts/core"}} =
             SourcePreferences.normalize_mode("/checkouts/core")

    assert {:error, {:invalid_source_preference, "github"}} =
             SourcePreferences.normalize_mode("github")

    File.write!(
      path,
      ~s({"schema":"mix_workspace_ops.source_preferences/v1","projects":{"consumer":{"core":"path"}}})
    )

    assert {:error, {:source_preferences, ^path, _reason}} = SourcePreferences.load(path)
  end

  test "an existing non-regular preferences path is an error", context do
    root = temporary_directory!(context)
    path = Path.join(root, "source_preferences.json")
    File.mkdir_p!(path)

    assert {:error, {:source_preferences_not_regular, ^path, :directory}} =
             SourcePreferences.load(path)
  end
end
