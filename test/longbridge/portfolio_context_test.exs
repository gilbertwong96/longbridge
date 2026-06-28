defmodule Longbridge.PortfolioContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.PortfolioContext

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

  describe "exchange_rates/2" do
    test "queries the exchange rates endpoint without base_currency" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/asset/exchange_rates"
          refute parsed.path_with_query =~ "base_currency"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = PortfolioContext.exchange_rates(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "passes base_currency when provided" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "base_currency=USD"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = PortfolioContext.exchange_rates(config_with(server.port), "USD")
      stop_fake_http_server(server)
    end
  end

  describe "portfolio_pl/2" do
    test "queries by-market endpoint" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/portfolio/profit-analysis/by-market"
          assert parsed.path_with_query =~ "market=HK"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} = PortfolioContext.portfolio_pl(config_with(server.port), market: "HK")
      stop_fake_http_server(server)
    end

    test "does not leak HTTP opts (:finch) into the query string" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "market=HK"
          refute parsed.path_with_query =~ "finch"
          refute parsed.path_with_query =~ "http_url"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               PortfolioContext.portfolio_pl(config_with(server.port),
                 market: "HK",
                 finch: Longbridge.Finch
               )

      stop_fake_http_server(server)
    end
  end

  describe "portfolio_positions/2" do
    test "queries the detail endpoint with date range" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query =~ "/v1/portfolio/profit-analysis/detail"
          assert parsed.path_with_query =~ "start_date=2024-05-01"
          assert parsed.path_with_query =~ "end_date=2024-05-31"

          ok(conn, Jason.encode!(%{code: 0, data: %{}}))
        end)

      assert {:ok, _} =
               PortfolioContext.portfolio_positions(config_with(server.port),
                 start_date: "2024-05-01",
                 end_date: "2024-05-31"
               )

      stop_fake_http_server(server)
    end
  end

  describe "error propagation" do
    test "all methods propagate API errors" do
      server =
        start_fake_http_server(fn conn ->
          payload = Jason.encode!(%{code: 403, message: "forbidden", data: nil})
          ok(conn, payload)
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               PortfolioContext.exchange_rates(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               PortfolioContext.portfolio_pl(config_with(server.port))

      assert {:error, {:api_error, 403, "forbidden"}} =
               PortfolioContext.portfolio_positions(config_with(server.port))

      stop_fake_http_server(server)
    end
  end
end
