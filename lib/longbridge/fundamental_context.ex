defmodule Longbridge.FundamentalContext do
  @moduledoc """
  Fundamental data context.

  Provides company profile, financial reports, analyst ratings, dividends,
  valuation, shareholder data, ETF asset allocation, and macroeconomic
  indicators / data.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, profile} = Longbridge.FundamentalContext.company_profile(config, "AAPL.US")
      {:ok, reports} = Longbridge.FundamentalContext.financial_reports(config, "AAPL.US")

      # ETF asset allocation (holdings / regional / asset class / industry)
      {:ok, etf} = Longbridge.FundamentalContext.etf_asset_allocation(config, "SPY.US")

      # List macroeconomic indicators for a country
      {:ok, indicators} = Longbridge.FundamentalContext.macroeconomic_indicators(config, :united_states)

      # Historical data for a specific macroeconomic indicator
      {:ok, macro} = Longbridge.FundamentalContext.macroeconomic(config, "CPI_YOY")
  """

  alias Longbridge.{Config, HTTPClient, Symbol}

  @etf_asset_allocation_path "/v1/quote/etf-asset-allocation"
  @filings_path "/v1/quote/filings"
  @macroeconomic_indicators_path "/v2/quote/macrodata"
  @macroeconomic_path_prefix "/v2/quote/macrodata/"
  @valuation_comparison_path "/v1/quote/compare/valuation"

  @country_to_market %{
    hong_kong: "HK",
    china: "CN",
    united_states: "US",
    euro_zone: "EuroZone",
    japan: "JP",
    singapore: "SG"
  }

  @doc """
  Lists regulatory filings (e.g. SEC 10-K, 10-Q, insider trading
  forms) for a symbol.

  Endpoint: `GET /v1/quote/filings?symbol=...`

  The response includes an `items` array, each with `id`, `title`,
  `description`, `file_name`, `file_urls`, and `publish_at`
  (Unix timestamp, seconds).
  """
  @spec filings(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def filings(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      @filings_path,
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc """
  Compares valuation metrics (PE/PB/PS/market cap/close price)
  across multiple stocks. When `comparison_symbols` is `nil`, the
  server auto-selects peers from the same industry.

  Endpoint: `GET /v1/quote/compare/valuation?counter_id=...&currency=...`

  `currency` is one of `"USD"`, `"HKD"`, `"CNY"`.
  `comparison_symbols` is a list of symbols to compare against
  (omit for auto-selection).

  Added in `longbridge/openapi` 4.2.0.
  """
  @spec valuation_comparison(Config.t(), String.t(), String.t(), [String.t()] | nil, keyword()) ::
          {:ok, map()} | {:error, term()}
  def valuation_comparison(
        %Config{} = config,
        symbol,
        currency,
        comparison_symbols \\ nil,
        http_opts \\ []
      ) do
    params =
      HTTPClient.build_query(
        counter_id: Symbol.to_counter_id(symbol),
        currency: currency,
        comparison_counter_ids:
          if comparison_symbols do
            JSON.encode!(Enum.map(comparison_symbols, &Longbridge.Symbol.to_counter_id/1))
          end
      )

    HTTPClient.request_json(
      :get,
      @valuation_comparison_path,
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  @doc """
  Returns ETF asset allocation (holdings, regional, asset class,
  industry) for an ETF symbol.

  Endpoint: `GET /v1/quote/etf-asset-allocation?counter_id=...`

  The user-supplied symbol is converted to a `counter_id` via
  `Longbridge.Symbol.to_counter_id/1`.
  """
  @spec etf_asset_allocation(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def etf_asset_allocation(%Config{} = config, symbol, opts \\ []) do
    params = "counter_id=#{Symbol.to_counter_id(symbol)}"

    HTTPClient.request_json(
      :get,
      @etf_asset_allocation_path,
      "",
      config,
      Keyword.put(opts, :params, params)
    )
  end

  @doc """
  Lists macroeconomic indicators for a country.

  Endpoint: `GET /v2/quote/macrodata`

  ## Options

    * `:country` — atom: `:hong_kong | :china | :united_states |
      :euro_zone | :japan | :singapore`. Required.
    * `:keyword` — string for fuzzy name filtering. Optional.
    * `:offset` — non_neg_integer page offset. Optional.
    * `:limit` — non_neg_integer page size. Optional.

  Mirrors `MacroeconomicCountry` from
  `longbridge/openapi/rust/src/fundamental/types.rs`.
  """
  @spec macroeconomic_indicators(Config.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def macroeconomic_indicators(%Config{} = config, opts, http_opts \\ []) do
    country = Keyword.fetch!(opts, :country)
    market = Map.fetch!(@country_to_market, country)

    query =
      HTTPClient.build_query(
        market: market,
        keyword: opts[:keyword],
        offset: opts[:offset],
        limit: opts[:limit]
      )

    HTTPClient.request_json(
      :get,
      @macroeconomic_indicators_path,
      "",
      config,
      Keyword.put(http_opts, :params, query)
    )
  end

  @doc """
  Historical data for a specific macroeconomic indicator.

  Endpoint: `GET /v2/quote/macrodata/{indicator_code}`

  ## Options

    * `:indicator_code` — string from `macroeconomic_indicators/2`
      (or known external codes like `"CPI_YOY"`). Required.
    * `:start_date` — `"YYYY-MM-DD"` string. Optional.
    * `:end_date` — `"YYYY-MM-DD"` string. Optional.
    * `:offset` — non_neg_integer page offset. Optional.
    * `:limit` — non_neg_integer page size. Optional.

  The response includes `info` (indicator metadata) and `data` (a
  list of historical data points with `period`, `actual_value`,
  `previous_value`, `forecast_value`, `revised_value`, `unit`,
  `unit_prefix`, `periodicity`, `importance`, etc.).
  """
  @spec macroeconomic(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def macroeconomic(%Config{} = config, indicator_code, opts \\ [], http_opts \\ []) do
    query =
      HTTPClient.build_query(
        start_date: opts[:start_date],
        end_date: opts[:end_date],
        offset: opts[:offset],
        limit: opts[:limit]
      )

    path = @macroeconomic_path_prefix <> indicator_code

    case query do
      "" -> HTTPClient.request_json(:get, path, "", config, http_opts)
      qs -> HTTPClient.request_json(:get, path, "", config, Keyword.put(http_opts, :params, qs))
    end
  end

  @doc "Returns company profile / overview for a symbol."
  @spec company_profile(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def company_profile(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/comp-overview",
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc "Returns dividend history for a symbol."
  @spec dividends(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dividends(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/dividends",
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc "Returns valuation metrics (PE, PB, PS, etc.) for a symbol."
  @spec valuation(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def valuation(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/valuation",
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc "Returns shareholder distribution data for a symbol."
  @spec shareholders(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def shareholders(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/shareholders",
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc "Returns the latest institutional analyst rating for a symbol."
  @spec analyst_ratings(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def analyst_ratings(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      "/v1/quote/institution-rating-latest",
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc "Returns financial reports (income, balance, cash flow) for a symbol."
  @spec financial_reports(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def financial_reports(%Config{} = config, symbol, opts \\ [], http_opts \\ []) do
    params = "symbol=#{symbol}" <> query_suffix(opts)

    HTTPClient.request_json(
      :get,
      "/v1/quote/financial-reports",
      "",
      config,
      Keyword.put(http_opts, :params, params)
    )
  end

  # ── Helpers ──────────────────────────────────────────────

  defp query_suffix([]), do: ""
  defp query_suffix(kw), do: "&" <> HTTPClient.build_query(kw)
end
