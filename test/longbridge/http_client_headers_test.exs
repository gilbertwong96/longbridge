defmodule Longbridge.HTTPClientHeadersTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, HTTPClient}
  alias Longbridge.TestSupport.FakeHTTPServer

  defp start_fake_http_server(handler), do: FakeHTTPServer.start_with_finch(handler)

  defp stop_fake_http_server(server), do: FakeHTTPServer.stop_with_finch(server)

  defp ok(conn, data), do: FakeHTTPServer.ok(conn, data)

  defp assert_req_header(conn, name, value) do
    assert Plug.Conn.get_req_header(conn, name) == [value],
           "expected header #{inspect(name)}: #{inspect(value)}"
  end

  defp refute_req_header(conn, name) do
    assert Plug.Conn.get_req_header(conn, name) == [],
           "expected header #{inspect(name)} to be absent"
  end

  describe "custom headers in Config.headers" do
    test "are emitted on every HTTP request" do
      server =
        start_fake_http_server(fn conn ->
          assert_req_header(conn, "x-forwarded-for", "1.2.3.4")
          assert_req_header(conn, "x-tenant", "acme")

          ok(conn, JSON.encode!(%{"code" => 0, "data" => %{}}))
        end)

      config =
        Config.new(
          token: "tok",
          app_key: "key",
          app_secret: "secret",
          http_url: "http://127.0.0.1:#{server.port}",
          headers: [{"X-Forwarded-For", "1.2.3.4"}, {"X-Tenant", "acme"}]
        )

      assert {:ok, _} = HTTPClient.request_json(:get, "/v1/quote/anything", "", config)

      stop_fake_http_server(server)
    end

    test "do not appear when Config.headers is nil" do
      server =
        start_fake_http_server(fn conn ->
          refute_req_header(conn, "x-forwarded-for")
          refute_req_header(conn, "x-tenant")

          ok(conn, JSON.encode!(%{"code" => 0, "data" => %{}}))
        end)

      config =
        Config.new(
          token: "tok",
          app_key: "key",
          app_secret: "secret",
          http_url: "http://127.0.0.1:#{server.port}"
        )

      assert {:ok, _} = HTTPClient.request_json(:get, "/v1/quote/anything", "", config)

      stop_fake_http_server(server)
    end
  end
end
