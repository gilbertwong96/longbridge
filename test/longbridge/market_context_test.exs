defmodule Longbridge.MarketContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, MarketContext}

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

  describe "top_movers/2" do
    test "POSTs with default options" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, body} = parse_request(request)
          assert method == "POST"
          assert request =~ "/v1/quote/market/stock-events"

          decoded = Jason.decode!(body)
          assert decoded["markets"] == []
          assert decoded["sort"] == 0
          assert decoded["limit"] == 20

          payload =
            Jason.encode!(%{
              "code" => 0,
              "data" => %{
                "events" => [
                  %{
                    "alert_reason" => "波动超 20 日均值",
                    "alert_type" => 11,
                    "timestamp" => "1779471885",
                    "stock" => %{
                      "symbol" => "TSLA.US",
                      "change" => "0.0324",
                      "last_done" => "426.010"
                    }
                  }
                ],
                "updated_at" => 1_779_471_885
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              %{
                "events" => [
                  %{
                    "stock" => %{"symbol" => "TSLA.US"}
                  }
                ]
              }} = MarketContext.top_movers(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "accepts :markets, :sort, :date, :limit options" do
      server =
        start_fake_http_server(fn request, socket ->
          {_method, _path, body} = parse_request(request)
          decoded = Jason.decode!(body)
          assert decoded["markets"] == ["US", "HK"]
          assert decoded["sort"] == 2
          assert decoded["limit"] == 50
          assert decoded["date"] == "2024-05-01"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"events" => []}}))
          )
        end)

      assert {:ok, _} =
               MarketContext.top_movers(config_with(server.port),
                 markets: ["US", "HK"],
                 sort: :change,
                 date: "2024-05-01",
                 limit: 50
               )

      stop_fake_http_server(server)
    end
  end

  describe "rank_categories/1" do
    test "queries the categories endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/market/rank/categories"

          payload =
            Jason.encode!(%{
              "code" => 0,
              "data" => [
                %{"key" => "ib_hot_all-us", "name" => "US Hot Stocks"},
                %{"key" => "ib_hot_all-hk", "name" => "HK Hot Stocks"}
              ]
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              [
                %{"key" => "ib_hot_all-us"},
                %{"key" => "ib_hot_all-hk"}
              ]} = MarketContext.rank_categories(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "accepts a flat list response" do
      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => %{"list" => [%{"key" => "x"}]}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, [%{"key" => "x"}]} =
               MarketContext.rank_categories(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "rank_list/3" do
    test "queries with the ib_ prefix auto-added" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/market/rank/list"
          assert request =~ "key=ib_hot_all-us"
          assert request =~ "need_article=false"

          payload =
            Jason.encode!(%{
              "code" => 0,
              "data" => %{
                "bmp" => false,
                "lists" => [
                  %{"rank" => 1, "symbol" => "AAPL.US"},
                  %{"rank" => 2, "symbol" => "MSFT.US"}
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"lists" => [%{"symbol" => "AAPL.US"}, _]}} =
               MarketContext.rank_list(config_with(server.port), "hot_all-us")

      stop_fake_http_server(server)
    end

    test "does not double-add the ib_ prefix" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "key=ib_hot_all-us"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"lists" => []}}))
          )
        end)

      assert {:ok, _} =
               MarketContext.rank_list(config_with(server.port), "ib_hot_all-us")

      stop_fake_http_server(server)
    end

    test "supports need_article: true" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "need_article=true"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"lists" => []}}))
          )
        end)

      assert {:ok, _} =
               MarketContext.rank_list(config_with(server.port), "hot_all-us", need_article: true)

      stop_fake_http_server(server)
    end
  end
end
