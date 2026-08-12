defmodule MixWorkspaceOps.Release.LocalAdapter do
  @moduledoc "Concrete clean-checkout, Hex-publication, verification, and tag adapter."

  @behaviour MixWorkspaceOps.Release.Adapter

  alias MixWorkspaceOps.{Command, Git, Project}

  @preserved_environment ~w(HOME PATH USER LOGNAME LANG LC_ALL TERM SHELL ASDF_DIR ASDF_DATA_DIR MIX_HOME MIX_ARCHIVES MIX_ENV MIX_TARGET ERL_AFLAGS ERL_FLAGS ELIXIR_ERL_OPTIONS SSH_AUTH_SOCK XDG_RUNTIME_DIR CI CODEX_CI)
  @hex_user_agent ~c"mix_workspace_ops/0.1.0"

  @impl true
  def transition(:preflight, context), do: preflight(context)
  def transition(:checkout, context), do: checkout(context)
  def transition(:gates, context), do: gates(context)
  def transition(:archive, context), do: archive(context)
  def transition(:publish, context), do: publish(context)
  def transition(:verify, context), do: verify(context)
  def transition(:tag, context), do: tag(context)
  def transition(:push_tag, context), do: push_tag(context)

  defp preflight(context) do
    plan = context.plan
    repository = plan.repository
    project = Path.expand(plan.project_path, repository)
    default_branch = plan.default_branch

    with {:ok, ^repository} <- Git.root(repository),
         true <- Git.clean?(repository) || {:error, :dirty_worktree},
         ^default_branch <- Git.branch!(repository),
         head <- Git.head!(repository),
         ^head <- Git.upstream_head!(repository),
         :ok <- ensure_absent(Git.tag_exists?(repository, plan.tag), :local_tag_exists),
         :ok <- ensure_remote_tag_absent(repository, plan.tag),
         {:ok, metadata} <- Project.metadata_at(project),
         true <- metadata.app == plan.package || {:error, {:wrong_package, metadata.app}},
         true <- metadata.version == plan.version || {:error, {:wrong_version, metadata.version}},
         :absent <- release_status(context),
         :ok <- ensure_no_overlay() do
      {:ok, %{head: head, project: project, origin: Git.remote_url!(repository)}}
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
         true <- Git.clean?(checkout) || {:error, :dirty_release_checkout} do
      {:ok, %{checkout: checkout, project: Path.expand(context.plan.project_path, checkout)}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp gates(context) do
    Enum.reduce_while(context.plan.gates, {:ok, %{}}, fn [executable | argv], {:ok, _evidence} ->
      case isolated_run(executable, argv, cd: context.project) do
        {:ok, _result} ->
          {:cont, {:ok, %{}}}

        {:error, result} ->
          IO.binwrite(:stderr, result.output)
          {:halt, {:error, {:gate_failed, executable, argv, result.exit_code}}}
      end
    end)
  end

  defp archive(context) do
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

  defp publish(context) do
    [executable | prefix_args] = context.plan.publisher_prefix
    argv = prefix_args ++ ["mix", "hex.publish", "--yes"]

    case isolated_run(executable, argv, cd: context.project, preserve: ["HEX_API_KEY"]) do
      {:ok, _result} -> {:ok, %{}}
      {:error, result} -> {:error, {:publisher_failed, result.exit_code}}
    end
  end

  defp verify(context) do
    url = ~c"https://hex.pm/api/packages/#{context.plan.package}/releases/#{context.plan.version}"
    :ok = ensure_http_started()

    case :httpc.request(:get, {url, hex_request_headers()}, [ssl: ssl_options()],
           body_format: :binary
         ) do
      {:ok, {{_http, 200, _reason}, _headers, body}} -> verify_checksum(context, body)
      {:ok, {{_http, status, _reason}, _headers, _body}} -> {:error, {:hex_status, status}}
      {:error, reason} -> {:error, {:hex_request, reason}}
    end
  end

  defp tag(context) do
    repository = context.plan.repository
    expected_head = context.head

    with ^expected_head <- Git.head!(repository),
         true <- Git.clean?(repository) || {:error, :worktree_changed_after_publish},
         {:ok, _result} <-
           Command.run("git", ["tag", context.plan.tag, context.head], cd: repository) do
      {:ok, %{tag: context.plan.tag}}
    else
      {:error, reason} -> {:error, reason}
      value -> {:error, {:tag_precondition_changed, value}}
    end
  end

  defp push_tag(context) do
    case Command.run("git", ["push", "origin", "refs/tags/#{context.plan.tag}"],
           cd: context.plan.repository
         ) do
      {:ok, _result} -> {:ok, %{tag: context.plan.tag}}
      {:error, result} -> {:error, {:tag_push_failed, result.exit_code}}
    end
  end

  defp ensure_remote_tag_absent(repository, tag) do
    case Command.run("git", ["ls-remote", "--exit-code", "--tags", "origin", "refs/tags/#{tag}"],
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

  defp ensure_absent(false, _reason), do: :ok
  defp ensure_absent(true, reason), do: {:error, reason}

  defp verify_checksum(context, body) do
    decoded = :json.decode(body)
    registry_checksum = decoded["checksum"] |> String.downcase()

    if registry_checksum == context.archive_checksum,
      do: {:ok, %{registry_checksum: registry_checksum}},
      else: {:error, {:checksum_mismatch, context.archive_checksum, registry_checksum}}
  catch
    kind, reason -> {:error, {:hex_response, kind, reason}}
  end

  defp ensure_http_started do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp release_status(%{plan: %{release_status: function}} = context)
       when is_function(function, 1),
       do: function.(context)

  defp release_status(context) do
    url = ~c"https://hex.pm/api/packages/#{context.plan.package}/releases/#{context.plan.version}"
    :ok = ensure_http_started()

    case :httpc.request(:get, {url, hex_request_headers()}, [ssl: ssl_options()],
           body_format: :binary
         ) do
      {:ok, {{_http, 404, _reason}, _headers, _body}} ->
        :absent

      {:ok, {{_http, 200, _reason}, _headers, _body}} ->
        {:error, :version_already_published}

      {:ok, {{_http, status, _reason}, _headers, _body}} ->
        {:error, {:hex_preflight_status, status}}

      {:error, reason} ->
        {:error, {:hex_preflight_request, reason}}
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

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @doc false
  def hex_request_headers, do: [{~c"user-agent", @hex_user_agent}]

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
