defmodule Longbridge.AssetContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.AssetContext
  alias Longbridge.TestSupport.FakeHTTPServer

  defp start_fake_http_server(handler), do: FakeHTTPServer.start_with_finch(handler)
  defp stop_fake_http_server(server), do: FakeHTTPServer.stop_with_finch(server)
  defp parse_conn(conn), do: FakeHTTPServer.parse_conn(conn)
  defp ok(conn, data), do: FakeHTTPServer.ok(conn, data)

  defp config_with(port) do
    Longbridge.Config.new(
      token: "test-token",
      app_key: "test-key",
      app_secret: "test-secret",
      http_url: "http://127.0.0.1:#{port}"
    )
  end

  describe "statements/2" do
    test "queries the daily statements endpoint by default" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/statement/list"
          assert parsed.path_with_query =~ "statement_type=1"

          ok(conn, Jason.encode!(%{code: 0, data: %{"list" => []}}))
        end)

      assert {:ok, %{"list" => []}} = AssetContext.statements(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "uses statement_type=2 when type: :monthly" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "statement_type=2"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = AssetContext.statements(config_with(server.port), type: :monthly)
      stop_fake_http_server(server)
    end

    test "passes page and page_size" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "page=2"
          assert parsed.path_with_query =~ "page_size=50"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               AssetContext.statements(config_with(server.port), page: 2, page_size: 50)

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(%{code: 401, message: "forbidden", data: nil}))
        end)

      assert {:error, {:api_error, 401, "forbidden"}} =
               AssetContext.statements(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "download_url/2" do
    test "queries the download endpoint with the file_key" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/statement/download"
          assert parsed.path_with_query =~ "file_key=abc-123"

          ok(conn, Jason.encode!(%{code: 0, data: %{"url" => "https://example.com/x"}}))
        end)

      assert {:ok, %{"url" => "https://example.com/x"}} =
               AssetContext.download_url(config_with(server.port), "abc-123")

      stop_fake_http_server(server)
    end

    test "URL-encodes file_key" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          # URI.encode_www_form uses + for spaces
          assert parsed.path_with_query =~ "file_key=key+with+space"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               AssetContext.download_url(config_with(server.port), "key with space")

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(%{code: 404, message: "not found", data: nil}))
        end)

      assert {:error, {:api_error, 404, "not found"}} =
               AssetContext.download_url(config_with(server.port), "missing")

      stop_fake_http_server(server)
    end
  end

  describe "http_url per-call override" do
    test "download_url/3 hits the URL passed in opts" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/statement/download"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      config =
        Longbridge.Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s",
          http_url: "http://127.0.0.1:1"
        )

      assert {:ok, _} =
               AssetContext.download_url(config, "file-key",
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end
  end
end
