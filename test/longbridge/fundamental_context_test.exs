defmodule Longbridge.FundamentalContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, FundamentalContext}

  # ── Fake HTTP server ─────────────────────────────────────

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

  describe "etf_asset_allocation/2" do
    test "converts the symbol to a counter_id and queries the endpoint" do
      response = %{
        "info" => [
          %{
            "report_date" => "20260601",
            "asset_type" => "Holdings",
            "lists" => [
              %{
                "name" => "Apple Inc",
                "code" => "AAPL",
                "position_ratio" => "0.0723",
                "counter_id" => "ST/US/AAPL",
                "name_locales_map" => %{"zh-CN" => "苹果"},
                "holding_detail" => nil
              }
            ]
          }
        ]
      }

      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, _body} = parse_request(request)
          assert method == "GET"
          assert request =~ "/v1/quote/etf-asset-allocation"
          assert request =~ "counter_id=ETF/US/SPY"

          payload = Jason.encode!(%{"code" => 0, "data" => response})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"info" => [%{"asset_type" => "Holdings"}]}} =
               FundamentalContext.etf_asset_allocation(config_with(server.port), "SPY.US")

      stop_fake_http_server(server)
    end

    test "falls back to ST/{market}/{code} for non-ETF symbols" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "counter_id=ST/US/AAPL"

          payload = Jason.encode!(%{"code" => 0, "data" => %{"info" => []}})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"info" => []}} =
               FundamentalContext.etf_asset_allocation(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end
  end

  describe "filings/2" do
    test "queries the filings endpoint with the symbol parameter" do
      response = %{
        "items" => [
          %{
            "id" => "627391979864985729",
            "title" => "Apple | (4) Statement of changes in beneficial ownership",
            "description" => "",
            "file_name" => "4 - Apple Inc. (0000320193) (Issuer)",
            "file_urls" => [
              "https://www.sec.gov/Archives/edgar/data/320193/000178052526000005/xslF345X05/wk-form4_1773786674.xml"
            ],
            "publish_at" => "1773786677"
          }
        ]
      }

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/filings"
          assert request =~ "symbol=AAPL.US"

          payload = Jason.encode!(%{"code" => 0, "data" => response})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              %{
                "items" => [
                  %{
                    "id" => "627391979864985729",
                    "title" => "Apple | (4) Statement of changes in beneficial ownership",
                    "publish_at" => "1773786677"
                  }
                ]
              }} = FundamentalContext.filings(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end

    test "URL-encodes symbols with special characters" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "symbol=BRK.B.US"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"items" => []}}))
          )
        end)

      assert {:ok, %{"items" => []}} =
               FundamentalContext.filings(config_with(server.port), "BRK.B.US")

      stop_fake_http_server(server)
    end

    test "returns an empty list when no filings exist" do
      server =
        start_fake_http_server(fn _request, socket ->
          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"items" => []}}))
          )
        end)

      assert {:ok, %{"items" => []}} =
               FundamentalContext.filings(config_with(server.port), "OBSCURE.US")

      stop_fake_http_server(server)
    end
  end

  describe "macroeconomic_indicators/2" do
    test "maps :country atoms to the upstream market strings" do
      response = %{
        "list" => [
          %{
            "indicator_code" => "CPI_YOY",
            "source_org" => "BLS",
            "country" => "United States",
            "name" => "CPI Year-over-Year",
            "adjustment_factor" => "NSA",
            "periodicity" => "monthly",
            "category" => "Inflation",
            "describe" => "Consumer Price Index year-over-year change",
            "importance" => 3
          }
        ],
        "count" => 1
      }

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "market=US"
          assert request =~ "/v2/quote/macrodata"

          payload = Jason.encode!(%{"code" => 0, "data" => response})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"list" => [%{"indicator_code" => "CPI_YOY"}], "count" => 1}} =
               FundamentalContext.macroeconomic_indicators(config_with(server.port),
                 country: :united_states
               )

      stop_fake_http_server(server)
    end

    test "maps :hong_kong to HK and :euro_zone to EuroZone" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "market=HK"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.macroeconomic_indicators(config_with(server.port),
                 country: :hong_kong
               )

      stop_fake_http_server(server)
    end

    test "maps :japan to JP, :singapore to SG" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "market=JP"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.macroeconomic_indicators(config_with(server.port),
                 country: :japan
               )

      stop_fake_http_server(server)
    end

    test "includes keyword, offset, and limit when provided" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "market=US"
          assert request =~ "keyword=CPI"
          assert request =~ "offset=20"
          assert request =~ "limit=50"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.macroeconomic_indicators(config_with(server.port),
                 country: :united_states,
                 keyword: "CPI",
                 offset: 20,
                 limit: 50
               )

      stop_fake_http_server(server)
    end

    test "omits nil optional fields" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "market=CN"
          # Only market should be present; nil keyword/offset/limit are dropped.
          refute request =~ "keyword="
          refute request =~ "offset="
          refute request =~ "limit="

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.macroeconomic_indicators(config_with(server.port),
                 country: :china
               )

      stop_fake_http_server(server)
    end

    test "raises if country is not a recognized atom" do
      assert_raise KeyError, fn ->
        FundamentalContext.macroeconomic_indicators(
          %Config{token: "t", app_key: "k", app_secret: "s"},
          country: :atlantis
        )
      end
    end
  end

  describe "valuation_comparison/4" do
    test "converts the symbol to a counter_id and queries the endpoint" do
      server =
        start_fake_http_server(fn request, socket ->
          {method, _path, _body} = parse_request(request)
          assert method == "GET"
          assert request =~ "/v1/quote/compare/valuation"
          assert request =~ "counter_id=ST%2FUS%2FAAPL"
          assert request =~ "currency=USD"

          payload =
            Jason.encode!(%{
              "code" => 0,
              "data" => %{
                "list" => [
                  %{
                    "counter_id" => "ST/US/AAPL",
                    "name" => "Apple Inc.",
                    "currency" => "USD",
                    "pe" => "32.15",
                    "pb" => "50.21"
                  }
                ]
              }
            })

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"list" => [%{"name" => "Apple Inc.", "pe" => "32.15"}]}} =
               FundamentalContext.valuation_comparison(
                 config_with(server.port),
                 "AAPL.US",
                 "USD"
               )

      stop_fake_http_server(server)
    end

    test "converts comparison_symbols to counter_ids" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "comparison_counter_ids="
          # The inner array is JSON-encoded; check the encoded counter IDs.
          assert request =~ "ST%2FUS%2FMSFT" or request =~ "ST/US/MSFT"
          assert request =~ "ST%2FUS%2FGOOGL" or request =~ "ST/US/GOOGL"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.valuation_comparison(
                 config_with(server.port),
                 "AAPL.US",
                 "USD",
                 ["MSFT.US", "GOOGL.US"]
               )

      stop_fake_http_server(server)
    end

    test "omits comparison_counter_ids when nil" do
      server =
        start_fake_http_server(fn request, socket ->
          refute request =~ "comparison_counter_ids"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"list" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.valuation_comparison(
                 config_with(server.port),
                 "AAPL.US",
                 "USD"
               )

      stop_fake_http_server(server)
    end
  end

  describe "macroeconomic/3" do
    test "URL-encodes the indicator code into the path" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v2/quote/macrodata/CPI_YOY "

          payload =
            Jason.encode!(%{"code" => 0, "data" => %{"info" => %{}, "data" => []}})

          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok, %{"info" => %{}, "data" => []}} =
               FundamentalContext.macroeconomic(config_with(server.port), "CPI_YOY")

      stop_fake_http_server(server)
    end

    test "passes start_date, end_date, offset, and limit through" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "start_date=2024-01-01"
          assert request =~ "end_date=2024-12-31"
          assert request =~ "offset=0"
          assert request =~ "limit=100"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{"data" => []}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.macroeconomic(config_with(server.port), "CPI_YOY",
                 start_date: "2024-01-01",
                 end_date: "2024-12-31",
                 offset: 0,
                 limit: 100
               )

      stop_fake_http_server(server)
    end

    test "omits nil optional fields from the query" do
      server =
        start_fake_http_server(fn request, socket ->
          # No query string at all when no options given
          assert request =~ "GET /v2/quote/macrodata/CPI_YOY HTTP"
          assert request =~ "GET /v2/quote/macrodata/CPI_YOY HTTP/1.1\r\n"

          :gen_tcp.send(
            socket,
            http_ok(Jason.encode!(%{"code" => 0, "data" => %{}}))
          )
        end)

      assert {:ok, _} =
               FundamentalContext.macroeconomic(config_with(server.port), "CPI_YOY")

      stop_fake_http_server(server)
    end

    test "decodes the full response shape" do
      response = %{
        "info" => %{
          "indicator_code" => "CPI_YOY",
          "name" => "CPI Year-over-Year",
          "importance" => 3,
          "periodicity" => "monthly"
        },
        "data" => [
          %{
            "period" => "2024-03",
            "actual_value" => "3.5",
            "previous_value" => "3.2",
            "forecast_value" => "3.4",
            "revised_value" => "3.3",
            "unit" => "%",
            "unit_prefix" => "",
            "importance" => 3,
            "periodicity" => "monthly"
          }
        ]
      }

      server =
        start_fake_http_server(fn _request, socket ->
          payload = Jason.encode!(%{"code" => 0, "data" => response})
          :gen_tcp.send(socket, http_ok(payload))
        end)

      assert {:ok,
              %{
                "info" => %{"indicator_code" => "CPI_YOY", "importance" => 3},
                "data" => [%{"actual_value" => "3.5"}]
              }} = FundamentalContext.macroeconomic(config_with(server.port), "CPI_YOY")

      stop_fake_http_server(server)
    end
  end

  describe "company_profile/2" do
    test "queries the comp-overview endpoint with the symbol" do
      response = %{"pe_ttm" => 28.5, "pb_ratio" => 47.1, "eps_ttm" => 6.2}

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/comp-overview"
          assert request =~ "symbol=AAPL.US"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} =
               FundamentalContext.company_profile(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end
  end

  describe "dividends/2" do
    test "queries the dividends endpoint with the symbol" do
      response = %{
        "dividends" => [%{"amount" => "0.24", "currency" => "USD", "date" => "2024-02-09"}]
      }

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/dividends"
          assert request =~ "symbol=AAPL.US"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} = FundamentalContext.dividends(config_with(server.port), "AAPL.US")
      stop_fake_http_server(server)
    end
  end

  describe "valuation/2" do
    test "queries the valuation endpoint with the symbol" do
      response = %{"pe_ttm" => 28.5, "pb_ratio" => 47.1}

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/valuation"
          assert request =~ "symbol=AAPL.US"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} = FundamentalContext.valuation(config_with(server.port), "AAPL.US")
      stop_fake_http_server(server)
    end
  end

  describe "shareholders/2" do
    test "queries the shareholders endpoint with the symbol" do
      response = %{"shareholders" => [%{"name" => "Vanguard", "ratio" => "0.082"}]}

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/shareholders"
          assert request =~ "symbol=AAPL.US"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} =
               FundamentalContext.shareholders(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end
  end

  describe "analyst_ratings/2" do
    test "queries the institution-rating-latest endpoint with the symbol" do
      response = %{"rating" => "Buy", "target_price" => "200.0"}

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/institution-rating-latest"
          assert request =~ "symbol=AAPL.US"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} =
               FundamentalContext.analyst_ratings(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end
  end

  describe "financial_reports/3" do
    test "queries the financial-reports endpoint with the symbol" do
      response = %{"income_statement" => [%{"period" => "2023-Q4", "revenue" => "119.6B"}]}

      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/financial-reports"
          assert request =~ "symbol=AAPL.US"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => response})))
        end)

      assert {:ok, ^response} =
               FundamentalContext.financial_reports(config_with(server.port), "AAPL.US")

      stop_fake_http_server(server)
    end

    test "forwards opts as query string parameters" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/financial-reports"
          assert request =~ "symbol=AAPL.US"
          assert request =~ "rpt_type=income_statement"

          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => %{}})))
        end)

      assert {:ok, _} =
               FundamentalContext.financial_reports(config_with(server.port), "AAPL.US",
                 rpt_type: "income_statement"
               )

      stop_fake_http_server(server)
    end
  end

  describe "http_url per-call override" do
    test "company_profile/3 hits the URL passed in opts" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/comp-overview"
          assert request =~ "symbol=AAPL.US"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => %{}})))
        end)

      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s",
          http_url: "http://127.0.0.1:1"
        )

      assert {:ok, _} =
               FundamentalContext.company_profile(config, "AAPL.US",
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end

    test "financial_reports/4 preserves :params while forwarding :http_url override" do
      server =
        start_fake_http_server(fn request, socket ->
          assert request =~ "GET /v1/quote/financial-reports"
          assert request =~ "symbol=AAPL.US"
          assert request =~ "rpt_type=income_statement"
          :gen_tcp.send(socket, http_ok(Jason.encode!(%{"code" => 0, "data" => %{}})))
        end)

      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s",
          http_url: "http://127.0.0.1:1"
        )

      assert {:ok, _} =
               FundamentalContext.financial_reports(
                 config,
                 "AAPL.US",
                 [rpt_type: "income_statement"],
                 http_url: "http://127.0.0.1:#{server.port}"
               )

      stop_fake_http_server(server)
    end
  end
end
