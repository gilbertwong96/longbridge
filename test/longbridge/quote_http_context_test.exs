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
          assert request =~ "GET /v1/quote/option-volume-stats"
          assert request =~ "symbol=AAPL230317P160000.US"

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                "c" => "50000",
                "p" => "40000"
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"c" => "50000", "p" => "40000"}} =
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
          assert request =~ "GET /v1/quote/option-volume-stats/daily"
          assert request =~ "symbol=AAPL230317P160000.US"
          assert request =~ "start=2024-06-01"
          assert request =~ "end=2024-06-30"

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                stats: [
                  %{"date" => "2024-06-03", "volume" => "5000"},
                  %{"date" => "2024-06-04", "volume" => "7000"}
                ]
              }
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

  describe "security_list/2" do
    test "queries the security list endpoint with market and category" do
      response = %{
        "list" => [
          %{"symbol" => "TSLA.US", "name_en" => "Tesla", "name_cn" => "特斯拉"},
          %{"symbol" => "NVDA.US", "name_en" => "NVIDIA", "name_cn" => "英伟达"}
        ]
      }

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/get_security_list"
          assert request =~ "market=US"
          assert request =~ "category=Overnight"

          payload = Jason.encode!(%{"code" => 0, "data" => response})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"symbol" => "TSLA.US", "name_en" => "Tesla"},
                %{"symbol" => "NVDA.US", "name_en" => "NVIDIA"}
              ]} =
               QuoteHTTPContext.security_list(config_with(server.port),
                 market: "US",
                 category: "Overnight"
               )

      stop_fake_http_server(server)
    end

    test "accepts page and count for pagination" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "page=2"
          assert request =~ "count=100"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               QuoteHTTPContext.security_list(config_with(server.port),
                 market: "HK",
                 category: "Overnight",
                 page: 2,
                 count: 100
               )

      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload =
            Jason.encode!(%{"code" => 0, "data" => [%{"symbol" => "TSLA.US"}]})

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"symbol" => "TSLA.US"}]} =
               QuoteHTTPContext.security_list(config_with(server.port),
                 market: "US",
                 category: "Overnight"
               )

      stop_fake_http_server(server)
    end

    test "accepts a wrapped %{\"list\" => [...]} response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                list: [
                  %{"symbol" => "AAPL.US"}
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"symbol" => "AAPL.US"}]} =
               QuoteHTTPContext.security_list(config_with(server.port),
                 market: "US",
                 category: "US.Overnight"
               )

      stop_fake_http_server(server)
    end

    test "returns [] when neither flat list nor %{\"list\" => _} present" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{code: 0, data: %{"other" => "x"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, []} =
               QuoteHTTPContext.security_list(config_with(server.port),
                 market: "US"
               )

      stop_fake_http_server(server)
    end
  end

  describe "market_temperature/2" do
    test "queries with the market parameter" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/market_temperature"
          assert request =~ "market=HK"

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{"temperature" => 65, "sentiment" => "Greed", "market" => "HK"}
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"temperature" => 65, "sentiment" => "Greed"}} =
               QuoteHTTPContext.market_temperature(config_with(server.port), "HK")

      stop_fake_http_server(server)
    end
  end

  describe "history_market_temperature/4" do
    test "queries with market and date range" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/history_market_temperature"
          assert request =~ "market=US"
          assert request =~ "start_date=2024-01-01"
          assert request =~ "end_date=2024-06-30"

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                "list" => [
                  %{"date" => "2024-01-02", "temperature" => 45, "sentiment" => "Neutral"},
                  %{"date" => "2024-01-03", "temperature" => 52, "sentiment" => "Neutral"}
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              %{
                "list" => [
                  %{"date" => "2024-01-02", "temperature" => 45},
                  %{"date" => "2024-01-03", "temperature" => 52}
                ]
              }} =
               QuoteHTTPContext.history_market_temperature(
                 config_with(server.port),
                 "US",
                 "2024-01-01",
                 "2024-06-30"
               )

      stop_fake_http_server(server)
    end
  end

  describe "short_trades/3" do
    test "routes .HK symbols to /short-trades/hk" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/short-trades/hk"
          assert request =~ "counter_id=ST%2FHK%2F700"
          assert request =~ "page_size=50"
          assert request =~ "last_timestamp=0"

          payload =
            Jason.encode!(%{
              code: 0,
              data: [
                %{
                  "timestamp" => "1779471885",
                  "price" => "426.010",
                  "volume" => "1000",
                  "side" => "Short"
                }
              ]
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"side" => "Short", "price" => "426.010"}]} =
               QuoteHTTPContext.short_trades(config_with(server.port), "700.HK")

      stop_fake_http_server(server)
    end

    test "routes non-HK symbols to /short-trades/us" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/short-trades"
          refute request =~ "/short-trades/hk"
          assert request =~ "counter_id=ST%2FUS%2FAAPL"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => []}))
          )
        end)

      assert {:ok, []} =
               QuoteHTTPContext.short_trades(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end

    test "supports count and last_timestamp options for pagination" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "page_size=100"
          assert request =~ "last_timestamp=1779471885"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               QuoteHTTPContext.short_trades(config_with(server.port), "TSLA.US",
                 count: 100,
                 last_timestamp: 1_779_471_885
               )

      stop_fake_http_server(server)
    end

    test "returns [] when data is not a list and has no list wrapper" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => %{"other" => "x"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, []} =
               QuoteHTTPContext.short_trades(config_with(server.port), "TSLA.US")

      stop_fake_http_server(server)
    end
  end

  describe "watchlist_groups/1" do
    test "queries the watchlist groups endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/watchlist/groups"

          payload =
            Jason.encode!(%{
              "code" => 0,
              "data" => %{
                "groups" => [
                  %{"id" => "1", "name" => "Tech", "securities" => ["AAPL.US"]},
                  %{"id" => "2", "name" => "Bank", "securities" => []}
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"id" => "1", "name" => "Tech"},
                %{"id" => "2", "name" => "Bank"}
              ]} = QuoteHTTPContext.watchlist_groups(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => [%{"id" => "1"}]})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"id" => "1"}]} =
               QuoteHTTPContext.watchlist_groups(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "returns [] when data is neither groups nor a list" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => %{"other" => "x"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, []} = QuoteHTTPContext.watchlist_groups(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "create_watchlist_group/3" do
    test "POSTs the group with name and securities" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, body} = parse_request(request)
          assert method == "POST"

          decoded = Jason.decode!(body)
          assert decoded["name"] == "Tech"
          assert decoded["securities"] == ["AAPL.US", "NVDA.US"]

          payload = Jason.encode!(%{"code" => 0, "data" => %{"id" => "group-42"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "group-42"} =
               QuoteHTTPContext.create_watchlist_group(
                 config_with(server.port),
                 "Tech",
                 ["AAPL.US", "NVDA.US"]
               )

      stop_fake_http_server(server)
    end

    test "accepts integer id" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => %{"id" => 123}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "123"} =
               QuoteHTTPContext.create_watchlist_group(
                 config_with(server.port),
                 "Tech",
                 []
               )

      stop_fake_http_server(server)
    end

    test "accepts group_id key (legacy)" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => %{"group_id" => "group-99"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, "group-99"} =
               QuoteHTTPContext.create_watchlist_group(
                 config_with(server.port),
                 "Tech",
                 []
               )

      stop_fake_http_server(server)
    end

    test "returns :missing_id when neither id nor group_id present" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => %{"other" => "x"}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, :missing_id} =
               QuoteHTTPContext.create_watchlist_group(
                 config_with(server.port),
                 "Tech",
                 []
               )

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 403, "message" => "forbidden", "data" => nil})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               QuoteHTTPContext.create_watchlist_group(
                 config_with(server.port),
                 "Tech",
                 []
               )

      stop_fake_http_server(server)
    end
  end

  describe "delete_watchlist_group/3" do
    test "DELETEs the group with purge flag" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "DELETE"
          assert path == "/v1/watchlist/groups"

          decoded = Jason.decode!(body)
          assert decoded["id"] == "group-1"
          assert decoded["purge"] == true

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert :ok =
               QuoteHTTPContext.delete_watchlist_group(
                 config_with(server.port),
                 "group-1",
                 true
               )

      stop_fake_http_server(server)
    end

    test "defaults purge to false" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert :ok =
               QuoteHTTPContext.delete_watchlist_group(
                 config_with(server.port),
                 "group-1"
               )

      stop_fake_http_server(server)
    end
  end

  describe "update_watchlist_group/5" do
    test "PUTs the group with mode encoded as a string" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, path, body} = parse_request(request)
          assert method == "PUT"
          assert path == "/v1/watchlist/groups"

          decoded = Jason.decode!(body)
          assert decoded["id"] == "group-1"
          assert decoded["name"] == "Tech"
          assert decoded["securities"] == ["AAPL.US"]
          assert decoded["mode"] == "add"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert :ok =
               QuoteHTTPContext.update_watchlist_group(
                 config_with(server.port),
                 "group-1",
                 "Tech",
                 ["AAPL.US"],
                 :add
               )

      stop_fake_http_server(server)
    end

    test "accepts :remove and :replace modes" do
      for mode <- [:remove, :replace] do
        server =
          start_fake_http_server(fn _request, socket ->
            :gen_tcp.send(
              socket,
              http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
            )
          end)

        assert :ok =
                 QuoteHTTPContext.update_watchlist_group(
                   config_with(server.port),
                   "group-1",
                   "Tech",
                   ["AAPL.US"],
                   mode
                 )

        stop_fake_http_server(server)
      end
    end

    test "accepts a binary mode string (passes through)" do
      server =
        start_fake_http_server(fn request, socket ->
          {_method, _path, body} = parse_request(request)
          decoded = Jason.decode!(body)
          assert decoded["mode"] == "custom-mode"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => %{}})))
        end)

      assert :ok =
               QuoteHTTPContext.update_watchlist_group(
                 config_with(server.port),
                 "group-1",
                 "Tech",
                 [],
                 "custom-mode"
               )

      stop_fake_http_server(server)
    end

    test "propagates API errors" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 403, "message" => "forbidden", "data" => nil})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:error, {:api_error, 403, "forbidden"}} =
               QuoteHTTPContext.update_watchlist_group(
                 config_with(server.port),
                 "group-1",
                 "Tech",
                 [],
                 :add
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

  describe "filings/2" do
    test "queries the filings endpoint with the symbol as a query param" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/filings"
          assert request =~ "symbol=AAPL.US"

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                items: [
                  %{
                    "id" => "filing-1",
                    "title" => "10-Q Quarterly Report",
                    "description" => "Q3 2024 quarterly report",
                    "file_name" => "aapl-10q-2024q3.pdf",
                    "file_urls" => ["https://example.com/aapl-10q.pdf"],
                    "publish_at" => 1_730_000_000
                  }
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [filing]} = QuoteHTTPContext.filings(config_with(server.port), "AAPL.US")
      assert filing["id"] == "filing-1"
      assert filing["title"] == "10-Q Quarterly Report"
      assert filing["publish_at"] == 1_730_000_000

      stop_fake_http_server(server)
    end

    test "URL-encodes symbols with special characters" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "symbol=00700.HK"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"items" => []}}))
          )
        end)

      assert {:ok, []} = QuoteHTTPContext.filings(config_with(server.port), "00700.HK")

      stop_fake_http_server(server)
    end

    test "returns an empty list when items is missing from the response" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, []} = QuoteHTTPContext.filings(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end
  end

  describe "symbol_to_counter_ids/2" do
    test "POSTs symbols and returns the result map" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "POST /v1/quote/symbol-to-counter-ids"
          assert request =~ ~s("ticker_regions":["AAPL.US","700.HK"])

          payload =
            Jason.encode!(%{
              code: 0,
              data: %{
                list: %{
                  "AAPL.US" => "ST/US/AAPL",
                  "700.HK" => "ST/HK/700"
                }
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"AAPL.US" => "ST/US/AAPL", "700.HK" => "ST/HK/700"}} =
               QuoteHTTPContext.symbol_to_counter_ids(
                 config_with(server.port),
                 ["AAPL.US", "700.HK"]
               )

      stop_fake_http_server(server)
    end

    test "returns an empty map when the response has no list field" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, %{}} =
               QuoteHTTPContext.symbol_to_counter_ids(config_with(server.port), ["AAPL.US"])

      stop_fake_http_server(server)
    end
  end
end
