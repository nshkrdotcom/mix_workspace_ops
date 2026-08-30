defmodule MixWorkspaceOps.Release.LocalAdapter do
  @moduledoc "Concrete clean-checkout, Hex-publication, verification, and tag adapter."

  @behaviour MixWorkspaceOps.Release.Adapter

  alias MixWorkspaceOps.{Command, Project, Registry}
  alias MixWorkspaceOps.Release.{HexRegistry, Preflight, PreparedArtifact}

  @preserved_environment ~w(HOME PATH USER LOGNAME LANG LC_ALL TERM SHELL ASDF_DIR ASDF_DATA_DIR MIX_HOME MIX_ARCHIVES MIX_ENV MIX_TARGET ERL_AFLAGS ERL_FLAGS ELIXIR_ERL_OPTIONS SSH_AUTH_SOCK XDG_RUNTIME_DIR CI CODEX_CI)

  @impl true
  def transition(:preflight, context), do: preflight(context)
  def transition(:checkout, context), do: checkout(context)
  def transition(:gates, context), do: gates(context)
  def transition(:archive, context), do: archive(context)
  def transition(:publish, context), do: publish(context)
  def transition(:verify, context), do: verify(context)
  def transition(:tag, context), do: tag(context)
  def transition(:push_tag, context), do: push_tag(context)

  @impl true
  def resume(:preflight, :started, _context), do: :rerun

  def resume(:preflight, :completed, context) do
    repository = context.plan.repository

    cond do
      git_head!(repository) != context.head -> {:error, :source_revision_changed}
      not git_clean?(repository) -> {:error, :source_worktree_changed}
      git_upstream_head!(repository) != context.head -> {:error, :source_upstream_changed}
      true -> {:ok, %{}}
    end
  end

  def resume(:checkout, :started, context) do
    checkout = Path.join(context.receipt_directory, "checkout")
    File.rm_rf!(checkout)
    :rerun
  end

  def resume(:checkout, :completed, context) do
    cond do
      not File.dir?(context.checkout) -> {:error, :release_checkout_missing}
      git_head!(context.checkout) != context.head -> {:error, :release_checkout_changed}
      not git_clean?(context.checkout) -> {:error, :release_checkout_dirty}
      true -> {:ok, %{}}
    end
  end

  def resume(:gates, :started, _context), do: :rerun
  def resume(:gates, :completed, _context), do: {:ok, %{}}
  def resume(:archive, :started, _context), do: :rerun

  def resume(:archive, :completed, context) do
    case file_checksum(context.archive) do
      {:ok, checksum} when checksum == context.archive_checksum -> {:ok, %{}}
      {:ok, checksum} -> {:error, {:archive_checksum_changed, context.archive_checksum, checksum}}
      {:error, reason} -> {:error, {:archive_unavailable, reason}}
    end
  end

  def resume(:publish, status, context), do: resume_publish(status, context)
  def resume(:verify, :started, _context), do: :rerun
  def resume(:verify, :completed, context), do: resume_publish(:completed, context)
  def resume(:tag, status, context), do: resume_tag(status, context)
  def resume(:push_tag, status, context), do: resume_push_tag(status, context)

  defp preflight(context) do
    plan = context.plan
    repository = plan.repository
    source_project = Path.expand(plan.project_path, repository)
    default_branch = plan.default_branch

    with {:ok, ^repository} <- git_root(repository),
         true <- git_clean?(repository) || {:error, :dirty_worktree},
         ^default_branch <- git_branch!(repository),
         head <- git_head!(repository),
         ^head <- git_upstream_head!(repository),
         :ok <- ensure_absent(git_tag_exists?(repository, plan.tag), :local_tag_exists),
         :ok <- ensure_remote_tag_absent(repository, plan.tag),
         {:ok, package_evidence} <- package_preflight(context, source_project, head),
         :absent <- release_status(context),
         :ok <- ensure_no_overlay() do
      {:ok,
       %{
         head: head,
         source_project: source_project,
         origin: git_remote_url!(repository),
         dependency_preflight: Map.get(package_evidence, :dependency_preflight, [])
       }
       |> Map.merge(package_evidence)}
    else
      {:error, reason} -> {:error, reason}
      value -> {:error, {:preflight_mismatch, value}}
    end
  end

  defp checkout(context) do
    checkout = Path.join(context.receipt_directory, "checkout")

    with :ok <- ensure_absent(File.exists?(checkout), {:checkout_exists, checkout}),
         {:ok, _result} <-
           isolated_run("git", ["clone", "--quiet", "--shared", context.plan.repository, checkout]),
         {:ok, _result} <-
           isolated_run("git", ["checkout", "--quiet", "--detach", context.head], cd: checkout),
         true <- git_clean?(checkout) || {:error, :dirty_release_checkout},
         {:ok, project_evidence} <- checkout_project(context, checkout) do
      {:ok, Map.put(project_evidence, :checkout, checkout)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp gates(context) do
    Enum.reduce_while(context.plan.gates, {:ok, []}, fn [executable | argv], {:ok, results} ->
      case isolated_run(executable, argv, cd: context.project) do
        {:ok, _result} ->
          result = %{argv: [executable | argv], exit_code: 0}
          {:cont, {:ok, [result | results]}}

        {:error, result} ->
          IO.binwrite(:stderr, result.output)
          {:halt, {:error, {:gate_failed, executable, argv, result.exit_code}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, %{gate_results: Enum.reverse(reversed)}}
      error -> error
    end
  end

  defp archive(context) do
    if Map.has_key?(context, :prepared_artifact) do
      prepared_archive(context)
    else
      build_archive(context)
    end
  end

  defp build_archive(context) do
    archive = Path.join(context.project, "#{context.plan.package}-#{context.plan.version}.tar")
    File.rm(archive)

    with {:ok, _result} <-
           isolated_run("mix", ["hex.build"], cd: context.project),
         true <- File.regular?(archive) || {:error, {:missing_archive, archive}},
         {:ok, bytes} <- File.read(archive) do
      {:ok, %{archive: archive, archive_checksum: sha256(bytes)}}
    else
      {:error, reason} -> {:error, reason}
      value -> {:error, {:archive_mismatch, value}}
    end
  end

  defp prepared_archive(context) do
    with {:ok, checksum} <- file_checksum(context.archive),
         true <-
           checksum == context.archive_checksum ||
             {:error, {:prepared_archive_checksum_changed, context.archive_checksum, checksum}} do
      {:ok,
       %{
         archive: context.archive,
         archive_checksum: checksum,
         manifest_path: context.manifest_path,
         manifest_sha256: context.manifest_sha256,
         project_sha256: context.project_sha256,
         source_revision: context.head
       }}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :prepared_archive_checksum_changed}
    end
  end

  defp publish(context) do
    [executable | prefix_args] = context.plan.publisher_prefix
    argv = prefix_args ++ ["mix", "hex.publish", "--yes"]

    case isolated_run(executable, argv, cd: context.project, preserve: ["HEX_API_KEY"]) do
      {:ok, _result} -> {:ok, %{}}
      {:error, result} -> {:error, {:publisher_failed, result.exit_code}}
    end
  end

  defp verify(context) do
    case registry_lookup(context) do
      {:published, checksum} -> verify_checksum(context, checksum)
      :missing -> {:error, :hex_release_missing}
      {:unverified, reason} -> {:error, reason}
    end
  end

  defp tag(context) do
    repository = context.plan.repository
    expected_head = context.head

    with ^expected_head <- git_head!(repository),
         true <- git_clean?(repository) || {:error, :worktree_changed_after_publish},
         {:ok, _result} <-
           isolated_run("git", ["tag", context.plan.tag, context.head], cd: repository) do
      {:ok, %{tag: context.plan.tag}}
    else
      {:error, reason} -> {:error, reason}
      value -> {:error, {:tag_precondition_changed, value}}
    end
  end

  defp push_tag(context) do
    case isolated_run("git", ["push", "origin", "refs/tags/#{context.plan.tag}"],
           cd: context.plan.repository
         ) do
      {:ok, _result} -> {:ok, %{tag: context.plan.tag}}
      {:error, result} -> {:error, {:tag_push_failed, result.exit_code}}
    end
  end

  defp ensure_remote_tag_absent(repository, tag) do
    case isolated_run("git", ["ls-remote", "--exit-code", "--tags", "origin", "refs/tags/#{tag}"],
           cd: repository
         ) do
      {:error, %{exit_code: 2}} -> :ok
      {:ok, _result} -> {:error, :remote_tag_exists}
      {:error, result} -> {:error, {:remote_tag_check_failed, result.exit_code}}
    end
  end

  defp ensure_no_overlay do
    variables =
      ~w(MIX_WORKSPACE_OPS_BOOTSTRAP MIX_WORKSPACE_OPS_CONTEXT_DIGEST MIX_WORKSPACE_OPS_LOCKFILE MIX_WORKSPACE_OPS_OVERLAY)

    if Enum.all?(variables, &(System.get_env(&1) in [nil, ""])),
      do: :ok,
      else: {:error, :active_workspace_state}
  end

  defp dependency_preflight(%{plan: %{registry: %Registry{} = registry}} = context, dependencies) do
    lookup = Map.get(context.plan, :registry_lookup, &HexRegistry.lookup/2)

    case Preflight.check(registry, context.plan.package,
           dependencies: dependencies,
           check_registry?: true,
           registry_lookup: lookup
         ) do
      {:ok, entries} ->
        require_verified_dependencies(entries)

      {:error, blockers} ->
        {:error, {:publish_preflight, blockers, Preflight.format_blockers(blockers)}}
    end
  end

  defp dependency_preflight(_context, _dependencies), do: {:ok, []}

  defp package_preflight(%{plan: %{prepared_artifact: nil}} = context, project, _head),
    do: ordinary_package_preflight(context, project)

  defp package_preflight(%{plan: %{prepared_artifact: prepared}} = context, _project, head)
       when is_map(prepared) do
    with {:ok, expected} <- PreparedArtifact.load(prepared.expected_handoff),
         :ok <- complete_prepared_artifact(expected),
         true <- expected.package == context.plan.package || {:error, :prepared_package_mismatch},
         true <- expected.version == context.plan.version || {:error, :prepared_version_mismatch},
         true <- expected.source_revision == head || {:error, :prepared_revision_mismatch} do
      {:ok, %{expected_prepared_artifact: expected}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp package_preflight(context, project, _head),
    do: ordinary_package_preflight(context, project)

  defp ordinary_package_preflight(context, project) do
    with {:ok, metadata} <- Project.metadata_at(project),
         true <- metadata.app == context.plan.package || {:error, {:wrong_package, metadata.app}},
         true <-
           metadata.version == context.plan.version ||
             {:error, {:wrong_version, metadata.version}},
         {:ok, dependencies} <- dependency_preflight(context, metadata.dependencies) do
      {:ok, %{project: project, dependency_preflight: dependencies}}
    else
      {:error, reason} -> {:error, reason}
      value -> {:error, {:package_preflight_mismatch, value}}
    end
  end

  defp checkout_project(%{plan: %{prepared_artifact: nil}} = context, checkout) do
    {:ok, %{project: Path.expand(context.plan.project_path, checkout)}}
  end

  defp checkout_project(%{plan: %{prepared_artifact: prepared}} = context, checkout)
       when is_map(prepared) do
    [executable | argv] = prepared.prepare
    rebuilt_path = Path.expand(prepared.rebuilt_handoff, checkout)

    with {:ok, _result} <- isolated_run(executable, argv, cd: checkout),
         {:ok, rebuilt} <- PreparedArtifact.load(rebuilt_path),
         :ok <- compare_prepared(context.expected_prepared_artifact, rebuilt),
         {:ok, paths} <- verify_prepared_files(rebuilt, rebuilt_path, checkout),
         {:ok, metadata} <- Project.metadata_at(paths.project),
         true <- metadata.app == context.plan.package || {:error, {:wrong_package, metadata.app}},
         true <-
           metadata.version == context.plan.version ||
             {:error, {:wrong_version, metadata.version}},
         {:ok, dependencies} <- dependency_preflight(context, metadata.dependencies) do
      {:ok,
       %{
         project: paths.project,
         archive: paths.archive,
         archive_checksum: prepared_field(rebuilt, :archive_sha256),
         manifest_path: paths.manifest,
         manifest_sha256: prepared_field(rebuilt, :manifest_sha256),
         project_sha256: prepared_field(rebuilt, :project_sha256),
         source_revision: prepared_field(rebuilt, :source_revision),
         prepared_artifact: rebuilt,
         dependency_preflight: dependencies
       }}
    else
      {:error, reason} -> {:error, reason}
      value -> {:error, {:prepared_checkout_mismatch, value}}
    end
  end

  defp checkout_project(context, checkout),
    do: {:ok, %{project: Path.expand(context.plan.project_path, checkout)}}

  defp complete_prepared_artifact(artifact) do
    required = [:manifest_path, :manifest_sha256, :archive_path, :archive_sha256]

    if Enum.all?(required, &is_binary(prepared_field(artifact, &1))),
      do: :ok,
      else: {:error, :incomplete_prepared_artifact}
  end

  defp compare_prepared(expected, rebuilt) do
    fields = [
      :package,
      :version,
      :source_revision,
      :manifest_path,
      :manifest_sha256,
      :project_sha256,
      :archive_sha256
    ]

    case Enum.find(fields, &(prepared_field(expected, &1) != prepared_field(rebuilt, &1))) do
      nil ->
        :ok

      field ->
        {:error,
         {:prepared_artifact_drift, field, prepared_field(expected, field),
          prepared_field(rebuilt, field)}}
    end
  end

  defp verify_prepared_files(artifact, rebuilt_path, checkout) do
    bundle = Path.dirname(rebuilt_path)
    manifest = Path.expand(prepared_field(artifact, :manifest_path), checkout)
    project = Path.expand(prepared_field(artifact, :project_path), bundle)
    archive = Path.expand(prepared_field(artifact, :archive_path), bundle)

    with :ok <- verify_file_digest(manifest, prepared_field(artifact, :manifest_sha256)),
         :ok <- verify_tree_digest(project, prepared_field(artifact, :project_sha256)),
         :ok <- verify_file_digest(archive, prepared_field(artifact, :archive_sha256)) do
      {:ok, %{manifest: manifest, project: project, archive: archive}}
    end
  end

  defp verify_file_digest(path, expected) do
    case file_checksum(path) do
      {:ok, ^expected} -> :ok
      {:ok, actual} -> {:error, {:prepared_file_digest, path, expected, actual}}
      {:error, reason} -> {:error, {:prepared_file_unavailable, path, reason}}
    end
  end

  defp verify_tree_digest(path, expected) do
    if File.dir?(path) do
      actual = tree_checksum(path)
      if actual == expected, do: :ok, else: {:error, {:prepared_tree_digest, expected, actual}}
    else
      {:error, {:prepared_tree_unavailable, path}}
    end
  end

  defp tree_checksum(root) do
    entries =
      root
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)
      |> Enum.sort()
      |> Enum.map_join("\n", fn path ->
        {:ok, digest} = file_checksum(path)
        "#{Path.relative_to(path, root)}:#{digest}"
      end)

    sha256(entries)
  end

  defp prepared_field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp require_verified_dependencies(entries) do
    case Enum.filter(entries, &(&1.status == :unverified)) do
      [] -> {:ok, entries}
      unverified -> {:error, {:dependency_preflight_unverified, unverified}}
    end
  end

  defp ensure_absent(false, _reason), do: :ok
  defp ensure_absent(true, reason), do: {:error, reason}

  defp verify_checksum(context, registry_checksum) do
    if registry_checksum == context.archive_checksum,
      do: {:ok, %{registry_checksum: registry_checksum}},
      else: {:error, {:checksum_mismatch, context.archive_checksum, registry_checksum}}
  end

  defp release_status(%{plan: %{release_status: function}} = context)
       when is_function(function, 1),
       do: function.(context)

  defp release_status(context) do
    case registry_lookup(context) do
      :missing -> :absent
      {:published, _checksum} -> {:error, :version_already_published}
      {:unverified, reason} -> {:error, {:hex_preflight_unverified, reason}}
    end
  end

  defp registry_lookup(%{plan: %{registry_lookup: function}} = context)
       when is_function(function, 2),
       do: function.(context.plan.package, context.plan.version)

  defp registry_lookup(context),
    do: HexRegistry.lookup(context.plan.package, context.plan.version)

  defp resume_publish(status, context) do
    case registry_lookup(context) do
      {:published, checksum} when checksum == context.archive_checksum ->
        {:ok, %{registry_checksum: checksum}}

      {:published, checksum} ->
        {:error, {:checksum_mismatch, context.archive_checksum, checksum}}

      :missing when status == :started ->
        :rerun

      :missing ->
        {:error, :published_release_missing}

      {:unverified, reason} ->
        {:error, {:registry_unverified, reason}}
    end
  end

  defp resume_tag(status, context) do
    case ref_target(context.plan.repository, "refs/tags/#{context.plan.tag}") do
      {:ok, target} when target == context.head -> {:ok, %{tag: context.plan.tag}}
      {:ok, target} -> {:error, {:tag_target_changed, context.head, target}}
      :missing when status == :started -> :rerun
      :missing -> {:error, :release_tag_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resume_push_tag(status, context) do
    case remote_tag_target(context.plan.repository, context.plan.tag) do
      {:ok, target} when target == context.head -> {:ok, %{tag: context.plan.tag}}
      {:ok, target} -> {:error, {:remote_tag_target_changed, context.head, target}}
      :missing when status == :started -> :rerun
      :missing -> {:error, :remote_release_tag_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ref_target(repository, ref) do
    case isolated_run("git", ["rev-parse", "--verify", ref], cd: repository) do
      {:ok, result} -> {:ok, String.trim(result.output)}
      {:error, %{exit_code: 128}} -> :missing
      {:error, result} -> {:error, {:git_ref, ref, result.exit_code}}
    end
  end

  defp remote_tag_target(repository, tag) do
    case isolated_run("git", ["ls-remote", "--tags", "origin", "refs/tags/#{tag}"],
           cd: repository
         ) do
      {:ok, %{output: output}} ->
        case String.split(output, "\t", parts: 2) do
          [""] -> :missing
          [target, _ref] -> {:ok, String.trim(target)}
          _other -> {:error, :invalid_remote_tag_response}
        end

      {:error, result} ->
        {:error, {:remote_tag_check_failed, result.exit_code}}
    end
  end

  defp file_checksum(path) do
    with {:ok, bytes} <- File.read(path), do: {:ok, sha256(bytes)}
  end

  defp git_root(repository) do
    case isolated_run("git", ["rev-parse", "--show-toplevel"], cd: repository) do
      {:ok, result} -> {:ok, String.trim(result.output)}
      {:error, result} -> {:error, {:git_root, result.output}}
    end
  end

  defp git_clean?(repository), do: git_output!(repository, ["status", "--porcelain"]) == ""
  defp git_branch!(repository), do: git_output!(repository, ["branch", "--show-current"])
  defp git_head!(repository), do: git_output!(repository, ["rev-parse", "HEAD"])
  defp git_upstream_head!(repository), do: git_output!(repository, ["rev-parse", "@{u}"])
  defp git_remote_url!(repository), do: git_output!(repository, ["remote", "get-url", "origin"])

  defp git_tag_exists?(repository, tag) do
    case isolated_run("git", ["show-ref", "--verify", "--quiet", "refs/tags/#{tag}"],
           cd: repository
         ) do
      {:ok, _result} -> true
      {:error, %{exit_code: 1}} -> false
      {:error, result} -> raise MixWorkspaceOps.CommandError, result: result
    end
  end

  defp git_output!(repository, argv) do
    case isolated_run("git", argv, cd: repository) do
      {:ok, result} -> String.trim(result.output)
      {:error, result} -> raise MixWorkspaceOps.CommandError, result: result
    end
  end

  defp isolated_run(executable, argv, opts \\ []) do
    {extra_preserved, opts} = Keyword.pop(opts, :preserve, [])

    environment =
      (@preserved_environment ++ extra_preserved)
      |> Enum.uniq()
      |> Enum.flat_map(fn key ->
        case System.get_env(key) do
          nil -> []
          value -> ["#{key}=#{value}"]
        end
      end)

    Command.run("/usr/bin/env", ["-i" | environment] ++ [executable | argv], opts)
  end

  @doc false
  defdelegate hex_request_headers, to: HexRegistry, as: :request_headers

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
