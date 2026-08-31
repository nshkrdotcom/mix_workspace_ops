defmodule MixWorkspaceOps.RemoteIdentity do
  @moduledoc "Normalizes hosted Git remote URLs to portable owner/repository identity."

  @remote_schemes ~w(git http https ssh)
  @url_remote ~r{^(?<scheme>[A-Za-z][A-Za-z0-9+.\-]*)://(?<authority>[^/]*)/(?<path>.+)$}
  @scp_remote ~r{^(?<authority>[^/:]+):(?<path>.+)$}
  @segment ~r{^[A-Za-z0-9_.\-]+$}

  @type classification :: {:hosted, String.t()} | :local | {:error, term()}

  @doc "Classifies a Git remote as hosted identity, local path, or malformed evidence."
  @spec classify(String.t()) :: classification()
  def classify(remote) when is_binary(remote) do
    trimmed = String.trim(remote)

    cond do
      trimmed == "" ->
        {:error, {:unrecognized_git_remote, remote}}

      String.starts_with?(trimmed, "file://") ->
        :local

      local_path?(trimmed) ->
        :local

      true ->
        with {:ok, path} <- remote_path(trimmed),
             {:ok, identity} <- owner_repository(path) do
          {:hosted, identity}
        else
          :error -> {:error, {:unrecognized_git_remote, remote}}
        end
    end
  end

  def classify(remote), do: {:error, {:unrecognized_git_remote, remote}}

  @doc "All hosted identities in an exact remote set; local paths contribute none."
  @spec hosted_identities([String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def hosted_identities(remotes) when is_list(remotes) do
    remotes
    |> Enum.reduce_while({:ok, []}, fn remote, {:ok, identities} ->
      case classify(remote) do
        {:hosted, identity} -> {:cont, {:ok, [identity | identities]}}
        :local -> {:cont, {:ok, identities}}
        {:error, reason} -> {:halt, {:error, {:remote_identity, remote, reason}}}
      end
    end)
    |> case do
      {:ok, identities} -> {:ok, identities |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  @doc "The `owner/repository` a hosted remote URL names."
  @spec github(String.t()) :: {:ok, String.t()} | {:error, term()}
  def github(remote) do
    case classify(remote) do
      {:hosted, identity} -> {:ok, identity}
      :local -> {:error, {:unrecognized_git_remote, remote}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp local_path?(remote) do
    not String.contains?(remote, "://") and not Regex.match?(@scp_remote, remote)
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
end
