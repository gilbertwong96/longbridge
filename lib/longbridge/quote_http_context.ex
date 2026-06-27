defmodule Longbridge.QuoteHTTPContext do
  @moduledoc """
  HTTP-backed Quote API methods.

  These endpoints are quote-related (short interest, option volume,
  pinned watchlist items) but exposed over HTTP rather than the
  WebSocket QuoteContext. They mirror the `QuoteContext` methods
  added in `longbridge/openapi` 4.0.6.

  All functions accept a `Longbridge.Config` struct and return
  `{:ok, data} | {:error, reason}` tuples.

  ## Usage

      config = Longbridge.Config.new(...)

      {:ok, positions} = Longbridge.QuoteHTTPContext.short_positions(config, "TSLA.US")
      {:ok, volume} = Longbridge.QuoteHTTPContext.option_volume(config, "AAPL230317P160000.US")
      :ok = Longbridge.QuoteHTTPContext.update_pinned(config, "group-id", "AAPL.US", true)
  """

  alias Longbridge.{Config, HTTPClient}

  @short_positions_path "/v1/quote/short-positions"
  @option_volume_path "/v1/quote/option-volume"
  @option_volume_daily_path "/v1/quote/option-volume-daily"
  @watchlist_pinned_path "/v1/quote/watchlist/pinned"
  @security_list_path "/v1/quote/get_security_list"

  @doc """
  Returns short interest data for a symbol.

  Endpoint: `GET /v1/quote/short-positions`

  For `.HK` symbols, returns HKEX short position data (daily).
  For other symbols, returns US FINRA short interest data
  (bi-monthly).

  ## Options

    * `:count` — integer 1-100, default 20.
  """
  @spec short_positions(Config.t(), String.t(), keyword()) ::
          {:ok, list() | map()} | {:error, term()}
  def short_positions(%Config{} = config, symbol, opts \\ []) do
    count = Keyword.get(opts, :count, 20)
    params = "symbol=#{symbol}&count=#{count}"

    case HTTPClient.request_json(:get, @short_positions_path, "", config, params: params) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Returns real-time call/put volume snapshot for today for an
  option symbol (e.g. `AAPL230317P160000.US`), including total
  volume, open interest, and put/call ratios.

  Endpoint: `GET /v1/quote/option-volume`
  """
  @spec option_volume(Config.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def option_volume(%Config{} = config, symbol) do
    HTTPClient.request_json(:get, @option_volume_path, "", config, params: "symbol=#{symbol}")
  end

  @doc """
  Returns daily option volume for an option symbol within a date range.

  Endpoint: `GET /v1/quote/option-volume-daily`
  """
  @spec option_volume_daily(Config.t(), String.t(), String.t(), String.t()) ::
          {:ok, list(map())} | {:error, term()}
  def option_volume_daily(%Config{} = config, symbol, start_date, end_date) do
    params = "symbol=#{symbol}&start_date=#{start_date}&end_date=#{end_date}"

    case HTTPClient.request_json(:get, @option_volume_daily_path, "", config, params: params) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Lists securities available for a given market on Longbridge.

  Endpoint: `GET /v1/quote/get_security_list`

  ## Options

    * `:market` — `"US" | "HK" | "CN" | "SG"`. Required.
    * `:category` — market subcategory. Currently only `"Overnight"`
      is documented.
    * `:page` — page number, default 1.
    * `:count` — records per page, default 50.

  Each entry has `symbol`, `name_cn`, `name_hk`, `name_en`.
  """
  @spec security_list(Config.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def security_list(%Config{} = config, opts) do
    params = HTTPClient.build_query(opts)

    case HTTPClient.request_json(:get, @security_list_path, "", config, params: params) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, %{"list" => items}} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Pins or unpins a security to the top of a watchlist group.

  Endpoint: `POST /v1/quote/watchlist/pinned`

  Pass `is_pinned: true` to pin, `false` to unpin.
  """
  @spec update_pinned(Config.t(), String.t(), String.t(), boolean()) ::
          :ok | {:error, term()}
  def update_pinned(%Config{} = config, group_id, symbol, is_pinned)
      when is_boolean(is_pinned) do
    body = Jason.encode!(%{group_id: group_id, symbol: symbol, is_pinned: is_pinned})

    case HTTPClient.request_json(:post, @watchlist_pinned_path, body, config) do
      {:ok, _response} -> :ok
      error -> error
    end
  end
end
