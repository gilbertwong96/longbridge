defmodule Longbridge.PortfolioContext do
  @moduledoc """
  Portfolio context.

  Provides exchange rates and portfolio P&L analysis. Current positions
  are served by `Longbridge.TradeContext.stock_positions/1` and
  `fund_positions/1`.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, rates} = Longbridge.PortfolioContext.exchange_rates(config)
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Returns current exchange rates (all currencies the server knows).

  `base_currency` is optional. The upstream returns rates for every
  supported counter-currency when omitted.
  """
  @spec exchange_rates(Config.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def exchange_rates(%Config{} = config, base_currency \\ nil) do
    params =
      if base_currency do
        "base_currency=#{base_currency}"
      else
        ""
      end

    HTTPClient.request_json(:get, "/v1/asset/exchange_rates", "", config, params: params)
  end

  @doc """
  Returns portfolio profit & loss analysis.

  ## Options

  - `:market` — `:HK`, `:US`, `:CN`, `:SG`
  """
  @spec portfolio_pl(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def portfolio_pl(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/portfolio/profit-analysis/by-market", "", config,
      params: HTTPClient.build_query(opts)
    )
  end

  @doc """
  Returns detailed profit & loss breakdown for a date range.

  ## Options

  - `:start_date` — `"YYYY-MM-DD"` (required)
  - `:end_date` — `"YYYY-MM-DD"` (required)
  - `:symbol` — filter by symbol
  """
  @spec portfolio_positions(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def portfolio_positions(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/portfolio/profit-analysis/detail", "", config,
      params: HTTPClient.build_query(opts)
    )
  end
end
