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
  """

  use GenServer

  alias Longbridge.{Config, WSConnection}
  alias Longbridge.Quote.V1, as: Q

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

  @sub_type_map %{
    QUOTE: 1,
    DEPTH: 2,
    BROKERS: 3,
    TRADE: 4
  }

  # ── Client API ───────────────────────────────────────────

  @doc "Starts a QuoteContext linked to the calling process."
  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, {config, opts}, opts)
  end

  @doc "Returns the current session info."
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

  # ── Quote API Methods ────────────────────────────────────

  @doc "Queries security static info for given symbols."
  @spec static_info(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def static_info(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_security_static_info, req, Q.SecurityStaticInfoResponse)
  end

  @doc "Queries real-time security quotes."
  @spec quote(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def quote(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_security_quote, req, Q.SecurityQuoteResponse)
  end

  @doc "Queries option quotes."
  @spec option_quote(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def option_quote(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_option_quote, req, Q.OptionQuoteResponse)
  end

  @doc "Queries warrant quotes."
  @spec warrant_quote(pid(), [String.t()]) :: {:ok, struct()} | {:error, term()}
  def warrant_quote(pid, symbols) do
    req = %Q.MultiSecurityRequest{symbol: symbols}
    request(pid, @cmd_warrant_quote, req, Q.WarrantQuoteResponse)
  end

  @doc "Queries market depth (order book) for a security."
  @spec depth(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def depth(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_depth, req, Q.SecurityDepthResponse)
  end

  @doc "Queries broker queue for a security."
  @spec brokers(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def brokers(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_brokers, req, Q.SecurityBrokersResponse)
  end

  @doc "Queries broker participant IDs."
  @spec participant_broker_ids(pid()) :: {:ok, struct()} | {:error, term()}
  def participant_broker_ids(pid) do
    request_empty(pid, @cmd_participant_broker_ids, Q.ParticipantBrokerIdsResponse)
  end

  @doc "Queries recent trades for a security."
  @spec trades(pid(), String.t(), non_neg_integer()) :: {:ok, struct()} | {:error, term()}
  def trades(pid, symbol, count \\ 100) do
    req = %Q.SecurityTradeRequest{symbol: symbol, count: count}
    request(pid, @cmd_trade, req, Q.SecurityTradeResponse)
  end

  @doc "Queries intraday lines for a security."
  @spec intraday(pid(), String.t(), non_neg_integer()) :: {:ok, struct()} | {:error, term()}
  def intraday(pid, symbol, trade_session \\ 0) do
    req = %Q.SecurityIntradayRequest{symbol: symbol, trade_session: trade_session}
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
          non_neg_integer()
        ) ::
          {:ok, struct()} | {:error, term()}
  def candlesticks(
        pid,
        symbol,
        period \\ :DAY,
        count \\ 100,
        adjust_type \\ 0,
        trade_session \\ 0
      ) do
    period_val = period_code(period)

    req = %Q.SecurityCandlestickRequest{
      symbol: symbol,
      period: period_val,
      count: count,
      adjust_type: adjust_type,
      trade_session: trade_session
    }

    request(pid, @cmd_candlestick, req, Q.SecurityCandlestickResponse)
  end

  @doc "Queries option chain expiry dates for an underlying."
  @spec option_chain_date(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def option_chain_date(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_option_chain_date, req, Q.OptionChainDateListResponse)
  end

  @doc "Queries option chain strike info for a date."
  @spec option_chain_strike_info(pid(), String.t(), String.t()) ::
          {:ok, struct()} | {:error, term()}
  def option_chain_strike_info(pid, symbol, expiry_date) do
    req = %Q.OptionChainDateStrikeInfoRequest{symbol: symbol, expiry_date: expiry_date}
    request(pid, @cmd_option_chain_date_strike_info, req, Q.OptionChainDateStrikeInfoResponse)
  end

  @doc "Queries warrant issuer info."
  @spec warrant_issuer_info(pid()) :: {:ok, struct()} | {:error, term()}
  def warrant_issuer_info(pid) do
    request_empty(pid, @cmd_warrant_issuer_info, Q.IssuerInfoResponse)
  end

  @doc "Queries market trade period information."
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

  @doc "Queries security calc indexes."
  @spec calc_index(pid(), [String.t()], [non_neg_integer()]) :: {:ok, struct()} | {:error, term()}
  def calc_index(pid, symbols, calc_indexes) do
    req = %Q.SecurityCalcQuoteRequest{symbols: symbols, calc_index: calc_indexes}
    request(pid, @cmd_security_calc_index, req, Q.SecurityCalcQuoteResponse)
  end

  @doc "Queries capital flow intraday."
  @spec capital_flow_intraday(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def capital_flow_intraday(pid, symbol) do
    req = %Q.CapitalFlowIntradayRequest{symbol: symbol}
    request(pid, @cmd_capital_flow_intraday, req, Q.CapitalFlowIntradayResponse)
  end

  @doc "Queries capital flow distribution."
  @spec capital_flow_distribution(pid(), String.t()) :: {:ok, struct()} | {:error, term()}
  def capital_flow_distribution(pid, symbol) do
    req = %Q.SecurityRequest{symbol: symbol}
    request(pid, @cmd_capital_flow_distribution, req, Q.CapitalDistributionResponse)
  end

  @doc "Queries current subscriptions."
  @spec subscription(pid()) :: {:ok, struct()} | {:error, term()}
  def subscription(pid) do
    req = %Q.SubscriptionRequest{}
    request(pid, @cmd_subscription, req, Q.SubscriptionResponse)
  end

  @doc """
  Subscribes to real-time push data.

  `sub_types` can include: `:QUOTE`, `:DEPTH`, `:BROKERS`, `:TRADE`

  Push data is received as messages in the calling process:
  `{:longbridge, conn_pid, {:push, cmd_code, protobuf_body}}`

  Push command codes:
  - 101 — Quote push (`Longbridge.Quote.V1.PushQuote`)
  - 102 — Depth push (`Longbridge.Quote.V1.PushDepth`)
  - 103 — Broker push (`Longbridge.Quote.V1.PushBrokers`)
  - 104 — Trade push (`Longbridge.Quote.V1.PushTrade`)
  """
  @spec subscribe(pid(), [String.t()], [sub_type()], boolean()) :: :ok | {:error, term()}
  def subscribe(pid, symbols, sub_types, is_first_push \\ true) do
    type_vals = Enum.map(sub_types, &Map.fetch!(@sub_type_map, &1))

    req = %Q.SubscribeRequest{
      symbol: symbols,
      sub_type: type_vals,
      is_first_push: is_first_push
    }

    case request_raw(pid, @cmd_subscribe, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unsubscribes from push data."
  @spec unsubscribe(pid(), [String.t()], [sub_type()], boolean()) :: :ok | {:error, term()}
  def unsubscribe(pid, symbols, sub_types, unsub_all \\ false) do
    type_vals = Enum.map(sub_types, &Map.fetch!(@sub_type_map, &1))

    req = %Q.UnsubscribeRequest{
      symbol: symbols,
      sub_type: type_vals,
      unsub_all: unsub_all
    }

    case request_raw(pid, @cmd_unsubscribe, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ── GenServer Callbacks ──────────────────────────────────

  @impl true
  def init({config, _opts}) do
    if config.token == nil and config.app_key == nil do
      {:stop, :missing_credentials}
    else
      conn_opts = [config: config, type: :quote, parent: self()]
      {:ok, conn} = WSConnection.start_link(conn_opts)
      schedule_heartbeat(config.heartbeat_interval)

      {:ok, %{conn: conn, config: config}}
    end
  end

  @impl true
  def handle_call(:session, _from, state) do
    reply = WSConnection.get_session(state.conn)
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:request, cmd_code, body, _timeout}, _from, state) do
    result = WSConnection.request(state.conn, cmd_code, body, state.config.request_timeout)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    send(state.conn, :heartbeat)
    schedule_heartbeat(state.config.heartbeat_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:longbridge, conn, msg}, %{conn: conn} = state) do
    send(self(), {:longbridge_push, msg})
    {:noreply, state}
  end

  # Forward push messages to the calling process. The caller should use
  # `receive` to handle `{:longbridge_push, msg}`.
  @impl true
  def handle_info({:longbridge_push, _msg}, state) do
    {:noreply, state}
  end

  # ── Helpers ──────────────────────────────────────────────

  defp request(pid, cmd_code, req_msg, resp_module) do
    {:ok, iodata, _size} = Protox.encode(req_msg)
    body = IO.iodata_to_binary(iodata)

    case GenServer.call(pid, {:request, cmd_code, body, 10_000}, 15_000) do
      {:ok, resp_body, _req_id} ->
        decode_response(resp_body, resp_module)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_raw(pid, cmd_code, req_msg) do
    {:ok, iodata, _size} = Protox.encode(req_msg)
    body = IO.iodata_to_binary(iodata)
    GenServer.call(pid, {:request, cmd_code, body, 10_000}, 15_000)
  end

  defp request_empty(pid, cmd_code, resp_module) do
    case GenServer.call(pid, {:request, cmd_code, <<>>, 10_000}, 15_000) do
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

  defp normalize_date(<<y::4-bytes, ?-, m::2-bytes, ?-, d::2-bytes>>) when is_binary(y) do
    y <> m <> d
  end

  defp normalize_date(<<_::8-bytes>> = d), do: d
end
