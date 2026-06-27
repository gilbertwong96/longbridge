defmodule Longbridge.DCAContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.DCAContext

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

  describe "create_plan/2" do
    test "POSTs the plan body with default allow_margin: false" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/dailycoins/create"

          decoded = Jason.decode!(parsed.body)
          assert decoded["symbol"] == "AAPL.US"
          assert decoded["amount"] == "100"
          assert decoded["allow_margin"] == false

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{"plan_id" => "p1"}})))
        end)

      assert {:ok, %{"plan_id" => "p1"}} =
               DCAContext.create_plan(config_with(server.port),
                 symbol: "AAPL.US",
                 amount: "100",
                 frequency: :weekly,
                 day_of_week: "Monday"
               )

      stop_fake_http_server(server)
    end

    test "preserves user-provided allow_margin" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          decoded = Jason.decode!(parsed.body)
          assert decoded["allow_margin"] == true
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               DCAContext.create_plan(config_with(server.port),
                 symbol: "AAPL.US",
                 amount: "100",
                 frequency: :daily,
                 allow_margin: true
               )

      stop_fake_http_server(server)
    end
  end

  describe "list_plans/2" do
    test "GETs the list endpoint with pagination defaults" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/dailycoins/query"
          assert parsed.path_with_query =~ "page=1"
          assert parsed.path_with_query =~ "limit=100"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{code: 0, data: %{"plans" => []}}))
          )
        end)

      assert {:ok, %{"plans" => []}} = DCAContext.list_plans(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "encodes :status atom to its numeric code" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "status=Active"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{code: 0, data: %{"plans" => []}}))
          )
        end)

      assert {:ok, _} =
               DCAContext.list_plans(config_with(server.port), status: :active)

      stop_fake_http_server(server)
    end

    test "accepts raw status string passthrough" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "status=custom-status"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{code: 0, data: %{"plans" => []}}))
          )
        end)

      assert {:ok, _} =
               DCAContext.list_plans(config_with(server.port), status: "custom-status")

      stop_fake_http_server(server)
    end
  end

  describe "update_plan/2" do
    test "POSTs the update endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query == "/v1/dailycoins/update"
          decoded = Jason.decode!(parsed.body)
          assert decoded["plan_id"] == "p1"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               DCAContext.update_plan(config_with(server.port),
                 plan_id: "p1",
                 amount: "200"
               )

      stop_fake_http_server(server)
    end
  end

  describe "pause_plan/2, resume_plan/2, delete_plan/2" do
    test "pause_plan/2 POSTs with status: 2" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query == "/v1/dailycoins/toggle"
          decoded = Jason.decode!(parsed.body)
          assert decoded["plan_id"] == "p1"
          assert decoded["status"] == "Suspended"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = DCAContext.pause_plan(config_with(server.port), "p1")
      stop_fake_http_server(server)
    end

    test "resume_plan/2 POSTs with status: 1" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          decoded = Jason.decode!(parsed.body)
          assert decoded["status"] == "Active"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = DCAContext.resume_plan(config_with(server.port), "p1")
      stop_fake_http_server(server)
    end

    test "delete_plan/2 POSTs with status: 3" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          decoded = Jason.decode!(parsed.body)
          assert decoded["status"] == "Finished"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = DCAContext.delete_plan(config_with(server.port), "p1")
      stop_fake_http_server(server)
    end
  end

  describe "plan_detail/2" do
    test "finds the matching plan by plan_id from the list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                plans: [
                  %{"plan_id" => "p1", "amount" => "100"},
                  %{"plan_id" => "p2", "amount" => "200"}
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"plan_id" => "p2"}} =
               DCAContext.plan_detail(config_with(server.port), "p2")

      stop_fake_http_server(server)
    end

    test "returns nil when the plan_id is not in the list" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 0, data: %{plans: []}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, nil} = DCAContext.plan_detail(config_with(server.port), "missing")
      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 403, message: "forbidden", data: nil})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               DCAContext.plan_detail(config_with(server.port), "p1")

      stop_fake_http_server(server)
    end
  end
end
