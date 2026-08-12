defmodule MixWorkspaceOps.Binding do
  @moduledoc "Binds portable registry identities to verified operator-owned Git checkouts."

  alias MixWorkspaceOps.{Git, Registry, StrictJSON}

  @spec resolve(Registry.t(), String.t(), keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def resolve(registry, checkout_root, opts \\ []) do
    checkout_root = Path.expand(checkout_root)

    with {:ok, overrides} <- load_overrides(Keyword.get(opts, :binding_file)),
         {:ok, bindings} <- bind_all(registry, checkout_root, overrides),
         :ok <- reject_duplicate_common_dirs(bindings) do
      {:ok, bindings}
    end
  end

  @spec normalize_github(String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_github(remote) do
    candidate =
      remote
      |> String.trim()
      |> String.replace_suffix(".git", "")
      |> String.replace(~r/^ssh:\/\//, "")
      |> String.replace(~r/^https?:\/\//, "")
      |> String.split(["/", ":"], trim: true)
      |> Enum.take(-2)
      |> Enum.join("/")

    if Regex.match?(~r/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/, candidate),
      do: {:ok, candidate},
      else: {:error, {:unrecognized_git_remote, remote}}
  end

  defp bind_all(registry, checkout_root, overrides) do
    registry.repositories
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, %{}}, fn repository, {:ok, bindings} ->
      path = Map.get(overrides, repository.id, conventional_path(checkout_root, repository))

      case verify(repository, path) do
        {:ok, root} -> {:cont, {:ok, Map.put(bindings, repository.id, root)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify(repository, path) do
    path = Path.expand(path)

    with true <- File.dir?(path) || {:error, {:missing_checkout, repository.id, path}},
         {:ok, root} <- Git.root(path),
         true <- root == path || {:error, {:checkout_not_git_root, repository.id, path, root}},
         {:ok, common_dir} <- Git.common_dir(path),
         true <-
           common_dir == Path.join(path, ".git") ||
             {:error, {:noncanonical_git_common_dir, repository.id, common_dir}},
         {:ok, actual_github} <- normalize_github(Git.remote_url!(path)),
         true <-
           actual_github == repository.github ||
             {:error, {:wrong_origin, repository.id, repository.github, actual_github}} do
      {:ok, root}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp conventional_path(checkout_root, repository) do
    name = repository.github |> String.split("/") |> List.last()
    Path.join(checkout_root, name)
  end

  defp load_overrides(nil), do: {:ok, %{}}

  defp load_overrides(path) do
    with {:ok, bytes} <- File.read(Path.expand(path)),
         {:ok, decoded} <- decode(bytes),
         true <- is_map(decoded) || {:error, :invalid_binding_file},
         true <-
           Enum.all?(decoded, fn {key, value} -> is_binary(key) and is_binary(value) end) ||
             {:error, :invalid_binding_file},
         true <-
           Enum.all?(Map.values(decoded), &(Path.type(&1) == :absolute)) ||
             {:error, :binding_paths_must_be_absolute} do
      {:ok, decoded}
    else
      {:error, reason} -> {:error, {:binding_file, reason}}
    end
  end

  defp decode(bytes) do
    StrictJSON.decode(bytes, maximum_bytes: 1024 * 1024)
  end

  defp reject_duplicate_common_dirs(bindings) do
    duplicates =
      bindings
      |> Enum.group_by(fn {_id, root} -> Git.common_dir(root) end)
      |> Enum.filter(fn {_common_dir, matches} -> length(matches) > 1 end)

    if duplicates == [], do: :ok, else: {:error, {:duplicate_git_bindings, duplicates}}
  end
end
