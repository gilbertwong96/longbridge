# AGENTS.md

Operating instructions for AI coding agents working on the **longbridge** Elixir SDK.

## Project shape

`longbridge` is an Elixir client for the [Longbridge OpenAPI](https://open.longbridge.com) trading platform. The codebase is a hand-written binary protocol layer (the wire format is a custom Protobuf over WebSocket) with one GenServer per connection and a context wrapper per endpoint.

| Module | Role |
| --- | --- |
| `Longbridge` | Top-level docs-only module. Public entry point. |
| `Longbridge.AlertContext` | Price alert management (add/enable/disable/delete). HTTP-only. |
| `Longbridge.Application` | Supervision tree. Starts the `Longbridge.Finch` HTTP pool. |
| `Longbridge.AssetContext` | Account statement download. HTTP-only. |
| `Longbridge.CalendarContext` | Financial calendar (earnings, dividends, IPOs, macro, closures). HTTP-only. |
| `Longbridge.Config` | Endpoint + auth configuration struct. `refresh_access_token/2` for legacy API key flow. |
| `Longbridge.Connection.Session` | Transport-agnostic session logic (reconnect, idle, broadcast, dispatch). Pure functions, no socket I/O. |
| `Longbridge.ContentContext` | News, community topics, announcements. HTTP-only. |
| `Longbridge.DCAContext` | Dollar-cost averaging plan management. HTTP-only. |
| `Longbridge.FundamentalContext` | Financial reports, analyst ratings, dividends, valuation, shareholders. HTTP-only. |
| `Longbridge.HTTPClient` | Signed HTTP requests via `Longbridge.Finch`. Used by all HTTP-only contexts. |
| `Longbridge.MarketContext` | Market status, broker holdings, indices, anomaly alerts. HTTP-only. |
| `Longbridge.OAuth` | OAuth 2.0 Authorization Code flow with PKCE. Browser flow and headless server flow. |
| `Longbridge.PortfolioContext` | Exchange rates and portfolio P&L analysis. HTTP-only. |
| `Longbridge.Protocol` | Wire-format constants + `pack/2` / `unpack/1` for whole packets. |
| `Longbridge.Protocol.Header` | Per-packet header encode/decode (request / response / push layouts). |
| `Longbridge.Protos` | `use Protox, files: protos/*.proto` — generates `Longbridge.{Control,Quote,Trade}.V1.*` structs. |
| `Longbridge.QuoteContext` | Public API for the quote endpoint — 20+ typed methods. |
| `Longbridge.SharelistContext` | Community sharelist management. HTTP-only. |
| `Longbridge.Symbol` | Symbol ↔ counter_id conversion (`to_counter_id/1`, `index_to_counter_id/1`, `from_counter_id/1`). Used by HTTP `MarketContext`. Vendored directory data lives in `priv/counter_ids/`. |
| `Longbridge.TradeContext` | Public API for the trade endpoint — orders, positions, account, executions, push. |
| `Longbridge.WSConnection` | WebSocket GenServer. Owns the socket, WS upgrade, auth, heartbeat, request/response pairing, push dispatch. |

## Quality gate (source of truth)

`mix ci` is the one command that proves the project is shippable. **Do not declare work done until `mix ci` exits 0.** It runs, in order:

1. `compile --all-warnings --warnings-as-errors`
2. `format --check-formatted`
3. `credo --strict`
4. `deps.unlock --check-unused`
5. `deps.audit`
6. `xref graph --label compile-connected --fail-above 0`
7. `dialyzer`
8. `ex_dna` (duplication)
9. `reach.check --dead-code --smells`

When a step fails, fix the underlying issue — never silence a check (`@compile {:no_warn_1}`, exempting files, deleting tests, etc.) without an explicit user request and a justification in the commit body.

## Build, test, run

```sh
mix deps.get            # first time only
mix compile             # builds protos + app
mix test                # run unit tests
mix format              # auto-format
mix docs                # generate ExDoc HTML
```

`protoc` must be on `$PATH` (Elixir `protox` shells out to it). On macOS: `brew install protobuf`.

## Architecture invariants

- **Wire format is BigEndian binary.** All multi-byte fields in the protocol are big-endian.
- **Handshake is two fixed bytes:** `<<0b00010001, 0b00001001>>` (version=1, codec=protobuf, platform=OpenAPI=9). See `Longbridge.Protocol.handshake/0`.
- **Proto dependency is vendored under `protos/`** and tracks the upstream `longbridge/openapi-protobufs` git dep pinned to `gen/go/v0.7.0`. Do **not** hand-edit the `.proto` files — to upgrade, bump the tag in `mix.exs` and re-run `cp deps/openapi_protobuf_specs/{control,quote,trade}/*.proto protos/`.
- **Generated proto modules live at:** `Longbridge.Control.V1.*`, `Longbridge.Quote.V1.*`, `Longbridge.Trade.V1.*`. Adding a new proto message means adding it to the right upstream `.proto` and re-vendoring — never define a `Longbridge.Foo.V1.*` struct by hand in this repo.
- **Connection ownership:** `Longbridge.WSConnection` is the only module that owns the Mint WebSocket connection. Contexts (`QuoteContext` / `TradeContext`) wrap a connection pid and forward requests to it. Push data is delivered to the *context's* caller process, not the connection's parent, via `Longbridge.WSConnection.subscribe_push/2`.
- **Auth is synchronous:** the WSConnection process does a blocking `receive` for the auth response inside `do_auth/1`. Don't add a `handle_info({:tcp, _, _}, ...)` clause that can race the auth handshake.
- **HTTP and WS tokens are different things.** `Longbridge.Config.with_socket_token/1` derives a one-time-password (OTP) from the long-lived access token; the OTP authenticates only the WebSocket handshake. The original access token is required for REST calls, so `Longbridge.TradeContext` keeps both side by side (`state.ws_config` vs `state.http_config`) and uses the OTP only for WS. Don't merge them.
- **HTTP paths track `longbridge/openapi` upstream.** Alert / calendar / content / dca / fundamental / market / portfolio / sharelist paths and request bodies all follow the upstream Rust core. When the upstream changes, the path lives in a single module attribute at the top of each context file (e.g. `@reminders_path` in `alert_context.ex`); update there.
- **gzip is bidirectional.** `Longbridge.Protocol.unpack/1` inflates response bodies when `Header.gzip == true`; `Longbridge.WSConnection.maybe_gzip/2` (private) deflates request bodies when they exceed `Config.gzip_threshold`. Both sides must stay in lock-step — if you add a new packet type, make sure both paths handle it.
- **HTTP endpoints use internal `counter_id`s.** The WebSocket layer accepts user-facing symbols (`AAPL.US`, `00700.HK`) and normalises them on the server. The HTTP `Longbridge.MarketContext` endpoints (broker-holding, ahpremium, index-constituents, trades-statistics) address instruments by an internal `counter_id` (`ST/US/AAPL`, `ST/HK/700`, `IX/HK/HSI`, `ETF/US/SPY`). `Longbridge.Symbol.to_counter_id/1` mirrors the upstream Rust conversion: HK numeric codes strip leading zeros (`00700` → `700`), SZ/CN codes keep them, leading-dot US symbols (`/DJI.US`) get `IX/`, ETFs match against `priv/counter_ids/US-ETF.csv` (vendored from `longbridge/openapi/rust/src/utils/`), and runtime-resolved IDs are cached in `$LONGBRIDGE_CACHE_DIR/counter-ids.csv` via `Longbridge.Symbol.Cache`. The WebSocket `QuoteContext` does NOT need this conversion — it passes user symbols directly and the server normalises.

## Code conventions

- **Module attributes that act as constants get an accessor function** (e.g., `@cmd_close 0` → `def cmd_close, do: @cmd_close`). This keeps callers from poking at internal attributes and gives Dialyzer something concrete to type-check against.
- **Aliases at the top of each module, alphabetically ordered within their group.** `Credo`'s `--strict` mode enforces this; if you add a new alias, run `mix credo --strict` and reorder.
- **No `IO.puts` / `IO.inspect` in library code.** Use `Logger` (the connection module already requires it). This includes temporary debugging — use `Logger.debug` and remove before committing.
- **Specs for public functions.** `@spec` for every public function. Prefer concrete types (`non_neg_integer()`, `:atom | binary()`) over generic ones (`term()`, `any()`).
- **Match on the struct shape, not just the variable.** When a function expects a `Header.t()`, pattern-match `def f(%Header{} = h, ...)` so Dialyzer can prove the type and you get a clear error if a caller passes the wrong shape.
- **One `use Protox` only.** The `use Protox, files: [...], paths: [...]` macro call lives **exclusively** in `lib/longbridge/_protos.ex`. The macro generates `Longbridge.{Control,Quote,Trade}.V1.*` modules and the file's name (and `defmodule Longbridge.Protos`) are load-bearing for the generated module names — renaming either one will require updating the `Q.`, `T.`, and `Ctrl.` aliases in `quote_context.ex`, `trade_context.ex`, and `connection.ex`.

## Tests

Tests live in `test/longbridge_test.exs` and cover: `Config` defaults, `Protocol` constants/predicates, `Protocol.Header` pack/unpack round-trips for all three packet types, and Protobuf struct round-trips through `Protox.encode/1` + `Protox.decode!/2`.

There are **no integration tests** — the SDK is exercised against a real Longbridge account by hand. Don't add a `mix test --include integration` or fake server until the user asks for one; the protocol is brittle enough that a mock server would diverge from production and the tests would lie.

## Things to avoid

- **Don't bump `protox`, `credo`, `dialyxir`, or `reach` past the version pinned in `mix.exs`** without checking their changelogs — this repo's `dialyzer:` flags, `credo:` plugins, and `.ex_dna.exs` / `.reach.exs` configs are tuned to the current versions.
- **Don't introduce a new top-level dep that doesn't appear in `mix.lock` already.** If you genuinely need a new one, add it to the appropriate `only: [:dev, :test]` group, run `mix deps.get`, and confirm `mix deps.audit` still reports zero vulnerabilities.
- **Don't replace the proto git dep with a different tag** without re-vendoring the `.proto` files. The pinned version in `protos/` must match the pinned tag in `mix.exs`.
- **Don't add `priv/plts/` to git.** The PLT is machine-local and `.gitignore` already excludes it.
- **Don't use `Map.put`/`Map.get` style when struct field access works.** `Longbridge.Config` is a struct — use `config.token`, not `Map.get(config, :token)`.

## Where to look when something breaks

- `mix ci` fails on step 1 (`compile --warnings-as-errors`) — usually a missing `body_length: 0` in a new `%Longbridge.Protocol.Header{...}` literal (see `connection.ex:118,186,244` for the pattern).
- `mix ci` fails on step 7 (`dialyzer`) — usually a header field with the wrong nullable type. `Longbridge.Protocol.Header.t/0` declares `request_id`, `timeout`, `status_code` as `non_neg_integer() | nil` because each packet type only sets the fields it carries.
- Push data never arrives — check that the caller process has `Longbridge.WSConnection.subscribe_push/2` registered (the contexts do this automatically, but custom consumers need to opt in).
- Auth hangs forever — the `Longbridge.Config.token` is `nil`; `do_auth/1` returns `{:error, :no_token}` and the GenServer stops. Set the token in your config or use a mock for testing.

## Protobufs and the decode pipeline

- The vendored protos under `protos/` are bit-for-bit identical to `longbridge/openapi-protobufs@gen/go/v0.7.0` and to the `main` branch's head. The pin **is not stale** — both `longbridge/openapi-go` and `longbridge/openapi`'s Rust SDK submodule use the same `v0.7.0` / commit `c3c1a3e1` (verified 2026-06).
- The server gzip-compresses response bodies that exceed its internal size threshold, regardless of the `gzip` flag we send on the request. `Longbridge.Protocol.unpack/1` reads `Header.gzip` and calls `:zlib.gunzip/1` when set. **This was the cause of every "5+ responses fail to decode" symptom** before commit `9c8eaf3`. Don't remove the decompression — test it with `scripts/verify_decode_fix.exs` if you doubt it.
- `Protox.decode!/2` raises `Protox.DecodingError` on a malformed body. `Longbridge.QuoteContext` wraps every decode in a `try/rescue Protox.DecodingError` that returns `{:error, {:decode_error, exception}}` so callers always see `{:ok, _} | {:error, _}`. Don't undo that wrapping to "let it crash" — the contract of the public API is the wrap.
- The response shape can drift (e.g. a new enum value). Protox will return the unknown enum as an atom other than what callers expect. If you see a decode error, compare `protos/quote.proto` against `openapi-protobufs/quote/api.proto@main` to see if upstream added a field.
