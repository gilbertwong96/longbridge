defmodule Longbridge.HTTPClientHeadersTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, HTTPClient}

  defp start_fake_http_server(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:ready, :ok})

        loop = fn loop ->
          case :gen_tcp.accept(listen, 5_000) do
            {:ok, socket} ->
              case :gen_tcp.recv(socket, 0, 5_000) do
                {:ok, data} ->
                  handler.(data, socket)
                  :gen_tcp.close(socket)

                _ ->
                  :gen_tcp.close(socket)
              end

              loop.(loop)

            {:error, :timeout} ->
              :ok

            {:error, _} ->
              :ok
          end
        end

        loop.(loop)
      end)

    receive do
      {:ready, :ok} -> :ok
    after
      2_000 -> raise "fake server failed to start"
    end

    %{port: port, pid: pid, socket: listen}
  end

  defp stop_fake_http_server(%{socket: socket, pid: pid}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
  end

  defp http_ok(body) do
    "HTTP/1.1 200 OK\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n\r\n" <> body
  end

  describe "custom headers in Config.headers" do
    test "are emitted on every HTTP request" do
      server =
        start_fake_http_server(fn request, socket ->
          # HTTP/1.1 headers are case-insensitive; the server-side
          # normalises them to lowercase.
          assert request =~ ~r/x-forwarded-for: 1\.2\.3\.4/i
          assert request =~ ~r/x-tenant: acme/i

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
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
        start_fake_http_server(fn request, socket ->
          refute request =~ ~r/x-forwarded-for/i
          refute request =~ ~r/x-tenant/i

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
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
