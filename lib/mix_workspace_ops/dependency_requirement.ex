defmodule MixWorkspaceOps.DependencyRequirement do
  @moduledoc """
  Validates the version selected for a managed application against every
  original Mix call-site requirement.

  Source projection makes one root source authoritative. It must not make an
  incompatible child requirement disappear, so lifecycle population validates
  the concrete fetched version before compilation starts.
  """

  alias MixWorkspaceOps.{Lockfile, Project}

  @doc "Validates every required managed application in a populated dependency context."
  @spec validate_runtime(map(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def validate_runtime(report, lockfile, deps_path, opts \\ []) do
    uses =
      report.dependency_applications
      |> Enum.reject(&is_nil(Map.get(&1, :requirement)))
      |> Enum.group_by(& &1.application)

    with {:ok, lock} <- read_lock(lockfile) do
      report.decisions
      |> Enum.reduce_while(:ok, fn decision, :ok ->
        validate_decision(
          decision,
          Map.get(uses, decision.application, []),
          lock,
          deps_path,
          opts
        )
      end)
    end
  end

  @doc "Validates one concrete version against a set of recorded dependency uses."
  @spec validate_version(String.t(), String.t() | nil, String.t(), [map()]) ::
          :ok | {:error, term()}
  def validate_version(app, provider, version, uses) do
    Enum.reduce_while(uses, :ok, fn use, :ok ->
      case matches?(version, use.requirement) do
        true ->
          {:cont, :ok}

        false ->
          {:halt,
           {:error,
            {:dependency_requirement_mismatch, app, use.consumer, label(use.requirement),
             provider, version}}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_dependency_requirement, app, use.consumer, reason}}}
      end
    end)
  end

  defp validate_decision(_decision, [], _lock, _deps_path, _opts), do: {:cont, :ok}

  defp validate_decision(decision, uses, lock, deps_path, opts) do
    case selected_version(decision, lock, deps_path, opts) do
      {:ok, version} ->
        provider = decision.provider || decision.source

        case validate_version(decision.application, provider, version, uses) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp selected_version(%{source: "hex", application: app}, lock, _deps_path, _opts) do
    with {:ok, entry} <- fetch_lock_entry(lock, app),
         [:hex, _package, version, _inner, _managers, _dependencies, _repo, _checksum | _rest] <-
           Tuple.to_list(entry),
         true <- is_binary(version) do
      {:ok, version}
    else
      _missing_or_invalid -> {:error, {:dependency_selected_version, app, :invalid_hex_lock}}
    end
  end

  defp selected_version(
         %{source: "local", application: app, location: path},
         _lock,
         _deps_path,
         opts
       ),
       do: evaluated_version(app, path, opts)

  defp selected_version(
         %{source: "github", application: app, location: location},
         _lock,
         deps_path,
         opts
       ) do
    root = Path.join(deps_path, app)
    root = if location[:subdir], do: Path.join(root, location.subdir), else: root
    evaluated_version(app, root, opts)
  end

  defp selected_version(%{application: app, source: source}, _lock, _deps_path, _opts),
    do: {:error, {:dependency_selected_version, app, {:unknown_source, source}}}

  defp evaluated_version(app, root, opts) do
    probe_opts =
      Keyword.take(opts, [:mix_env, :mix_target, :dependency_scope, :probe_memo, :toolchain])

    case Project.metadata_at(root, probe_opts) do
      {:ok, %{app: ^app, version: version}} -> {:ok, version}
      {:ok, %{app: actual}} -> {:error, {:dependency_selected_application, app, actual}}
      {:error, reason} -> {:error, {:dependency_selected_version, app, reason}}
    end
  end

  defp read_lock(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, lock} <- Lockfile.parse_map(bytes) do
      {:ok, lock}
    else
      {:error, reason} -> {:error, {:dependency_selected_versions, path, reason}}
    end
  end

  defp fetch_lock_entry(lock, app) do
    case Enum.find(lock, fn {key, _entry} -> to_string(key) == app end) do
      {_key, entry} -> {:ok, entry}
      nil -> :error
    end
  end

  defp matches?(version, %{kind: "string", value: requirement}) do
    with {:ok, parsed_version} <- Version.parse(version),
         {:ok, parsed_requirement} <- Version.parse_requirement(requirement) do
      Version.match?(parsed_version, parsed_requirement)
    else
      :error -> false
    end
  end

  defp matches?(version, %{kind: "regex", value: source, opts: opts}) do
    case Regex.compile(source, opts) do
      {:ok, requirement} -> Regex.match?(requirement, version)
      {:error, _reason} -> {:error, :invalid_regex}
    end
  end

  defp matches?(_version, _requirement), do: {:error, :invalid_requirement}

  defp label(%{kind: "string", value: requirement}), do: requirement

  defp label(%{kind: "regex", value: source, opts: opts}) do
    case Regex.compile(source, opts) do
      {:ok, requirement} -> inspect(requirement)
      {:error, _reason} -> "invalid regex"
    end
  end
end
