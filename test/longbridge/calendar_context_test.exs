defmodule Longbridge.CalendarContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.CalendarContext

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

  describe "earnings/4" do
    test "queries the finance calendar endpoint with category=earnings" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.method == "GET"
          assert parsed.path_with_query =~ "/v1/quote/finance_calendar"
          assert parsed.path_with_query =~ "types=report"
          assert parsed.path_with_query =~ "date=2024-05-01"
          assert parsed.path_with_query =~ "date_end=2024-05-31"

          payload = Jason.encode!(%{code: 0, data: []})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, _} =
               CalendarContext.earnings(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end

    test "passes the :market option" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "markets=HK"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
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
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "types=dividend"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
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
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "types=split"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
        end)

      assert {:ok, _} =
               CalendarContext.stock_splits(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end

  describe "ipo_calendar/4" do
    test "queries with category=ipo" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "types=ipo"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
        end)

      assert {:ok, _} =
               CalendarContext.ipo_calendar(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end

  describe "macro_events/4" do
    test "queries with category=macro" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "types=macrodata"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
        end)

      assert {:ok, _} =
               CalendarContext.macro_events(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end

  describe "market_closures/2" do
    test "queries with category=closed and today as the date range" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "types=closed"
          today = Date.to_iso8601(Date.utc_today())
          assert parsed.path_with_query =~ "date=#{today}"
          assert parsed.path_with_query =~ "date_end=#{today}"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
        end)

      assert {:ok, _} = CalendarContext.market_closures(config_with(server.port))
      stop_fake_http_server(server)
    end

    test "passes the :market option" do
      server =
        start_fake_http_server(fn request, socket ->
          parsed = parse_request(request)
          assert parsed.path_with_query =~ "markets=US"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{code: 0, data: []})))
        end)

      assert {:ok, _} =
               CalendarContext.market_closures(config_with(server.port), market: "US")

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 403, message: "forbidden", data: nil})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               CalendarContext.earnings(config_with(server.port), "2024-05-01", "2024-05-31")

      stop_fake_http_server(server)
    end
  end
end
