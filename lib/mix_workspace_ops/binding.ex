defmodule MixWorkspaceOps.Binding do
  @moduledoc """
  Binds portable registry identities to verified operator-owned Git checkouts.

  A checkout is the repository the catalog names when **exactly one** of the
  URLs its `origin` carries resolves to a catalogued identity, and that identity
  is the repository being bound. A URL naming no catalogued repository is not
  evidence of identity; two URLs naming different catalogued repositories are a
  contradiction rather than a choice.
  """

  alias MixWorkspaceOps.{Git, Registry, StrictJSON}

  @remote_schemes ~w(git http https ssh)
  @url_remote ~r{^(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*)://(?<authority>[^/]*)/(?<path>.+)$}
  @scp_remote ~r{^(?<authority>[^/:]+):(?<path>.+)$}
  @segment ~r{^[A-Za-z0-9_.\-]+$}

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

    with {:ok, overrides} <- load_overrides(Keyword.get(opts, :binding_file)),
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
  def normalize_github(remote) do
    trimmed = String.trim(remote)

    with {:ok, path} <- remote_path(trimmed),
         {:ok, identity} <- owner_repository(path) do
      {:ok, identity}
    else
      :error -> {:error, {:unrecognized_git_remote, remote}}
    end
  end

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

    registry.repositories
    |> Map.values()
    |> Enum.sort_by(& &1.id)
    |> Enum.reduce_while({:ok, empty}, fn repository, {:ok, report} ->
      path = Map.get(overrides, repository.id, conventional_path(checkout_root, repository))

      case verify(repository, path, catalogued) do
        {:ok, root} ->
          {:cont, {:ok, put_in(report.bound[repository.id], root)}}

        {:absent, expected} ->
          {:cont, {:ok, put_in(report.absent[repository.id], expected)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp verify(repository, path, catalogued) do
    path = Path.expand(path)

    with true <- File.dir?(path) || {:absent, path},
         {:ok, root} <- Git.root(path),
         true <- root == path || {:error, {:checkout_not_git_root, repository.id, path, root}},
         {:ok, common_dir} <- Git.common_dir(path),
         true <-
           common_dir == Path.join(path, ".git") ||
             {:error, {:noncanonical_git_common_dir, repository.id, common_dir}},
         :ok <- verify_identity(repository, path, catalogued) do
      {:ok, root}
    else
      {:absent, expected} -> {:absent, expected}
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_identity(repository, path, catalogued) do
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

  defp remote_path(remote) do
    case url_path(remote) do
      {:ok, path} -> {:ok, path}
      :error -> scp_path(remote)
    end
  end

  defp url_path(remote) do
    case Regex.named_captures(@url_remote, remote) do
      %{"scheme" => scheme, "authority" => authority, "path" => path} ->
        if scheme in @remote_schemes and host(authority) != "", do: {:ok, path}, else: :error

      nil ->
        :error
    end
  end

  defp scp_path(remote) do
    case Regex.named_captures(@scp_remote, remote) do
      %{"authority" => authority, "path" => path} ->
        if host(authority) != "", do: {:ok, path}, else: :error

      nil ->
        :error
    end
  end

  defp host(authority) do
    authority |> String.split("@") |> List.last() |> String.split(":") |> List.first()
  end

  defp owner_repository(path) do
    segments =
      path
      |> String.trim_leading("/")
      |> String.replace_suffix(".git", "")
      |> String.split("/", trim: true)

    case segments do
      [owner, repository] ->
        if Regex.match?(@segment, owner) and Regex.match?(@segment, repository),
          do: {:ok, owner <> "/" <> repository},
          else: :error

      _other ->
        :error
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
