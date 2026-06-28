defmodule Longbridge.MarketContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.MarketContext
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

  describe "market_session/1" do
    test "queries the market status endpoint" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/market-status"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.market_session(config_with(server.port))
      stop_fake_http_server(server)
    end
  end

  describe "broker_holdings/3" do
    test "queries with period" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/broker-holding"
          assert parsed.path_with_query =~ "counter_id=ST/HK/700"
          assert parsed.path_with_query =~ "type=rct_5"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.broker_holdings(config_with(server.port), "700.HK", period: :rct_5)

      stop_fake_http_server(server)
    end
  end

  describe "anomaly_alerts/2" do
    test "queries the anomaly endpoint with the market" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/changes"
          assert parsed.path_with_query =~ "market=HK"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.anomaly_alerts(config_with(server.port), "HK")
      stop_fake_http_server(server)
    end
  end

  describe "index_constituents/2" do
    test "queries with the index symbol" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/index-constituents"
          assert parsed.path_with_query =~ "counter_id=HSI"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.index_constituents(config_with(server.port), "HSI")
      stop_fake_http_server(server)
    end
  end

  describe "trade_status/2" do
    test "queries with the symbol" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/trades-statistics"
          assert parsed.path_with_query =~ "counter_id=ST/US/AAPL"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.trade_status(config_with(server.port), "AAPL.US")
      stop_fake_http_server(server)
    end
  end

  describe "ah_premium/3" do
    test "encodes period and count" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/ahpremium/klines"
          assert parsed.path_with_query =~ "line_type=day"
          assert parsed.path_with_query =~ "line_num=100"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
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
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "line_type=custom"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK", period: "custom")

      stop_fake_http_server(server)
    end

    test "encodes period :week as line_type=week" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "line_type=week"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK", period: :week)

      stop_fake_http_server(server)
    end

    test "encodes period :month as line_type=month" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "line_type=month"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK", period: :month)

      stop_fake_http_server(server)
    end

    test "encodes period :quarter as line_type=quarter" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "line_type=quarter"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK", period: :quarter)

      stop_fake_http_server(server)
    end

    test "encodes period :year as line_type=year" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "line_type=year"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.ah_premium(config_with(server.port), "700.HK", period: :year)

      stop_fake_http_server(server)
    end
  end

  describe "broker_holdings/3 - all period atoms" do
    test "encodes period :rct_1 as type=rct_1" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "type=rct_1"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.broker_holdings(config_with(server.port), "AAPL.US", period: :rct_1)

      stop_fake_http_server(server)
    end

    test "encodes period :rct_20 as type=rct_20" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "type=rct_20"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.broker_holdings(config_with(server.port), "AAPL.US", period: :rct_20)

      stop_fake_http_server(server)
    end

    test "encodes period :rct_60 as type=rct_60" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "type=rct_60"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.broker_holdings(config_with(server.port), "AAPL.US", period: :rct_60)

      stop_fake_http_server(server)
    end

    test "accepts a raw binary period (passthrough)" do
      server =
        start_fake_http_server(fn conn ->
          assert parse_conn(conn).path_with_query =~ "type=custom"
          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.broker_holdings(config_with(server.port), "AAPL.US",
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
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "POST"
          assert parsed.path_with_query == "/v1/quote/market/stock-events"
          decoded = Jason.decode!(parsed.body)
          assert decoded["sort"] == 0
          assert decoded["limit"] == 20
          assert decoded["markets"] == []

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.top_movers(config_with(server.port), sort: :hot)
      stop_fake_http_server(server)
    end

    test "encodes :time sort atom" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          decoded = Jason.decode!(parsed.body)
          assert decoded["sort"] == 1

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.top_movers(config_with(server.port), sort: :time)
      stop_fake_http_server(server)
    end

    test "encodes :change sort atom" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          decoded = Jason.decode!(parsed.body)
          assert decoded["sort"] == 2

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.top_movers(config_with(server.port), sort: :change)
      stop_fake_http_server(server)
    end

    test "encodes markets list of atoms strings" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          decoded = Jason.decode!(parsed.body)
          assert decoded["markets"] == ["HK", "US"]

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               MarketContext.top_movers(config_with(server.port), markets: ["HK", "US"])

      stop_fake_http_server(server)
    end
  end

  describe "rank_categories/1" do
    test "queries the rank categories endpoint" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/market/rank/categories"

          ok(conn, Jason.encode!(%{code: 0, data: %{"list" => []}}))
        end)

      assert {:ok, []} = MarketContext.rank_categories(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, []} = MarketContext.rank_categories(config_with(server.port))
      stop_fake_http_server(server)
    end
  end

  describe "rank_list/3" do
    test "prepends ib_ when missing" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/quote/market/rank/list"
          assert parsed.path_with_query =~ "key=ib_active"
          assert parsed.path_with_query =~ "need_article=false"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.rank_list(config_with(server.port), "active")
      stop_fake_http_server(server)
    end

    test "preserves ib_ prefix when present" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "key=ib_already_prefixed"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = MarketContext.rank_list(config_with(server.port), "ib_already_prefixed")
      stop_fake_http_server(server)
    end
  end

  describe "error propagation" do
    test "all methods propagate API errors" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(%{code: 403, message: "forbidden", data: nil}))
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
