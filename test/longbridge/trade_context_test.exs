defmodule Longbridge.TradeContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, TradeContext}

  # ── Fake HTTP server ─────────────────────────────────────

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

  defp reply_json(socket, data) do
    body = Jason.encode!(data)

    resp =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\n\r\n#{body}"

    :gen_tcp.send(socket, resp)
  end

  defp parse_request(req) do
    [head, body] = String.split(req, "\r\n\r\n", parts: 2)
    [request_line | _header_lines] = String.split(head, "\r\n", parts: 2)
    [method, path, _ver] = String.split(request_line, " ", parts: 3)

    %{method: method, path: path, body: body || ""}
  end

  # ── Tests ────────────────────────────────────────────────

  describe "submit_order/2" do
    test "sends a POST to /v1/trade/order with transformed keys" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "POST"
          assert String.starts_with?(parsed.path, "/v1/trade/order")
          reply_json(sock, %{code: 0, message: "ok", data: %{"order_id" => "12345"}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)

      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"order_id" => "12345"}} =
               TradeContext.submit_order(ctx,
                 symbol: "AAPL.US",
                 side: :buy,
                 order_type: :lo,
                 submitted_quantity: "100",
                 time_in_force: :day,
                 submitted_price: "250.00"
               )
    end
  end

  describe "cancel_order/2" do
    test "sends a POST to /v1/trade/order/cancel with order_id" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "POST"
          assert String.contains?(parsed.path, "/v1/trade/order/cancel")
          reply_json(sock, %{code: 0, message: "ok", data: %{}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} = TradeContext.cancel_order(ctx, "my-order-id")
    end
  end

  describe "replace_order/2" do
    test "sends a POST to /v1/trade/order/replace" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "POST"
          assert String.contains?(parsed.path, "/v1/trade/order/replace")
          reply_json(sock, %{code: 0, message: "ok", data: %{}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} =
               TradeContext.replace_order(ctx,
                 order_id: "o1",
                 quantity: "200",
                 price: "100.00"
               )
    end
  end

  describe "order_detail/2" do
    test "sends a GET to /v1/trade/order with order_id param" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "GET"
          assert String.contains?(parsed.path, "/v1/trade/order")
          assert String.contains?(parsed.path, "order_id=o123")
          reply_json(sock, %{code: 0, message: "ok", data: %{}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} = TradeContext.order_detail(ctx, "o123")
    end
  end

  describe "today_orders/2" do
    test "sends a GET with query params and parses response" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "GET"
          assert String.contains?(parsed.path, "/v1/trade/order/today")
          assert String.contains?(parsed.path, "symbol=700.HK")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"orders" => [%{"order_id" => "o1"}]}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"orders" => [%{"order_id" => "o1"}]}} =
               TradeContext.today_orders(ctx, symbol: "700.HK")
    end

    test "works with no filters" do
      server =
        start_fake_http_server(fn _req, sock ->
          reply_json(sock, %{code: 0, message: "ok", data: %{"orders" => []}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      assert {:ok, %{"orders" => []}} = TradeContext.today_orders(ctx)
    end
  end

  describe "history_orders/2" do
    test "includes start_at and end_at in query" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "start_at=1600000000")
          assert String.contains?(parsed.path, "end_at=1700000000")
          reply_json(sock, %{code: 0, message: "ok", data: %{"orders" => []}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} =
               TradeContext.history_orders(ctx,
                 start_at: 1_600_000_000,
                 end_at: 1_700_000_000
               )
    end
  end

  describe "today_executions/2 and history_executions/2" do
    test "today_executions calls /v1/trade/execution/today" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/trade/execution/today")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"trades" => []}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"trades" => []}} = TradeContext.today_executions(ctx)
    end

    test "history_executions calls /v1/trade/execution/history" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/trade/execution/history")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"trades" => [%{"trade_id" => "t1"}]}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"trades" => [%{"trade_id" => "t1"}]}} =
               TradeContext.history_executions(ctx)
    end
  end

  describe "account_balance/1-2" do
    test "returns account data" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/asset/account")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"list" => [%{"currency" => "HKD"}]}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"list" => [%{"currency" => "HKD"}]}} =
               TradeContext.account_balance(ctx)
    end

    test "filters by currency" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "currency=USD")
          reply_json(sock, %{code: 0, message: "ok", data: %{"list" => []}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      TradeContext.account_balance(ctx, "USD")
    end
  end

  describe "stock_positions/2 and fund_positions/2" do
    test "stock_positions calls /v1/asset/stock" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/asset/stock")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"list" => [%{"symbol" => "AAPL.US"}]}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} = TradeContext.stock_positions(ctx)
    end

    test "fund_positions calls /v1/asset/fund" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/asset/fund")
          reply_json(sock, %{code: 0, message: "ok", data: %{"list" => []}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} = TradeContext.fund_positions(ctx)
    end
  end

  describe "margin_ratio/2" do
    test "calls /v1/risk/margin-ratio" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/risk/margin-ratio")
          assert String.contains?(parsed.path, "TSLA.US")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"im_factor" => "0.5"}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"im_factor" => "0.5"}} =
               TradeContext.margin_ratio(ctx, "TSLA.US")
    end
  end

  describe "cash_flow/2" do
    test "calls /v1/asset/cashflow with filters" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert String.contains?(parsed.path, "/v1/asset/cashflow")
          reply_json(sock, %{code: 0, message: "ok", data: %{"list" => []}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} = TradeContext.cash_flow(ctx)
    end
  end

  describe "estimate_max_purchase_quantity/2" do
    test "sends a POST to /v1/trade/estimate" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "POST"
          assert String.contains?(parsed.path, "/v1/trade/estimate")

          reply_json(sock, %{
            code: 0,
            message: "ok",
            data: %{"cash_max_qty" => "100"}
          })
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"cash_max_qty" => "100"}} =
               TradeContext.estimate_max_purchase_quantity(ctx,
                 symbol: "AAPL.US",
                 side: :buy,
                 order_type: :lo
               )
    end
  end

  describe "API error handling" do
    test "returns error tuple for API error codes" do
      server =
        start_fake_http_server(fn _req, sock ->
          reply_json(sock, %{code: 403_201, message: "signature invalid", data: nil})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:error, {:api_error, 403_201, "signature invalid"}} =
               TradeContext.today_orders(ctx)
    end
  end

  describe "history_orders/2 extra coverage" do
    test "transforms atom keys and list values" do
      server =
        start_fake_http_server(fn req, sock ->
          parsed = parse_request(req)
          assert parsed.method == "GET"
          assert String.contains?(parsed.path, "/v1/trade/order/history")
          assert String.contains?(parsed.path, "symbol=AAPL.US,BABA.US")
          reply_json(sock, %{code: 0, message: "ok", data: %{"orders" => []}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"orders" => []}} =
               TradeContext.history_orders(ctx, symbol: ["AAPL.US", "BABA.US"])
    end

    test "handles binary keys in opts" do
      server =
        start_fake_http_server(fn req, sock ->
          assert String.contains?(req, "/v1/trade/order/history")
          reply_json(sock, %{code: 0, message: "ok", data: %{}})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, _} = TradeContext.history_orders(ctx, %{"limit" => 5})
    end

    test "returns error on API error" do
      server =
        start_fake_http_server(fn _req, sock ->
          reply_json(sock, %{code: 5001, message: "bad request"})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:error, {:api_error, 5001, "bad request"}} =
               TradeContext.history_orders(ctx)
    end

    test "returns error on transport error" do
      config =
        Config.new(token: "tok", app_key: "k", app_secret: "s", http_url: "http://127.0.0.1:1")

      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:error, _} = TradeContext.history_orders(ctx)
    end

    test "returns ok for non-standard response" do
      server =
        start_fake_http_server(fn _req, sock ->
          reply_json(sock, %{not_code: true})
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = test_config(server.port)
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      assert {:ok, %{"not_code" => true}} = TradeContext.history_orders(ctx)
    end
  end

  describe "push dispatch" do
    test "default callback receives push events" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      test_pid = self()
      TradeContext.set_default_push_callback(ctx, fn event -> send(test_pid, {:push, event}) end)

      notif = %Longbridge.Trade.V1.Notification{
        topic: "order_changed",
        content_type: :CONTENT_JSON,
        data: ~s({"order_id": "123"})
      }

      {:ok, iodata, _} = Protox.encode(notif)
      body = IO.iodata_to_binary(iodata)
      send(ctx, {:longbridge, nil, {:push, 18, body}})

      assert_receive {:push, %{"order_id" => "123"}}, 1_000
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "topic callback takes priority over default" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      test_pid = self()

      TradeContext.put_callback(ctx, "order_changed", fn event ->
        send(test_pid, {:topic, event})
      end)

      TradeContext.set_default_push_callback(ctx, fn event ->
        send(test_pid, {:default, event})
      end)

      notif = %Longbridge.Trade.V1.Notification{
        topic: "order_changed",
        content_type: :CONTENT_JSON,
        data: ~s({"order_id": "456"})
      }

      {:ok, iodata, _} = Protox.encode(notif)
      body = IO.iodata_to_binary(iodata)
      send(ctx, {:longbridge, nil, {:push, 18, body}})

      assert_receive {:topic, %{"order_id" => "456"}}, 1_000
      refute_receive {:default, _}, 100
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "push with no callback does nothing" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      notif = %Longbridge.Trade.V1.Notification{
        topic: "order_changed",
        content_type: :CONTENT_JSON,
        data: ~s({"order_id": "789"})
      }

      {:ok, iodata, _} = Protox.encode(notif)
      body = IO.iodata_to_binary(iodata)
      send(ctx, {:longbridge, nil, {:push, 18, body}})
      Process.sleep(100)
      assert Process.alive?(ctx)
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "push with unknown cmd and default callback" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      test_pid = self()
      TradeContext.set_default_push_callback(ctx, fn event -> send(test_pid, {:push, event}) end)

      send(ctx, {:longbridge, nil, {:push, 99, ~s({"data": 1})}})
      assert_receive {:push, %{"data" => 1}}, 1_000
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "push with unknown cmd and no default callback" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      send(ctx, {:longbridge, nil, {:push, 99, ~s({"data": 1})}})
      Process.sleep(100)
      assert Process.alive?(ctx)
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "push with non-JSON data is ignored" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      test_pid = self()
      TradeContext.set_default_push_callback(ctx, fn event -> send(test_pid, {:push, event}) end)

      notif = %Longbridge.Trade.V1.Notification{
        topic: "order_changed",
        content_type: :CONTENT_JSON,
        data: "not-json"
      }

      {:ok, iodata, _} = Protox.encode(notif)
      body = IO.iodata_to_binary(iodata)
      send(ctx, {:longbridge, nil, {:push, 18, body}})
      Process.sleep(100)
      refute_receive {:push, _}, 100
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "push with empty topic is ignored" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      notif = %Longbridge.Trade.V1.Notification{
        topic: "",
        content_type: :CONTENT_JSON,
        data: ~s({"order_id": "123"})
      }

      {:ok, iodata, _} = Protox.encode(notif)
      body = IO.iodata_to_binary(iodata)
      send(ctx, {:longbridge, nil, {:push, 18, body}})
      Process.sleep(100)
      assert Process.alive?(ctx)
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "non-push message is ignored" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      send(ctx, {:longbridge, nil, {:response, 1, <<>>}})
      Process.sleep(100)
      assert Process.alive?(ctx)
      GenServer.stop(ctx, :normal, 1_000)
    end
  end

  describe "GenServer callbacks" do
    test "heartbeat sends to conn" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      send(ctx, :heartbeat)
      Process.sleep(100)
      assert Process.alive?(ctx)
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "unknown messages are ignored" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      send(ctx, {:unknown, "msg"})
      Process.sleep(100)
      assert Process.alive?(ctx)
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "register with name" do
      name = :test_trade_named_ctx
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true, name: name)

      assert Process.whereis(name) == ctx
      GenServer.stop(ctx, :normal, 1_000)
    end

    test "remove_callback works" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)

      TradeContext.put_callback(ctx, :private, fn _ -> :ok end)
      TradeContext.remove_callback(ctx, :private)
      GenServer.stop(ctx, :normal, 1_000)
    end
  end

  # ── Helpers ──────────────────────────────────────────────

  defp test_config(port) do
    Config.new(token: "tok", app_key: "k", app_secret: "s", http_url: "http://127.0.0.1:#{port}")
  end
end
