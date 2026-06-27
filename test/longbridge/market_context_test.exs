defmodule Longbridge.MarketContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.MarketContext

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
                  # Give the client time to read the response.
                  Process.sleep(20)
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

  describe "market_session/1" do
    test "queries the market status endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/market-status"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.market_session(config_with(server.port))
      stop_fake_http_server(server)
    end
  end

  describe "broker_holdings/3" do
    test "queries with period" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/broker-holding"
          assert parsed.path_with_query =~ "counter_id=ST/HK/700"
          assert parsed.path_with_query =~ "type=rct_5"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               MarketContext.broker_holdings(config_with(server.port), "700.HK",
                 period: :rct_5
               )

      stop_fake_http_server(server)
    end
  end

  describe "anomaly_alerts/2" do
    test "queries the anomaly endpoint with the market" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/changes"
          assert parsed.path_with_query =~ "market=HK"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.anomaly_alerts(config_with(server.port), "HK")
      stop_fake_http_server(server)
    end
  end

  describe "index_constituents/2" do
    test "queries with the index symbol" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/index-constituents"
          assert parsed.path_with_query =~ "counter_id=HSI"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.index_constituents(config_with(server.port), "HSI")
      stop_fake_http_server(server)
    end
  end

  describe "trade_status/2" do
    test "queries with the symbol" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/trades-statistics"
          assert parsed.path_with_query =~ "counter_id=ST/US/AAPL"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.trade_status(config_with(server.port), "AAPL.US")
      stop_fake_http_server(server)
    end
  end

  describe "ah_premium/3" do
    test "encodes period and count" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/ahpremium/klines"
          assert parsed.path_with_query =~ "line_type=day"
          assert parsed.path_with_query =~ "line_num=100"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK",
                 period: :day,
                 count: 100
               )

      stop_fake_http_server(server)
    end

    test "accepts raw binary period (passthrough)" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "line_type=custom"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK",
                 period: "custom"
               )

      stop_fake_http_server(server)
    end
  end

  describe "trading_days/4" do
    test "returns :removed_upstream" do
      assert {:error, :removed_upstream} =
               MarketContext.trading_days(config_with(0), "2024-01-01", "2024-12-31", "US")
    end
  end

  describe "top_movers/2" do
    test "POSTs with encoded sort atom" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/quote/market/stock-events"
          decoded = Jason.decode!(parsed.body)
          assert decoded["sort"] == 0
          assert decoded["limit"] == 20
          assert decoded["markets"] == []

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.top_movers(config_with(server.port), sort: :hot)
      stop_fake_http_server(server)
    end

    test "encodes :time and :change sort atoms" do
      Enum.each([{:time, 1}, {:change, 2}], fn {sort_atom, sort_code} ->
        server =
          start_fake_http_server(fn request, socket ->
            parsed = parse_request(request)
            decoded = Jason.decode!(parsed.body)
            assert decoded["sort"] == sort_code
            :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
          end)

        assert {:ok, _} = MarketContext.top_movers(config_with(server.port), sort: sort_atom)
        stop_fake_http_server(server)
      end)
    end

    test "encodes markets list of atoms strings" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          decoded = Jason.decode!(parsed.body)
          assert decoded["markets"] == ["HK", "US"]

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} =
               MarketContext.top_movers(config_with(server.port), markets: ["HK", "US"])

      stop_fake_http_server(server)
    end
  end

  describe "rank_categories/1" do
    test "queries the rank categories endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/market/rank/categories"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{code: 0, data: %{"list" => []}}))
          )
        end)

      assert {:ok, []} = MarketContext.rank_categories(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
        end)

      assert {:ok, []} = MarketContext.rank_categories(config_with(server.port))
      stop_fake_http_server(server)
    end
  end

  describe "rank_list/3" do
    test "prepends ib_ when missing" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/quote/market/rank/list"
          assert parsed.path_with_query =~ "key=ib_active"
          assert parsed.path_with_query =~ "need_article=false"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.rank_list(config_with(server.port), "active")
      stop_fake_http_server(server)
    end

    test "preserves ib_ prefix when present" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "key=ib_already_prefixed"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = MarketContext.rank_list(config_with(server.port), "ib_already_prefixed")
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
               MarketContext.market_session(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.broker_holdings(config_with(server.port), "AAPL.US")

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.anomaly_alerts(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.index_constituents(config_with(server.port), "HSI")

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.trade_status(config_with(server.port), "AAPL.US")

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.ah_premium(config_with(server.port), "700.HK")

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.top_movers(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.rank_categories(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               MarketContext.rank_list(config_with(server.port), "active")

      stop_fake_http_server(server)
    end
  end
end