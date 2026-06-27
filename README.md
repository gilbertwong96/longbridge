# Longbridge

Elixir SDK for the [Longbridge OpenAPI](https://open.longbridge.com) trading platform — real-time market data, push subscriptions, and (in-progress) trading APIs for US, HK, SG, and CN markets.

The SDK speaks Longbridge's binary protocol directly over TCP: 2-byte handshake, then Protobuf-encoded request/response and push frames with a custom 11/10/5-byte header layout. There is no JSON-over-HTTP path; this library is a faithful re-implementation of the wire format, not an HTTP client.

> **Status: beta.** The quote endpoint is feature-complete; the trade endpoint supports subscription, order submission, position queries, account balance, and execution history via the Longbridge REST API. The API is subject to change before 0.1.0.

## Installation

The package is not yet published to Hex. Add it to your `mix.exs` via a git dep:

```elixir
def deps do
  [
    {:longbridge, github: "longbridge/longbridge", tag: "0.1.0"}
  ]
end
```

`protoc` is a build-time dependency of `protox` (one of the transitive deps). On macOS:

```sh
brew install protobuf
```

## Quick start

```elixir
config = Longbridge.Config.new(
  token: System.fetch_env!("LONGBRIDGE_TOKEN"),
  app_key: System.fetch_env!("LONGBRIDGE_APP_KEY"),
  app_secret: System.fetch_env!("LONGBRIDGE_APP_SECRET")
)

{:ok, quote_ctx} = Longbridge.QuoteContext.start_link(config)

# One-shot request
{:ok, %Longbridge.Quote.V1.SecurityQuote{} = quote} =
  Longbridge.QuoteContext.quote(quote_ctx, ["AAPL.US", "700.HK"])

IO.inspect(quote)

# Subscribe to real-time push
:ok = Longbridge.QuoteContext.subscribe(quote_ctx, ["AAPL.US"], [:QUOTE])

# Push frames arrive as messages in the *caller* process
receive do
  {:longbridge_push, {:push, 101, body}} ->
    IO.inspect(Protox.decode!(body, Longbridge.Quote.V1.PushQuote))
end
```

## Configuration

`Longbridge.Config` holds everything needed to open a connection:

| Field | Default | Notes |
| --- | --- | --- |
| `token` | `nil` | OAuth access token. **Required**; `Connection` stops with `{:error, :no_token}` if nil. |
| `app_key` / `app_secret` | `nil` | App credentials (used to sign HTTP requests, e.g. for token refresh). |
| `expired_at` | `nil` | Unix timestamp when `token` expires. Set after `refresh_access_token/2`. |
| `http_url` | `https://openapi.longbridge.{com,cn}` | HTTP API base, used by `refresh_access_token/2`. |
| `china` | `false` | When true, switch to `.longbridge.cn` endpoints for mainland connectivity. |
| `quote_host` / `quote_port` | `openapi-quote.longbridge.{com,cn}`:2020 | Override for staging or proxies. |
| `trade_host` / `trade_port` | `openapi-trade.longbridge.{com,cn}`:2020 | Same. |
| `transport` | `:tcp` | `:websocket` is reserved for a future WebSocket transport. |

To inject custom HTTP/WS request headers (e.g. `X-Forwarded-For`,
custom auth, tenant routing), pass `:headers` as a list of
`{name, value}` tuples. Mirrors `Config::header(key, value)` from
the Rust SDK (4.0.6).

```elixir
config = Longbridge.Config.new(
  token: "...",
  app_key: "...",
  app_secret: "...",
  headers: [{"X-Forwarded-For", "1.2.3.4"}, {"X-Tenant", "acme"}]
)
```

The headers are appended to every signed HTTP request and to the
WebSocket upgrade request.

## Refreshing the access token (legacy API key)

The legacy API Key `access_token` expires after 90 days. To obtain a
new one, call `Longbridge.Config.refresh_access_token/2` and use the returned
config. The new `token` and `expired_at` are set on the result.

```elixir
{:ok, new_config} = Longbridge.Config.refresh_access_token(config)
{:ok, quote_ctx} = Longbridge.QuoteContext.start_link(new_config)
```

Internally this calls Longbridge's `GET /v1/token/refresh` HTTP
endpoint, signed with HMAC-SHA256 using the same scheme as the
official Python / Go SDKs. No new dependency beyond the existing
`finch` (HTTP) and `jason` (JSON) deps is required.

## Working with monetary values

Longbridge returns monetary fields as strings to preserve
precision. The `Longbridge.Decimal` helper provides two layers
of support:

```elixir
# No dependency required — returns int or float:
price = Longbridge.Decimal.parse_number("0.0723")

# For exact arithmetic, add :decimal to your app's deps and use:
dec = Longbridge.Decimal.to_bigdecimal("3241500000000")
```

`to_bigdecimal/1` and `sum_bigdecimal/1` raise `ArgumentError` with
a hint if `:decimal` is not loaded.

## OAuth 2.0 (browser flow)

```elixir
# Desktop / interactive (browser available)
{:ok, config} = Longbridge.OAuth.authorize("your-client-id")
{:ok, ctx} = Longbridge.QuoteContext.start_link(config)
```

The first call opens a browser, exchanges the code for a token, and
persists it to `~/.longbridge/openapi/tokens/<client_id>`. Subsequent
calls reuse the cached token transparently.

If you don't have a `client_id` yet, register one first:

```elixir
{:ok, client_id} = Longbridge.OAuth.register_client("My App")
```

## OAuth 2.0 (headless server)

OAuth 2.0 in Longbridge only supports `authorization_code` (browser
required) and `refresh_token` grants. For server-side programs,
authorize once on a developer's workstation, then copy the token
file to the server.

## OAuth 2.0 (custom token storage)

The default storage writes tokens to
`~/.longbridge/openapi/tokens/<client_id>`. To plug in Redis,
Vault, an encrypted file, or anything else, implement the
`Longbridge.OAuth.TokenStorage` behaviour and pass it via the
`:storage` option:

```elixir
defmodule MyApp.RedisStorage do
  @behaviour Longbridge.OAuth.TokenStorage

  @impl true
  def load(client_id) do
    case Redix.command(:redix, ["GET", "oauth:token:#{client_id}"]) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, json} -> decode(json)
      {:error, _} -> {:error, :not_found}
    end
  end

  @impl true
  def save(client_id, token) do
    Redix.command(:redix, ["SET", "oauth:token:#{client_id}", Jason.encode!(token)])
    :ok
  end
end

Longbridge.OAuth.authorize("client-id", storage: MyApp.RedisStorage)
```

The `:storage` option is supported by `authorize/2`,
`refresh_token/2`, `load_token/2`, and `export_token/2`.



```
# On dev machine (browser available)
Longbridge.OAuth.authorize("your-client-id")
# → writes ~/.longbridge/openapi/tokens/<client_id>

# Copy that file to the server (same path)

# On server
{:ok, config} = Longbridge.OAuth.load_token("your-client-id")
```

`load_token/1` auto-refreshes expired tokens via the `refresh_token`
grant. The `Longbridge.OAuth` module's full API:

- `authorize/2` — full browser flow
- `load_token/1` — load from disk, auto-refresh if expired
- `export_token/1` — export for cross-machine copy / secret manager
- `refresh_token/2` — manual refresh
- `register_client/1` — register a new OAuth client
- `authorize_url/5` — build the authorization URL (testable)
- `pkce_challenge/1` — PKCE S256 helper (testable)
| `gzip_threshold` | `1024` bytes | Bodies ≥ this size will be gzipped on send. |
| `heartbeat_interval` | `15_000` ms | Client→server keep-alive cadence. |
| `request_timeout` | `10_000` ms | Per-request timeout. |

`config.token` must be a fresh OAuth token from [open.longbridge.com](https://open.longbridge.com). Token refresh is the caller's responsibility — this SDK does not implement the OAuth flow.

## Architecture

```
lib/
├── longbridge.ex                # top-level module, public entry, docs
└── longbridge/
    ├── _protos.ex              # use Protox, files: [protos/*.proto] — code-gen entry
    ├── alert_context.ex         # price alert management (add/enable/disable/delete)
    ├── application.ex           # supervision tree, starts Longbridge.Finch pool
    ├── asset_context.ex         # account statement download
    ├── calendar_context.ex      # financial calendar (earnings, dividends, IPOs, macro)
    ├── config.ex                # Longbridge.Config struct, refresh_access_token/2
    ├── connection.ex            # TCP GenServer (one per endpoint)
    ├── content_context.ex       # news, community topics, announcements
    ├── dca_context.ex           # dollar-cost averaging plan management
    ├── fundamental_context.ex   # financial reports, analyst ratings, dividends, valuation
    ├── http_client.ex           # HMAC-SHA256 signed HTTP requests via Finch
    ├── market_context.ex        # market status, broker holdings, indices, anomaly alerts
    ├── oauth.ex                 # OAuth 2.0 Authorization Code flow with PKCE
    ├── portfolio_context.ex     # exchange rates, portfolio P&L analysis
    ├── protocol.ex              # packet pack/unpack + wire-format constants
    ├── protocol/header.ex       # 11/10/5-byte header encode/decode
    ├── quote_context.ex         # public API: 20+ quote methods
    ├── sharelist_context.ex     # community sharelist management
    └── trade_context.ex         # public API: orders, positions, account, executions, push
protos/
├── control.proto                # Auth, Heartbeat, Close
├── quote.proto                  # Market data (securities, quotes, depth, brokers, etc.)
└── trade.proto                  # Trade, order, notification messages
```

### Wire format

A Longbridge frame is:

```
┌─────────────────────────────────────────────────────────────┐
│ header (11 / 10 / 5 bytes, big-endian)                      │
│   type:4 │ v:1 │ g:1 │ res:2 │ cmd:8 │ ...                 │
├─────────────────────────────────────────────────────────────┤
│ body   (Protobuf-encoded, ≤ 16 MiB)                        │
├─────────────────────────────────────────────────────────────┤
│ optional nonce (8) + signature (16)  when v=1                │
└─────────────────────────────────────────────────────────────┘
```

The handshake is two fixed bytes, `<<0b00010001, 0b00001001>>` (version=1, codec=protobuf, platform=OpenAPI=9). See `Longbridge.Protocol.handshake/0`.

### Connection lifecycle

`Longbridge.Connection` is a `GenServer` that owns the raw `:gen_tcp` socket. Its lifecycle is driven by `handle_continue/2`:

```
init  →  do_connect  →  do_handshake  →  do_auth  (synchronous receive)  →  idle
```

After auth succeeds, the connection enters active mode, sends a heartbeat every `heartbeat_interval`, dispatches response packets to in-flight `request_id` callers, and forwards push packets to subscribed context processes.

### Push data flow

Contexts subscribe themselves to the connection on `start_link/2` via `Longbridge.Connection.subscribe_push/2`. When a push frame arrives:

1. The connection's `process_data/2` decodes the packet.
2. The connection's `dispatch_packet/3` sends `{:longbridge, conn_pid, {:push, cmd_code, body}}` to every subscriber.
3. Each context receives this message, re-dispatches as `{:longbridge_push, msg}` to its own caller process, and the user pattern-matches in their own process.

The context's caller must be alive to receive push messages — `Longbridge.QuoteContext.start_link/2` is the right way to spawn one per long-running process.

For typed callbacks instead of mailbox pattern-matching, `Longbridge.QuoteContext` also supports:

```elixir
QuoteContext.set_on_quote(ctx, fn push ->
  IO.inspect(push.symbol)
end)

QuoteContext.set_on_depth(ctx, fn depth -> ... end)
QuoteContext.set_on_brokers(ctx, fn brokers -> ... end)
QuoteContext.set_on_trades(ctx, fn trades -> ... end)

# Fallback for any topic
QuoteContext.set_default_push_callback(ctx, fn msg -> ... end)
```

Each callback receives the decoded proto struct (`Longbridge.Quote.V1.PushQuote`, `PushDepth`, `PushBrokers`, or `PushTrade`). Mailbox delivery still works alongside the callbacks.

## API reference

### `Longbridge.QuoteContext`

| Method | Sub-command | Notes |
| --- | --- | --- |
| `user_quote_profile/2` | `QueryUserQuoteProfile` (4) | `language` option, defaults to `"en"`. |
| `static_info/2` | `QuerySecurityStaticInfo` (10) | |
| `quote/2` | `QuerySecurityQuote` (11) | |
| `option_quote/2` | `QueryOptionQuote` (12) | |
| `warrant_quote/2` | `QueryWarrantQuote` (13) | |
| `depth/2` | `QueryDepth` (14) | |
| `brokers/2` | `QueryBrokers` (15) | |
| `participant_broker_ids/1` | `QueryParticipantBrokerIds` (16) | |
| `trades/3` | `QueryTrade` (17) | `count` defaults to 100. |
| `intraday/3` | `QueryIntraday` (18) | `trade_session` defaults to 0. |
| `candlesticks/6` | `QueryCandlestick` (19) | `period` accepts `:DAY`, `:MINUTE`, `:WEEK`, etc. |
| `history_candlesticks_by_offset/3` | `QueryHistoryCandlestick` (27) | Walks forward/backward from a date. `direction: :forward | :backward`. |
| `history_candlesticks_by_date/3` | `QueryHistoryCandlestick` (27) | Fetches within a `start_date`/`end_date` range. |
| `option_chain_date/2` | `QueryOptionChainDate` (20) | |
| `option_chain_strike_info/3` | `QueryOptionChainDateStrikeInfo` (21) | |
| `warrant_issuer_info/1` | `QueryWarrantIssuerInfo` (22) | |
| `warrant_list/2` | `QueryWarrantFilterList` (23) | Filtered HK warrant list. Options: `:symbol`, `:language`, `:sort_by`, `:sort_order`, `:type`, `:expiry_date`, `:status`, `:price_type`, `:issuer`. |
| `market_trade_period/1` | `QueryMarketTradePeriod` (8) | |
| `market_trade_day/4` | `QueryMarketTradeDay` (9) | |
| `calc_index/3` | `QuerySecurityCalcIndex` (26) | `calc_indexes` is a list of `CalcIndex` atoms. |
| `capital_flow_intraday/2` | `QueryCapitalFlowIntraday` (24) | |
| `capital_flow_distribution/2` | `QueryCapitalFlowDistribution` (25) | |
| `subscription/1` | `Subscription` (5) | |
| `subscribe/3` | `Subscribe` (6) | `sub_types` ∈ `{:QUOTE, :DEPTH, :BROKERS, :TRADE}`. |
| `unsubscribe/3` | `Unsubscribe` (7) | |

### `Longbridge.TradeContext`

**Push & subscription**

| Method | Description |
| --- | --- |
| `subscribe/2` | Subscribe to trade push topics (`:private` for orders) |
| `unsubscribe/2` | Unsubscribe from trade push |
| `put_callback/3` | Register a topic-specific callback (e.g. `"/v1/trade/order_changed"`) |
| `remove_callback/2` | Remove a topic callback |
| `set_default_push_callback/2` | Fallback callback for unregistered topics |
| `set_on_order_changed/2` | Convenience wrapper for order-changed events |
| `on_order_changed/2` | Alias for `set_on_order_changed/2` |

**Orders** (HTTP — REST API)

| Method | Description |
| --- | --- |
| `submit_order/2` | Place a new order |
| `replace_order/2` | Replace an existing order |
| `cancel_order/2` | Cancel an order by ID |
| `today_orders/2` | List today's orders |
| `history_orders/2` | Search historical orders |
| `order_detail/2` | Get a single order by ID |

**Executions** (HTTP)

| Method | Description |
| --- | --- |
| `today_executions/2` | List today's fills |
| `history_executions/2` | Search historical fills |

**Account & positions** (HTTP)

| Method | Description |
| --- | --- |
| `account_balance/2` | Get cash / buying power |
| `stock_positions/2` | List stock holdings |
| `fund_positions/2` | List fund holdings |

### `Longbridge.AssetContext` (HTTP)

| Method | Description |
| --- | --- |
| `statements/2` | List account statements (daily/monthly) |
| `download_url/2` | Get presigned download URL for a statement file |

### `Longbridge.MarketContext` (HTTP)

| Method | Description |
| --- | --- |
| `trading_days/4` | Trading days between two dates |
| `market_session/2` | Current trading session for a market |
| `broker_holdings/2` | Broker holdings (HK stocks) |
| `ah_premium/2` | A/H share premium data |
| `trade_status/2` | Intraday trade status for a symbol |
| `index_constituents/2` | Constituents of a market index |
| `anomaly_alerts/1` | Market anomaly alerts |
| `top_movers/2` | Stocks with anomalous 20d price movement + linked news |
| `rank_categories/1` | List rank categories for `rank_list/3` |
| `rank_list/3` | Ranked securities for a category (adds `ib_` prefix automatically) |

### `Longbridge.ContentContext` (HTTP)

| Method | Description |
| --- | --- |
| `news/2` | News articles with filtering/pagination |
| `topics/2` | Community topics/posts |
| `my_topics/2` | Topics created by the current authenticated user |
| `create_topic/2` | Create a community topic; returns `{:ok, topic_id}` |
| `topic_detail/2` | Single topic by ID |
| `list_topic_replies/3` | Replies for a topic |
| `create_topic_reply/3` | Post a reply to a topic |
| `announcements/2` | Company announcements |

### `Longbridge.FundamentalContext` (HTTP)

| Method | Description |
| --- | --- |
| `company_profile/2` | Company profile / overview |
| `financial_reports/3` | Income, balance, cash flow reports |
| `analyst_ratings/2` | Analyst ratings and targets |
| `dividends/2` | Dividend history |
| `valuation/2` | PE, PB, PS metrics |
| `shareholders/2` | Shareholder distribution |
| `etf_asset_allocation/2` | ETF asset allocation (holdings, regional, asset class, industry) |
| `filings/2` | Regulatory filings for a symbol (e.g. SEC 10-K, 10-Q, insider forms) |
| `macroeconomic_indicators/2` | List macroeconomic indicators for a country |
| `macroeconomic/3` | Historical data for a specific macroeconomic indicator |
| `valuation_comparison/4` | Compare valuation metrics across stocks (auto-selects peers when `comparison_symbols` is `nil`) |

### `Longbridge.CalendarContext` (HTTP)

| Method | Description |
| --- | --- |
| `earnings/4` | Upcoming earnings dates |
| `dividend_dates/4` | Dividend schedule |
| `stock_splits/4` | Stock split calendar |
| `ipo_calendar/4` | IPO calendar |
| `macro_events/4` | Macro economic event dates |
| `market_closures/2` | Market closure dates (holidays) |

### `Longbridge.PortfolioContext` (HTTP)

| Method | Description |
| --- | --- |
| `exchange_rates/3` | Real-time exchange rates |
| `portfolio_pl/2` | Portfolio P&L analysis |
| `portfolio_positions/1` | Portfolio position list |

### `Longbridge.AlertContext` (HTTP)

| Method | Description |
| --- | --- |
| `add_alert/2` | Create a price alert |
| `list_alerts/1` | List active price alerts |
| `update/3` | Update an alert (enable/disable) — re-sends the full item, use this instead of `enable_alert`/`disable_alert` |
| `enable_alert/2` | _Deprecated._ Enable a price alert by `alert_id` (may fail server-side for alerts created through `add_alert/2`). |
| `disable_alert/2` | _Deprecated._ Disable a price alert by `alert_id`. |
| `delete_alert/2` | Delete one or more price alerts by id (string or list of strings) |

### `Longbridge.DCAContext` (HTTP)

| Method | Description |
| --- | --- |
| `create_plan/2` | Create a DCA plan |
| `list_plans/2` | List DCA plans |
| `plan_detail/2` | Get plan details |
| `update_plan/2` | Update an existing plan |
| `pause_plan/2` | Pause an active plan |
| `resume_plan/2` | Resume a paused plan |
| `delete_plan/2` | Delete a plan |

### `Longbridge.SharelistContext` (HTTP)

| Method | Description |
| --- | --- |
| `create/2` | Create a new sharelist |
| `list/2` | List owned sharelists |
| `detail/2` | Get symbols in a sharelist |
| `rename/3` | Rename a sharelist |
| `add_symbols/3` | Add symbols to a sharelist |
| `remove_symbols/3` | Remove symbols from a sharelist |
| `delete/2` | Delete a sharelist |

### `Longbridge.ScreenerContext` (HTTP)

| Method | Description |
| --- | --- |
| `recommend_strategies/2` | Pre-defined recommended screener strategies for a market |
| `user_strategies/2` | Current user's saved screener strategies |
| `strategy/2` | A single screener strategy by ID (strips `filter_` prefix from `filter.filters[].key`) |
| `search/3` | Run a screener search — Mode A (`strategy_id:`) or Mode B (typed `conditions:`) |
| `indicators/1` | List available screener indicators (strips `filter_` prefix; builds `tech_values` from `tech_indicators`) |

### `Longbridge.QuoteHTTPContext` (HTTP)

| Method | Description |
| --- | --- |
| `short_positions/3` | Short interest data (`.HK` = HKEX daily, others = US FINRA bi-monthly) |
| `option_volume/2` | Real-time call/put volume snapshot for an option symbol |
| `option_volume_daily/4` | Daily option volume for a symbol within a date range |
| `update_pinned/4` | Pin or unpin a security to the top of a watchlist group |
| `security_list/2` | List securities available for a market (market, category, page, count) |
| `market_temperature/2` | Current market temperature (0-100) for a market |
| `history_market_temperature/4` | Historical market temperature within a YYYY-MM-DD date range |
| `short_trades/3` | Recent short-selling trades (`.HK` → `/hk`, others → `/us`; count, last_timestamp) |
| `watchlist_groups/1` | List watchlist groups |
| `create_watchlist_group/3` | Create a watchlist group; returns `{:ok, group_id}` |
| `delete_watchlist_group/3` | Delete a watchlist group (`purge: false` by default) |
| `update_watchlist_group/5` | Update a watchlist group (`:add | :remove | :replace` modes) |

### Push command codes (consumer-side)

| Code | Message | Decode with |
| --- | --- | --- |
| 101 | `PushQuote` | `Longbridge.Quote.V1.PushQuote` |
| 102 | `PushDepth` | `Longbridge.Quote.V1.PushDepth` |
| 103 | `PushBrokers` | `Longbridge.Quote.V1.PushBrokers` |
| 104 | `PushTrade` | `Longbridge.Quote.V1.PushTrade` |
| 18  | `Notification` (trade) | `Longbridge.Trade.V1.Notification` |

## Development

```sh
mix deps.get
mix compile        # generates 98 proto modules on first build
mix test           # unit tests
mix docs           # ExDoc HTML in doc/
```

The full quality gate is one command:

```sh
mix ci
```

It runs, in order: `compile --all-warnings --warnings-as-errors`, `format --check-formatted`, `credo --strict`, `deps.unlock --check-unused`, `deps.audit`, `xref graph --label compile-connected --fail-above 0`, `dialyzer`, `ex_dna` (duplication), `reach.check --dead-code --smells`. See `mix.exs` for the alias definition.

### Proto specs

The four `.proto` files under `protos/` are vendored from [`longbridge/openapi-protobufs`](https://github.com/longbridge/openapi-protobufs), pinned to tag `gen/go/v0.7.0` via a git dep in `mix.exs`. To upgrade:

```sh
# 1. bump the tag in mix.exs
# 2. mix deps.get
# 3. sync the vendored files
cp deps/openapi_protobuf_specs/control/*.proto protos/
cp deps/openapi_protobuf_specs/quote/*.proto   protos/
cp deps/openapi_protobuf_specs/trade/*.proto   protos/
# 4. mix compile && mix test
```

Don't hand-edit files under `protos/` — the next sync will clobber your changes.

## License

TBD. See the LICENSE file once one is added.
