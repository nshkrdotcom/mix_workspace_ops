defmodule MixWorkspaceOps.Release.HexRegistryTest do
  use ExUnit.Case, async: true

  alias MixWorkspaceOps.Release.HexRegistry

  test "looks up the exact package/version and normalizes its checksum" do
    checksum = String.duplicate("AB", 32)

    assert HexRegistry.lookup("sample_package", "1.2.3",
             request: fn url ->
               assert to_string(url) ==
                        "https://hex.pm/api/packages/sample_package/releases/1.2.3"

               {:ok, 200, :json.encode(%{checksum: checksum}) |> IO.iodata_to_binary()}
             end
           ) == {:published, String.downcase(checksum)}
  end

  test "distinguishes absence, transport uncertainty and malformed evidence" do
    assert HexRegistry.lookup("sample_package", "1.2.3", request: fn _url -> {:ok, 404, ""} end) ==
             :missing

    assert HexRegistry.lookup("sample_package", "1.2.3",
             request: fn _url -> {:error, :offline} end
           ) == {:unverified, {:hex_request, :offline}}

    assert HexRegistry.lookup("sample_package", "1.2.3", request: fn _url -> {:ok, 503, ""} end) ==
             {:unverified, {:hex_status, 503}}

    assert HexRegistry.lookup("sample_package", "1.2.3",
             request: fn _url -> {:ok, 200, ~s({"checksum":"short"})} end
           ) == {:unverified, :invalid_hex_checksum}
  end

  test "registry requests identify the client without authorization" do
    assert [{~c"user-agent", user_agent}] = HexRegistry.request_headers()
    assert List.starts_with?(user_agent, ~c"mix_workspace_ops/")

    refute Enum.any?(HexRegistry.request_headers(), fn {name, _value} ->
             String.downcase(to_string(name)) == "authorization"
           end)
  end
end
