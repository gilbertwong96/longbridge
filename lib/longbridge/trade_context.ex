defmodule Longbridge.TradeContext do
  @moduledoc """
  Trade context for Longbridge trading APIs.

  Manages a TCP connection to the trade endpoint for push
  subscriptions and provides HTTP-based APIs for order
  submission, order queries, account balance, positions,
  executions, and cash flow.

  ## Usage

      {:ok, ctx} = Longbridge.TradeContext.start_link(config)

      # Submit an order
      {:ok, %{"order_id" => order_id}} =
        Longbridge.TradeContext.submit_order(ctx,
          symbol: "700.HK",
          side: :buy,
          order_type: :lo,
          submitted_quantity: "100",
          time_in_force: :day,
          submitted_price: "50.00"
        )

      # Get today's orders
      {:ok, %{"orders" => orders}} =
        Longbridge.TradeContext.today_orders(ctx)

      # Account balance
      {:ok, %{"list" => balances}} =
        Longbridge.TradeContext.account_balance(ctx)

  ## Push events

  Subscribe to order status push after starting:

      {:ok, ctx} = Longbridge.TradeContext.start_link(config)
      :ok = Longbridge.TradeContext.subscribe(ctx, [:private])

  Events arrive as `{:longbridge_push, {dispatch_type, body}}`
  messages in the caller's mailbox.
  """

  use GenServer
  alias Longbridge.{Config, HTTPClient, WSConnection}

  @order_changed_topic "/v1/trade/order_changed"

  # ── Constants ──────────────────────────────────────────

  @topic_private "private"
  @topic_public "public"

  @type order_side :: :buy | :sell
  @type order_type ::
          :lo | :elo | :alo | :odd | :lit | :mit | :tslpamt | :tslppct | :market
  @type time_in_force :: :day | :gtc | :gtd
  @type order_status ::
          :not_reported
          | :replaced
          | :cancelled
          | :rejected
          | :new
          | :partially_filled
          | :filled
  @type market :: :us | :hk | :cn | :sg
  @type outside_rth :: :rth_only | :any_time | :overnight

  # ── Client API ──────────────────────────────────────────

  @doc "Starts a TradeContext linked to the calling process."
  @spec start_link(Config.t(), keyword()) :: GenServer.on_start()
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, {config, opts}, opts)
  end

  @doc "Returns the current session info from the underlying WS connection."
  @spec session(pid()) :: {:ok, String.t() | nil, integer() | nil} | {:error, term()}
  def session(pid) do
    GenServer.call(pid, :session)
  end

  # ── Order submission ────────────────────────────────────

  @doc """
  Submits a new order.

  See the [Longbridge Submit Order docs](https://open.longbridge.com/docs/trade/order/submit).

  ## Options

  - `:symbol` — Stock symbol in `ticker.region` format (required).
  - `:side` — `:buy` or `:sell` (required).
  - `:order_type` — Order type (required). See `t:order_type/0`.
  - `:submitted_quantity` — Quantity as a string (required).
  - `:time_in_force` — `:day`, `:gtc`, or `:gtd` (required).
  - `:submitted_price` — Price as a string. Required for LO/ELO/ALO/ODD/LIT.
  - `:trigger_price` — Trigger price. Required for LIT/MIT.
  - `:limit_offset` — Limit offset. Required for TSLPAMT/TSLPPCT when limit_depth_level is 0.
  - `:trailing_amount` — Trailing amount for TSLPAMT.
  - `:trailing_percent` — Trailing percent for TSLPPCT.
  - `:expire_date` — Expiry date as `"YYYY-MM-DD"`. Required for GTD.
  - `:outside_rth` — Outside RTH mode. For US stocks only.
  - `:remark` — Remark (max 255 chars).
  - `:limit_depth_level` — Bid/ask depth level (-5 to 5).
  - `:monitor_price` — Monitoring price for TSLPAMT/TSLPPCT.
  - `:trigger_count` — Trigger count (0-3).
  """
  @spec submit_order(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def submit_order(pid, opts) do
    body = Jason.encode!(transform_keys(Map.new(opts)))
    http_post(pid, "/v1/trade/order", body)
  end

  @doc """
  Replaces (amends) an existing order.

  ## Options

  - `:order_id` — The order to replace (required).
  - `:quantity` — New quantity as a string (required).
  - `:price` — New price as a string (required).
  """
  @spec replace_order(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def replace_order(pid, opts) do
    body = Jason.encode!(transform_keys(Map.new(opts)))
    http_put(pid, "/v1/trade/order", body)
  end

  @doc "Cancels an order by its order_id."
  @spec cancel_order(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def cancel_order(pid, order_id) do
    http_delete(pid, "/v1/trade/order", %{order_id: order_id})
  end

  # ── Order queries ───────────────────────────────────────

  @doc """
  Returns today's orders. Accepts optional filters:

  - `:symbol` — Stock symbol.
  - `:status` — List of order statuses (atoms).
  - `:side` — `:buy` or `:sell`.
  - `:market` — `:us`, `:hk`, `:cn`, `:sg`.
  - `:order_id` — A specific order ID.
  """
  @spec today_orders(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def today_orders(pid, opts \\ []) do
    params = transform_keys(Map.new(opts))
    http_get(pid, "/v1/trade/order/today", params)
  end

  @doc """
  Returns historical orders. Requires:

  - `:start_at` — Start time as a Unix timestamp (seconds).
  - `:end_at` — End time as a Unix timestamp (seconds).
  """
  @spec history_orders(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def history_orders(pid, opts \\ []) do
    params = transform_keys(Map.new(opts))
    http_get(pid, "/v1/trade/order/history", params)
  end

  @doc "Returns the detail for a single order."
  @spec order_detail(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def order_detail(pid, order_id) do
    http_get(pid, "/v1/trade/order", %{order_id: order_id})
  end

  # ── Executions ──────────────────────────────────────────

  @doc """
  Returns today's executions. Accepts optional filters:

  - `:symbol` — Stock symbol.
  - `:order_id` — A specific order ID.
  """
  @spec today_executions(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def today_executions(pid, opts \\ []) do
    params = transform_keys(Map.new(opts))
    http_get(pid, "/v1/trade/execution/today", params)
  end

  @doc """
  Returns historical executions. Requires:

  - `:start_at` — Start time as a Unix timestamp (seconds).
  - `:end_at` — End time as a Unix timestamp (seconds).
  """
  @spec history_executions(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def history_executions(pid, opts \\ []) do
    params = transform_keys(Map.new(opts))
    http_get(pid, "/v1/trade/execution/history", params)
  end

  # ── Account & positions ──────────────────────────────────

  @doc """
  Returns account balance across all currencies.
  Optionally filter by `currency` (e.g. `"HKD"`, `"USD"`).
  """
  @spec account_balance(pid(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def account_balance(pid, currency \\ nil) do
    params = if currency, do: %{currency: currency}, else: %{}
    http_get(pid, "/v1/asset/account", params)
  end

  @doc """
  Returns stock positions. Optionally filter by `symbols` (list of strings).
  """
  @spec stock_positions(pid(), [String.t()] | nil) :: {:ok, map()} | {:error, term()}
  def stock_positions(pid, symbols \\ nil) do
    params = if symbols, do: %{symbol: Enum.join(symbols, ",")}, else: %{}
    http_get(pid, "/v1/asset/stock", params)
  end

  @doc """
  Returns fund positions. Optionally filter by `symbols` (list of strings).
  """
  @spec fund_positions(pid(), [String.t()] | nil) :: {:ok, map()} | {:error, term()}
  def fund_positions(pid, symbols \\ nil) do
    params = if symbols, do: %{symbol: Enum.join(symbols, ",")}, else: %{}
    http_get(pid, "/v1/asset/fund", params)
  end

  # ── Cash flow ───────────────────────────────────────────

  @doc """
  Returns cash flow history.

  ## Options

  - `:start_at` — Start time as Unix timestamp (seconds).
  - `:end_at` — End time as Unix timestamp (seconds).
  - `:business_type` — `:cash`, `:stock`, or `:fund`.
  - `:symbol` — Stock symbol filter.
  - `:page` — Page number (default 1).
  - `:size` — Page size (default 50).
  """
  @spec cash_flow(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def cash_flow(pid, opts \\ []) do
    params = transform_keys(Map.new(opts))
    http_get(pid, "/v1/asset/cashflow", params)
  end

  # ── Margin ──────────────────────────────────────────────

  @doc "Returns the margin ratio for a given symbol."
  @spec margin_ratio(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def margin_ratio(pid, symbol) do
    http_get(pid, "/v1/risk/margin-ratio", %{symbol: symbol})
  end

  # ── Estimate max purchase ───────────────────────────────

  @doc """
  Estimates the maximum purchase quantity for a symbol.

  ## Options

  - `:symbol` — Stock symbol (required).
  - `:order_type` — Order type (required).
  - `:side` — `:buy` or `:sell` (required).
  - `:price` — Price as a string (optional).
  - `:currency` — Currency (optional).
  - `:fractional_shares` — Boolean (optional, default false).
  """
  @spec estimate_max_purchase_quantity(pid(), keyword()) :: {:ok, map()} | {:error, term()}
  def estimate_max_purchase_quantity(pid, opts) do
    params = transform_keys(Map.new(opts))
    http_get(pid, "/v1/trade/estimate/buy_limit", params)
  end

  # ── Subscribe / unsubscribe ─────────────────────────────

  @doc """
  Subscribes to trade push data. Accepts a list of topics:

  - `:private` — Order status updates.

  Set a callback with `set_on_order_changed/2` first to receive
  structured push events. Raw events arrive at the caller's mailbox
  as `{:longbridge_push, {:push, cmd_code, body}}` messages.
  """
  @spec subscribe(pid(), [atom()]) :: :ok | {:error, term()}
  def subscribe(pid, topics \\ [:private]) do
    topics_str = Enum.map(topics, &topic_to_string/1)
    req = %Longbridge.Trade.V1.Sub{topics: topics_str}

    case request_raw(pid, 16, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Unsubscribes from trade push data."
  @spec unsubscribe(pid(), [atom()]) :: :ok | {:error, term()}
  def unsubscribe(pid, topics \\ [:private]) do
    topics_str = Enum.map(topics, &topic_to_string/1)
    req = %Longbridge.Trade.V1.Unsub{topics: topics_str}

    case request_raw(pid, 17, req) do
      {:ok, _body, _req_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Sets a callback for a specific push topic.

  The callback receives the decoded JSON event map
  for the given topic (e.g., `@order_changed_topic`).

  See `set_on_order_changed/2` for a convenience wrapper.
  """
  @spec put_callback(pid(), String.t(), (map() -> any())) :: :ok
  def put_callback(pid, topic, callback) when is_function(callback, 1) do
    GenServer.cast(pid, {:put_push_callback, topic, callback})
  end

  @doc """
  Removes the callback for a specific push topic.
  """
  @spec remove_callback(pid(), String.t()) :: :ok
  def remove_callback(pid, topic) do
    GenServer.cast(pid, {:remove_push_callback, topic})
  end

  @doc """
  Sets a fallback callback invoked when push data arrives
  for a topic with no registered callback.
  """
  @spec set_default_push_callback(pid(), (map() -> any())) :: :ok
  def set_default_push_callback(pid, callback) when is_function(callback, 1) do
    GenServer.cast(pid, {:set_default_push_callback, callback})
  end

  @doc """
  Sets a callback for order-changed push events.

  The callback receives a map with fields like
  `order_id`, `status`, `filled_qty`, `executed_price`, etc.

  Set this **before** calling `subscribe/2` so you don't miss events.
  """
  @spec set_on_order_changed(pid(), (map() -> any())) :: :ok
  def set_on_order_changed(pid, callback) when is_function(callback, 1) do
    put_callback(pid, @order_changed_topic, callback)
  end

  @doc "Alias for `set_on_order_changed/2`."
  @spec on_order_changed(pid(), (map() -> any())) :: :ok
  def on_order_changed(pid, callback), do: set_on_order_changed(pid, callback)

  # ── GenServer Callbacks ──────────────────────────────────

  @impl true
  def init({config, opts}) do
    # Derive the WS-only OTP config from the caller's access-token config.
    # The OTP authenticates only the WebSocket handshake. HTTP endpoints
    # require the original access token, so we keep both side by side and
    # never let the WS rotation poison HTTP signing.
    {:ok, ws_config} = Config.with_socket_token(config)
    http_config = config
    finch = Keyword.get(opts, :finch)

    if Keyword.get(opts, :skip_connection, false) do
      {:ok,
       %{
         conn: nil,
         ws_config: ws_config,
         http_config: http_config,
         finch: finch,
         push_callbacks: %{},
         default_push_callback: nil
       }}
    else
      conn_opts = [config: ws_config, type: :trade, parent: self()]
      {:ok, conn} = Longbridge.WSConnection.start_link(conn_opts)
      schedule_heartbeat(ws_config.heartbeat_interval)

      {:ok,
       %{
         conn: conn,
         ws_config: ws_config,
         http_config: http_config,
         finch: finch,
         push_callbacks: %{},
         default_push_callback: nil
       }}
    end
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.http_config, state}

  @impl true
  def handle_call(:session, _from, state) do
    reply =
      case state.conn do
        nil -> {:ok, nil, nil}
        conn -> WSConnection.get_session(conn)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:request, cmd_code, body, timeout}, _from, state) do
    case Longbridge.WSConnection.request(state.conn, cmd_code, body, timeout) do
      {:ok, body, req_id} -> {:reply, {:ok, body, req_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:http_get, path, params}, _from, state) do
    {result, state} = signed_http_call(:get, path, "", state, params: build_query(params))
    {:reply, unwrap_http(result), state}
  end

  @impl true
  def handle_call({:http_post, path, body}, _from, state) do
    {result, state} = signed_http_call(:post, path, body, state)
    {:reply, unwrap_http(result), state}
  end

  @impl true
  def handle_call({:http_put, path, body}, _from, state) do
    {result, state} = signed_http_call(:put, path, body, state)
    {:reply, unwrap_http(result), state}
  end

  @impl true
  def handle_call({:http_delete, path, params}, _from, state) do
    {result, state} = signed_http_call(:delete, path, "", state, params: build_query(params))
    {:reply, unwrap_http(result), state}
  end

  # Performs an HTTP request, automatically retrying once on a 401
  # (token-expired) response by calling Config.refresh_access_token/2
  # and persisting the refreshed token into `state.http_config`.
  defp signed_http_call(method, path, body, state, extra_opts \\ []) do
    opts =
      case state.finch do
        nil -> extra_opts
        finch -> Keyword.put(extra_opts, :finch, finch)
      end

    result = HTTPClient.request(method, path, body, state.http_config, opts)

    case result do
      {:error, {:http_status, 401, _body}} ->
        retry_after_refresh(method, path, body, state, opts, result)

      _ ->
        {result, state}
    end
  end

  defp retry_after_refresh(method, path, body, state, opts, original_err) do
    case Config.refresh_access_token(state.http_config) do
      {:ok, new_config} ->
        state = %{state | http_config: new_config}
        retry_result = HTTPClient.request(method, path, body, new_config, opts)
        {retry_result, state}

      {:error, _refresh_err} ->
        {original_err, state}
    end
  end

  @impl true
  def handle_cast({:set_callback, callback}, state) do
    callbacks = Map.put(state.push_callbacks, @order_changed_topic, callback)
    {:noreply, %{state | push_callbacks: callbacks}}
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

  @impl true
  def handle_info(:heartbeat, state) do
    if state.conn, do: send(state.conn, :heartbeat)
    schedule_heartbeat(state.ws_config.heartbeat_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info({:longbridge, _conn, msg}, state) do
    {:noreply, state, {:continue, {:process_push, msg}}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_continue({:process_push, msg}, state) do
    dispatch_push(msg, state.push_callbacks, state.default_push_callback)
    {:noreply, state}
  end

  # ── Helpers ──────────────────────────────────────────────

  defp request_raw(pid, cmd_code, req_msg) do
    {:ok, iodata, _size} = Protox.encode(req_msg)
    body = IO.iodata_to_binary(iodata)
    GenServer.call(pid, {:request, cmd_code, body, 10_000}, 15_000)
  end

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp http_get(pid, path, params) do
    GenServer.call(pid, {:http_get, path, params}, 30_000)
  end

  defp http_post(pid, path, body) do
    GenServer.call(pid, {:http_post, path, body}, 30_000)
  end

  defp http_put(pid, path, body) do
    GenServer.call(pid, {:http_put, path, body}, 30_000)
  end

  defp http_delete(pid, path, params) do
    GenServer.call(pid, {:http_delete, path, params}, 30_000)
  end

  defp unwrap_http({:ok, %{"code" => 0, "data" => data}}) do
    {:ok, data}
  end

  defp unwrap_http({:ok, %{"code" => code, "message" => msg}}) do
    {:error, {:api_error, code, msg}}
  end

  defp unwrap_http({:ok, other}) do
    {:ok, other}
  end

  defp unwrap_http({:error, reason}) do
    {:error, reason}
  end

  defp build_query(params) when params == %{}, do: ""

  defp build_query(params) do
    Enum.map_join(params, "&", fn {k, v} -> "#{k}=#{encode_param(v)}" end)
  end

  defp encode_param(v) when is_list(v), do: Enum.join(v, ",")
  defp encode_param(v) when is_binary(v), do: URI.encode(v)
  defp encode_param(v), do: to_string(v)

  defp topic_to_string(:private), do: @topic_private
  defp topic_to_string(:public), do: @topic_public
  defp topic_to_string(s) when is_binary(s), do: s

  # ── Key/value transforms (atom → API-compatible string) ──

  defp transform_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {transform_key(k), transform_value(v)} end)
  end

  defp transform_key(k) when is_atom(k), do: Atom.to_string(k)
  defp transform_key(k) when is_binary(k), do: k

  defp transform_value(v) when is_atom(v) do
    v |> Atom.to_string() |> Macro.camelize()
  end

  defp transform_value(v) when is_list(v) do
    Enum.map(v, &transform_value/1)
  end

  defp transform_value(v), do: v

  # ── Push event processing ───────────────────────────────

  defp dispatch_push({:push, 18, body}, callbacks, default_callback) do
    notif = Protox.decode!(body, Longbridge.Trade.V1.Notification)

    if notif.topic != "" and notif.content_type == :CONTENT_JSON and notif.data != "" do
      case Jason.decode(notif.data) do
        {:ok, event} ->
          if callback = Map.get(callbacks, notif.topic) do
            callback.(event)
          else
            if default_callback, do: default_callback.(event)
          end

        _ ->
          :ok
      end
    end
  end

  defp dispatch_push({:push, _cmd_code, _body}, _callbacks, nil), do: :ok

  defp dispatch_push({:push, _cmd_code, body}, _callbacks, default_callback) do
    case Jason.decode(body) do
      {:ok, event} -> default_callback.(event)
      _ -> :ok
    end
  end

  defp dispatch_push(_other, _callbacks, _default), do: :ok
end
