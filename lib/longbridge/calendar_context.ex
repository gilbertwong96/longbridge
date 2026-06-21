defmodule Longbridge.CalendarContext do
  @moduledoc """
  Financial calendar context.

  Provides earnings dates, dividend schedules, stock splits, IPO
  calendars, macroeconomic event dates, and market closure schedules.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, earnings} = Longbridge.CalendarContext.earnings(config, "2024-01-01", "2024-06-30", market: "US")
  """

  alias Longbridge.{Config, HTTPClient}

  @doc """
  Lists upcoming earnings dates.

  `start_date` and `end_date` are `"YYYY-MM-DD"` strings.

  ## Options

  - `:market` — `"US"`, `"HK"`, `"CN"`, `"SG"`
  - `:page` — page cursor
  - `:page_size` — results per page
  """
  @spec earnings(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def earnings(%Config{} = config, start_date, end_date, opts \\ []) do
    params = "start_date=#{start_date}&end_date=#{end_date}#{query_suffix(opts)}"
    HTTPClient.request_json(:get, "/v1/calendar/earnings", "", config, params: params)
  end

  @doc "Lists upcoming dividend dates."
  @spec dividend_dates(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dividend_dates(%Config{} = config, start_date, end_date, opts \\ []) do
    params = "start_date=#{start_date}&end_date=#{end_date}#{query_suffix(opts)}"
    HTTPClient.request_json(:get, "/v1/calendar/dividends", "", config, params: params)
  end

  @doc "Lists upcoming stock splits."
  @spec stock_splits(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stock_splits(%Config{} = config, start_date, end_date, opts \\ []) do
    params = "start_date=#{start_date}&end_date=#{end_date}#{query_suffix(opts)}"
    HTTPClient.request_json(:get, "/v1/calendar/splits", "", config, params: params)
  end

  @doc "Lists IPO calendar entries."
  @spec ipo_calendar(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ipo_calendar(%Config{} = config, start_date, end_date, opts \\ []) do
    params = "start_date=#{start_date}&end_date=#{end_date}#{query_suffix(opts)}"
    HTTPClient.request_json(:get, "/v1/calendar/ipo", "", config, params: params)
  end

  @doc """
  Lists macro economic event dates (CPI, GDP, Fed meetings, etc.).
  """
  @spec macro_events(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def macro_events(%Config{} = config, start_date, end_date, opts \\ []) do
    params = "start_date=#{start_date}&end_date=#{end_date}#{query_suffix(opts)}"
    HTTPClient.request_json(:get, "/v1/calendar/macro", "", config, params: params)
  end

  @doc "Lists market closure dates (holidays, half-days)."
  @spec market_closures(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def market_closures(%Config{} = config, opts \\ []) do
    HTTPClient.request_json(:get, "/v1/calendar/market_closures", "", config,
      params: HTTPClient.build_query(opts)
    )
  end

  # ── Helpers ──────────────────────────────────────────────

  defp query_suffix([]), do: ""
  defp query_suffix(kw), do: "&" <> HTTPClient.build_query(kw)
end
