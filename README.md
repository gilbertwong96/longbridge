# Longbridge

Elixir SDK for the [Longbridge OpenAPI](https://open.longbridge.com) trading platform — real-time market data, push subscriptions, and (in-progress) trading APIs for US, HK, SG, and CN markets.

The SDK speaks Longbridge's binary protocol directly over TCP: 2-byte handshake, then Protobuf-encoded request/response and push frames with a custom 11/10/5-byte header layout. There is no JSON-over-HTTP path; this library is a faithful re-implementation of the wire format, not an HTTP client.

> **Status: alpha.** The quote endpoint is feature-complete; the trade endpoint ships subscribe/unsubscribe only. Order submission, account/balance, and position queries are not yet implemented. The API is subject to change before 0.1.0.

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
| `app_key` / `app_secret` | `nil` | Reserved for future signing flows. |
| `china` | `false` | When true, switch to `.longbridge.cn` endpoints for mainland connectivity. |
| `quote_host` / `quote_port` | `openapi-quote.longbridge.{com,cn}`:2020 | Override for staging or proxies. |
| `trade_host` / `trade_port` | `openapi-trade.longbridge.{com,cn}`:2020 | Same. |
| `transport` | `:tcp` | `:websocket` is reserved for a future WebSocket transport. |
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
    ├── config.ex                # Longbridge.Config struct
    ├── connection.ex            # TCP GenServer (one per endpoint)
    ├── protocol.ex              # packet pack/unpack + wire-format constants
    ├── protocol/header.ex       # 11/10/5-byte header encode/decode
    ├── quote_context.ex         # public API: 20+ quote methods
    └── trade_context.ex         # public API: subscribe/unsubscribe
protos/
├── control.proto                # Auth, Heartbeat, Close
├── error.proto                  # server error envelope
├── api.proto                    # quote API (vendored from upstream)
└── subscribe.proto              # trade push subscription
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

## API reference

### `Longbridge.QuoteContext`

| Method | Sub-command | Notes |
| --- | --- | --- |
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
| `option_chain_date/2` | `QueryOptionChainDate` (20) | |
| `option_chain_strike_info/3` | `QueryOptionChainDateStrikeInfo` (21) | |
| `warrant_issuer_info/1` | `QueryWarrantIssuerInfo` (22) | |
| `market_trade_period/1` | `QueryMarketTradePeriod` (8) | |
| `market_trade_day/4` | `QueryMarketTradeDay` (9) | |
| `calc_index/3` | `QuerySecurityCalcIndex` (26) | `calc_indexes` is a list of `CalcIndex` atoms. |
| `capital_flow_intraday/2` | `QueryCapitalFlowIntraday` (24) | |
| `capital_flow_distribution/2` | `QueryCapitalFlowDistribution` (25) | |
| `subscription/1` | `Subscription` (5) | |
| `subscribe/3` | `Subscribe` (6) | `sub_types` ∈ `{:QUOTE, :DEPTH, :BROKERS, :TRADE}`. |
| `unsubscribe/3` | `Unsubscribe` (7) | |

### `Longbridge.TradeContext`

| Method | Sub-command | Notes |
| --- | --- | --- |
| `subscribe/1` | `CMD_SUB` (16) | Receives `Notification` push frames. |
| `unsubscribe/1` | `CMD_UNSUB` (17) | |

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
mix test           # 17 unit tests
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
