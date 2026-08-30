defmodule MixWorkspaceOps.Release.HexRegistry do
  @moduledoc "Read-only exact-release lookup against the Hex API."

  @hex_user_agent ~c"mix_workspace_ops/0.1.0"

  @type state :: {:published, String.t()} | :missing | {:unverified, term()}

  @doc "Returns the exact package/version release checksum without using credentials."
  @spec lookup(String.t(), String.t(), keyword()) :: state()
  def lookup(package, version, opts \\ []) when is_binary(package) and is_binary(version) do
    request = Keyword.get(opts, :request, &request/1)

    case request.(url(package, version)) do
      {:ok, 200, body} -> decode_release(body)
      {:ok, 404, _body} -> :missing
      {:ok, status, _body} -> {:unverified, {:hex_status, status}}
      {:error, reason} -> {:unverified, {:hex_request, reason}}
    end
  rescue
    error -> {:unverified, {:hex_exception, error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:unverified, {:hex_throw, kind, reason}}
  end

  @doc false
  def request_headers, do: [{~c"user-agent", @hex_user_agent}]

  defp request(url) do
    with :ok <- ensure_http_started() do
      case :httpc.request(:get, {url, request_headers()}, [ssl: ssl_options()],
             body_format: :binary
           ) do
        {:ok, {{_http, status, _reason}, _headers, body}} -> {:ok, status, body}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp decode_release(body) do
    case :json.decode(body) do
      %{"checksum" => checksum} when is_binary(checksum) ->
        normalized = String.downcase(checksum)

        if Regex.match?(~r/^[0-9a-f]{64}$/, normalized),
          do: {:published, normalized},
          else: {:unverified, :invalid_hex_checksum}

      _other ->
        {:unverified, :missing_hex_checksum}
    end
  rescue
    _error -> {:unverified, :invalid_hex_response}
  catch
    _kind, _reason -> {:unverified, :invalid_hex_response}
  end

  defp ensure_http_started do
    with {:ok, _apps} <- Application.ensure_all_started(:inets),
         {:ok, _apps} <- Application.ensure_all_started(:ssl) do
      :ok
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp url(package, version),
    do: ~c"https://hex.pm/api/packages/#{package}/releases/#{version}"
end
