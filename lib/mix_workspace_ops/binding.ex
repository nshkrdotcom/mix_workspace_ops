defmodule MixWorkspaceOps.Binding do
  @moduledoc """
  Binds portable registry identities to verified operator-owned Git checkouts.

  A checkout is the repository the catalog names when **exactly one** of the
  URLs its `origin` carries resolves to a catalogued identity, and that identity
  is the repository being bound. A URL naming no catalogued repository is not
  evidence of identity; two URLs naming different catalogued repositories are a
  contradiction rather than a choice.
  """

  alias MixWorkspaceOps.{Git, OperatorLedger, Registry, RemoteIdentity, StrictJSON}

  @typedoc """
  What binding found for every catalogued repository.

  `bound` maps a repository id to its verified checkout root. `absent` maps a
  repository id to the path a checkout was looked for at. Every catalogued
  repository appears in exactly one of the two.
  """
  @type report :: %{bound: %{String.t() => String.t()}, absent: %{String.t() => String.t()}}

  @doc """
  Binds every catalogued repository against `checkout_root`.

  Absence is data: a repository with no checkout is recorded in `absent` with
  the path it was looked for at, and binding continues. An invalid checkout is
  an error and stops the whole binding — a directory that is not a Git root, a
  non-canonical common directory, an origin naming the wrong catalogued
  repository or two of them, and two repositories bound to one Git directory are
  all statements that contradict the catalog rather than facts about what an
  operator has cloned.
  """
  @spec resolve(Registry.t(), String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def resolve(registry, checkout_root, opts \\ []) do
    checkout_root = Path.expand(checkout_root)

    with {:ok, overrides} <- load_overrides(registry, Keyword.get(opts, :binding_file)),
         {:ok, report} <- bind_all(registry, checkout_root, overrides),
         :ok <- reject_duplicate_common_dirs(report.bound) do
      {:ok, report}
    end
  end

  @doc """
  The `owner/repository` a remote URL names, or an error where it names none.

  A remote URL addresses a host: `scheme://host/owner/repository` or the
  scp-like `[user@]host:owner/repository`. A local filesystem path addresses no
  host and therefore names no remote identity, however it is laid out on disk. A
  bare mirror under `<anything>/<owner>/<repository>.git` is one machine's
  arrangement of its own disk, and reading an `owner/repository` out of it would
  manufacture a coordinate no other machine could resolve.
  """
  @spec normalize_github(String.t()) :: {:ok, String.t()} | {:error, term()}
  def normalize_github(remote), do: RemoteIdentity.github(remote)

  @doc "Every catalogued remote coordinate, as a set."
  @spec catalogued_identities(Registry.t()) :: MapSet.t()
  def catalogued_identities(%Registry{repositories: repositories}) do
    repositories |> Map.values() |> MapSet.new(& &1.github)
  end

  @doc """
  The catalogued identity a checkout resolves to.

  `{:ok, identity}` where exactly one origin URL names a catalogued repository.
  `{:unmatched, identities}` where none does, and `{:ambiguous, identities}`
  where several do — which is a checkout that claims to be two catalogued
  repositories at once, and is refused rather than resolved by preference.
  """
  @spec resolve_identity(String.t(), MapSet.t()) ::
          {:ok, String.t()} | {:unmatched, [String.t()]} | {:ambiguous, [String.t()]}
  def resolve_identity(path, catalogued) do
    identities = github_identities(path)

    case Enum.filter(identities, &MapSet.member?(catalogued, &1)) do
      [identity] -> {:ok, identity}
      [] -> {:unmatched, identities}
      several -> {:ambiguous, several}
    end
  end

  @doc """
  Every GitHub identity `origin` names in a checkout, sorted.

  Fetch and push URLs are read together: a checkout that fetches from a local
  mirror and pushes to GitHub is still the GitHub repository, and which of the
  two an operator configured is a machine-local arrangement the catalog does not
  record. URLs that name no host contribute nothing.
  """
  @spec github_identities(String.t()) :: [String.t()]
  def github_identities(path) do
    path
    |> Git.remote_urls!()
    |> Enum.flat_map(fn url ->
      case normalize_github(url) do
        {:ok, identity} -> [identity]
        {:error, _reason} -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp bind_all(registry, checkout_root, overrides) do
    catalogued = catalogued_identities(registry)
    empty = %{bound: %{}, absent: %{}}

    registry
    |> Registry.selected_repositories()
    |> Enum.reduce_while({:ok, empty}, fn repository, {:ok, report} ->
      override = Map.get(overrides, repository.id)
      path = if override, do: override.path, else: conventional_path(checkout_root, repository)

      case verify(repository, path, catalogued, override) do
        {:ok, root} ->
          {:cont, {:ok, put_in(report.bound[repository.id], root)}}

        {:absent, expected} ->
          {:cont, {:ok, put_in(report.absent[repository.id], expected)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp verify(repository, path, catalogued, override) do
    path = Path.expand(path)

    with true <- File.dir?(path) || {:absent, path},
         {:ok, root} <- Git.root(path),
         true <- root == path || {:error, {:checkout_not_git_root, repository.id, path, root}},
         {:ok, common_dir} <- Git.common_dir(path),
         true <-
           common_dir == Path.join(path, ".git") ||
             {:error, {:noncanonical_git_common_dir, repository.id, common_dir}},
         :ok <- verify_identity(repository, path, catalogued, override) do
      {:ok, root}
    else
      {:absent, expected} -> {:absent, expected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_identity(repository, path, catalogued, nil) do
    case resolve_identity(path, catalogued) do
      {:ok, identity} ->
        if identity == repository.github,
          do: :ok,
          else: {:error, {:wrong_origin, repository.id, repository.github, [identity]}}

      {:unmatched, identities} ->
        {:error, {:wrong_origin, repository.id, repository.github, identities}}

      {:ambiguous, identities} ->
        {:error, {:ambiguous_origin, repository.id, path, identities}}
    end
  end

  defp verify_identity(repository, path, _catalogued, %{remotes: expected})
       when is_list(expected) do
    with {:ok, actual} <- Git.remote_urls(path),
         true <-
           actual == expected ||
             {:error, {:binding_remote_drift, repository.id, expected, actual}},
         {:ok, identities} <- normalized_identities(actual) do
      ledger_identity(repository, path, identities)
    end
  end

  defp verify_identity(repository, path, catalogued, %{remotes: nil}),
    do: verify_identity(repository, path, catalogued, nil)

  defp ledger_identity(_repository, _path, []), do: :ok

  defp ledger_identity(repository, path, identities) do
    expected = String.downcase(repository.github)
    normalized = Enum.map(identities, &String.downcase/1)

    if normalized == [expected],
      do: :ok,
      else: {:error, {:wrong_origin, repository.id, repository.github, identities, path}}
  end

  defp normalized_identities(remotes) do
    case RemoteIdentity.hosted_identities(remotes) do
      {:ok, identities} -> {:ok, identities}
      {:error, reason} -> {:error, {:binding_remote_identity, reason}}
    end
  end

  defp conventional_path(checkout_root, repository) do
    name = repository.github |> String.split("/") |> List.last()
    Path.join(checkout_root, name)
  end

  defp load_overrides(_registry, nil), do: {:ok, %{}}

  defp load_overrides(registry, path) do
    with {:ok, bytes} <- File.read(Path.expand(path)),
         {:ok, decoded} <- decode(bytes) do
      load_override_shape(registry, path, decoded)
    else
      {:error, reason} -> {:error, {:binding_file, reason}}
    end
  end

  defp load_override_shape(registry, path, %{"schema" => "mix_workspace_ops.operator_ledger/v1"}) do
    case OperatorLedger.load(path, registry) do
      {:ok, ledger} -> {:ok, OperatorLedger.binding_overrides(ledger)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_override_shape(_registry, _path, decoded) when is_map(decoded) do
    with true <-
           Enum.all?(decoded, fn {key, value} -> is_binary(key) and is_binary(value) end) ||
             {:error, :invalid_binding_file},
         true <-
           Enum.all?(Map.values(decoded), &(Path.type(&1) == :absolute)) ||
             {:error, :binding_paths_must_be_absolute} do
      {:ok,
       Map.new(decoded, fn {repository, path} ->
         {repository, %{repository: repository, path: Path.expand(path), remotes: nil}}
       end)}
    end
  end

  defp load_override_shape(_registry, _path, _decoded), do: {:error, :invalid_binding_file}

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
