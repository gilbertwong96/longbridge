defmodule Longbridge.PortfolioContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.PortfolioContext

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

  describe "exchange_rates/2" do
    test "queries the exchange rates endpoint without base_currency" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/asset/exchange_rates"
          refute parsed.path_with_query =~ "base_currency"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = PortfolioContext.exchange_rates(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "passes base_currency when provided" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "base_currency=USD"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = PortfolioContext.exchange_rates(config_with(server.port), "USD")
      stop_fake_http_server(server)
    end
  end

  describe "portfolio_pl/2" do
    test "queries by-market endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/portfolio/profit-analysis/by-market"
          assert parsed.path_with_query =~ "market=HK"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
        end)

      assert {:ok, _} = PortfolioContext.portfolio_pl(config_with(server.port), market: "HK")
      stop_fake_http_server(server)
    end
  end

  describe "portfolio_positions/2" do
    test "queries the detail endpoint with date range" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "/v1/portfolio/profit-analysis/detail"
          assert parsed.path_with_query =~ "start_date=2024-05-01"
          assert parsed.path_with_query =~ "end_date=2024-05-31"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: %{}})))
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
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 403, message: "forbidden", data: nil})
          :gen_tcp.send(socket, http_ok(payload))
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
