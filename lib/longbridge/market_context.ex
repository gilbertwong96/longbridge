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

  @doc """
  Returns the current trading session for all markets.

  The upstream `/v1/quote/market-status` endpoint does not accept a
  `market` filter; the response includes US/HK/CN/SG entries that callers
  filter client-side.
  """
  @spec market_session(Config.t()) :: {:ok, map()} | {:error, term()}
  def market_session(%Config{} = config) do
    HTTPClient.request_json(:get, "/v1/quote/market-status", "", config)
  end

  @doc """
  Returns top broker holdings (buy/sell leaders) for a symbol.

  ## Options

  - `:period` — `:rct_1` (1d, default), `:rct_5`, `:rct_20`, `:rct_60`
  """
  @spec broker_holdings(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def broker_holdings(%Config{} = config, symbol, opts \\ []) do
    period = Keyword.get(opts, :period, :rct_1)
    params = "counter_id=#{Symbol.to_counter_id(symbol)}&type=#{encode_period(period)}"
    HTTPClient.request_json(:get, "/v1/quote/broker-holding", "", config, params: params)
  end

  @doc """
  Lists market anomaly alerts (trading halts, suspensions, etc.).

  `market` is a region code: `"US"`, `"HK"`, `"CN"`, `"SG"`.
  """
  @spec anomaly_alerts(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def anomaly_alerts(%Config{} = config, market \\ "US") do
    HTTPClient.request_json(:get, "/v1/quote/changes", "", config,
      params: "market=#{market}&category=0"
    )
  end

  @doc """
  Returns the constituents of a market index.

  `index_symbol` examples: `"HSI.HK"`, `"HSCEI.HK"`, `"HSTECH.HK"`.
  """
  @spec index_constituents(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def index_constituents(%Config{} = config, index_symbol) do
    HTTPClient.request_json(:get, "/v1/quote/index-constituents", "", config,
      params: "counter_id=#{Symbol.index_to_counter_id(index_symbol)}"
    )
  end

  @doc """
  Returns buy/sell/neutral trade statistics for a symbol.
  """
  @spec trade_status(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def trade_status(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/quote/trades-statistics", "", config,
      params: "counter_id=#{Symbol.to_counter_id(symbol)}"
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
  @spec ah_premium(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def ah_premium(%Config{} = config, symbol, opts \\ []) do
    period = Keyword.get(opts, :period, :day)
    count = Keyword.get(opts, :count, 100)

    params =
      "counter_id=#{Symbol.to_counter_id(symbol)}&line_type=#{encode_line_type(period)}&line_num=#{count}"

    HTTPClient.request_json(:get, "/v1/quote/ahpremium/klines", "", config, params: params)
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
end
