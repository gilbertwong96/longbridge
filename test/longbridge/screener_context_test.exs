defmodule Longbridge.ScreenerContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, ScreenerContext}

  alias Longbridge.TestSupport.FakeHTTPServer

  @path_strategy_recommend "/v1/quote/ai/screener/strategies/recommend"
  @path_strategy_mine "/v1/quote/ai/screener/strategies/mine"
  @path_strategy_detail "/v1/quote/ai/screener/strategy/"
  @path_strategy_search "/v1/quote/ai/screener/search"
  @path_indicators "/v1/quote/ai/screener/indicators"

  defp start_fake_http_server(handler), do: FakeHTTPServer.start_with_finch(handler)

  defp stop_fake_http_server(server), do: FakeHTTPServer.stop_with_finch(server)

  defp parse_conn(conn), do: FakeHTTPServer.parse_conn(conn)

  defp ok(conn, data), do: FakeHTTPServer.ok(conn, data)

  defp config_with(port) do
    Config.new(
      token: "test-token",
      app_key: "test-key",
      app_secret: "test-secret",
      http_url: "http://127.0.0.1:#{port}"
    )
  end

  defp body_json(conn) do
    parsed = parse_conn(conn)

    case Jason.decode(parsed.body) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end

  describe "recommend_strategies/2" do
    test "queries the recommend endpoint with the market parameter" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query == @path_strategy_recommend <> "?market=US"

          body =
            Jason.encode!(%{
              code: 0,
              data: %{
                "strategies" => [%{"id" => 1, "name" => "Top Value"}]
              }
            })

          ok(conn, body)
        end)

      assert {:ok, %{"strategies" => [%{"id" => 1, "name" => "Top Value"}]}} =
               ScreenerContext.recommend_strategies(config_with(server.port), "US")

      stop_fake_http_server(server)
    end

    test "URL-encodes the market parameter" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.path_with_query == @path_strategy_recommend <> "?market=US%2FHK"

          ok(conn, ~s({"code":0,"data":{}}))
        end)

      assert {:ok, _} =
               ScreenerContext.recommend_strategies(config_with(server.port), "US/HK")

      stop_fake_http_server(server)
    end
  end

  describe "user_strategies/2" do
    test "queries the user strategies endpoint" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query == @path_strategy_mine <> "?market=HK"

          ok(conn, ~s({"code":0,"data":{"strategies":[]}}))
        end)

      assert {:ok, %{"strategies" => []}} =
               ScreenerContext.user_strategies(config_with(server.port), "HK")

      stop_fake_http_server(server)
    end
  end

  describe "strategy/2" do
    test "queries the strategy detail endpoint by ID and strips the filter_ prefix" do
      strategy_response = %{
        "code" => 0,
        "data" => %{
          "id" => 42,
          "name" => "Low P/E",
          "filter" => %{
            "filters" => [
              %{"key" => "filter_pettm", "min" => "5", "max" => "20"},
              %{"key" => "filter_pbmrq", "min" => "", "max" => "3"}
            ]
          }
        }
      }

      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query == @path_strategy_detail <> "42"

          ok(conn, Jason.encode!(strategy_response))
        end)

      assert {:ok,
              %{
                "id" => 42,
                "filter" => %{
                  "filters" => [
                    %{"key" => "pettm", "min" => "5", "max" => "20"},
                    %{"key" => "pbmrq", "min" => "", "max" => "3"}
                  ]
                }
              }} = ScreenerContext.strategy(config_with(server.port), 42)

      stop_fake_http_server(server)
    end

    test "leaves keys without the filter_ prefix unchanged" do
      strategy_response = %{
        "code" => 0,
        "data" => %{
          "id" => 42,
          "filter" => %{"filters" => [%{"key" => "roe", "min" => "10", "max" => ""}]}
        }
      }

      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(strategy_response))
        end)

      assert {:ok, %{"filter" => %{"filters" => [%{"key" => "roe"}]}}} =
               ScreenerContext.strategy(config_with(server.port), 42)

      stop_fake_http_server(server)
    end

    test "leaves data without a filter key unchanged" do
      strategy_response = %{
        "code" => 0,
        "data" => %{"id" => 42, "name" => "No filter"}
      }

      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(strategy_response))
        end)

      assert {:ok, %{"id" => 42, "name" => "No filter"}} =
               ScreenerContext.strategy(config_with(server.port), 42)

      stop_fake_http_server(server)
    end

    test "leaves filter items without a key field unchanged" do
      strategy_response = %{
        "code" => 0,
        "data" => %{
          "id" => 42,
          "filter" => %{"filters" => [%{"min" => "5", "max" => "10"}]}
        }
      }

      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(strategy_response))
        end)

      assert {:ok, %{"filter" => %{"filters" => [%{"min" => "5", "max" => "10"}]}}} =
               ScreenerContext.strategy(config_with(server.port), 42)

      stop_fake_http_server(server)
    end
  end

  describe "search/3 (Mode A: strategy_id)" do
    test "POSTs the strategy_id without conditions or market" do
      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "POST"
          assert parsed.path_with_query == @path_strategy_search

          body =
            case Jason.decode(parsed.body) do
              {:ok, decoded} -> decoded
              _ -> %{}
            end

          assert body["strategy_id"] == 42
          assert body["page"] == 0
          assert body["size"] == 50

          ok(conn, ~s({"code":0,"data":{"items":[]}}))
        end)

      assert {:ok, %{"items" => []}} =
               ScreenerContext.search(config_with(server.port), "US",
                 strategy_id: 42,
                 page: 0,
                 size: 50
               )

      stop_fake_http_server(server)
    end
  end

  describe "search/3 (Mode B: conditions)" do
    test "builds the filter_ prefixed conditions and includes default returns" do
      server =
        start_fake_http_server(fn conn ->
          body = body_json(conn)
          assert body["market"] == "US"
          # The caller-provided key gets the filter_ prefix
          [filter | _] = body["filters"]
          assert filter["key"] == "filter_pettm"
          assert filter["min"] == "5"
          assert filter["max"] == "20"
          # Default returns are always included
          assert "filter_prevclose" in body["returns"]
          assert "filter_industry" in body["returns"]
          assert body["page"] == 0
          assert body["size"] == 50

          ok(conn, ~s({"code":0,"data":{"items":[]}}))
        end)

      assert {:ok, _} =
               ScreenerContext.search(config_with(server.port), "US",
                 conditions: [%{key: "pettm", min: "5", max: "20"}],
                 page: 0,
                 size: 50
               )

      stop_fake_http_server(server)
    end

    test "strips the filter_ prefix from items[].indicators[].key in the response" do
      response = %{
        "code" => 0,
        "data" => %{
          "items" => [
            %{
              "symbol" => "AAPL.US",
              "indicators" => [
                %{"key" => "filter_pettm", "value" => "12.5"},
                %{"key" => "filter_marketcap", "value" => "3000B"}
              ]
            }
          ]
        }
      }

      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(response))
        end)

      assert {:ok,
              %{
                "items" => [
                  %{
                    "symbol" => "AAPL.US",
                    "indicators" => [
                      %{"key" => "pettm", "value" => "12.5"},
                      %{"key" => "marketcap", "value" => "3000B"}
                    ]
                  }
                ]
              }} =
               ScreenerContext.search(config_with(server.port), "US",
                 conditions: [%{key: "pettm", min: "", max: ""}],
                 page: 0,
                 size: 10
               )

      stop_fake_http_server(server)
    end

    test "includes extra show columns in the returns list" do
      server =
        start_fake_http_server(fn conn ->
          body = body_json(conn)
          [filter | _] = body["filters"]
          assert filter["key"] == "filter_pettm"
          assert "filter_revenue_growth" in body["returns"]
          assert "filter_prevclose" in body["returns"]

          ok(conn, ~s({"code":0,"data":{"items":[]}}))
        end)

      assert {:ok, _} =
               ScreenerContext.search(config_with(server.port), "US",
                 conditions: [%{key: "pettm", min: "", max: ""}],
                 show: ["revenue_growth"],
                 page: 0,
                 size: 10
               )

      stop_fake_http_server(server)
    end

    test "uses an empty filters array when no conditions are given" do
      server =
        start_fake_http_server(fn conn ->
          body = body_json(conn)
          assert body["filters"] == []
          assert body["page"] == 0
          assert body["size"] == 10

          ok(conn, ~s({"code":0,"data":{"items":[]}}))
        end)

      assert {:ok, _} =
               ScreenerContext.search(config_with(server.port), "US",
                 page: 0,
                 size: 10
               )

      stop_fake_http_server(server)
    end

    test "leaves response without an items key unchanged" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, ~s({"code":0,"data":{"summary":"some summary"}}))
        end)

      assert {:ok, %{"summary" => "some summary"}} =
               ScreenerContext.search(config_with(server.port), "US",
                 page: 0,
                 size: 10
               )

      stop_fake_http_server(server)
    end

    test "leaves items without indicators unchanged" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, ~s({"code":0,"data":{"items":[{"symbol":"AAPL.US"}]}}))
        end)

      assert {:ok, %{"items" => [%{"symbol" => "AAPL.US"}]}} =
               ScreenerContext.search(config_with(server.port), "US",
                 page: 0,
                 size: 10
               )

      stop_fake_http_server(server)
    end
  end

  describe "indicators/1" do
    test "queries the indicators endpoint and normalizes the response" do
      response = %{
        "code" => 0,
        "data" => %{
          "groups" => [
            %{
              "name" => "Valuation",
              "indicators" => [
                %{
                  "key" => "filter_pettm",
                  "name" => "P/E (TTM)",
                  "tech_indicators" => [
                    %{
                      "tech_key" => "period",
                      "tech_items" => [
                        %{"item_value" => "day", "item_name" => "Day"},
                        %{"item_value" => "week", "item_name" => "Week"}
                      ]
                    }
                  ]
                }
              ]
            }
          ]
        }
      }

      server =
        start_fake_http_server(fn conn ->
          parsed = parse_conn(conn)
          assert parsed.method == "GET"
          assert parsed.path_with_query == @path_indicators

          ok(conn, Jason.encode!(response))
        end)

      assert {:ok,
              %{
                "groups" => [
                  %{
                    "name" => "Valuation",
                    "indicators" => [
                      %{
                        "key" => "pettm",
                        "name" => "P/E (TTM)",
                        "tech_indicators" => [
                          %{
                            "tech_key" => "period",
                            "tech_items" => [
                              %{"item_value" => "day", "item_name" => "Day"},
                              %{"item_value" => "week", "item_name" => "Week"}
                            ]
                          }
                        ],
                        "tech_values" => %{
                          "period" => [
                            %{"value" => "day", "label" => "Day"},
                            %{"value" => "week", "label" => "Week"}
                          ]
                        }
                      }
                    ]
                  }
                ]
              }} = ScreenerContext.indicators(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "leaves indicators without tech_indicators unchanged" do
      response = %{
        "code" => 0,
        "data" => %{
          "groups" => [
            %{"indicators" => [%{"key" => "filter_roe", "name" => "ROE"}]}
          ]
        }
      }

      server =
        start_fake_http_server(fn conn ->
          ok(conn, Jason.encode!(response))
        end)

      assert {:ok, %{"groups" => [%{"indicators" => [%{"key" => "roe"}]}]}} =
               ScreenerContext.indicators(config_with(server.port))

      stop_fake_http_server(server)
    end

    test "handles a response without a `groups` key" do
      server =
        start_fake_http_server(fn conn ->
          ok(conn, ~s({"code":0,"data":{}}))
        end)

      assert {:ok, %{}} =
               ScreenerContext.indicators(config_with(server.port))

      stop_fake_http_server(server)
    end
  end

  describe "ensure_filter_prefix/1" do
    test "adds the prefix when missing" do
      assert ScreenerContext.ensure_filter_prefix("pettm") == "filter_pettm"
    end

    test "does not double-add the prefix" do
      assert ScreenerContext.ensure_filter_prefix("filter_pettm") == "filter_pettm"
    end

    test "returns an empty string for non-binary input" do
      assert ScreenerContext.ensure_filter_prefix(nil) == ""
    end
  end
end
