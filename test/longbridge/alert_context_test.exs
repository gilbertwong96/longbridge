defmodule Longbridge.AlertContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{AlertContext, Config}

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

  defp config_with(port) do
    Config.new(
      token: "test-token",
      app_key: "test-key",
      app_secret: "test-secret",
      http_url: "http://127.0.0.1:#{port}"
    )
  end

  defp parse_request(request) do
    [head, body] = String.split(request, "\r\n\r\n", parts: 2)
    [line | _] = String.split(head, "\r\n")
    [method, path, _version] = String.split(line, " ", parts: 3)
    {method, path, body || ""}
  end

  describe "update/3" do
    test "POSTs the full alert item with the new enabled flag" do
      item = %{
        "id" => "alert-1",
        "indicator_id" => "5",
        "frequency" => "daily",
        "scope" => "AAPL.US",
        "state" => "active",
        "value_map" => %{"price" => "150.00"},
        "enabled" => true
      }

      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "POST"
          assert path == "/v1/notify/reminders"

          decoded = Jason.decode!(body)
          # All fields are forwarded, with `enabled` toggled.
          assert decoded["id"] == "alert-1"
          assert decoded["indicator_id"] == "5"
          assert decoded["frequency"] == "daily"
          assert decoded["scope"] == "AAPL.US"
          assert decoded["state"] == "active"
          assert decoded["value_map"] == %{"price" => "150.00"}
          assert decoded["enabled"] == false

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, _} = AlertContext.update(config_with(server.port), item, false)

      stop_fake_http_server(server)
    end

    test "supports enabling (true) as well" do
      item = %{
        "id" => "alert-2",
        "indicator_id" => "5",
        "frequency" => "daily",
        "scope" => "AAPL.US",
        "state" => "active",
        "value_map" => %{},
        "enabled" => false
      }

      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, _} = AlertContext.update(config_with(server.port), item, true)

      stop_fake_http_server(server)
    end
  end

  describe "delete_alert/2" do
    test "accepts a single id and wraps it in a list" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "DELETE"
          assert path == "/v1/notify/reminders"

          decoded = Jason.decode!(body)
          assert decoded == %{"ids" => ["alert-1"]}

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, _} = AlertContext.delete_alert(config_with(server.port), "alert-1")

      stop_fake_http_server(server)
    end

    test "accepts a list of ids for batch delete" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, _} =
               AlertContext.delete_alert(config_with(server.port), ["alert-1", "alert-2"])

      stop_fake_http_server(server)
    end
  end

  describe "add_alert/2" do
    test "POSTs the alert options as the body" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, body} = parse_request(request)
          assert method == "POST"

          decoded = Jason.decode!(body)
          assert decoded["symbol"] == "AAPL.US"
          assert decoded["price"] == "150.00"
          assert decoded["direction"] == "above"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"id" => "alert-1"}}))
          )
        end)

      assert {:ok, %{"id" => "alert-1"}} =
               AlertContext.add_alert(config_with(server.port),
                 symbol: "AAPL.US",
                 price: "150.00",
                 direction: :above
               )

      stop_fake_http_server(server)
    end
  end

  describe "list_alerts/1" do
    test "queries the reminders endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/notify/reminders"

          payload =
            Jason.encode!(%{
              "code" => 0,
              "data" => [
                %{
                  "id" => "alert-1",
                  "scope" => "AAPL.US",
                  "enabled" => true
                }
              ]
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"id" => "alert-1", "scope" => "AAPL.US", "enabled" => true}
              ]} = AlertContext.list_alerts(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "enable_alert/2 (deprecated)" do
    test "POSTs enable: true with the alert_id" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "POST"
          assert path == "/v1/notify/reminders"
          decoded = Jason.decode!(body)
          assert decoded["alert_id"] == "alert-1"
          assert decoded["enable"] == true

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => %{}})))
        end)

      assert {:ok, _} = AlertContext.enable_alert(config_with(server.port), "alert-1")
      stop_fake_http_server(server)
    end
  end

  describe "disable_alert/2 (deprecated)" do
    test "POSTs enable: false with the alert_id" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "POST"
          assert path == "/v1/notify/reminders"
          decoded = Jason.decode!(body)
          assert decoded["alert_id"] == "alert-2"
          assert decoded["enable"] == false

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => %{}})))
        end)

      assert {:ok, _} = AlertContext.disable_alert(config_with(server.port), "alert-2")
      stop_fake_http_server(server)
    end
  end
end
