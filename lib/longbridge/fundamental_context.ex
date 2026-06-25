defmodule Longbridge.FundamentalContext do
  @moduledoc """
  Fundamental data context.

  Provides company profile, financial reports, analyst ratings, dividends,
  valuation, and shareholder data.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, profile} = Longbridge.FundamentalContext.company_profile(config, "AAPL.US")
      {:ok, reports} = Longbridge.FundamentalContext.financial_reports(config, "AAPL.US")
  """

  alias Longbridge.{Config, HTTPClient}

  @doc "Returns company profile / overview for a symbol."
  @spec company_profile(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def company_profile(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/quote/comp-overview", "", config,
      params: "symbol=#{symbol}"
    )
  end

  @doc "Returns dividend history for a symbol."
  @spec dividends(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def dividends(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/quote/dividends", "", config, params: "symbol=#{symbol}")
  end

  @doc "Returns valuation metrics (PE, PB, PS, etc.) for a symbol."
  @spec valuation(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def valuation(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/quote/valuation", "", config, params: "symbol=#{symbol}")
  end

  @doc "Returns shareholder distribution data for a symbol."
  @spec shareholders(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def shareholders(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/quote/shareholders", "", config,
      params: "symbol=#{symbol}"
    )
  end

  @doc "Returns the latest institutional analyst rating for a symbol."
  @spec analyst_ratings(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def analyst_ratings(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, "/v1/quote/institution-rating-latest", "", config,
      params: "symbol=#{symbol}"
    )
  end

  @doc "Returns financial reports (income, balance, cash flow) for a symbol."
  @spec financial_reports(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def financial_reports(%Config{} = config, symbol, opts \\ []) do
    params = "symbol=#{symbol}" <> query_suffix(opts)
    HTTPClient.request_json(:get, "/v1/quote/financial-reports", "", config, params: params)
  end

  # ── Helpers ──────────────────────────────────────────────

  defp query_suffix([]), do: ""
  defp query_suffix(kw), do: "&" <> HTTPClient.build_query(kw)
end
