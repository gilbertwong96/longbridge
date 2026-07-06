defmodule Longbridge.ScreenerContext do
  @moduledoc """
  Screener context.

  Stock-screener strategies, indicator search, and pre-defined
  recommendation strategies. Mirrors the official `ScreenerContext`
  in `longbridge/openapi-go` (Go) and `longbridge/openapi/rust`
  (Rust) SDKs.

  ## Usage

      config = Longbridge.Config.new(...)

      # Pre-defined recommended strategies
      {:ok, response} = Longbridge.ScreenerContext.recommend_strategies(config, "US")

      # The user's saved screener strategies
      {:ok, response} = Longbridge.ScreenerContext.user_strategies(config, "US")

      # A single strategy by ID
      {:ok, strategy} = Longbridge.ScreenerContext.strategy(config, 42)

      # Search by typed conditions (Mode B)
      {:ok, results} = Longbridge.ScreenerContext.search(config, "US",
        conditions: [
          %{key: "pettm", min: "5", max: "20"}
        ],
        page: 0,
        size: 50
      )

      # Or by a saved strategy ID (Mode A) — the server-side strategy
      # supplies its own filters and market.
      {:ok, results} = Longbridge.ScreenerContext.search(config, "US",
        strategy_id: 42, page: 0, size: 50
      )

      # List of available indicators
      {:ok, indicators} = Longbridge.ScreenerContext.indicators(config)

  ## Note on responses

  The screener API returns free-form JSON (`json.RawMessage` in the
  Go SDK). We surface the raw decoded map directly; callers should
  not assume a fixed schema. The upstream applies a `filter_` prefix
  transformation on some fields — see the docs in each function.
  """

  alias Longbridge.{Config, HTTPClient}

  @strategy_recommend_path "/v1/quote/ai/screener/strategies/recommend"
  @strategy_mine_path "/v1/quote/ai/screener/strategies/mine"
  @strategy_path_prefix "/v1/quote/ai/screener/strategy/"
  @strategy_search_path "/v1/quote/ai/screener/search"
  @indicators_path "/v1/quote/ai/screener/indicators"

  # Default return columns always included in a screener search request.
  # Matches `defaultReturns` in longbridge/openapi-go/screener/context.go.
  @default_returns [
    "filter_prevclose",
    "filter_prevchg",
    "filter_marketcap",
    "filter_salesgrowthyoy",
    "filter_pettm",
    "filter_pbmrq",
    "filter_industry"
  ]

  @doc """
  Fetches the list of pre-defined recommended screener strategies for
  a market (`"US"`, `"HK"`, `"CN"`, `"SG"`).

  Endpoint: `GET /v1/quote/ai/screener/strategies/recommend?market=...`
  """
  @spec recommend_strategies(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def recommend_strategies(%Config{} = config, market, opts \\ []) do
    HTTPClient.request_json(
      :get,
      @strategy_recommend_path,
      "",
      config,
      Keyword.put(opts, :params, "market=#{URI.encode_www_form(market)}")
    )
  end

  @doc """
  Fetches the current user's saved screener strategies for a market.

  Endpoint: `GET /v1/quote/ai/screener/strategies/mine?market=...`
  """
  @spec user_strategies(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def user_strategies(%Config{} = config, market, opts \\ []) do
    HTTPClient.request_json(
      :get,
      @strategy_mine_path,
      "",
      config,
      Keyword.put(opts, :params, "market=#{URI.encode_www_form(market)}")
    )
  end

  @doc """
  Fetches a single screener strategy by ID.

  Endpoint: `GET /v1/quote/ai/screener/strategy/{id}`

  The `"filter_"` prefix is stripped from every
  `filter.filters[].key` in the response before it is returned.
  """
  @spec strategy(Config.t(), non_neg_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def strategy(%Config{} = config, id, opts \\ []) when is_integer(id) do
    case HTTPClient.request_json(
           :get,
           @strategy_path_prefix <> Integer.to_string(id),
           "",
           config,
           opts
         ) do
      {:ok, data} when is_map(data) ->
        {:ok, strip_strategy_filter_prefixes(data)}

      error ->
        error
    end
  end

  defp strip_strategy_filter_prefixes(%{"filter" => %{"filters" => filters}} = data)
       when is_list(filters) do
    Map.put(data, "filter", %{
      "filters" => Enum.map(filters, &strip_filter_key/1)
    })
  end

  defp strip_strategy_filter_prefixes(data), do: data

  defp strip_filter_key(%{"key" => key} = item) do
    Map.put(item, "key", String.trim_leading(key, "filter_"))
  end

  defp strip_filter_key(item), do: item

  @doc """
  Executes a screener search.

  Endpoint: `POST /v1/quote/ai/screener/search`

  Two modes:

    * **Mode A** (`strategy_id:` given) — the server-side strategy
      supplies its own filters and market. The `market` argument is
      ignored; the strategy's own market is used.

    * **Mode B** (`conditions:` given) — typed conditions drive the
      filters, and the supplied `market` is used directly.

  The `"filter_"` prefix is stripped from every
  `items[].indicators[].key` in the response before it is returned.

  ## Options

    * `:strategy_id` — non_neg_integer, sets Mode A. Mutually exclusive
      with `:conditions`.
    * `:conditions` — list of `%{key: String.t(), min: String.t(), max: String.t()}`,
      sets Mode B. The `"filter_"` prefix is added automatically.
    * `:show` — list of extra return columns to include beyond the
      defaults. Optional.
    * `:page` — 0-indexed page number. Required.
    * `:size` — page size. Required.
  """
  @spec search(Config.t(), String.t(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def search(%Config{} = config, market, opts \\ [], http_opts \\ []) do
    strategy_id = Keyword.get(opts, :strategy_id)
    conditions = Keyword.get(opts, :conditions, [])
    show = Keyword.get(opts, :show, [])
    page = Keyword.fetch!(opts, :page)
    size = Keyword.fetch!(opts, :size)

    body_map =
      if strategy_id != nil do
        mode_a_body(strategy_id, show, page, size)
      else
        mode_b_body(market, conditions, show, page, size)
      end

    body = JSON.encode!(body_map)

    case HTTPClient.request_json(:post, @strategy_search_path, body, config, http_opts) do
      {:ok, data} when is_map(data) ->
        {:ok, strip_search_filter_prefixes(data)}

      error ->
        error
    end
  end

  defp strip_search_filter_prefixes(%{"items" => items} = data) when is_list(items) do
    Map.put(data, "items", Enum.map(items, &strip_item_indicator_prefix/1))
  end

  defp strip_search_filter_prefixes(data), do: data

  defp strip_item_indicator_prefix(%{"indicators" => indicators} = item)
       when is_list(indicators) do
    Map.put(item, "indicators", Enum.map(indicators, &strip_filter_key/1))
  end

  defp strip_item_indicator_prefix(item), do: item

  @doc """
  Lists available screener indicators.

  Endpoint: `GET /v1/quote/ai/screener/indicators`

  The response is normalized:

    * `"filter_"` prefix is stripped from every
      `groups[].indicators[].key`.
    * `tech_values` is built from `tech_indicators` as
      `{tech_key: [%{value: String.t(), label: String.t()}]}`.
  """
  @spec indicators(Config.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def indicators(%Config{} = config, opts \\ []) do
    case HTTPClient.request_json(:get, @indicators_path, "", config, opts) do
      {:ok, response} -> {:ok, normalize_indicators(response)}
      error -> error
    end
  end

  # ── Helpers ──────────────────────────────────────────────

  # Mode A: fetch the strategy server-side, copy its filters and
  # market into the search body. `market` from the caller is
  # intentionally ignored — the strategy's own market wins.
  defp mode_a_body(strategy_id, show, page, size) do
    %{"strategy_id" => strategy_id, "show" => show, "page" => page, "size" => size}
  end

  # Mode B: build the request body from typed conditions. Each
  # condition's key gets the `"filter_"` prefix automatically.
  defp mode_b_body(market, conditions, show, page, size) do
    filters =
      Enum.map(conditions, fn cond ->
        %{"key" => ensure_filter_prefix(cond[:key]), "min" => cond[:min], "max" => cond[:max]}
      end)

    returns = build_returns(filters, show)

    body = %{
      "market" => market,
      "filters" => filters,
      "returns" => returns,
      "page" => page,
      "size" => size
    }

    if filters == [] do
      Map.put(body, "filters", [])
    else
      body
    end
  end

  # Build the list of return columns: defaults first, then filter keys,
  # then user-supplied `show` columns. Duplicates are removed. Every
  # key gets the `"filter_"` prefix.
  defp build_returns(filters, show) do
    filter_keys =
      filters
      |> Enum.map(fn f -> f["key"] end)
      |> Enum.reject(&(&1 == ""))

    [@default_returns ++ filter_keys ++ show]
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.map(&ensure_filter_prefix/1)
  end

  @doc false
  def ensure_filter_prefix(key) when is_binary(key) do
    case String.starts_with?(key, "filter_") do
      true -> key
      false -> "filter_" <> key
    end
  end

  def ensure_filter_prefix(_), do: ""

  defp normalize_indicators(%{"groups" => groups} = response) when is_list(groups) do
    normalized =
      Enum.map(groups, fn group ->
        indicators =
          group
          |> Map.get("indicators", [])
          |> Enum.map(&normalize_indicator/1)

        Map.put(group, "indicators", indicators)
      end)

    Map.put(response, "groups", normalized)
  end

  defp normalize_indicators(response), do: response

  defp normalize_indicator(%{} = indicator) do
    indicator
    |> strip_indicator_prefix()
    |> build_tech_values()
  end

  defp normalize_indicator(other), do: other

  defp strip_indicator_prefix(%{"key" => key} = indicator) do
    Map.put(indicator, "key", String.trim_leading(key, "filter_"))
  end

  defp strip_indicator_prefix(indicator), do: indicator

  defp build_tech_values(%{"tech_indicators" => tech_indicators} = indicator)
       when is_list(tech_indicators) and tech_indicators != [] do
    tv =
      Enum.reduce(tech_indicators, %{}, fn ti, acc ->
        tech_key = Map.get(ti, "tech_key")

        if is_binary(tech_key) and tech_key != "" do
          opts =
            ti
            |> Map.get("tech_items", [])
            |> Enum.map(fn item ->
              %{
                "value" => Map.get(item, "item_value"),
                "label" => Map.get(item, "item_name")
              }
            end)

          Map.put(acc, tech_key, opts)
        else
          acc
        end
      end)

    if map_size(tv) > 0 do
      Map.put(indicator, "tech_values", tv)
    else
      indicator
    end
  end

  defp build_tech_values(indicator), do: indicator
end
