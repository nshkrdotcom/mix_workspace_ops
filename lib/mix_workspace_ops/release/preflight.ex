defmodule MixWorkspaceOps.Release.Preflight do
  @moduledoc "Catalog-aware publication preflight and clean-checkout topology verification."

  alias MixWorkspaceOps.{Project, Registry}
  alias MixWorkspaceOps.Registry.{ReleaseChain, Source}
  alias MixWorkspaceOps.Release.HexRegistry

  @type entry :: map()

  @doc "Checks the effective managed dependencies actually declared by `package`."
  @spec check(Registry.t(), String.t(), keyword()) :: {:ok, [entry()]} | {:error, [entry()]}
  def check(%Registry{} = registry, package, opts \\ []) when is_binary(package) do
    with {:ok, project} <- provider(registry, package),
         {:ok, dependencies} <- dependencies(registry, project, opts),
         table = Registry.dependency_sources(registry, project),
         {:ok, entries} <- entries(registry, project, dependencies, table, package, opts) do
      blocker_result(entries)
    end
  end

  defp blocker_result(entries) do
    case Enum.filter(entries, &(&1.status == :blocked)) do
      [] -> {:ok, entries}
      blockers -> {:error, blockers}
    end
  end

  @doc "Verifies clean-checkout managed publish dependencies against declared release policy."
  @spec verify_topology(Registry.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def verify_topology(%Registry{} = registry, package, project_root, prerequisites, opts \\ [])
      when is_binary(package) and is_binary(project_root) and is_map(prerequisites) do
    probe_opts =
      opts
      |> Keyword.put(:mix_env, "prod")
      |> Keyword.put_new(:mix_target, "host")

    with {:ok, consumer} <- provider(registry, package),
         {:ok, metadata} <- read_metadata(project_root, probe_opts, opts),
         true <- metadata.app == package || {:error, {:wrong_package, metadata.app}},
         {:ok, classified} <- classify_publish_dependencies(registry, consumer, metadata.dependencies),
         declared <- prerequisite_closure(prerequisites, package),
         report <- topology_report(package, classified, declared),
         true <- report.missing_prerequisites == [] || {:error, {:release_topology_mismatch, report}} do
      {:ok, report}
    else
      {:error, _reason} = error -> error
      false -> {:error, :release_topology_mismatch}
    end
  end

  defp read_metadata(project_root, probe_opts, opts) do
    reader = Keyword.get(opts, :metadata_reader, &Project.metadata_at/2)
    reader.(project_root, probe_opts)
  end

  defp classify_publish_dependencies(registry, consumer, dependencies) do
    train = ReleaseChain.packages(registry)

    dependencies
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{observed: [], ignored: []}}, fn app, {:ok, acc} ->
      provider_hint = Registry.declared_provider(registry, consumer, app)

      case Registry.resolve_dependency(registry, app, provider_hint, consumer.repository) do
        {:ok, provider_project} ->
          case publish_dependency(registry, consumer, app, provider_project, train) do
            {:required, row} ->
              {:cont, {:ok, %{acc | observed: [row | acc.observed]}}}

            {:ignored, row} ->
              {:cont, {:ok, %{acc | ignored: [row | acc.ignored]}}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:known_unselected, project_ids} ->
          {:halt, {:error, {:release_dependency_unselected, app, project_ids}}}

        {:error, reason} ->
          {:halt, {:error, {:release_dependency_provider, app, reason}}}

        :unknown ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok,
         %{
           observed: Enum.reverse(result.observed),
           ignored: Enum.reverse(result.ignored)
         }}

      error ->
        error
    end
  end

  defp publish_dependency(registry, consumer, app, provider_project, train) do
    packages = publish_packages_for_provider(registry, provider_project, train)
    declaration = Map.get(Registry.dependency_sources(registry, consumer), app)

    cond do
      packages == [] ->
        {:ignored,
         dependency_row(app, provider_project, nil, :provider_not_in_release_train)}

      declaration && not Source.reaches_while_publishing?(declaration, "hex") ->
        with {:ok, package} <- publish_package(app, packages) do
          {:ignored,
           dependency_row(app, provider_project, package, :non_hex_publish_strategy)}
        end

      true ->
        with {:ok, package} <- publish_package(app, packages) do
          {:required, dependency_row(app, provider_project, package, :managed_publish_dependency)}
        end
    end
  end

  defp publish_packages_for_provider(registry, provider_project, train) do
    train
    |> Enum.filter(fn package ->
      case Registry.resolve_dependency(registry, package) do
        {:ok, project} -> project.id == provider_project.id
        _other -> false
      end
    end)
    |> Enum.sort()
  end

  defp publish_package(app, packages) do
    cond do
      app in packages -> {:ok, app}
      length(packages) == 1 -> {:ok, hd(packages)}
      true -> {:error, {:ambiguous_release_package_provider, app, packages}}
    end
  end

  defp dependency_row(app, provider_project, package, reason) do
    %{
      application: app,
      provider_project: provider_project.id,
      provider_repository: provider_project.repository,
      package: package,
      reason: reason
    }
  end

  defp topology_report(package, classified, declared) do
    observed_packages =
      classified.observed
      |> Enum.map(& &1.package)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    satisfied = Enum.filter(observed_packages, &(&1 in declared))
    missing = observed_packages -- declared

    %{
      package: package,
      observed_managed_publish_dependencies: classified.observed,
      declared_prerequisites: declared,
      satisfied_prerequisites: satisfied,
      missing_prerequisites: missing,
      ignored_internal_dependencies: classified.ignored
    }
  end

  defp prerequisite_closure(prerequisites, package) do
    walk_prerequisites(prerequisites, [package], MapSet.new())
    |> MapSet.delete(package)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp walk_prerequisites(_prerequisites, [], seen), do: seen

  defp walk_prerequisites(prerequisites, [package | rest], seen) do
    if MapSet.member?(seen, package) do
      walk_prerequisites(prerequisites, rest, seen)
    else
      direct = Map.get(prerequisites, package, Map.get(prerequisites, to_string(package), []))
      walk_prerequisites(prerequisites, Enum.map(direct, &to_string/1) ++ rest, MapSet.put(seen, package))
    end
  end

  @doc "Formats blockers with the messages emitted by the copied helper."
  @spec format_blockers([entry()]) :: String.t()
  def format_blockers(blockers) when is_list(blockers) do
    lines = Enum.map(blockers, &("  " <> format_blocker(&1)))
    Enum.join(["publish preflight refused:" | lines], "\n")
  end

  @doc false
  @spec evaluate(String.t(), String.t() | nil, term()) :: entry()
  def evaluate(app, hex, :absent) do
    %{app: app, status: :unverified, hex: hex, sibling_version: nil, sibling_path: nil}
  end

  def evaluate(app, hex, {:absent, sibling_path}) do
    %{
      app: app,
      status: :unverified,
      hex: hex,
      sibling_version: nil,
      sibling_path: sibling_path
    }
  end

  def evaluate(app, hex, {:error, sibling_path}) do
    blocker(app, :unreadable_sibling_version, hex, nil, sibling_path, nil)
  end

  def evaluate(app, nil, {:ok, version, sibling_path}) do
    blocker(app, :missing_hex_constraint, nil, version, sibling_path, required(version))
  end

  def evaluate(app, hex, {:ok, version, sibling_path}) do
    case requirement_admits?(hex, version) do
      :ok ->
        %{
          app: app,
          status: :ok,
          hex: hex,
          sibling_version: version,
          sibling_path: sibling_path
        }

      :stale ->
        blocker(app, :hex_constraint_stale, hex, version, sibling_path, required(version))

      :invalid ->
        blocker(app, :invalid_hex_constraint, hex, version, sibling_path, required(version))
    end
  end

  defp check_declaration(registry, project, app, declaration, opts) do
    if Source.reaches_while_publishing?(declaration, "hex") do
      with {:ok, sibling} <- sibling_state(registry, project, app, declaration) do
        {:ok, app |> evaluate(declaration.hex, sibling) |> check_registry(opts)}
      end
    else
      {:ok,
       %{
         app: app,
         status: :ok,
         publish_source: List.first(declaration.publish_order),
         hex: declaration.hex,
         sibling_version: nil,
         sibling_path: nil
       }}
    end
  end

  defp entries(registry, project, dependencies, table, package, opts) do
    dependencies
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reject(&(&1 == package))
    |> Enum.reduce_while({:ok, []}, fn app, {:ok, acc} ->
      reduce_entry(Map.fetch(table, app), registry, project, app, opts, acc)
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp reduce_entry(:error, _registry, _project, _app, _opts, acc),
    do: {:cont, {:ok, acc}}

  defp reduce_entry({:ok, declaration}, registry, project, app, opts, acc) do
    case check_declaration(registry, project, app, declaration, opts) do
      {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp check_registry(%{status: :ok, sibling_version: version} = entry, opts) do
    if Keyword.get(opts, :check_registry?, false) do
      lookup = Keyword.get(opts, :registry_lookup, &HexRegistry.lookup/2)

      case lookup.(entry.app, version) do
        :published ->
          entry

        {:published, checksum} ->
          Map.put(entry, :registry_checksum, checksum)

        :missing ->
          entry |> Map.merge(%{status: :blocked, reason: :hex_release_missing})

        {:unverified, reason} ->
          Map.merge(entry, %{status: :unverified, registry: {:unverified, reason}})

        other ->
          Map.merge(entry, %{
            status: :unverified,
            registry: {:unverified, {:invalid_registry_result, other}}
          })
      end
    else
      entry
    end
  end

  defp check_registry(entry, _opts), do: entry

  defp sibling_state(registry, consumer, app, declaration) do
    case Registry.resolve_dependency(registry, app, declaration.provider, consumer.repository) do
      {:ok, provider} ->
        {:ok, sibling_state(registry, provider)}

      {:known_unselected, project_ids} ->
        {:error, {:known_unselected_dependency, app, project_ids}}

      {:error, reason} ->
        {:error, {:dependency_provider, app, reason}}

      :unknown ->
        {:ok, :absent}
    end
  end

  defp sibling_state(registry, provider) do
    case Registry.checkout(registry, provider.repository) do
      {:bound, repository_root} ->
        project_root = Path.expand(provider.path, repository_root)

        case Project.declared_version(project_root) do
          {:ok, version} -> {:ok, version, project_root}
          {:error, _reason} -> {:error, project_root}
        end

      {:absent, expected} ->
        {:absent, Path.expand(provider.path, expected)}

      :unknown ->
        :absent
    end
  end

  defp dependencies(registry, project, opts) do
    case Keyword.fetch(opts, :dependencies) do
      {:ok, dependencies} when is_list(dependencies) ->
        {:ok, Enum.map(dependencies, &to_string/1)}

      {:ok, _invalid} ->
        {:error, :invalid_preflight_dependencies}

      :error ->
        Project.dependencies(registry, project, opts)
    end
  end

  defp provider(registry, package) do
    case Registry.resolve_dependency(registry, package) do
      {:ok, project} ->
        {:ok, project}

      {:known_unselected, project_ids} ->
        {:error, {:unselected_release_package, package, project_ids}}

      {:error, reason} ->
        {:error, {:release_package, package, reason}}

      :unknown ->
        {:error, {:release_package, package, {:unprovided_application, package}}}
    end
  end

  defp format_blocker(%{reason: :hex_constraint_stale} = blocker) do
    "#{blocker.app}: committed hex constraint #{inspect(blocker.hex)} does not admit " <>
      "sibling version #{blocker.sibling_version}; bump it to #{inspect(blocker.required)}"
  end

  defp format_blocker(%{reason: :missing_hex_constraint} = blocker) do
    "#{blocker.app}: no committed hex constraint; publishing requires one " <>
      "(#{inspect(blocker.required)} admits the sibling version)"
  end

  defp format_blocker(%{reason: :invalid_hex_constraint} = blocker) do
    "#{blocker.app}: committed hex constraint #{inspect(blocker.hex)} is not a valid requirement"
  end

  defp format_blocker(%{reason: :unreadable_sibling_version} = blocker) do
    "#{blocker.app}: sibling checkout #{blocker.sibling_path} has no readable mix.exs version"
  end

  defp format_blocker(%{reason: :hex_release_missing} = blocker) do
    "#{blocker.app}: sibling version #{blocker.sibling_version} is not published on Hex, so " <>
      "a package requiring #{inspect(blocker.hex)} cannot yet publish"
  end

  defp format_blocker(%{reason: :missing_release_prerequisite} = blocker) do
    "#{blocker.app}: release prerequisite of #{blocker.package} is absent from " <>
      "the portfolio registry"
  end

  defp blocker(app, reason, hex, version, sibling_path, required) do
    %{
      app: app,
      status: :blocked,
      reason: reason,
      hex: hex,
      sibling_version: version,
      sibling_path: sibling_path,
      required: required
    }
  end

  defp requirement_admits?(requirement, version) do
    if Version.match?(version, requirement), do: :ok, else: :stale
  rescue
    Version.InvalidRequirementError -> :invalid
    Version.InvalidVersionError -> :invalid
  end

  defp required(version) do
    parsed = Version.parse!(version)
    "~> #{parsed.major}.#{parsed.minor}.0"
  end
end