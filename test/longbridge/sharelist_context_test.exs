defmodule Longbridge.SharelistContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.SharelistContext

  defp start_fake_http_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    pid =
      spawn(fn ->
        loop = fn loop ->
          case :gen_tcp.accept(listen) do
            {:ok, socket} ->
              case :gen_tcp.recv(socket, 0, 5_000) do
                {:ok, data} ->
                  handler.(data, socket)
                  :gen_tcp.close(socket)

                _ ->
                  :gen_tcp.close(socket)
              end

              loop.(loop)

            {:error, :closed} ->
              :ok
          end
        end

        loop.(loop)
      end)

    Process.unlink(pid)

    %{port: port, pid: pid, socket: listen}
  end

  defp stop_fake_http_server(%{socket: socket, pid: pid}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
  end

  defp http_ok(body) do
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
  end

  defp parse_request(request) do
    [head, body] = String.split(request, "\r\n\r\n", parts: 2)
    [request_line | _] = String.split(head, "\r\n", parts: 2)
    [method, path_with_query, _] = String.split(request_line, " ", parts: 3)
    %{method: method, path_with_query: path_with_query, body: body || ""}
  end

  defp config_with(port) do
    Longbridge.Config.new(
      token: "test-token",
      app_key: "test-key",
      app_secret: "test-secret",
      http_url: "http://127.0.0.1:#{port}"
    )
  end

  describe "create/2" do
    test "POSTs the sharelist body" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/sharelists"
          decoded = Jason.decode!(parsed.body)
          assert decoded["name"] == "My List"
          assert decoded["symbols"] == ["AAPL.US", "NVDA.US"]

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{"id" => "1"}})))
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
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/sharelists"
          assert parsed.path_with_query =~ "count=20"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = SharelistContext.list(config_with(server.port), count: 20)
      stop_fake_http_server(server)
    end
  end

  describe "popular/2" do
    test "GETs the /popular endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/sharelists/popular"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = SharelistContext.popular(config_with(server.port))
      stop_fake_http_server(server)
    end
  end

  describe "detail/2" do
    test "GETs /v1/sharelists/<id>" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "GET"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = SharelistContext.detail(config_with(server.port), "abc-123")
      stop_fake_http_server(server)
    end
  end

  describe "rename/3" do
    test "POSTs /v1/sharelists/<id> with new name" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"
          decoded = Jason.decode!(parsed.body)
          assert decoded["name"] == "New Name"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = SharelistContext.rename(config_with(server.port), "abc-123", "New Name")
      stop_fake_http_server(server)
    end
  end

  describe "add_symbols/3" do
    test "POSTs /v1/sharelists/<id>/items with the symbols" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/sharelists/abc-123/items"
          decoded = Jason.decode!(parsed.body)
          assert decoded["symbols"] == ["AAPL.US", "NVDA.US"]

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
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
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "DELETE"
          assert parsed.path_with_query == "/v1/sharelists/abc-123/items"
          decoded = Jason.decode!(parsed.body)
          assert decoded["symbols"] == ["AAPL.US"]

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               SharelistContext.remove_symbols(config_with(server.port), "abc-123", ["AAPL.US"])

      stop_fake_http_server(server)
    end
  end

  describe "delete/2" do
    test "DELETEs /v1/sharelists/<id>" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "DELETE"
          assert parsed.path_with_query == "/v1/sharelists/abc-123"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = SharelistContext.delete(config_with(server.port), "abc-123")
      stop_fake_http_server(server)
    end
  end

  describe "error propagation" do
    test "all methods propagate API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 403, message: "forbidden", data: nil})
          :gen_tcp.send(socket, http_ok(payload))
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
end
