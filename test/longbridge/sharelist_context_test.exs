defmodule Longbridge.SharelistContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.Config
  alias Longbridge.SharelistContext
  alias Longbridge.TestSupport.FakeHTTPServer

  defp start_fake_http_server(handler), do: FakeHTTPServer.start_with_finch(handler)
  defp stop_fake_http_server(server), do: FakeHTTPServer.stop_with_finch(server)
  defp parse_conn(conn), do: FakeHTTPServer.parse_conn(conn)
  defp ok(conn, data), do: FakeHTTPServer.ok(conn, data)

  defp config_with(port) do
    Config.new(
      token: "test-token",
      app_key: "test-key",
      app_secret: "test-secret",
      http_url: "http://127.0.0.1:#{port}"
    )
  end

  describe "create/2" do
    test "POSTs the sharelist body" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/sharelists"
          decoded = JSON.decode!(parsed.body)
          assert decoded["name"] == "My List"
          assert decoded["symbols"] == ["AAPL.US", "NVDA.US"]

          ok(conn, JSON.encode!(%{code: 0, data: %{"id" => "1"}}))
        end)

      assert {:ok, _} =
               SharelistContext.create(config_with(server.port),
                 name: "My List",
                 description: "tech",
                 symbols: ["AAPL.US", "NVDA.US"]
               )

      stop_fake_http_server(server)
    end
  end

  describe "list/2" do
    test "GETs the base endpoint with optional query params" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/sharelists"
          assert parsed.path_with_query =~ "count=20"

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = SharelistContext.list(config_with(server.port), count: 20)
      stop_fake_http_server(server)
    end
  end

  describe "popular/2" do
    test "GETs the /popular endpoint" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/sharelists/popular"

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = SharelistContext.popular(config_with(server.port))
      stop_fake_http_server(server)
    end
  end

  describe "detail/2" do
    test "GETs /v1/sharelists/<id>" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = SharelistContext.detail(config_with(server.port), "abc-123")
      stop_fake_http_server(server)
    end
  end

  describe "rename/3" do
    test "POSTs /v1/sharelists/<id> with new name" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"
          decoded = JSON.decode!(parsed.body)
          assert decoded["name"] == "New Name"

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = SharelistContext.rename(config_with(server.port), "abc-123", "New Name")
      stop_fake_http_server(server)
    end
  end

  describe "add_symbols/3" do
    test "POSTs /v1/sharelists/<id>/items with the symbols" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/sharelists/abc-123/items"
          decoded = JSON.decode!(parsed.body)
          assert decoded["symbols"] == ["AAPL.US", "NVDA.US"]

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               SharelistContext.add_symbols(config_with(server.port), "abc-123", [
                 "AAPL.US",
                 "NVDA.US"
               ])

      stop_fake_http_server(server)
    end
  end

  describe "remove_symbols/3" do
    test "DELETEs /v1/sharelists/<id>/items with the symbols" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "DELETE"
          assert parsed.path_with_query == "/v1/sharelists/abc-123/items"
          decoded = JSON.decode!(parsed.body)
          assert decoded["symbols"] == ["AAPL.US"]

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               SharelistContext.remove_symbols(config_with(server.port), "abc-123", ["AAPL.US"])

      stop_fake_http_server(server)
    end
  end

  describe "delete/2" do
    test "DELETEs /v1/sharelists/<id>" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "DELETE"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"

          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = SharelistContext.delete(config_with(server.port), "abc-123")
      stop_fake_http_server(server)
    end
  end

  describe "error propagation" do
    test "all methods propagate API errors" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, JSON.encode!(%{code: 403, message: "forbidden", data: nil}))
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               SharelistContext.list(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               SharelistContext.detail(config_with(server.port), "x")

      assert {:error, {:api_error, 403, "forbidden"}} =
               SharelistContext.delete(config_with(server.port), "x")

      stop_fake_http_server(server)
    end
  end

  describe "http_url per-call override" do
    test "detail/3 hits the URL passed in opts" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"
          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      config =
        Config.new(token: "tok", app_key: "k", app_secret: "s", http_url: "http://127.0.0.1:1")

      assert {:ok, _} =
               SharelistContext.detail(config, "abc-123",
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end

    test "list/3 preserves :params while forwarding :http_url override" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/sharelists"
          assert parsed.path_with_query =~ "count=20"
          ok(conn, JSON.encode!(%{code: 0, data: %{}}))
        end)

      config =
        Config.new(token: "tok", app_key: "k", app_secret: "s", http_url: "http://127.0.0.1:1")

      assert {:ok, _} =
               SharelistContext.list(config, [count: 20],
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end
  end
end
