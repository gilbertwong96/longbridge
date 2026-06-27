defmodule Longbridge.QuoteHTTPContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, QuoteHTTPContext}

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

  describe "short_positions/3" do
    test "queries US short interest with default count" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, _body} = parse_request(request)
          assert method == "GET"
          assert request =~ "/v1/quote/short-positions"
          assert request =~ "symbol=TSLA.US"
          assert request =~ "count=20"

          payload =
            Jason.encode!(%{
              code: 0,
              data: [
                %{
                  "timestamp" => "2024-03-15T04:00:00Z",
                  "current_shares_short" => "111286790",
                  "avg_daily_share_volume" => "95077016",
                  "days_to_cover" => "1.17",
                  "rate" => "0.0068",
                  "close" => ""
                }
              ]
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{
                  "current_shares_short" => "111286790",
                  "days_to_cover" => "1.17"
                }
              ]} = QuoteHTTPContext.short_positions(config_with(server.port), "TSLA.US")

      stop_fake_http_server(server)
    end

    test "supports custom count" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "count=50"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => []}))
          )
        end)

      assert {:ok, []} =
               QuoteHTTPContext.short_positions(config_with(server.port), "AAPL.US", count: 50)

      stop_fake_http_server(server)
    end

    test "returns an empty list when data is not a list" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"unexpected" => "shape"}}))
          )
        end)

      assert {:ok, []} =
               QuoteHTTPContext.short_positions(config_with(server.port), "TSLA.US")

      stop_fake_http_server(server)
    end
  end

  describe "option_volume/2" do
    test "queries the option volume endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/option-volume"
          assert request =~ "symbol=AAPL230317P160000.US"

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                "total_volume" => "100000",
                "total_turnover" => "15000000",
                "open_interest" => "50000",
                "put_call_ratio" => "0.85"
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"total_volume" => "100000", "put_call_ratio" => "0.85"}} =
               QuoteHTTPContext.option_volume(
                 config_with(server.port),
                 "AAPL230317P160000.US"
               )

      stop_fake_http_server(server)
    end
  end

  describe "option_volume_daily/4" do
    test "queries the daily option volume endpoint with a date range" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/option-volume-daily"
          assert request =~ "symbol=AAPL230317P160000.US"
          assert request =~ "start_date=2024-06-01"
          assert request =~ "end_date=2024-06-30"

          payload =
            Jason.encode!(%{
              code: 0,
              data: [
                %{"date" => "2024-06-03", "volume" => "5000"},
                %{"date" => "2024-06-04", "volume" => "7000"}
              ]
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"date" => "2024-06-03", "volume" => "5000"},
                %{"date" => "2024-06-04", "volume" => "7000"}
              ]} =
               QuoteHTTPContext.option_volume_daily(
                 config_with(server.port),
                 "AAPL230317P160000.US",
                 "2024-06-01",
                 "2024-06-30"
               )

      stop_fake_http_server(server)
    end
  end

  describe "update_pinned/4" do
    test "POSTs the pin request and returns :ok on success" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, body} = parse_request(request)
          assert method == "POST"
          assert request =~ "/v1/quote/watchlist/pinned"

          decoded = Jason.decode!(body)
          assert decoded["group_id"] == "group-1"
          assert decoded["symbol"] == "AAPL.US"
          assert decoded["is_pinned"] == true

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert :ok =
               QuoteHTTPContext.update_pinned(
                 config_with(server.port),
                 "group-1",
                 "AAPL.US",
                 true
               )

      stop_fake_http_server(server)
    end

    test "supports is_pinned: false" do
      server =
        start_fake_http_server(fn request, socket ->
          {_method, _path, body} = parse_request(request)
          decoded = Jason.decode!(body)
          assert decoded["is_pinned"] == false

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert :ok =
               QuoteHTTPContext.update_pinned(
                 config_with(server.port),
                 "group-1",
                 "AAPL.US",
                 false
               )

      stop_fake_http_server(server)
    end
  end
end
