# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0]

### Added

- **`Longbridge.QuoteContext.candlesticks_paginated/3`** — fetch up to N
  K-line bars across multiple `candlesticks/3` calls. Deduplicates by
  timestamp to avoid infinite loops when the API returns the same recent
  bars on every call (e.g. paper-trading accounts where the historical
  window is unavailable), and returns candles sorted oldest-first.
  Rate-limited by the SDK's connection-level throttle.

### Fixed

- **`mix credo --strict` `FunctionArity` finding** —
  `Longbridge.QuoteContext.paginate/9` took 9 parameters, exceeding
  the max-8 limit and causing the strict Credo run to exit with rc=8.
  The two loop-state arguments (`acc`, `seen`) have been collapsed
  into a single `state` map, dropping the arity to 8. Public API is
  unchanged.
- **README `Longbridge.TradeContext.cancel_order/2` example** — the
  install/quickstart snippet destructured the return as `:ok`; the
  function's `@spec` returns `{:ok, map()}`. The snippet now pattern-
  matches the actual tuple shape.

## [0.1.2]

### Changed

- **Pre-generated protobuf modules** — `lib/longbridge/_protos.ex` now ships
  the compiled output of `mix protox.generate` instead of using `use Protox,
  files: [...]`. **Downstream consumers no longer need `protoc` installed** to
  compile the SDK. `protoc` is only required for maintainers regenerating the
  modules after a `.proto` change (run `mix gen_protos`). The `protos/` source
  files are kept in the package so consumers can inspect the schema.
- **Removed the `protoc` build-time requirement** from the README installation
  instructions (no longer needed thanks to pre-generated modules).

## [0.1.1]

### Changed

- **Dropped the `jason` dependency** in favor of the built-in `JSON` module
  (Elixir 1.20+). All encode/decode call sites in `lib/` and `test/` now use
  `JSON.encode!/1` / `JSON.decode/1`. `jason` remains only as a transitive
  dependency of `req` and `ex_doc`.
- **Removed the redundant License section** from the README; the MIT LICENSE
  file now ships with the package and is linked via the badge.

## [0.1.0] — Initial beta release

Initial public beta. The SDK implements the Longbridge OpenAPI binary protocol
over WebSocket for the **quote** and **trade** endpoints, plus 8 HTTP-backed
context modules for alerts, asset, calendar, content, DCA, fundamental,
market, portfolio, screener, sharelist, and quote-HTTP endpoints.

The SDK is feature-complete against the upstream protocol for the pinned
`longbridge/openapi-protobufs@gen/go/v0.7.0` protobuf definitions.

### Added

- **`Longbridge.QuoteContext` realtime push-data cache** — `realtime_quote/2`,
  `realtime_depth/2`, `realtime_brokers/2`, `realtime_trades/3`, and
  `reset_realtime_cache/1`. Mirrors the in-memory store pattern from the
  upstream Rust/Go SDKs, backed by an ETS table owned by the context.
- **`Longbridge.QuoteContext.RealtimeStore`** — internal GenServer that owns
  the `:longbridge_quote_realtime` ETS table.
- **`Longbridge.QuoteHTTPContext.filings/2`** — regulatory filings for a
  symbol (e.g. SEC 10-K, 10-Q). Mirrors `Filings` from upstream.
- **`Longbridge.QuoteHTTPContext.symbol_to_counter_ids/2`** — HTTP-only
  batch symbol → counter_id lookup. For local-first resolution with
  embedded directory + cache, use `Longbridge.Symbol.resolve_counter_ids/2`.
- **`Longbridge.OAuth.InMemoryTokenStorage`** — in-memory implementation of
  the `Longbridge.OAuth.TokenStorage` behaviour for tests and ephemeral CLI
  sessions. Mirrors the v4.2.0 in-memory storage patterns from upstream.
