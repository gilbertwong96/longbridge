defmodule Longbridge.AssetContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.AssetContext

  defp start_fake_http_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

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

  defp parse_request(req) do
    [head, body] = String.split(req, "\r\n\r\n", parts: 2)
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

  describe "statements/2" do
    test "queries the daily statements endpoint by default" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/statement/list"
          assert parsed.path_with_query =~ "statement_type=1"

          payload = Jason.encode!(%{code: 0, data: %{"list" => []}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"list" => []}} = AssetContext.statements(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "uses statement_type=2 when type: :monthly" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "statement_type=2"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = AssetContext.statements(config_with(server.port), type: :monthly)
      stop_fake_http_server(server)
    end

    test "passes page and page_size" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "page=2"
          assert parsed.path_with_query =~ "page_size=50"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               AssetContext.statements(config_with(server.port), page: 2, page_size: 50)

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 401, message: "forbidden", data: nil})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, {:api_error, 401, "forbidden"}} =
               AssetContext.statements(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "download_url/2" do
    test "queries the download endpoint with the file_key" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/statement/download"
          assert parsed.path_with_query =~ "file_key=abc-123"

          payload = Jason.encode!(%{code: 0, data: %{"url" => "https://example.com/x"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"url" => "https://example.com/x"}} =
               AssetContext.download_url(config_with(server.port), "abc-123")

      stop_fake_http_server(server)
    end

    test "URL-encodes file_key" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          # URI.encode_www_form uses + for spaces
          assert parsed.path_with_query =~ "file_key=key+with+space"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               AssetContext.download_url(config_with(server.port), "key with space")

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 404, message: "not found", data: nil})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, {:api_error, 404, "not found"}} =
               AssetContext.download_url(config_with(server.port), "missing")

      stop_fake_http_server(server)
    end
  end
end
