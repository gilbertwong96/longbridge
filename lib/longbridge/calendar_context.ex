defmodule Longbridge.CalendarContext do
  @moduledoc """
  Financial calendar context.

  Provides earnings, dividends, splits, IPOs, macroeconomic events and
  market closures, all served from the upstream
  `GET /v1/quote/finance_calendar` endpoint.

  The endpoint is paginated: when the response carries a non-empty
  `next_date`, pass it as `start_date` to fetch the next page.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, earnings} =
        Longbridge.CalendarContext.earnings(config, "2024-01-01", "2024-06-30", market: "US")
  """

  alias Longbridge.{Config, HTTPClient}

  @finance_calendar_path "/v1/quote/finance_calendar"

  # Category slugs the upstream accepts in the `types[]` query parameter.
  @category_earnings "report"
  @category_dividend "dividend"
  @category_split "split"
  @category_ipo "ipo"
  @category_macro "macrodata"
  @category_closed "closed"

  @doc """
  Lists earnings announcement dates.

  `start_date` and `end_date` are `"YYYY-MM-DD"` strings.

  ## Options

  - `:market` — `"US"`, `"HK"`, `"CN"`, `"SG"`
  """
  @spec earnings(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def earnings(%Config{} = config, start_date, end_date, opts \\ []) do
    fetch(config, @category_earnings, start_date, end_date, opts)
  end

  @doc "Lists upcoming dividend dates."
  @spec dividend_dates(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def dividend_dates(%Config{} = config, start_date, end_date, opts \\ []) do
    fetch(config, @category_dividend, start_date, end_date, opts)
  end

  @doc "Lists upcoming stock splits."
  @spec stock_splits(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def stock_splits(%Config{} = config, start_date, end_date, opts \\ []) do
    fetch(config, @category_split, start_date, end_date, opts)
  end

  @doc "Lists IPO calendar entries."
  @spec ipo_calendar(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def ipo_calendar(%Config{} = config, start_date, end_date, opts \\ []) do
    fetch(config, @category_ipo, start_date, end_date, opts)
  end

  @doc """
  Lists macroeconomic event dates (CPI, GDP, Fed meetings, etc.).
  """
  @spec macro_events(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def macro_events(%Config{} = config, start_date, end_date, opts \\ []) do
    fetch(config, @category_macro, start_date, end_date, opts)
  end

  @doc """
  Lists market closure dates (holidays, half-days).

  The upstream calendar endpoint does not accept a date range for closures;
  pass `market` to scope by region.
  """
  @spec market_closures(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def market_closures(%Config{} = config, opts \\ []) do
    today = Date.to_iso8601(Date.utc_today())
    fetch(config, @category_closed, today, today, opts)
  end

  # ── Helpers ──────────────────────────────────────────────

  defp fetch(config, category, start_date, end_date, opts) do
    market = Keyword.get(opts, :market)

    params =
      [
        date: start_date,
        date_end: end_date,
        types: category
      ]
      |> maybe_put(:markets, market)
      |> URI.encode_query()

    HTTPClient.request_json(:get, @finance_calendar_path, "", config, params: params)
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)
end