- **`Longbridge.TradeContext` HTTP 401 auto-refresh + retry** — all HTTP
  calls (`order_detail`, `today_orders`, `submit_order`, etc.)
  automatically retry once on a `401 Unauthorized` response after refreshing
  the access token via `Config.refresh_access_token/2`.
- **`Longbridge.OAuth.load_token/2` `:refresh_skew` option** — refresh
  tokens proactively when within `:refresh_skew` seconds of expiry.
  Default `0` (only refresh after expiry).
- **`Longbridge.OAuth.load_token/2` error wrapping** — refresh failures are
  now wrapped as `{:error, {:refresh_failed, reason}}` (network/parse
  errors) or `{:error, {:refresh_token_revoked, error, data}}` (server
  rejected, user must re-authorize). Previously these were indistinguishable
  from "no token file" errors.

### Changed

- **`Longbridge.QuoteHTTPContext.option_volume` paths renamed** —
  `GET /v1/quote/option-volume` → `/v1/quote/option-volume-stats` and
  `/v1/quote/option-volume-daily` → `/v1/quote/option-volume-stats/daily`.
  Params renamed `start_date`/`end_date` → `start`/`end`. Response shapes
  updated. Mirrors upstream renaming.
- **`Longbridge.TradeContext.estimate_max_purchase_quantity/2` endpoint
  corrected** — `POST /v1/trade/estimate` → `GET /v1/trade/estimate/buy_limit`
  with query params (matches upstream).
- **`Longbridge.TradeContext.replace_order` and `cancel_order` HTTP methods
  corrected** — both were using `POST /v1/trade/order/{replace,cancel}`
  which don't exist. Now use `PUT /v1/trade/order` and
  `DELETE /v1/trade/order?order_id=...` matching upstream.

### Endpoints

- **QuoteContext** (28 methods) — static_info, quote, option_quote,
  warrant_quote, depth, brokers, participant_broker_ids, trades, intraday,
  candlesticks, history_candlesticks_by_offset, history_candlesticks_by_date,
  option_chain_date, option_chain_strike_info, warrant_issuer_info,
  warrant_list, calc_index, capital_flow_intraday, capital_flow_distribution,
  market_trade_period, market_trade_day, subscription, subscribe, unsubscribe,
  user_quote_profile, typed push callbacks
  (`set_on_quote/depth/brokers/trades`)
- **TradeContext** (16 methods) — submit_order, replace_order, cancel_order,
  history_orders, today_orders, history_executions, today_executions,
  order_detail, account_balance, cash_flow, fund_positions, stock_positions,
  margin_ratio, estimate_max_purchase_quantity, subscribe/unsubscribe (push)
- **QuoteHTTPContext** (15 methods) — short_positions, option_volume,
  option_volume_daily, security_list, watchlist_groups CRUD + update_pinned,
  market_temperature, history_market_temperature, short_trades
- **Other HTTP contexts** — AlertContext, AssetContext, CalendarContext,
  ContentContext, DCAContext, FundamentalContext, MarketContext,
  PortfolioContext, ScreenerContext, SharelistContext

### Transport

- WebSocket transport via Mint + Finch (binary protocol with custom
  11/10/5-byte header layouts, gzip-compressed response bodies)
- HTTP transport via Finch for REST endpoints (HMAC-SHA256 signed)
- Pluggable OAuth token storage (`Longbridge.OAuth.TokenStorage` behaviour)
  with default `Longbridge.OAuth.FileTokenStorage`

### Test coverage

- 642 tests pass, 0 credo, 0 dialyzer, 0 ex_dna, 0 reach.
- Total coverage: 90.8% (above 89% threshold).
- `Longbridge.TradeContext`: 95.9%.
- `Longbridge.QuoteContext.RealtimeStore`: 100%.

[0.2.1]: https://github.com/gilbertwong96/longbridge/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/gilbertwong96/longbridge/compare/v0.1.2...v0.2.0
[0.1.2]: https://github.com/gilbertwong96/longbridge/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/gilbertwong96/longbridge/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/gilbertwong96/longbridge/releases/tag/v0.1.0
