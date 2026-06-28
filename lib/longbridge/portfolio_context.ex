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

  Trailing `http_opts` is forwarded to `HTTPClient.request_json/5`,
  so callers may override `:http_url`, `:finch`, etc. on a per-call basis.
  """
  @spec exchange_rates(Config.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def exchange_rates(%Config{} = config, base_currency \\ nil, http_opts \\ []) do
    params =
      if base_currency do
        "base_currency=#{base_currency}"
      else
        ""
      end

    HTTPClient.request_json(
      :get,
      "/v1/asset/exchange_rates",
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  @doc """
  Returns portfolio profit & loss analysis.

  ## Options

  - `:market` — `:HK`, `:US`, `:CN`, `:SG`

  HTTP-level keys such as `:http_url` and `:finch` may be passed in
  the same keyword list; they are forwarded to `HTTPClient.request_json/5`
  alongside the built query string. Function-built `:params` take
  precedence over any caller-supplied `:params`.
  """
  @spec portfolio_pl(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def portfolio_pl(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/portfolio/profit-analysis/by-market",
      "",
      config,
      Keyword.put(opts, :params, HTTPClient.build_query(market: opts[:market]))
    )
  end

  @doc """
  Returns detailed profit & loss breakdown for a date range.

  ## Options

  - `:start_date` — `"YYYY-MM-DD"` (required)
  - `:end_date` — `"YYYY-MM-DD"` (required)
  - `:symbol` — filter by symbol

  HTTP-level keys such as `:http_url` and `:finch` may be passed in
  the same keyword list; they are forwarded to `HTTPClient.request_json/5`
  alongside the built query string. Function-built `:params` take
  precedence over any caller-supplied `:params`.
  """
  @spec portfolio_positions(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def portfolio_positions(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/portfolio/profit-analysis/detail",
      "",
      config,
      Keyword.put(
        opts,
        :params,
        HTTPClient.build_query(
          start_date: opts[:start_date],
          end_date: opts[:end_date],
          symbol: opts[:symbol]
        )
      )
    )
  end
end
