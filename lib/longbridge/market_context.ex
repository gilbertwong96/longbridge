defmodule Longbridge.MarketContext do
  @moduledoc """
  Market context.

  Provides market-level data: trading status, broker holdings,
  A/H share premiums, trade statistics, and index constituents.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, status} = Longbridge.MarketContext.trading_days(config, "2024-01-01", "2024-12-31", "US")
      {:ok, constituents} = Longbridge.MarketContext.index_constituents(config, "HSI.HK")
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Returns the list of trading days between `start_date` and `end_date`
  for a given market.

  `market` is a region code: `"US"`, `"HK"`, `"CN"`, `"SG"`.
  """
  @spec trading_days(Config.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def trading_days(%Config{} = config, start_date, end_date, market) do
    params = "start_date=#{start_date}&end_date=#{end_date}&market=#{market}"
    HTTPClient.request_json(:get, "/v1/market/trading_days", "", config, params: params)
  end

  @doc """
  Returns the current trading session for a market.

  `market` is a region code: `"US"`, `"HK"`, `"CN"`, `"SG"`.
  """
  @spec market_session(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def market_session(%Config{} = config, market) do
    HTTPClient.request_json(:get, "/v1/market/session", "", config, params: "market=#{market}")
  end

  @doc """
  Lists broker holdings (HK stocks) for a symbol.
  """
  @spec broker_holdings(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def broker_holdings(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/market/broker_holdings", "", config,
      params: "symbol=#{symbol}"
    )
  end

  @doc """
  Returns A/H share premium data for a pair of symbols.
  """
  @spec ah_premium(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def ah_premium(%Config{} = config, ah_pair) do
    HTTPClient.request_json(:get, "/v1/market/ah_premium", "", config,
      params: "ah_pair=#{ah_pair}"
    )
  end

  @doc "Returns intraday trade status for a symbol."
  @spec trade_status(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def trade_status(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/market/trade_status", "", config,
      params: "symbol=#{symbol}"
    )
  end

  @doc """
  Returns the constituents of a market index.

  `index_symbol` examples: `"HSI.HK"`, `"HSCEI.HK"`, `"HSTECH.HK"`.
  """
  @spec index_constituents(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def index_constituents(%Config{} = config, index_symbol) do
    HTTPClient.request_json(:get, "/v1/market/index_constituents", "", config,
      params: "index=#{index_symbol}"
    )
  end

  @doc "Lists market anomaly alerts (trading halts, suspensions, etc.)."
  @spec anomaly_alerts(Config.t()) :: {:ok, map()} | {:error, term()}
  def anomaly_alerts(%Config{} = config) do
    HTTPClient.request_json(:get, "/v1/market/anomaly_alerts", "", config)
  end
end
