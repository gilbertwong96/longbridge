defmodule Longbridge.MarketContext do
  @moduledoc """
  Market context.

  Provides market-level data: trading status, broker holdings,
  A/H share premiums, trade statistics, index constituents, and
  anomaly alerts.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, status} = Longbridge.MarketContext.market_session(config, "US")
      {:ok, constituents} = Longbridge.MarketContext.index_constituents(config, "HSI.HK")
  """

  alias Longbridge.{Config, HTTPClient, Symbol}

  @top_movers_path "/v1/quote/market/stock-events"
  @rank_categories_path "/v1/quote/market/rank/categories"
  @rank_list_path "/v1/quote/market/rank/list"

  @doc """
  Returns the current trading session for all markets.

  The upstream `/v1/quote/market-status` endpoint does not accept a
  `market` filter; the response includes US/HK/CN/SG entries that callers
  filter client-side.
  """
  @spec market_session(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def market_session(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/quote/market-status", "", config, opts)
  end

  @doc """
  Returns top broker holdings (buy/sell leaders) for a symbol.

  ## Options

  - `:period` — `:rct_1` (1d, default), `:rct_5`, `:rct_20`, `:rct_60`
  """
  @spec broker_holdings(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def broker_holdings(%Config{} = config, symbol, opts \\ [], http_opts \\ []) do
    period = Keyword.get(opts, :period, :rct_1)
    params = "counter_id=#{Symbol.to_counter_id(symbol)}&type=#{encode_period(period)}"

    HTTPClient.request_json(
      :get,
      "/v1/quote/broker-holding",
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  @doc """
  Lists market anomaly alerts (trading halts, suspensions, etc.).

  `market` is a region code: `"US"`, `"HK"`, `"CN"`, `"SG"`. Defaults
  to `"US"`.

  Endpoint: `GET /v1/quote/changes?market=<m>&category=0`. The
  response has `"all_off"` (true if no active alerts) and `"changes"`
  (list of `%{"symbol", "type", "title_cn" | "title_en", "update_at"}`
  entries).
  """
  @spec anomaly_alerts(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def anomaly_alerts(%Config{} = config, market \\ "US", opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/changes",
      "",
      config,
      Keyword.put(opts, :params, "market=#{market}&category=0")
    )
  end

  @doc """
  Returns the constituents of a market index.

  `index_symbol` examples: `"HSI.HK"`, `"HSCEI.HK"`, `"HSTECH.HK"`.
  """
  @spec index_constituents(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def index_constituents(%Config{} = config, index_symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/index-constituents",
      "",
      config,
      Keyword.put(opts, :params, "counter_id=#{Symbol.index_to_counter_id(index_symbol)}")
    )
  end

  @doc """
  Returns buy/sell/neutral trade statistics for a symbol.

  Endpoint: `GET /v1/quote/trades-statistics?counter_id=...`. The
  response is shaped as
  `%{"statistics" => %{"buy_ratio" => ..., "sell_ratio" => ..., ...},
      "trades" => [%{"price", "volume", "direction", "ts"}, ...]}`
  — a windowed summary plus the recent trade tape used to derive it.
  """
  @spec trade_status(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def trade_status(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/trades-statistics",
      "",
      config,
      Keyword.put(opts, :params, "counter_id=#{Symbol.to_counter_id(symbol)}")
    )
  end

  @doc """
  Returns A/H share premium K-line data for a dual-listed security.

  `symbol` must be the **H-share** counterpart, e.g. `"2318.HK"` (Ping
  An). The upstream derives the A-share pair server-side.

  ## Options

  - `:period` — `:day` (default), `:week`, `:month`, `:quarter`, `:year`
  - `:count` — number of klines (default `100`)
  """
  @spec ah_premium(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ah_premium(%Config{} = config, symbol, opts \\ [], http_opts \\ []) do
    period = Keyword.get(opts, :period, :day)
    count = Keyword.get(opts, :count, 100)

    params =
      "counter_id=#{Symbol.to_counter_id(symbol)}&line_type=#{encode_line_type(period)}&line_num=#{count}"

    HTTPClient.request_json(
      :get,
      "/v1/quote/ahpremium/klines",
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  # `trading_days` was removed upstream; the calendar endpoint
  # `Longbridge.CalendarContext.fetch/5` with `types[]=closed` is the
  # closest replacement.
  @deprecated "Use Longbridge.CalendarContext.fetch/5 with category: :closed"
  @spec trading_days(Config.t(), String.t(), String.t(), String.t()) ::
          {:error, :removed_upstream}
  def trading_days(_config, _start_date, _end_date, _market) do
    {:error, :removed_upstream}
  end

  @doc """
  Returns top market movers — stocks whose price movement exceeds
  their 20-day standard deviation, with linked news context.

  Endpoint: `POST /v1/quote/market/stock-events`

  ## Options

    * `:markets` — list of `"HK" | "US" | "CN" | "SG"`. Omit (or pass
      `[]`) for all markets.
    * `:sort` — `:hot` (default), `:time`, or `:change`.
    * `:date` — `"YYYY-MM-DD"` filter. Optional.
    * `:limit` — integer 1-100, default 20.

  Renamed from `stock_events` in longbridge/openapi 4.2.0.
  """
  @spec top_movers(Config.t(), keyword(), keyword()) :: {:ok, map()} | {:error, term()}
  def top_movers(%Config{} = config, opts \\ [], http_opts \\ []) do
    body =
      opts
      |> Map.new()
      |> Map.put_new(:markets, [])
      |> Map.put_new(:sort, 0)
      |> Map.put_new(:limit, 20)
      |> Enum.map(fn
        {:markets, list} -> {:markets, Enum.map(list, &to_string/1)}
        {:sort, atom} when is_atom(atom) -> {:sort, encode_top_movers_sort(atom)}
        other -> other
      end)
      |> Map.new()
      |> Jason.encode!()

    HTTPClient.request_json(:post, @top_movers_path, body, config, http_opts)
  end

  @doc """
  Lists rank categories for `rank_list/2`.

  Endpoint: `GET /v1/quote/market/rank/categories`

  Returns a list of categories keyed by their `ib_<key>` IDs.
  Pass the value of a category entry's `key` field to `rank_list/2`.
  """
  @spec rank_categories(Config.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def rank_categories(%Config{} = config, opts \\ []) do
    case HTTPClient.request_json(:get, @rank_categories_path, "", config, opts) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, %{"list" => items}} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Returns the ranked security list for a rank category.

  Endpoint: `GET /v1/quote/market/rank/list?key=ib_<key>`

  Pass the `key` value from one of the entries returned by
  `rank_categories/1`. The `ib_` prefix is added automatically if
  missing.

  ## Options

    * `:need_article` — boolean (default `false`). When `true`, the
      response includes article content.
  """
  @spec rank_list(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def rank_list(%Config{} = config, key, opts \\ [], http_opts \\ []) when is_binary(key) do
    need_article = Keyword.get(opts, :need_article, false)
    api_key = if String.starts_with?(key, "ib_"), do: key, else: "ib_" <> key

    params =
      "key=#{api_key}&delay_bmp=false&need_article=#{if need_article, do: "true", else: "false"}"

    HTTPClient.request_json(
      :get,
      @rank_list_path,
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  # ── Helpers ──────────────────────────────────────────────

  defp encode_period(:rct_1), do: "rct_1"
  defp encode_period(:rct_5), do: "rct_5"
  defp encode_period(:rct_20), do: "rct_20"
  defp encode_period(:rct_60), do: "rct_60"
  defp encode_period(other) when is_binary(other), do: other

  defp encode_line_type(:day), do: "day"
  defp encode_line_type(:week), do: "week"
  defp encode_line_type(:month), do: "month"
  defp encode_line_type(:quarter), do: "quarter"
  defp encode_line_type(:year), do: "year"
  defp encode_line_type(other) when is_binary(other), do: other

  defp encode_top_movers_sort(:hot), do: 0
  defp encode_top_movers_sort(:time), do: 1
  defp encode_top_movers_sort(:change), do: 2
end
