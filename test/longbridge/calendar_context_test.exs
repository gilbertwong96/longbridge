defmodule Longbridge.CalendarContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.CalendarContext

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

  describe "earnings/4" do
    test "queries the finance calendar endpoint with category=earnings" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/quote/finance_calendar"
          assert parsed.path_with_query =~ "types=report"
          assert parsed.path_with_query =~ "date=2024-05-01"
          assert parsed.path_with_query =~ "date_end=2024-05-31"

          payload = JSON.encode!(%{code: 0, data: []})
          ok(conn, payload)
        end)

      assert {:ok, _} =
               CalendarContext.earnings(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end

    test "passes the :market option" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "markets=HK"

          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} =
               CalendarContext.earnings(config_with(server.port), "2024-05-01", "2024-05-31",
                 market: "HK"
               )

      stop_fake_http_server(server)
    end
  end

  describe "dividend_dates/4" do
    test "queries with category=dividend" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "types=dividend"
          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} =
               CalendarContext.dividend_dates(
                 config_with(server.port),
                 "2024-05-01",
                 "2024-05-31"
               )

      stop_fake_http_server(server)
    end
  end

  describe "stock_splits/4" do
    test "queries with category=split" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "types=split"
          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} =
               CalendarContext.stock_splits(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end

  describe "ipo_calendar/4" do
    test "queries with category=ipo" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "types=ipo"
          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} =
               CalendarContext.ipo_calendar(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end

  describe "macro_events/4" do
    test "queries with category=macro" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "types=macrodata"
          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} =
               CalendarContext.macro_events(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end

  describe "market_closures/2" do
    test "queries with category=closed and today as the date range" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "types=closed"
          today = Date.to_iso8601(Date.utc_today())
          assert parsed.path_with_query =~ "date=#{today}"
          assert parsed.path_with_query =~ "date_end=#{today}"

          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} = CalendarContext.market_closures(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "passes the :market option" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "markets=US"
          ok(conn, JSON.encode!(%{code: 0, data: []}))
        end)

      assert {:ok, _} =
               CalendarContext.market_closures(config_with(server.port), market: "US")

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn conn ->
          payload = JSON.encode!(%{code: 403, message: "forbidden", data: nil})
          ok(conn, payload)
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               CalendarContext.earnings(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end
end
