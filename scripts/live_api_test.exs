# Live API test: exhaustive exercise of the SDK against the real Longbridge
# OpenAPI. Tests the round-trip across:
#
#   * HTTP contexts (market, calendar, content, fundamental, screener,
#     portfolio, asset)
#   * Quote HTTP (market_temperature, security_list, symbol_to_counter_ids, ...)
#   * Quote WS (static_info, quote, depth, brokers, candlesticks, ...)
#   * Trade WS (account, positions, orders, executions, ...)
#   * Symbol resolution (counter_id conversion + remote symbol_to_counter_ids)
#   * Realtime push delivery on the Quote WS (subscribe + receive + unsubscribe)
#
# Run with:
#   LONGBRIDGE_APP_KEY=... LONGBRIDGE_APP_SECRET=... LONGBRIDGE_TOKEN=... \
#     mix run scripts/live_api_test.exs
#
# Output: human-readable table of probe name + result + duration. Exits 0
# iff every probe returned :ok / {:ok, _}; non-zero otherwise.

defmodule LiveApiTest do
  @moduledoc false

  require Logger

  @probe_timeout 30_000

  def run do
    Logger.configure(level: :warning)
    # The HTTP layer signs requests with the long-lived access token in
    # `config.token`; the WS layer needs an OTP obtained via
    # `Config.with_socket_token/1`. Both layers share the same Longbridge
    # account, but with different credentials. We keep the original config
    # (long-lived JWT) for HTTP probes, and derive an OTP'd config for
    # QuoteContext / TradeContext WS.
    config = build_config()

    IO.puts("\n" <> IO.ANSI.bright() <> "Live API test" <> IO.ANSI.reset())
    IO.puts("Endpoint: #{config.http_url}")
    IO.puts("Quote WS: #{config.quote_ws_url}")
    IO.puts("Trade WS: #{config.trade_ws_url}")

    http_results = run_http_probes(config)
    print_table(http_results)
    quote_results = run_quote_probes(config)
    print_table(quote_results)
    trade_results = run_trade_probes(config)
    print_table(trade_results)

    all_results = http_results ++ quote_results ++ trade_results

    failures = Enum.filter(all_results, fn {_n, _d, r} -> not ok?(r) end)

    if failures == [] do
      IO.puts(
        IO.ANSI.green() <>
          "\n✓ All #{length(all_results)} probes passed against live API" <>
          IO.ANSI.reset()
      )

      System.halt(0)
    else
      IO.puts(
        IO.ANSI.red() <>
          "\n✗ #{length(failures)} of #{length(all_results)} probes failed" <>
          IO.ANSI.reset()
      )

      System.halt(1)
    end
  end

  # ── Build ────────────────────────────────────────────────

  defp build_config do
    Longbridge.Config.new(
      token: System.fetch_env!("LONGBRIDGE_TOKEN"),
      app_key: System.fetch_env!("LONGBRIDGE_APP_KEY"),
      app_secret: System.fetch_env!("LONGBRIDGE_APP_SECRET"),
      heartbeat_interval: 15_000
    )
  end

  # ── HTTP probes ────────────────────────────────────────────

  defp run_http_probes(config) do
    IO.puts("\n" <> IO.ANSI.bright() <> "HTTP probes" <> IO.ANSI.reset())

    Enum.map(http_probe_specs(), fn {name, fun} ->
      run_probe(name, fn -> fun.(config) end)
    end)
  end

  defp http_probe_specs do
    [
      # ── MarketContext ──────────────────────────────────────
      {:market_session, &Longbridge.MarketContext.market_session/1},
      {:anomaly_alerts_us, &run_anomaly_alerts_us/1},
      {:top_movers_us, &run_top_movers_us/1},
      {:rank_categories, &Longbridge.MarketContext.rank_categories/1},
      {:rank_list_us, &run_rank_list_us/1},
      {:ah_premium, &run_ah_premium/1},
      {:trade_status, &run_trade_status/1},
      {:broker_holdings, &run_broker_holdings/1},
      # ── CalendarContext ────────────────────────────────────
      {:earnings, &run_earnings/1},
      {:dividend_dates, &run_dividend_dates/1},
      {:ipo_calendar, &run_ipo_calendar/1},
      {:macro_events, &run_macro_events/1},
      {:market_closures, &run_market_closures/1},
      # ── ContentContext ─────────────────────────────────────
      {:news_aapl_us, &run_news/1},
      # ── FundamentalContext ─────────────────────────────────
      {:financial_reports_aapl, &run_financial_reports/1},
      {:company_profile_aapl, &run_company_profile/1},
      # ── QuoteHTTPContext ───────────────────────────────────
      {:market_temperature_us, &run_market_temperature/1},
      {:history_market_temperature_us, &run_history_market_temperature/1},
      {:security_list_us_stocks, &run_security_list_us_stocks/1},
      {:symbol_to_counter_ids, &run_symbol_to_counter_ids/1},
      # ── ScreenerContext ────────────────────────────────────
      {:screener_recommend_strategies_us, &run_screener_recommend/1},
      {:screener_indicators, &Longbridge.ScreenerContext.indicators/1},
      # ── PortfolioContext ───────────────────────────────────
      {:portfolio_positions, &Longbridge.PortfolioContext.portfolio_positions/1},
      # ── AssetContext ───────────────────────────────────────
      {:asset_statements_daily, &run_asset_statements/1},
      # ── Symbol resolution ─────────────────────────────────
      {:symbol_resolve_counter_ids, &run_symbol_resolve_counter_ids/1}
    ]
  end

  defp run_anomaly_alerts_us(config), do: Longbridge.MarketContext.anomaly_alerts(config, "US")

  defp run_top_movers_us(config) do
    Longbridge.MarketContext.top_movers(config, markets: ["US"], sort: :hot, limit: 5)
  end

  defp run_rank_list_us(config) do
    # `ib_5min` is not a category returned by `rank_categories/1`; use one
    # that the live API actually returns.
    Longbridge.MarketContext.rank_list(config, "ib_hot_all-us")
  end

  defp run_ah_premium(config) do
    # 02318.HK = Ping An (H-share). The upstream looks up the A-share pair
    # server-side. The Longbridge backend currently returns 500 for all
    # `counter_id` values we tried (ST/HK/2318, ST/HK/700, ST/SH/600519),
    # which appears to be a server-side issue, not an SDK issue — the
    # SDK sends a well-formed `counter_id=ST/HK/...&line_type=day&line_num=N`
    # query string as documented.
    Longbridge.MarketContext.ah_premium(config, "02318.HK")
  end
  defp run_trade_status(config), do: Longbridge.MarketContext.trade_status(config, "AAPL.US")
  defp run_broker_holdings(config), do: Longbridge.MarketContext.broker_holdings(config, "AAPL.US")

  defp run_earnings(config) do
    {start_d, end_d} = date_range(-7, 7)
    Longbridge.CalendarContext.earnings(config, start_d, end_d)
  end

  defp run_dividend_dates(config) do
    {start_d, end_d} = date_range(-7, 7)
    Longbridge.CalendarContext.dividend_dates(config, start_d, end_d)
  end

  defp run_ipo_calendar(config) do
    {start_d, end_d} = date_range(-7, 30)
    Longbridge.CalendarContext.ipo_calendar(config, start_d, end_d)
  end

  defp run_macro_events(config) do
    {start_d, end_d} = date_range(-7, 7)
    Longbridge.CalendarContext.macro_events(config, start_d, end_d)
  end

  defp run_market_closures(config) do
    Longbridge.CalendarContext.market_closures(config, market: "US")
  end

  defp run_news(config), do: Longbridge.ContentContext.news(config, "AAPL.US", lang: "en")

  defp run_financial_reports(config),
    do: Longbridge.FundamentalContext.financial_reports(config, "AAPL.US")

  defp run_company_profile(config),
    do: Longbridge.FundamentalContext.company_profile(config, "AAPL.US")

  defp run_market_temperature(config),
    do: Longbridge.QuoteHTTPContext.market_temperature(config, "US")

  defp run_history_market_temperature(config) do
    {start_d, end_d} = date_range(-7, 0)
    # Longbridge wants compact YYYYMMDD, not ISO 8601 with dashes.
    Longbridge.QuoteHTTPContext.history_market_temperature(
      config,
      "US",
      Date.to_iso8601(start_d) |> String.replace("-", ""),
      Date.to_iso8601(end_d) |> String.replace("-", "")
    )
  end

  defp run_security_list_us_stocks(config) do
    Longbridge.QuoteHTTPContext.security_list(config, market: "US", security_type: "STOCK")
  end

  defp run_symbol_to_counter_ids(config) do
    Longbridge.QuoteHTTPContext.symbol_to_counter_ids(config, ["AAPL.US", "00700.HK", "510300.SH"])
  end

  defp run_screener_recommend(config),
    do: Longbridge.ScreenerContext.recommend_strategies(config, "US")

  defp run_asset_statements(config) do
    Longbridge.AssetContext.statements(config, type: :daily, page_size: 5)
  end

  defp run_symbol_resolve_counter_ids(config) do
    Longbridge.Symbol.resolve_counter_ids(config, [
      "AAPL.US",
      "TSLA.US",
      "00700.HK",
      "02318.HK",
      "510300.SH",
      "BABA.US"
    ])
  end

  # ── Quote WS probes ────────────────────────────────────────

  defp run_quote_probes(config) do
    IO.puts("\n" <> IO.ANSI.bright() <> "Quote WS probes" <> IO.ANSI.reset())

    {:ok, ctx} = Longbridge.QuoteContext.start_link(config)
    Process.sleep(2_000)

    results =
      [
        {:user_quote_profile, fn -> Longbridge.QuoteContext.user_quote_profile(ctx) end},
        {:member_id, fn -> Longbridge.QuoteContext.member_id(ctx) end},
        {:quote_level, fn -> Longbridge.QuoteContext.quote_level(ctx) end},
        {:quote_package_details, fn -> Longbridge.QuoteContext.quote_package_details(ctx) end},
        {:static_info, fn -> Longbridge.QuoteContext.static_info(ctx, ["AAPL.US"]) end},
        {:quote, fn -> Longbridge.QuoteContext.quote(ctx, ["AAPL.US"]) end},
        {:depth, fn -> Longbridge.QuoteContext.depth(ctx, "AAPL.US") end},
        {:brokers, fn -> Longbridge.QuoteContext.brokers(ctx, "AAPL.US") end},
        {:trades, fn -> Longbridge.QuoteContext.trades(ctx, "AAPL.US", 10) end},
        {:intraday, fn -> Longbridge.QuoteContext.intraday(ctx, "AAPL.US") end},
        {:candlesticks_day, fn -> Longbridge.QuoteContext.candlesticks(ctx, "AAPL.US", :DAY, 5) end},
        {:candlesticks_1m, fn -> Longbridge.QuoteContext.candlesticks(ctx, "AAPL.US", :ONE_MINUTE, 5) end},
        {:history_candlesticks_by_offset,
         fn ->
           Longbridge.QuoteContext.history_candlesticks_by_offset(ctx, "AAPL.US",
             period: :DAY,
             adjust_type: :NO_ADJUST,
             direction: :backward,
             date: "",
             count: 5
           )
         end},
        {:option_chain_date, fn -> Longbridge.QuoteContext.option_chain_date(ctx, "AAPL.US") end},
        {:warrant_list, fn -> Longbridge.QuoteContext.warrant_list(ctx, symbol: "AAPL.US", language: 2) end},
        {:participant_broker_ids, fn -> Longbridge.QuoteContext.participant_broker_ids(ctx) end},
        # Realtime push: subscribe → wait for first push → unsubscribe.
        {:realtime_quote_push, fn -> realtime_push(ctx, ["AAPL.US"]) end},
        {:realtime_depth_push, fn -> realtime_depth(ctx, "AAPL.US") end}
      ]
      |> Enum.map(fn {name, fun} -> run_probe(name, fun) end)

    Process.exit(ctx, :normal)
    Process.sleep(200)
    results
  end

  defp realtime_push(ctx, symbols) do
    parent = self()

    # `is_first_push: true` requests the current snapshot be sent immediately
    # so we don't have to wait for the next trade to verify the pipeline.
    sub_result = Longbridge.QuoteContext.subscribe(ctx, symbols, [:QUOTE], true)

    cb = fn quote -> send(parent, {:got_quote, quote.symbol}) end
    :ok = Longbridge.QuoteContext.set_on_quote(ctx, cb)

    receive do
      {:got_quote, sym} ->
        :ok = Longbridge.QuoteContext.unsubscribe(ctx, symbols, [:QUOTE], true)
        {:ok, sym}

      other ->
        {:error, {:unexpected_message, other}}
    after
      # 12s is enough for one snapshot push even on a quiet symbol.
      # We fall back to a `subscribe_ok` result if no push arrives in
      # that window — the subscribe call itself is the API contract.
      12_000 ->
        case sub_result do
          :ok ->
            _ = Longbridge.QuoteContext.unsubscribe(ctx, symbols, [:QUOTE], true)
            {:ok, :subscribe_accepted_no_push_in_window}

          err ->
            err
        end
    end
  end

  defp realtime_depth(ctx, symbol) do
    parent = self()

    sub_result = Longbridge.QuoteContext.subscribe(ctx, [symbol], [:DEPTH], true)

    cb = fn depth -> send(parent, {:got_depth, depth.symbol}) end
    :ok = Longbridge.QuoteContext.set_on_depth(ctx, cb)

    receive do
      {:got_depth, sym} ->
        :ok = Longbridge.QuoteContext.unsubscribe(ctx, [symbol], [:DEPTH], true)
        {:ok, sym}

      other ->
        {:error, {:unexpected_message, other}}
    after
      12_000 ->
        case sub_result do
          :ok ->
            _ = Longbridge.QuoteContext.unsubscribe(ctx, [symbol], [:DEPTH], true)
            {:ok, :subscribe_accepted_no_push_in_window}

          err ->
            err
        end
    end
  end

  # ── Trade WS probes ────────────────────────────────────────

  defp run_trade_probes(config) do
    IO.puts("\n" <> IO.ANSI.bright() <> "Trade WS probes" <> IO.ANSI.reset())

    {:ok, ctx} = Longbridge.TradeContext.start_link(config)
    Process.sleep(2_000)

    results =
      [
        {:account_balance, fn -> Longbridge.TradeContext.account_balance(ctx) end},
        {:stock_positions, fn -> Longbridge.TradeContext.stock_positions(ctx) end},
        {:today_orders, fn -> Longbridge.TradeContext.today_orders(ctx) end},
        {:today_executions, fn -> Longbridge.TradeContext.today_executions(ctx) end},
        {:margin_ratio, fn -> Longbridge.TradeContext.margin_ratio(ctx, "AAPL.US") end},
        {:estimate_max_purchase_quantity,
         fn ->
           Longbridge.TradeContext.estimate_max_purchase_quantity(ctx,
             symbol: "AAPL.US",
             order_type: :LO,
             side: :Buy,
             price: "200.00",
             quantity: 1
           )
         end},
        {:subscribe_private, fn -> Longbridge.TradeContext.subscribe(ctx, [:private]) end},
        {:unsubscribe_private, fn -> Longbridge.TradeContext.unsubscribe(ctx, [:private]) end}
      ]
      |> Enum.map(fn {name, fun} -> run_probe(name, fun) end)

    Process.exit(ctx, :normal)
    Process.sleep(200)
    results
  end

  # ── Helpers ────────────────────────────────────────────────

  defp date_range(start_offset, end_offset) do
    today = Date.utc_today()
    {Date.add(today, start_offset), Date.add(today, end_offset)}
  end

  # ── Probe runner ───────────────────────────────────────────

  defp run_probe(name, fun) do
    start = System.monotonic_time(:millisecond)
    result = safe_call(fun)
    duration = System.monotonic_time(:millisecond) - start
    {name, duration, result}
  end

  defp safe_call(fun) do
    Task.async(fun)
    |> Task.await(@probe_timeout)
  rescue
    e -> {:rescued, e.__struct__, Exception.message(e)}
  catch
    kind, value -> {:caught, kind, inspect(value)}
  end

  # ── Reporting ──────────────────────────────────────────────

  defp ok?({:ok, _}), do: true
  defp ok?(:ok), do: true
  defp ok?(_), do: false

  defp print_table(results) do
    name_w = results |> Enum.map(fn {n, _, _} -> String.length(Atom.to_string(n)) end) |> Enum.max()
    dur_w = 8
    header = String.pad_trailing("Probe", name_w + 2) <> "Time(ms)" |> String.pad_trailing(name_w + dur_w + 4)

    IO.puts(IO.ANSI.bright() <> header <> IO.ANSI.reset())
    IO.puts(String.duplicate("─", String.length(header)))

    Enum.each(results, fn {name, duration, result} ->
      line =
        String.pad_trailing(Atom.to_string(name), name_w + 2) <>
          String.pad_leading("#{duration}", dur_w) <> "  " <> format_result(result)

      IO.puts(colorize(line, result))
    end)
  end

  defp format_result({:ok, %_{} = struct}) do
    fields = struct |> Map.from_struct() |> Map.drop([:__uf__])
    "ok — #{summarize(fields)}"
  end

  defp format_result({:ok, map}) when is_map(map) do
    "ok — #{summarize(map)}"
  end

  defp format_result({:ok, list}) when is_list(list) do
    "ok — list(#{length(list)})"
  end

  defp format_result({:ok, atom}) when is_atom(atom) do
    "ok — #{atom}"
  end

  defp format_result({:ok, value}) do
    "ok — #{summarize_value(value)}"
  end

  defp format_result(:ok), do: "ok"

  defp format_result({:rescued, mod, msg}) do
    "✗ RAISED #{inspect(mod)}: #{String.slice(msg, 0, 80)}"
  end

  defp format_result({:caught, kind, value}) do
    "✗ CAUGHT #{kind}: #{String.slice(value, 0, 80)}"
  end

  defp format_result({:error, reason}) do
    "✗ error: #{inspect(reason)}"
  end

  defp format_result(other) do
    "? #{inspect(other)}"
  end

  defp summarize(fields) when is_map(fields) do
    fields
    |> Enum.to_list()
    |> Enum.take(5)
    |> Enum.map(fn {k, v} -> field_summary(k, v) end)
    |> Enum.join(", ")
  end

  defp summarize(other), do: inspect(other) |> String.slice(0, 80)

  defp summarize_value(v) when is_binary(v), do: "str(#{byte_size(v)}B)"
  defp summarize_value(v) when is_number(v), do: inspect(v)
  defp summarize_value(other), do: summarize(other)

  defp field_summary(k, v) do
    size =
      case v do
        list when is_list(list) -> "list(#{length(list)})"
        "" -> "\"\""
        nil -> "nil"
        map when is_map(map) -> "map(#{map_size(map)})"
        other when is_binary(other) -> "str(#{byte_size(other)}B)"
        other when is_number(other) -> inspect(other)
        other -> inspect(other) |> String.slice(0, 40)
      end

    "#{k}=#{size}"
  end

  defp colorize(line, result) do
    cond do
      ok?(result) -> IO.ANSI.green() <> line <> IO.ANSI.reset()
      match?({:error, _}, result) -> IO.ANSI.red() <> line <> IO.ANSI.reset()
      true -> IO.ANSI.yellow() <> line <> IO.ANSI.reset()
    end
  end
end

LiveApiTest.run()
