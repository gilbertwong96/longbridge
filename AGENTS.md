# AGENTS.md

Operating instructions for AI coding agents working on the **longbridge** Elixir SDK.

## Project shape

`longbridge` is an Elixir client for the [Longbridge OpenAPI](https://open.longbridge.com) trading platform. The codebase is a hand-written binary protocol layer (the wire format is a custom Protobuf over TCP) with one GenServer per connection and a context wrapper per endpoint.

| Module | Role |
| --- | --- |
| `Longbridge` | Top-level docs-only module. Public entry point. |
| `Longbridge.AlertContext` | Price alert management (add/enable/disable/delete). HTTP-only. |
| `Longbridge.Application` | Supervision tree. Starts the `Longbridge.Finch` HTTP pool. |
| `Longbridge.AssetContext` | Account statement download. HTTP-only. |
| `Longbridge.CalendarContext` | Financial calendar (earnings, dividends, IPOs, macro, closures). HTTP-only. |
| `Longbridge.Config` | Endpoint + auth configuration struct. `refresh_access_token/2` for legacy API key flow. |
| `Longbridge.Connection` | TCP GenServer. Owns the socket, handshake, auth, heartbeat, request/response pairing, push dispatch. |
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
| `Longbridge.TradeContext` | Public API for the trade endpoint — orders, positions, account, executions, push. |

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
- **Connection ownership:** `Longbridge.Connection` is the only module that calls `:gen_tcp.send/2` / receives `:tcp` messages. Contexts (`QuoteContext` / `TradeContext`) wrap a connection pid and forward requests to it. Push data is delivered to the *context's* caller process, not the connection's parent, via `Longbridge.Connection.subscribe_push/2`.
- **Auth is synchronous:** the connection process does a blocking `receive` for the auth response inside `do_auth/1`. Don't add a `handle_info({:tcp, _, _}, ...)` clause that can race the auth handshake.

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
- Push data never arrives — check that the caller process has `Longbridge.Connection.subscribe_push/2` registered (the contexts do this automatically, but custom consumers need to opt in).
- Auth hangs forever — the `Longbridge.Config.token` is `nil`; `do_auth/1` returns `{:error, :no_token}` and the GenServer stops. Set the token in your config or use a mock for testing.
