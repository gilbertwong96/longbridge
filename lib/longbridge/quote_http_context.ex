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
  @option_volume_path "/v1/quote/option-volume-stats"
  @option_volume_daily_path "/v1/quote/option-volume-stats/daily"
  @watchlist_pinned_path "/v1/quote/watchlist/pinned"
  @security_list_path "/v1/quote/get_security_list"
  @market_temperature_path "/v1/quote/market_temperature"
  @history_market_temperature_path "/v1/quote/history_market_temperature"
  @short_trades_path "/v1/quote/short-trades"
  @watchlist_groups_path "/v1/watchlist/groups"
  @filings_path "/v1/quote/filings"
  @symbol_to_counter_ids_path "/v1/quote/symbol-to-counter-ids"

  @doc """
  Returns short interest data for a symbol.

  Endpoint: `GET /v1/quote/short-positions`

  For `.HK` symbols, returns HKEX short position data (daily).
  For other symbols, returns US FINRA short interest data
  (bi-monthly).

  ## Options

    * `:count` — integer 1-100, default 20.
  """
  @spec short_positions(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, list() | map()} | {:error, term()}
  def short_positions(%Config{} = config, symbol, opts \\ [], http_opts \\ []) do
    count = Keyword.get(opts, :count, 20)
    params = "symbol=#{symbol}&count=#{count}"

    case HTTPClient.request_json(
           :get,
           @short_positions_path,
           "",
           config,
           Keyword.put(http_opts, :params, params)
         ) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Returns real-time call/put volume snapshot for today for an
  option symbol (e.g. `AAPL230317P160000.US`).

  Endpoint: `GET /v1/quote/option-volume-stats`

  Returns a map with `"c"` (call volume, decimal string) and
  `"p"` (put volume, decimal string) keys. Mirrors
  `OptionVolumeStats` from `longbridge/openapi-go`.
  """
  @spec option_volume(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def option_volume(%Config{} = config, symbol, opts \\ []) do
    HTTPClient.request_json(
      :get,
      @option_volume_path,
      "",
      config,
      Keyword.put(opts, :params, "symbol=#{symbol}")
    )
  end

  @doc """
  Returns daily option volume for an option symbol within a date
  range (inclusive `YYYY-MM-DD`).

  Endpoint: `GET /v1/quote/option-volume-stats/daily`

  Returns a list of maps with `total_volume`, `total_put_volume`,
  `total_call_volume`, `put_call_volume_ratio`, and open
  interest fields. Mirrors `DailyOptionVolume` from
  `longbridge/openapi-go`.
  """
  @spec option_volume_daily(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def option_volume_daily(%Config{} = config, symbol, start_date, end_date, opts \\ []) do
    params = "symbol=#{symbol}&start=#{start_date}&end=#{end_date}"

    case HTTPClient.request_json(
           :get,
           @option_volume_daily_path,
           "",
           config,
           Keyword.put(opts, :params, params)
         ) do
      {:ok, %{"stats" => items}} when is_list(items) -> {:ok, items}
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
  @spec security_list(Config.t(), keyword(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def security_list(%Config{} = config, opts \\ [], http_opts \\ []) do
    params = HTTPClient.build_query(opts)

    case HTTPClient.request_json(
           :get,
           @security_list_path,
           "",
           config,
           Keyword.put(http_opts, :params, params)
         ) do
      {:ok, items} when is_list(items) -> {:ok, items}
      {:ok, %{"list" => items}} when is_list(items) -> {:ok, items}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Lists the current user's watchlist groups.

  Endpoint: `GET /v1/watchlist/groups`
  """
  @spec watchlist_groups(Config.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def watchlist_groups(%Config{} = config, opts \\ []) do
    case HTTPClient.request_json(:get, @watchlist_groups_path, "", config, opts) do
      {:ok, %{"groups" => groups}} when is_list(groups) -> {:ok, groups}
      {:ok, groups} when is_list(groups) -> {:ok, groups}
      {:ok, _} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Creates a new watchlist group with the given name and seed symbols.

  Endpoint: `POST /v1/watchlist/groups`

  Returns `{:ok, group_id}` where `group_id` is the new group id.
  """
  @spec create_watchlist_group(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_watchlist_group(%Config{} = config, name, securities, opts \\ []) do
    body = Jason.encode!(%{name: name, securities: securities})

    case HTTPClient.request_json(:post, @watchlist_groups_path, body, config, opts) do
      {:ok, %{"id" => id}} when is_binary(id) -> {:ok, id}
      {:ok, %{"id" => id}} when is_integer(id) -> {:ok, Integer.to_string(id)}
      {:ok, %{"id" => id}} -> {:ok, to_string(id)}
      {:ok, %{"group_id" => id}} -> {:ok, to_string(id)}
      {:ok, _} -> {:error, :missing_id}
      error -> error
    end
  end

  @doc """
  Deletes a watchlist group by id.

  Endpoint: `DELETE /v1/watchlist/groups`

  `purge: true` removes the symbols from all other watchlist
  groups; `purge: false` only deletes the group, leaving symbols
  in other groups intact.
  """
  @spec delete_watchlist_group(Config.t(), String.t(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def delete_watchlist_group(%Config{} = config, group_id, purge \\ false, opts \\ [])
      when is_boolean(purge) do
    body = Jason.encode!(%{id: group_id, purge: purge})

    case HTTPClient.request_json(:delete, @watchlist_groups_path, body, config, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  @doc """
  Updates a watchlist group.

  Endpoint: `PUT /v1/watchlist/groups`

  `mode` is one of:
    * `:add` — append `securities` to the group (preserving existing entries).
    * `:remove` — remove `securities` from the group.
    * `:replace` — replace the group's full symbol list.
  """
  @spec update_watchlist_group(
          Config.t(),
          String.t(),
          String.t(),
          [String.t()],
          atom(),
          keyword()
        ) ::
          :ok | {:error, term()}
  def update_watchlist_group(%Config{} = config, group_id, name, securities, mode, opts \\ []) do
    body =
      Jason.encode!(%{
        id: group_id,
        name: name,
        securities: securities,
        mode: encode_watchlist_mode(mode)
      })

    case HTTPClient.request_json(:put, @watchlist_groups_path, body, config, opts) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp encode_watchlist_mode(:add), do: "add"
  defp encode_watchlist_mode(:remove), do: "remove"
  defp encode_watchlist_mode(:replace), do: "replace"
  defp encode_watchlist_mode(other) when is_binary(other), do: other

  @doc """
  Returns the current market temperature for a market.

  Endpoint: `GET /v1/quote/market_temperature`

  `market` is one of `"US" | "HK" | "CN" | "SG"`.

  The response includes a numeric `temperature` (0-100, where
  higher = greedier market) and a sentiment label.
  """
  @spec market_temperature(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def market_temperature(%Config{} = config, market, opts \\ []) do
    HTTPClient.request_json(
      :get,
      @market_temperature_path,
      "",
      config,
      Keyword.put(opts, :params, "market=#{market}")
    )
  end

  @doc """
  Returns historical market temperature for a market within
  a date range.

  Endpoint: `GET /v1/quote/history_market_temperature`

  `start_date` and `end_date` are `"YYYY-MM-DD"` strings.
  """
  @spec history_market_temperature(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def history_market_temperature(%Config{} = config, market, start_date, end_date, opts \\ []) do
    params = "market=#{market}&start_date=#{start_date}&end_date=#{end_date}"

    HTTPClient.request_json(
      :get,
      @history_market_temperature_path,
      "",
      config,
      Keyword.put(opts, :params, params)
    )
  end

  @doc """
  Returns recent short-selling trades for a symbol.

  Endpoint: `GET /v1/quote/short-trades/us` (or `.../hk` for `.HK`
  symbols).

  ## Options

    * `:count` — integer, default 50.
    * `:last_timestamp` — Unix timestamp seconds to paginate
      backwards from (omit for latest).
  """
  @spec short_trades(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, list(map())} | {:error, term()}
  def short_trades(%Config{} = config, symbol, opts \\ [], http_opts \\ []) do
    count = Keyword.get(opts, :count, 50)
    last_ts = Keyword.get(opts, :last_timestamp, 0)

    path =
      if String.ends_with?(String.upcase(symbol), ".HK") do
        "/v1/quote/short-trades/hk"
      else
        @short_trades_path
      end

    params =
      HTTPClient.build_query(
        counter_id: Longbridge.Symbol.to_counter_id(symbol),
        last_timestamp: last_ts,
        page_size: count
      )

    case HTTPClient.request_json(:get, path, "", config, Keyword.put(http_opts, :params, params)) do
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
  @spec update_pinned(Config.t(), String.t(), String.t(), boolean(), keyword()) ::
          :ok | {:error, term()}
  def update_pinned(%Config{} = config, group_id, symbol, is_pinned, opts \\ [])
      when is_boolean(is_pinned) do
    body = Jason.encode!(%{group_id: group_id, symbol: symbol, is_pinned: is_pinned})

    case HTTPClient.request_json(:post, @watchlist_pinned_path, body, config, opts) do
      {:ok, _response} -> :ok
      error -> error
    end
  end

  @doc """
  Returns the filings list for a symbol.

  Endpoint: `GET /v1/quote/filings`

  Mirrors `QuoteContext::Filings` from `longbridge/openapi/rust` and
  `QuoteContext.Filings` from `longbridge/openapi-go`.

  Each item has the shape:

      %{
        "id"          => String.t(),
        "title"       => String.t(),
        "description" => String.t(),
        "file_name"   => String.t(),
        "file_urls"   => [String.t()],
        "publish_at"  => non_neg_integer()
      }

  `publish_at` is a Unix timestamp in seconds; convert with
  `DateTime.from_unix!/2` or `Longbridge.Decimal` as appropriate.
  """
  @spec filings(Config.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def filings(%Config{} = config, symbol, opts \\ []) when is_binary(symbol) do
    params = "symbol=#{URI.encode_www_form(symbol)}"

    case HTTPClient.request_json(
           :get,
           @filings_path,
           "",
           config,
           Keyword.put(opts, :params, params)
         ) do
      {:ok, %{"items" => items}} when is_list(items) -> {:ok, items}
      {:ok, _other} -> {:ok, []}
      error -> error
    end
  end

  @doc """
  Batch-converts user-facing symbols to their internal
  `counter_id`s via the remote API.

  Endpoint: `POST /v1/quote/symbol-to-counter-ids`

  Mirrors `QuoteContext::SymbolToCounterIds` from
  `longbridge/openapi/rust` and `QuoteContext.SymbolToCounterIds`
  from `longbridge/openapi-go`.

  Returns a map of `symbol => counter_id`. Symbols the backend
  does not recognize are omitted. For local-first resolution with
  embedded directory + cache, use
  `Longbridge.Symbol.resolve_counter_ids/2` instead.
  """
  @spec symbol_to_counter_ids(Config.t(), [String.t()], keyword()) ::
          {:ok, %{String.t() => String.t()}} | {:error, term()}
  def symbol_to_counter_ids(%Config{} = config, symbols, opts \\ []) when is_list(symbols) do
    body = Jason.encode!(%{ticker_regions: symbols})

    case HTTPClient.request_json(:post, @symbol_to_counter_ids_path, body, config, opts) do
      {:ok, %{"list" => list}} when is_map(list) -> {:ok, list}
      {:ok, _other} -> {:ok, %{}}
      error -> error
    end
  end
end
