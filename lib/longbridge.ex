defmodule Longbridge do
  @moduledoc """
  Longbridge OpenAPI Elixir SDK.

  Real-time market data, push subscriptions, trading, watchlists,
  screener, financial calendar, fundamental data, and portfolio
  analytics for US, HK, SG, and CN markets.

  ## Two transport layers

  * **WebSocket** — `Longbridge.QuoteContext` and `Longbridge.TradeContext`
    own a long-lived Mint WebSocket that streams real-time data and
    answers request/response pairs. Auto-reconnects with back-off;
    resubscribes push topics on reconnect.
  * **HTTP** — every `Longbridge.*Context` with HTTP-only methods
    (`MarketContext`, `CalendarContext`, `ContentContext`, ...) signs
    requests with HMAC-SHA256 via `Longbridge.HTTPClient`.

  The WebSocket layer uses a one-time password (OTP) obtained from
  `Longbridge.Config.with_socket_token/1`; the HTTP layer uses the
  long-lived access token directly. `Longbridge.TradeContext.start_link/2`
  splits the config into `ws_config` + `http_config` automatically.

  ## Authentication

  Two options:

    1. **Legacy API key** — `token` is a long-lived `access_token` you
       obtain once from `Longbridge.Config.refresh_access_token/2`. The
       HTTP layer signs with HMAC-SHA256.
    2. **OAuth 2.0** — `Longbridge.OAuth.authorize/2` runs the PKCE
       browser flow and writes a token file. Subsequent
       `Longbridge.OAuth.load_token/1` calls transparently refresh
       expired tokens.

  ## Entry points

    * `Longbridge.Config` — credentials, endpoints, timeouts.
    * `Longbridge.QuoteContext` — streaming quotes + 25+ typed methods.
    * `Longbridge.TradeContext` — order placement, positions, account,
      executions, cash flow, push subscriptions.
    * `Longbridge.MarketContext` — sessions, broker holdings, A/H premium,
      anomaly alerts, rank lists.
    * `Longbridge.QuoteHTTPContext` — watchlists, market temperature,
      security list, short interest, filings, symbol→counter_id.
    * `Longbridge.CalendarContext` — earnings, dividends, IPOs, macro events,
      market closures.
    * `Longbridge.FundamentalContext` — company profile, financial reports,
      analyst ratings, dividends, valuation, shareholders, ETF allocation.
    * `Longbridge.ContentContext` — news, community topics, announcements.
    * `Longbridge.PortfolioContext` — exchange rates, P&L, positions.
    * `Longbridge.ScreenerContext` — screener strategies, indicator search,
      AI recommendations.
    * `Longbridge.AlertContext` — price alerts.
    * `Longbridge.DCAContext` — dollar-cost averaging plans.
    * `Longbridge.SharelistContext` — community sharelists.
    * `Longbridge.AssetContext` — daily/monthly account statements.
    * `Longbridge.Symbol` — user symbol ↔ counter_id conversion with
      embedded directory + remote fallback.

  ## Quality gate

  Run `mix ci` before submitting a change. It runs, in order:
  compile-with-warnings-as-errors, format, credo --strict, deps.audit,
  xref, dialyzer, ex_dna (duplication), reach (dead code + smells).
  """
end
