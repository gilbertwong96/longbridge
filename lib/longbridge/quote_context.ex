defmodule Longbridge.QuoteContext do
  @moduledoc """
  Quote connection context for Longbridge market data APIs.

  Manages a connection to the quote endpoint and provides
  a high-level API for market data operations.

  ## Usage

      {:ok, ctx} = Longbridge.QuoteContext.start_link(config)

      # Get security static info
      {:ok, result} = Longbridge.QuoteContext.static_info(ctx, ["AAPL.US"])

      # Get real-time quotes
      {:ok, result} = Longbridge.QuoteContext.quote(ctx, ["AAPL.US", "TSLA.US"])

      # Subscribe to push data
      :ok = Longbridge.QuoteContext.subscribe(ctx, ["AAPL.US"], [:QUOTE])

      # Receive push messages in your process
      receive do
        {:longbridge_push, {:push, 101, body}} ->
          quote = Protox.decode!(body, Longbridge.Quote.V1.PushQuote)
          IO.inspect(quote)
      end

  Push messages can also be dispatched to typed callbacks via
  `set_on_quote/2`, `set_on_depth/2`, `set_on_brokers/2`, and
  `set_on_trades/2`, or to a single default handler via
  `set_default_push_callback/2`. Callbacks fire in addition to
  mailbox delivery — the underlying `{:longbridge_push, msg}`
  message is still sent to the calling process when it has
  subscribed via `Longbridge.WSConnection.subscribe_push/2`.
  """

  use GenServer

  alias Longbridge.{Config, WSConnection}
  alias Longbridge.Quote.V1, as: Q
  alias Longbridge.QuoteContext.RealtimeStore

  @type sub_type :: :QUOTE | :DEPTH | :BROKERS | :TRADE

  # ── Command codes from quote API ─────────────────────────

  @cmd_user_quote_profile 4
  @cmd_subscription 5
  @cmd_subscribe 6
  @cmd_unsubscribe 7
  @cmd_market_trade_period 8
  @cmd_market_trade_day 9
  @cmd_security_static_info 10
  @cmd_security_quote 11
  @cmd_option_quote 12
  @cmd_warrant_quote 13
  @cmd_depth 14
  @cmd_brokers 15
  @cmd_participant_broker_ids 16
  @cmd_trade 17
  @cmd_intraday 18
  @cmd_candlestick 19
  @cmd_option_chain_date 20
  @cmd_option_chain_date_strike_info 21
  @cmd_warrant_issuer_info 22
  @cmd_capital_flow_intraday 24
  @cmd_capital_flow_distribution 25
  @cmd_security_calc_index 26
  @cmd_history_candlestick 27
  @cmd_warrant_filter_list 23

  @sub_type_map %{
    QUOTE: 1,
    DEPTH: 2,
    BROKERS: 3,
    TRADE: 4
  }

  @type trade_session ::
          :NORMAL_TRADE | :PRE_TRADE | :POST_TRADE | :OVERNIGHT_TRADE | non_neg_integer()

  # Wire-format push command codes from the upstream QuoteContext.
  @push_cmd_quote 101
  @push_cmd_depth 102
  @push_cmd_brokers 103
  @push_cmd_trade 104

  @push_cmd_to_topic %{
    @push_cmd_quote => :quote,
    @push_cmd_depth => :depth,
    @push_cmd_brokers => :brokers,
    @push_cmd_trade => :trade
  }

  # ── Client API ───────────────────────────────────────────

  @doc """
  Starts a QuoteContext linked to the calling process.

  The context owns a `Longbridge.WSConnection` (one Mint WebSocket to
  `config.quote_ws_url`) and a per-instance `RealtimeStore` for cached
  push data. The caller is automatically subscribed to push frames.

  ## Options

    * `:name` — registered process name, passed through to `GenServer.start_link/3`.
    * Any other `GenServer` option (`:timeout`, `:spawn_opt`, `:hibernate_after`, ...).

  ## Example

      {:ok, ctx} = Longbridge.QuoteContext.start_link(config)

  """
  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, {config, opts}, opts)
  end

  @doc """
  Returns the current WS session info.

  Returns `{:ok, session_id, heartbeat_interval_ms}` once the
  underlying `Longbridge.WSConnection` has finished authenticating.
  Returns `{:ok, nil, nil}` before auth completes.

  `session_id` is the opaque string assigned by the Longbridge
  backend (e.g. `"15766270:21526413:1eef69007cb60d68d6111f7ea02b7531"`).
  """
  @spec session(pid()) :: {:ok, String.t(), integer()} | {:error, term()}
  def session(pid) do
    GenServer.call(pid, :session)
  end

  @doc """
  Queries the user's quote profile (cmd_code 4).

  Returns the user's `member_id`, `quote_level`, `subscribe_limit`,
  `history_candlestick_limit`, per-command `rate_limit`, and the
  `quote_level_detail` (subscribed quote packages by market).

  ## Options

  - `:language` — response language for `quote_level_detail`.
    Accepts `"zh-CN"`, `"zh-HK"`, or `"en"`. Defaults to `"en"`.

  Mirrors `longbridge/openapi/rust/src/quote/core.rs::Core::connect()`,
  which calls `QueryUserQuoteProfile` once after auth. The Rust SDK
  uses the response to populate rate-limit throttling; we expose the
  raw response so callers can do the same.

  ## Example

      {:ok, profile} = Longbridge.QuoteContext.user_quote_profile(ctx)
      profile.member_id
      profile.subscribe_limit
      profile.rate_limit
  """
  @spec user_quote_profile(pid(), keyword()) ::
          {:ok, Q.UserQuoteProfileResponse.t()} | {:error, term()}
  def user_quote_profile(pid, opts \\ []) do
    language = Keyword.get(opts, :language, "en")
    req = %Q.UserQuoteProfileRequest{language: language}
    request(pid, @cmd_user_quote_profile, req, Q.UserQuoteProfileResponse)
  end

  @doc """
  Returns the authenticated member ID.

  Convenience over `user_quote_profile/2` that extracts just the
  `member_id` field — no need to decode the full profile response.

  Mirrors `QuoteContext::member_id` from `longbridge/openapi/rust`.
  """
  @spec member_id(pid()) :: {:ok, integer()} | {:error, term()}
  def member_id(pid) do
    with {:ok, profile} <- user_quote_profile(pid), do: {:ok, profile.member_id}
  end

  @doc """
  Returns the user's quote level (e.g. `"Lv1"`, `"Lv2"`).

  Convenience over `user_quote_profile/2` that extracts just the
  `quote_level` field. Mirrors `QuoteContext::quote_level` from
  `longbridge/openapi/rust`.
  """
  @spec quote_level(pid()) :: {:ok, String.t()} | {:error, term()}
  def quote_level(pid) do
    with {:ok, profile} <- user_quote_profile(pid), do: {:ok, profile.quote_level}
  end

  @doc """
  Returns the user's subscribed quote packages by market.

  Each market entry contains the package details (key, name,
  description, start/end timestamps) and a `warning_msg` shown when
  no packages are active for that market.

  The `language` parameter (`"en"` by default) controls the
  localized package names. Accepted values: `"zh-CN"`, `"zh-HK"`,
  `"en"`.

  Mirrors `QuoteContext::quote_package_details` from
  `longbridge/openapi/rust`.

  ## Example

      {:ok, %UserQuoteLevelDetail{} = details} =
        Longbridge.QuoteContext.quote_package_details(ctx, language: "en")
      Enum.each(details.market_package_details, fn entry ->
        IO.inspect(entry.market)
      end)
  """
  @spec quote_package_details(pid(), keyword()) ::
          {:ok, Q.UserQuoteLevelDetail.t()} | {:error, term()}
  def quote_package_details(pid, opts \\ []) do
    with {:ok, profile} <- user_quote_profile(pid, opts) do
      {:ok, profile.quote_level_detail}
    end
  end

  # ── Quote API Methods ────────────────────────────────────

  @doc """
  Returns static metadata for one or more symbols.

  Endpoint: cmd_code 10 (`QuerySecurityStaticInfo`).

  Each entry in `response.secu_static_info` contains the listing
  exchange, lot size, board, underlying symbol, etc. Mirrors
  `QuoteContext::static_info` from `longbridge/openapi/rust`.

  ## Example

      {:ok, %{secu_static_info: [%{symbol: "AAPL.US", name_en: "Apple Inc."} | _]}} =
        Longbridge.QuoteContext.static_info(ctx, ["AAPL.US"])
  """
  @spec static_info(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def static_info(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_security_static_info, req, Q.SecurityStaticInfoResponse)
  end

  @doc """
  Returns a real-time snapshot quote for one or more symbols.

  Endpoint: cmd_code 11 (`QuerySecurityQuote`). One-shot request; for
  a continuously-updating view, subscribe via `subscribe/4` with
  `:QUOTE` and read the local cache with `realtime_quote/2`.

  The server gzips the response when the body crosses its internal
  size threshold — `Longbridge.Protocol.unpack/1` transparently
  decompresses it.

  ## Example

      {:ok, %{secu_quote: [%{symbol: "AAPL.US", last_done: "282.50", ...} | _]}} =
        Longbridge.QuoteContext.quote(ctx, ["AAPL.US"])
  """
  @spec quote(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def quote(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_security_quote, req, Q.SecurityQuoteResponse)
  end

  @doc """
  Returns option quotes (greeks + theoretical price) for one or more
  option symbols.

  Endpoint: cmd_code 12 (`QueryOptionQuote`). The `symbol` entries
  must be **option** symbols (`"AAPL250117C150000.US"`), not the
  underlying equity.
  """
  @spec option_quote(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def option_quote(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_option_quote, req, Q.OptionQuoteResponse)
  end

  @doc """
  Returns warrant quotes for one or more warrant symbols.

  Endpoint: cmd_code 13 (`QueryWarrantQuote`). Same caveat as
  `option_quote/2` — `symbols` are warrant IDs, not the underlying
  equity.
  """
  @spec warrant_quote(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def warrant_quote(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_warrant_quote, req, Q.WarrantQuoteResponse)
  end

  @doc """
  Returns the order book (market depth) for a single symbol.

  Endpoint: cmd_code 14 (`QueryDepth`). Returns the current top-of-book
  snapshot; subscribe to `:DEPTH` push for a continuously-updating view.

  Each `ask` / `bid` entry is `[price_cents, volume, order_count]`
  where `price_cents` is a decimal string.
  """
  @spec depth(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def depth(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_depth, req, Q.SecurityDepthResponse)
  end

  @doc """
  Returns the broker queue (top 10 bid/ask brokers) for a symbol.

  Endpoint: cmd_code 15 (`QueryBrokers`). Each broker id can be looked
  up against `participant_broker_ids/1`.
  """
  @spec brokers(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def brokers(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_brokers, req, Q.SecurityBrokersResponse)
  end

  @doc """
  Returns the broker participant ID list for the current session's
  market.

  Endpoint: cmd_code 16 (`QueryParticipantBrokerIds`). The returned
  id list is what `brokers/2` indexes into. Mirrors
  `ParticipantBrokerIds` from `longbridge/openapi-go`.
  """
  @spec participant_broker_ids(pid()) :: {:ok, struct()} | {:error, term()}
  def participant_broker_ids(pid) do
    request_empty(pid, @cmd_participant_broker_ids, Q.ParticipantBrokerIdsResponse)
  end

  @doc """
  Returns the most recent `count` trades (tick data) for a symbol.

  Endpoint: cmd_code 17 (`QueryTrade`). Each entry has
  `price_cents`, `volume`, `timestamp`, `trade_type` (0 = `?`, 1 = `?`,
  see upstream docs), and `direction` (`-1`/`0`/`+1`).

  For a live, capped-at-500 tail, subscribe to `:TRADE` push and read
  `realtime_trades/3`.
  """
  @spec trades(pid(), String.t(), non_neg_integer()) :: {:ok, struct()} | {:error, term()}
  def trades(pid, symbol, count \\ 100) do
    req = %Q.SecurityTradeRequest{symbol: symbol, count: count}
    request(pid, @cmd_trade, req, Q.SecurityTradeResponse)
  end

  @doc """
  Queries intraday lines for a security.

  `trade_session` is one of:
    * `:NORMAL_TRADE` (default) — regular trading session only.
    * `:PRE_TRADE` — pre-market quotes only.
    * `:POST_TRADE` — post-market quotes only.
    * `:OVERNIGHT_TRADE` — overnight session quotes only.

  Or pass an integer (0-3) directly.
  """
  @spec intraday(pid(), String.t(), trade_session()) ::
          {:ok, struct()} | {:error, term()}
  def intraday(pid, symbol, trade_session \\ :NORMAL_TRADE) do
    req = %Q.SecurityIntradayRequest{
      symbol: symbol,
      trade_session: trade_session_code(trade_session)
    }

    request(pid, @cmd_intraday, req, Q.SecurityIntradayResponse)
  end

  @doc """
  Queries candlestick data.

  `period` is one of: `:ONE_MINUTE`, `:FIVE_MINUTE`, `:FIFTEEN_MINUTE`,
  `:THIRTY_MINUTE`, `:SIXTY_MINUTE`, `:DAY`, `:WEEK`, `:MONTH`, `:QUARTER`, `:YEAR`
  """
  @spec candlesticks(
          pid(),
          String.t(),
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          trade_session()
        ) ::
          {:ok, struct()} | {:error, term()}
  def candlesticks(
        pid,
        symbol,
        period \\ :DAY,
        count \\ 100,
        adjust_type \\ 0,
        trade_session \\ :NORMAL_TRADE
      ) do
    period_val = period_code(period)

    req = %Q.SecurityCandlestickRequest{
      symbol: symbol,
      period: period_val,
      count: count,
      adjust_type: adjust_type,
      trade_session: trade_session_code(trade_session)
    }

    request(pid, @cmd_candlestick, req, Q.SecurityCandlestickResponse)
  end

  @doc """
  Fetches a large number of candlesticks by paginating across multiple
  `candlesticks/6` calls.

  The single-request API caps at 1000 candles per call. This function
  fetches up to `count` candles total, issuing multiple requests with
  `history_candlesticks_by_offset/3` to walk backward from the oldest
  bar of each batch.

  If the offset API is unavailable (e.g. paper-trading accounts), it
  falls back to a single `candlesticks/6` call and returns whatever
  the API provides.

  ## Rate limiting

  The SDK applies built-in rate-limit throttling (learned from
  `user_quote_profile/2` at connection time). No manual throttling
  is needed.

  ## Options

    * `:period` — same as `candlesticks/6` (default `:DAY`)
    * `:count` — total number of candles to fetch (default 1000)
    * `:adjust_type` — `0` or `1` (default `0`)
    * `:batch_size` — candles per request (default 1000, the API max)
    * `:trade_session` — `:NORMAL_TRADE` or `:ALL_TRADE` (default `:NORMAL_TRADE`)

  ## Returns

    * `{:ok, candlesticks}` — list of `Candlestick` structs, oldest first
    * `{:error, reason}` — first error encountered

  ## Example

      {:ok, candles} = QuoteContext.candlesticks_paginated(ctx, "700.HK",
        period: :DAY, count: 5000
      )
  """
  @spec candlesticks_paginated(pid(), String.t(), keyword()) ::
          {:ok, [struct()]} | {:error, term()}
  def candlesticks_paginated(pid, symbol, opts) do
    period = Keyword.get(opts, :period, :DAY)
    count = Keyword.get(opts, :count, 1000)
    adjust_type = Keyword.get(opts, :adjust_type, 0)
    batch_size = min(Keyword.get(opts, :batch_size, 1000), 1000)
    trade_session = Keyword.get(opts, :trade_session, :NORMAL_TRADE)

    paginate(pid, symbol, period, count, adjust_type, batch_size, trade_session, [], MapSet.new())
  end

  defp paginate(_pid, _symbol, _period, remaining, _adjust, _batch, _session, acc, _seen)
       when remaining <= 0 do
    {:ok, sort_by_ts(acc)}
  end

  defp paginate(pid, symbol, period, remaining, adjust, batch, session, acc, seen) do
    fetch_count = min(batch, remaining)

    with {:ok, resp} <- candlesticks(pid, symbol, period, fetch_count, adjust, session),
         candles when candles != [] <- resp.candlesticks do
      new_candles = Enum.reject(candles, &MapSet.member?(seen, &1.timestamp))

      if new_candles == [] do
        {:ok, sort_by_ts(acc)}
      else
        new_seen = Enum.reduce(new_candles, seen, &MapSet.put(&2, &1.timestamp))
        new_acc = new_candles ++ acc
        fetched = length(new_candles)

        if fetched < fetch_count do
          {:ok, sort_by_ts(new_acc)}
        else
          paginate(
            pid,
            symbol,
            period,
            remaining - fetched,
            adjust,
            batch,
            session,
            new_acc,
            new_seen
          )
        end
      end
    else
      [] ->
        {:ok, sort_by_ts(acc)}

      {:error, _reason} = err ->
        err
    end
  end

  defp sort_by_ts(candles), do: Enum.sort_by(candles, & &1.timestamp)

  @doc """
  Queries historical candlesticks for a symbol, walking forward or
  backward from a specific date and time.

  Endpoint: cmd_code 27 (`QueryHistoryCandlestick`) with
  `query_type = QUERY_BY_OFFSET`.

  ## Options

    * `:period` — `:MIN_1 | :MIN_5 | :MIN_15 | :MIN_30 | :MIN_60 |
      :DAY | :WEEK | :MONTH | :YEAR | :QUARTER`. Required.
    * `:adjust_type` — `0` (no adjust) or `1` (forward adjust).
      Required.
    * `:direction` — `:forward` (from offset toward latest data)
      or `:backward` (from offset toward historical data).
      Required.
    * `:date` — date string `"YYYY-MM-DD"` for the offset anchor.
      Required.
    * `:minute` — minute string `"HH:MM"` (intraday periods only).
      Optional.
    * `:count` — non_neg_integer count. Required.
    * `:trade_session` — `0` (regular session) or `1` (all sessions).
      Optional.

  Mirrors `HistoryCandlesticksByOffset` in `longbridge/openapi-go`
  and `QuoteContext::history_candlesticks_by_offset` in
  `longbridge/openapi/rust`.
  """
  @spec history_candlesticks_by_offset(pid(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def history_candlesticks_by_offset(pid, symbol, opts) do
    period = Keyword.fetch!(opts, :period)
    adjust_type = Keyword.fetch!(opts, :adjust_type)
    direction = Keyword.fetch!(opts, :direction)
    date = Keyword.fetch!(opts, :date)
    count = Keyword.fetch!(opts, :count)

    direction_val =
      case direction do
        :forward -> 1
        :backward -> 0
        v when v in [0, 1] -> v
      end

    offset_query = %Q.SecurityHistoryCandlestickRequest.OffsetQuery{
      direction: direction_val,
      date: date,
      minute: Keyword.get(opts, :minute, ""),
      count: count
    }

    req = %Q.SecurityHistoryCandlestickRequest{
      symbol: symbol,
      period: period_code(period),
      adjust_type: adjust_type,
      query_type: 1,
      offset_request: offset_query,
      trade_session: trade_session_code(Keyword.get(opts, :trade_session, :NORMAL_TRADE))
    }

    request(pid, @cmd_history_candlestick, req, Q.SecurityCandlestickResponse)
  end

  @doc """
  Queries historical candlesticks for a symbol within a date range.

  Endpoint: cmd_code 27 (`QueryHistoryCandlestick`) with
  `query_type = QUERY_BY_DATE`.

  ## Options

    * `:period` — `:MIN_1 | :MIN_5 | :MIN_15 | :MIN_30 | :MIN_60 |
      :DAY | :WEEK | :MONTH | :YEAR | :QUARTER`. Required.
    * `:adjust_type` — `0` (no adjust) or `1` (forward adjust).
      Required.
    * `:start_date` — `"YYYY-MM-DD"` string. Required.
    * `:end_date` — `"YYYY-MM-DD"` string. Required.
    * `:trade_session` — `0` (regular session) or `1` (all sessions).
      Optional.

  Mirrors `HistoryCandlesticksByDate` in `longbridge/openapi-go`.
  """
  @spec history_candlesticks_by_date(pid(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def history_candlesticks_by_date(pid, symbol, opts) do
    period = Keyword.fetch!(opts, :period)
    adjust_type = Keyword.fetch!(opts, :adjust_type)
    start_date = Keyword.fetch!(opts, :start_date)
    end_date = Keyword.fetch!(opts, :end_date)

    date_query = %Q.SecurityHistoryCandlestickRequest.DateQuery{
      start_date: start_date,
      end_date: end_date
    }

    req = %Q.SecurityHistoryCandlestickRequest{
      symbol: symbol,
      period: period_code(period),
      adjust_type: adjust_type,
      query_type: 2,
      date_request: date_query,
      trade_session: trade_session_code(Keyword.get(opts, :trade_session, :NORMAL_TRADE))
    }

    request(pid, @cmd_history_candlestick, req, Q.SecurityCandlestickResponse)
  end

  @doc """
  Returns the option chain expiry dates available for an underlying.

  Endpoint: cmd_code 20 (`QueryOptionChainDate`). Each entry in
  `expiry_date` is a date string the server accepts as the
  `expiry_date` argument to `option_chain_strike_info/3`.
  """
  @spec option_chain_date(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def option_chain_date(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_option_chain_date, req, Q.OptionChainDateListResponse)
  end

  @doc """
  Returns option chain strike info (price, OI, volume) for an
  underlying on a specific expiry date.

  Endpoint: cmd_code 21 (`QueryOptionChainDateStrikeInfo`).
  `expiry_date` must be one of the values returned by
  `option_chain_date/2`.
  """
  @spec option_chain_strike_info(pid(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def option_chain_strike_info(pid, symbol, expiry_date) do
    req = %Q.OptionChainDateStrikeInfoRequest{symbol: symbol, expiry_date: expiry_date}
    request(pid, @cmd_option_chain_date_strike_info, req, Q.OptionChainDateStrikeInfoResponse)
  end

  @doc """
  Returns the list of warrant issuers with their numeric ids.

  Endpoint: cmd_code 22 (`QueryWarrantIssuerInfo`). Pass these ids in
  the `:issuer` list of `warrant_list/2` to filter by issuer.
  """
  @spec warrant_issuer_info(pid()) :: {:ok, struct()} | {:error, term()}
  def warrant_issuer_info(pid) do
    request_empty(pid, @cmd_warrant_issuer_info, Q.IssuerInfoResponse)
  end

  @doc """
  Filters HK warrants for a given underlying symbol.

  Endpoint: cmd_code 23 (`QueryWarrantFilterList`).

  ## Required options

    * `:symbol` — the underlying symbol (e.g. `"700.HK"`).
    * `:language` — `0` (Simplified Chinese), `1` (English), `2`
      (Traditional Chinese).

  ## Optional filters

    * `:sort_by` — `:last_done | :change_rate | :change_value | :volume |
      :turnover | :outstanding_qty | :leverage_ratio | :implied_volatility
      | :status` (default: `:last_done`).
    * `:sort_order` — `:desc | :asc` (default: `:desc`).
    * `:sort_offset` — non_neg_integer pagination offset (default 0).
    * `:sort_count` — non_neg_integer page size (default 50).
    * `:type` — `:call | :put` (or `0 | 1`).
    * `:expiry_date` — `:lt_3 | :between_3_6 | :between_6_12 | :gt_12`
      (or `1 | 2 | 3 | 4`).
    * `:status` — `:suspend | :prepare_list | :normal` (or `2 | 3 | 4`).
    * `:price_type` — `:in_bounds | :out_bounds` (or `1 | 2`).
    * `:issuer` — list of issuer ids from `warrant_issuer_info/1`.

  Mirrors `WarrantList` from `longbridge/openapi-go`.
  """
  @spec warrant_list(pid(), keyword()) :: {:ok, struct()} | {:error, term()}
  def warrant_list(pid, opts) do
    symbol = Keyword.fetch!(opts, :symbol)
    language = Keyword.fetch!(opts, :language)

    filter_config = %Q.FilterConfig{
      sort_by: warrant_sort_by_code(Keyword.get(opts, :sort_by, :last_done)),
      sort_order: warrant_sort_order_code(Keyword.get(opts, :sort_order, :desc)),
      sort_offset: Keyword.get(opts, :sort_offset, 0),
      sort_count: Keyword.get(opts, :sort_count, 50),
      type: encode_int_list(Keyword.get(opts, :type, []), &warrant_type_code/1),
      issuer: encode_int_list(Keyword.get(opts, :issuer, []), & &1),
      expiry_date: encode_int_list(Keyword.get(opts, :expiry_date, []), &warrant_expiry_code/1),
      price_type: encode_int_list(Keyword.get(opts, :price_type, []), &warrant_price_type_code/1),
      status: encode_int_list(Keyword.get(opts, :status, []), &warrant_status_code/1)
    }

    req = %Q.WarrantFilterListRequest{
      symbol: symbol,
      filter_config: filter_config,
      language: language
    }

    request(pid, @cmd_warrant_filter_list, req, Q.WarrantFilterListResponse)
  end

  @doc """
  Returns the most recent cached quote data for each symbol
  from the local push-data store.

  Reads from the in-memory store populated by incoming push
  events. If the symbol has not been pushed since the
  QuoteContext started, returns `nil` for that entry.

  Mirrors `RealtimeQuote` from `longbridge/openapi-go` and
  `QuoteContext::realtime_quote` in `longbridge/openapi/rust`.
  """
  @spec realtime_quote(pid(), [String.t()]) ::
          {:ok, [struct() | nil]} | {:error, term()}
  def realtime_quote(pid, symbols) when is_list(symbols) do
    GenServer.call(pid, {:realtime_quote, symbols}, 5_000)
  end

  @doc """
  Returns the most recent cached depth data for a symbol
  from the local push-data store.
  """
  @spec realtime_depth(pid(), String.t()) ::
          {:ok, struct() | nil} | {:error, term()}
  def realtime_depth(pid, symbol) when is_binary(symbol) do
    GenServer.call(pid, {:realtime_depth, symbol}, 5_000)
  end

  @doc """
  Returns the most recent cached broker queue for a symbol
  from the local push-data store.
  """
  @spec realtime_brokers(pid(), String.t()) ::
          {:ok, struct() | nil} | {:error, term()}
  def realtime_brokers(pid, symbol) when is_binary(symbol) do
    GenServer.call(pid, {:realtime_brokers, symbol}, 5_000)
  end

  @doc """
  Returns the most recent `count` cached trades for a symbol
  from the local push-data store (capped at 500).

  If fewer than `count` trades have been pushed, returns all
  available trades in chronological order.
  """
  @spec realtime_trades(pid(), String.t(), non_neg_integer()) ::
          {:ok, [struct()]} | {:error, term()}
  def realtime_trades(pid, symbol, count \\ 50)
      when is_binary(symbol) and is_integer(count) and count >= 0 do
    GenServer.call(pid, {:realtime_trades, symbol, count}, 5_000)
  end

  @doc """
  Clears the local push-data cache. Useful when reconnecting
  or wanting to ignore stale data.
  """
  @spec reset_realtime_cache(pid()) :: :ok
  def reset_realtime_cache(pid) do
    GenServer.call(pid, :reset_realtime_cache)
  end

  @doc """
  Returns the current market trade-period metadata for the session
  (open/close timestamps, timezone, etc.).

  Endpoint: cmd_code 8 (`QueryMarketTradePeriod`). One-shot; for a
  specific day's calendar, use `market_trade_day/4`.
  """
  @spec market_trade_period(pid()) :: {:ok, struct()} | {:error, term()}
  def market_trade_period(pid) do
    request_empty(pid, @cmd_market_trade_period, Q.MarketTradePeriodResponse)
  end

  @doc """
  Queries market trade days.

  The interval must be **less than one month** and **within the most
  recent year** (an upstream constraint). `beg_day` / `end_day` accept
  either `"YYYY-MM-DD"` or `"YYYYMMDD"`; the server receives the latter.
  """
  @spec market_trade_day(pid(), String.t(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def market_trade_day(pid, market, beg_day, end_day) do
    req = %Q.MarketTradeDayRequest{
      market: market,
      beg_day: normalize_date(beg_day),
      end_day: normalize_date(end_day)
    }

    request(pid, @cmd_market_trade_day, req, Q.MarketTradeDayResponse)
  end

  @doc """
  Returns precomputed calc indexes for one or more symbols.

  Endpoint: cmd_code 26 (`QuerySecurityCalcIndex`). `calc_indexes`
  is a list of upstream-defined integers (see the
  `SecurityCalcIndex` enum in `protos/api.proto`); the most common
  values are listed in the upstream docs at
  `https://open.longbridge.com/docs/quote/pull/calc-index`.
  """
  @spec calc_index(pid(), [String.t()], [non_neg_integer()]) :: {:ok, struct()} | {:error, term()}
  def calc_index(pid, symbols, calc_indexes) do
    req = %Q.SecurityCalcQuoteRequest{symbols: symbols, calc_index: calc_indexes}
    request(pid, @cmd_security_calc_index, req, Q.SecurityCalcQuoteResponse)
  end

  @doc """
  Returns intraday capital flow lines (large/small/medium order
  net inflow) for a single symbol.

  Endpoint: cmd_code 24 (`QueryCapitalFlowIntraday`). For HK/CN
  symbols only.
  """
  @spec capital_flow_intraday(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def capital_flow_intraday(pid, symbol) do
    req = %Q.CapitalFlowIntradayRequest{symbol: symbol}
    request(pid, @cmd_capital_flow_intraday, req, Q.CapitalFlowIntradayResponse)
  end

  @doc """
  Returns the capital flow size-bucket distribution
  (super-large / large / medium / small) for a single symbol.

  Endpoint: cmd_code 25 (`QueryCapitalFlowDistribution`). For
  HK/CN symbols only.
  """
  @spec capital_flow_distribution(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def capital_flow_distribution(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_capital_flow_distribution, req, Q.CapitalDistributionResponse)
  end

  @doc """
  Returns the list of subscriptions currently active on the WS
  connection.

  Endpoint: cmd_code 5 (`Subscription`). Useful for verifying that
  `subscribe/4` actually landed at the server, and for re-syncing
  state after a reconnect if you're not relying on the auto-resubscribe.
  """
  @spec subscription(pid()) :: {:ok, struct()} | {:error, term()}
  def subscription(pid) do
    req = %Q.SubscriptionRequest{}
    request(pid, @cmd_subscription, req, Q.SubscriptionResponse)
  end

  @doc """
  Subscribes to real-time push data for one or more symbols.

  Endpoint: cmd_code 6 (`Subscribe`). Records the subscription
  internally so it is **re-issued automatically after a WS reconnect**;
  callers do not need to re-subscribe after a network blip.

  ## Arguments

    * `symbols` — user-facing symbols (`"AAPL.US"`, `"00700.HK"`).
    * `sub_types` — list of atoms from `:QUOTE`, `:DEPTH`, `:BROKERS`, `:TRADE`.
      The same (symbols, sub_types) tuple is idempotent: subscribing
      twice is a no-op on the server.
    * `is_first_push` — when `true` (default), the server immediately
      pushes the current snapshot for each subscribed type. Pass
      `false` if you only want deltas after the subscribe lands.

  ## Push delivery

  Push data is delivered three ways:

    1. **Mailbox** — every subscriber of the underlying
       `Longbridge.WSConnection` receives
       `{:longbridge, conn_pid, {:push, cmd_code, body}}`. The context
       forwards this to the caller as `{:longbridge_push, msg}`.
    2. **Local cache** — `realtime_quote/2`, `realtime_depth/2`,
       `realtime_brokers/2`, and `realtime_trades/3` read the latest
       value without blocking on the server.
    3. **Typed callbacks** — `set_on_quote/2`, `set_on_depth/2`,
       `set_on_brokers/2`, `set_on_trades/2` (or `set_default_push_callback/2`
       for any topic).

  Push command codes:

    | Code | Message | Decode with |
    | --- | --- | --- |
    | 101 | `PushQuote` | `Longbridge.Quote.V1.PushQuote` |
    | 102 | `PushDepth` | `Longbridge.Quote.V1.PushDepth` |
    | 103 | `PushBrokers` | `Longbridge.Quote.V1.PushBrokers` |
    | 104 | `PushTrade` | `Longbridge.Quote.V1.PushTrade` |

  ## Example

      :ok = QuoteContext.set_on_quote(ctx, fn push -> IO.inspect(push) end)
      :ok = QuoteContext.subscribe(ctx, ["AAPL.US"], [:QUOTE], true)

  """
  @spec subscribe(pid(), [String.t()], [sub_type()], boolean()) :: :ok | {:error, term()}
  def subscribe(pid, symbols, sub_types, is_first_push \\ true) do
    GenServer.call(pid, {:subscribe, symbols, sub_types, is_first_push})
  end

  @doc """
  Unsubscribes from push data.

  `unsub_all: true` removes every subscription for those symbols
  across all sub-types (server-side ignores `sub_types` when set).
  Mirrors `Unsubscribe` (cmd_code 7) in `longbridge/openapi-go`.
  """
  @spec unsubscribe(pid(), [String.t()], [sub_type()], boolean()) :: :ok | {:error, term()}
  def unsubscribe(pid, symbols, sub_types, unsub_all \\ false) do
    GenServer.call(pid, {:unsubscribe, symbols, sub_types, unsub_all})
  end

  @doc """
  Sets a callback invoked on each `PushQuote` push event.

  The callback receives a `%Longbridge.Quote.V1.PushQuote{}` struct.
  Set this **before** `subscribe/4` (with `is_first_push: true`) so
  you don't miss events. Replaces any callback previously set for the
  `:quote` topic. Mirrors `QuoteContext::on_quote` from
  `longbridge/openapi-go`.
  """
  @spec set_on_quote(pid(), (map() -> any())) :: :ok
  def set_on_quote(pid, callback) when is_function(callback, 1) do
    put_push_callback(pid, :quote, callback)
  end

  @doc """
  Sets a callback invoked on each `PushDepth` push event.

  The callback receives a `%Longbridge.Quote.V1.PushDepth{}` struct.
  Mirrors `QuoteContext::on_depth` from `longbridge/openapi-go`.
  """
  @spec set_on_depth(pid(), (map() -> any())) :: :ok
  def set_on_depth(pid, callback) when is_function(callback, 1) do
    put_push_callback(pid, :depth, callback)
  end

  @doc """
  Sets a callback invoked on each `PushBrokers` push event.

  The callback receives a `%Longbridge.Quote.V1.PushBrokers{}` struct.
  Mirrors `QuoteContext::on_brokers` from `longbridge/openapi-go`.
  """
  @spec set_on_brokers(pid(), (map() -> any())) :: :ok
  def set_on_brokers(pid, callback) when is_function(callback, 1) do
    put_push_callback(pid, :brokers, callback)
  end

  @doc """
  Sets a callback invoked on each `PushTrade` push event.

  The callback receives a `%Longbridge.Quote.V1.PushTrade{}` struct.
  Mirrors `QuoteContext::on_trades` from `longbridge/openapi-go`.
  """
  @spec set_on_trades(pid(), (map() -> any())) :: :ok
  def set_on_trades(pid, callback) when is_function(callback, 1) do
    put_push_callback(pid, :trade, callback)
  end

  @doc """
  Alias for `set_on_trades/2`. Mirrors the upstream `OnTrade` method
  in `longbridge/openapi-go`.
  """
  @spec on_trade(pid(), (map() -> any())) :: :ok
  def on_trade(pid, callback), do: set_on_trades(pid, callback)

  @doc """
  Sets a callback for an arbitrary push topic.

  Use the predefined `set_on_quote/2`, `set_on_depth/2`,
  `set_on_brokers/2`, `set_on_trades/2` wrappers for the
  standard topics. Pass a custom string for niche cases.
  """
  @spec put_push_callback(pid(), atom() | String.t(), (map() -> any())) :: :ok
  def put_push_callback(pid, topic, callback) when is_function(callback, 1) do
    GenServer.cast(pid, {:put_push_callback, topic, callback})
  end

  @doc """
  Removes the callback for a push topic (`:quote`, `:depth`,
  `:brokers`, `:trade`, or a custom topic registered via
  `put_push_callback/3`).

  After removal, no callback fires for `topic`; the default callback
  (if set via `set_default_push_callback/2`) still does.
  """
  @spec remove_push_callback(pid(), atom() | String.t()) :: :ok
  def remove_push_callback(pid, topic) do
    GenServer.cast(pid, {:remove_push_callback, topic})
  end

  @doc """
  Sets a fallback callback invoked for any push topic without a
  registered handler.

  Useful when you want one function to handle every push type during
  bring-up or when you don't know the topic key up front (e.g. for
  custom server topics). The callback receives the raw decoded struct
  for the push event.
  """
  @spec set_default_push_callback(pid(), (map() -> any())) :: :ok
  def set_default_push_callback(pid, callback) when is_function(callback, 1) do
    GenServer.cast(pid, {:set_default_push_callback, callback})
  end

  # ── GenServer Callbacks ──────────────────────────────────

  @impl true
  def init({config, _opts}) do
    if config.token == nil and config.app_key == nil do
      {:stop, :missing_credentials}
    else
      conn_opts = [config: config, type: :quote, parent: self()]
      {:ok, conn} = WSConnection.start_link(conn_opts)

      # Local push-data cache. Mirrors the in-memory store in the
      # upstream Rust/Go SDKs (SecuritiesData). The realtime_* family
      # of methods reads from this store.
      {:ok, store} = RealtimeStore.start_link(owner: self())

      # Schedule the user_quote_profile fetch as a follow-up so it
      # doesn't block init/1. Mirrors longbridge/openapi/rust/src/quote/
      # core.rs::Core::connect().
      send(self(), :apply_user_quote_profile)

      schedule_heartbeat(config.heartbeat_interval)

      {:ok,
       %{
         conn: conn,
         config: config,
         store: store,
         # Recorded subscriptions, keyed by {sorted symbols, sorted sub_types},
         # so we can re-apply them after a WS reconnect instead of silently
         # losing push delivery.
         subscriptions: %{},
         push_callbacks: %{},
         default_push_callback: nil
       }}
    end
  end

  defp apply_rate_limits(conn) do
    # Build and send a UserQuoteProfileRequest via the WS connection.
    # Failures (timeout, decode error, missing rate_limit field) are
    # silently swallowed — we just fall back to no throttling.
    language = "en"
    req = %Q.UserQuoteProfileRequest{language: language}
    body = req |> Protox.encode() |> elem(1) |> IO.iodata_to_binary()

    try do
      case WSConnection.request(conn, @cmd_user_quote_profile, body) do
        {:ok, resp_bytes, _req_id} ->
          case Protox.decode(resp_bytes, Q.UserQuoteProfileResponse) do
            {:ok, %{rate_limit: entries}} when is_list(entries) ->
              if entries == [] do
                :ok
              else
                WSConnection.apply_rate_limits(conn, entries)
              end

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    catch
      _kind, _value -> :ok
    end
  end

  @impl true
  def handle_call(:session, _from, state) do
    reply = WSConnection.get_session(state.conn)
    {:reply, reply, state}
  end

  @impl true
  def handle_call(:request_timeout, _from, state) do
    {:reply, state.config.request_timeout, state}
  end

  @impl true
  def handle_call({:request, cmd_code, body, _timeout}, _from, state) do
    result = WSConnection.request(state.conn, cmd_code, body, state.config.request_timeout)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:subscribe, symbols, sub_types, is_first_push}, _from, state) do
    case send_subscribe(state, symbols, sub_types, is_first_push) do
      :ok ->
        {:reply, :ok, put_subscription(state, symbols, sub_types, is_first_push)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, symbols, sub_types, unsub_all}, _from, state) do
    case send_unsubscribe(state, symbols, sub_types, unsub_all) do
      :ok ->
        {:reply, :ok, drop_subscription(state, symbols, sub_types)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:realtime_quote, symbols}, _from, state) do
    {:reply, RealtimeStore.get_quote(state.store, symbols), state}
  end

  @impl true
  def handle_call({:realtime_depth, symbol}, _from, state) do
    {:reply, RealtimeStore.get_depth(state.store, symbol), state}
  end

  @impl true
  def handle_call({:realtime_brokers, symbol}, _from, state) do
    {:reply, RealtimeStore.get_brokers(state.store, symbol), state}
  end

  @impl true
  def handle_call({:realtime_trades, symbol, count}, _from, state) do
    {:reply, RealtimeStore.get_trades(state.store, symbol, count), state}
  end

  @impl true
  def handle_call(:reset_realtime_cache, _from, state) do
    _ = RealtimeStore.reset(state.store)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    send(state.conn, :heartbeat)
    schedule_heartbeat(state.config.heartbeat_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:longbridge, conn, {:connected, _session_id}}, %{conn: conn} = state) do
    # The WS connection (re)connected. Re-apply recorded subscriptions so
    # push delivery resumes after a reconnect instead of going silent.
    state = resubscribe(state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:longbridge, conn, msg}, %{conn: conn} = state) do
    send(self(), {:longbridge_push, msg})
    {:noreply, state, {:continue, {:process_push, msg}}}
  end

  # Forward push messages to the calling process. The caller should use
  # `receive` to handle `{:longbridge_push, msg}`. We also dispatch the
  # message to any callbacks registered via `set_on_quote/2` etc.
  @impl true
  def handle_info({:longbridge_push, _msg}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:apply_user_quote_profile, state) do
    apply_rate_limits(state.conn)
    {:noreply, state}
  end

  @impl true
  def handle_continue({:process_push, msg}, state) do
    dispatch_push(msg, state.push_callbacks, state.default_push_callback, state.store)
    {:noreply, state}
  end

  @impl true
  def handle_cast({:put_push_callback, topic, callback}, state) do
    {:noreply, %{state | push_callbacks: Map.put(state.push_callbacks, topic, callback)}}
  end

  @impl true
  def handle_cast({:remove_push_callback, topic}, state) do
    {:noreply, %{state | push_callbacks: Map.delete(state.push_callbacks, topic)}}
  end

  @impl true
  def handle_cast({:set_default_push_callback, callback}, state) do
    {:noreply, %{state | default_push_callback: callback}}
  end

  # ── Push event dispatch ───────────────────────────────

  defp dispatch_push({:push, cmd_code, body}, callbacks, default_callback, store) do
    topic = Map.get(@push_cmd_to_topic, cmd_code)

    case safe_decode_push(cmd_code, body) do
      {:ok, decoded} ->
        push_to_store(store, cmd_code, decoded)
        callback = topic && Map.get(callbacks, topic)

        cond do
          is_function(callback, 1) -> callback.(decoded)
          is_function(default_callback, 1) -> default_callback.(decoded)
          true -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp dispatch_push(_other, _callbacks, _default, _store), do: :ok

  defp decode_push(@push_cmd_quote, body),
    do: Protox.decode!(body, Q.PushQuote)

  defp decode_push(@push_cmd_depth, body),
    do: Protox.decode!(body, Q.PushDepth)

  defp decode_push(@push_cmd_brokers, body),
    do: Protox.decode!(body, Q.PushBrokers)

  defp decode_push(@push_cmd_trade, body),
    do: Protox.decode!(body, Q.PushTrade)

  defp decode_push(_cmd_code, body), do: body

  # Wraps Protox.decode! so a malformed body (e.g. the literal
  # "push-data" used in tests) doesn't crash the QuoteContext. We
  # silently drop undecodable events — they're still reachable via
  # Longbridge.WSConnection.subscribe_push/2.
  defp safe_decode_push(cmd_code, body) do
    {:ok, decode_push(cmd_code, body)}
  rescue
    _ -> {:error, :decode_failed}
  end

  defp push_to_store(store, @push_cmd_quote, %Q.PushQuote{} = push),
    do: RealtimeStore.put_quote(store, push)

  defp push_to_store(store, @push_cmd_depth, %Q.PushDepth{} = push),
    do: RealtimeStore.put_depth(store, push)

  defp push_to_store(store, @push_cmd_brokers, %Q.PushBrokers{} = push),
    do: RealtimeStore.put_brokers(store, push)

  defp push_to_store(store, @push_cmd_trade, %Q.PushTrade{} = push),
    do: RealtimeStore.put_trades(store, push)

  defp push_to_store(_store, _cmd, _decoded), do: :ok

  # ── Helpers ──────────────────────────────────────────────

  defp request(pid, cmd_code, req_msg, resp_module) do
    {:ok, iodata, _size} = Protox.encode(req_msg)
    body = IO.iodata_to_binary(iodata)
    req_timeout = GenServer.call(pid, :request_timeout)

    case GenServer.call(pid, {:request, cmd_code, body, req_timeout}, req_timeout + 5_000) do
      {:ok, resp_body, _req_id} ->
        decode_response(resp_body, resp_module)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_empty(pid, cmd_code, resp_module) do
    req_timeout = GenServer.call(pid, :request_timeout)

    case GenServer.call(pid, {:request, cmd_code, <<>>, req_timeout}, req_timeout + 5_000) do
      {:ok, resp_body, _req_id} ->
        decode_response(resp_body, resp_module)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Decodes a response body, turning Protox decode failures into
  # `{:error, {:decode_error, exception}}` so the public API contract
  # (`{:ok, _} | {:error, _}`) is preserved even when the server
  # returns a malformed payload (schema drift, truncated frame, etc.).
  defp decode_response(resp_body, resp_module) do
    {:ok, Protox.decode!(resp_body, resp_module)}
  rescue
    exception in [Protox.DecodingError] ->
      {:error, {:decode_error, exception}}
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  # ── Subscription tracking / reconnect re-apply ───────────

  defp send_subscribe(state, symbols, sub_types, is_first_push) do
    type_vals = Enum.map(sub_types, &Map.fetch!(@sub_type_map, &1))

    req = %Q.SubscribeRequest{
      symbol: symbols,
      sub_type: type_vals,
      is_first_push: is_first_push
    }

    case ws_request(state, @cmd_subscribe, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_unsubscribe(state, symbols, sub_types, unsub_all) do
    type_vals = Enum.map(sub_types, &Map.fetch!(@sub_type_map, &1))

    req = %Q.UnsubscribeRequest{
      symbol: symbols,
      sub_type: type_vals,
      unsub_all: unsub_all
    }

    case ws_request(state, @cmd_unsubscribe, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Encodes a request and sends it straight to the WS connection (not via
  # a self GenServer.call, which would deadlock from handle_info/handle_call).
  defp ws_request(state, cmd_code, req_msg) do
    {:ok, iodata, _size} = Protox.encode(req_msg)
    body = IO.iodata_to_binary(iodata)
    WSConnection.request(state.conn, cmd_code, body, state.config.request_timeout)
  end

  defp subscription_key(symbols, sub_types) do
    {Enum.sort(symbols), Enum.sort(sub_types)}
  end

  defp put_subscription(state, symbols, sub_types, is_first_push) do
    key = subscription_key(symbols, sub_types)

    %{
      state
      | subscriptions: Map.put(state.subscriptions, key, {symbols, sub_types, is_first_push})
    }
  end

  defp drop_subscription(state, symbols, sub_types) do
    key = subscription_key(symbols, sub_types)
    %{state | subscriptions: Map.delete(state.subscriptions, key)}
  end

  defp resubscribe(state) do
    Enum.each(state.subscriptions, fn {_key, {symbols, sub_types, is_first_push}} ->
      _ = send_subscribe(state, symbols, sub_types, is_first_push)
    end)

    state
  end

  defp period_code(:ONE_MINUTE), do: 1
  defp period_code(:FIVE_MINUTE), do: 5
  defp period_code(:FIFTEEN_MINUTE), do: 15
  defp period_code(:THIRTY_MINUTE), do: 30
  defp period_code(:SIXTY_MINUTE), do: 60
  defp period_code(:DAY), do: 1000
  defp period_code(:WEEK), do: 2000
  defp period_code(:MONTH), do: 3000
  defp period_code(:QUARTER), do: 3500
  defp period_code(:YEAR), do: 4000
  defp period_code(other) when is_integer(other), do: other

  defp trade_session_code(:NORMAL_TRADE), do: 0
  defp trade_session_code(:PRE_TRADE), do: 1
  defp trade_session_code(:POST_TRADE), do: 2
  defp trade_session_code(:OVERNIGHT_TRADE), do: 3
  defp trade_session_code(other) when is_integer(other), do: other

  # ── Warrant filter encoders ─────────────────────────

  defp warrant_sort_by_code(:last_done), do: 0
  defp warrant_sort_by_code(:change_rate), do: 1
  defp warrant_sort_by_code(:change_value), do: 2
  defp warrant_sort_by_code(:volume), do: 3
  defp warrant_sort_by_code(:turnover), do: 4
  defp warrant_sort_by_code(:outstanding_qty), do: 5
  defp warrant_sort_by_code(:leverage_ratio), do: 6
  defp warrant_sort_by_code(:implied_volatility), do: 7
  defp warrant_sort_by_code(:status), do: 8
  defp warrant_sort_by_code(other) when is_integer(other), do: other

  defp warrant_sort_order_code(:desc), do: 0
  defp warrant_sort_order_code(:asc), do: 1
  defp warrant_sort_order_code(other) when is_integer(other), do: other

  defp warrant_type_code(:call), do: 0
  defp warrant_type_code(:put), do: 1
  defp warrant_type_code(other) when is_integer(other), do: other

  defp warrant_expiry_code(:lt_3), do: 1
  defp warrant_expiry_code(:between_3_6), do: 2
  defp warrant_expiry_code(:between_6_12), do: 3
  defp warrant_expiry_code(:gt_12), do: 4
  defp warrant_expiry_code(other) when is_integer(other), do: other

  defp warrant_price_type_code(:in_bounds), do: 1
  defp warrant_price_type_code(:out_bounds), do: 2
  defp warrant_price_type_code(other) when is_integer(other), do: other

  defp warrant_status_code(:suspend), do: 2
  defp warrant_status_code(:prepare_list), do: 3
  defp warrant_status_code(:normal), do: 4
  defp warrant_status_code(other) when is_integer(other), do: other

  # Apply encoder `f` to every element of a list, dropping nils and
  # integers that come from already-encoded values. The proto expects
  # `repeated int32` so we always return a list of integers.
  defp encode_int_list(values, f) when is_list(values) do
    Enum.flat_map(values, fn
      nil -> []
      v when is_integer(v) -> [v]
      v -> [f.(v)]
    end)
  end

  defp encode_int_list(value, f), do: encode_int_list([value], f)

  defp normalize_date(<<y::4-bytes, ?-, m::2-bytes, ?-, d::2-bytes>>) when is_binary(y) do
    y <> m <> d
  end

  defp normalize_date(<<_::8-bytes>> = d), do: d
end
