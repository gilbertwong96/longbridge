defmodule Longbridge.Config do
  @moduledoc """
  Configuration for Longbridge OpenAPI connections.

  ## Examples

      iex> config = Longbridge.Config.new(
      ...>   token: "your-oauth-token",
      ...>   app_key: "your-app-key",
      ...>   app_secret: "your-app-secret"
      ...> )
      iex> config.token
      "your-oauth-token"

  ## Endpoints

  By default, the international endpoints are used:

  - Quote: `wss://openapi-quote.longbridge.com`
  - Trade: `wss://openapi-trade.longbridge.com`

  For mainland China, set `china: true`:

      Longbridge.Config.new(token: "...", china: true)

  This uses `openapi-quote.longbridge.cn` and `openapi-trade.longbridge.cn`.
  """

  defstruct [
    :token,
    :app_key,
    :app_secret,
    :expired_at,
    :china,
    :quote_ws_url,
    :trade_ws_url,
    :http_url,
    :gzip_threshold,
    :headers,
    heartbeat_interval: 15_000,
    request_timeout: 10_000,
    idle_timeout: 600_000
  ]

  @type t :: %__MODULE__{
          token: String.t() | nil,
          app_key: String.t() | nil,
          app_secret: String.t() | nil,
          expired_at: non_neg_integer() | nil,
          china: boolean(),
          quote_ws_url: String.t() | nil,
          trade_ws_url: String.t() | nil,
          http_url: String.t(),
          gzip_threshold: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}] | nil,
          heartbeat_interval: non_neg_integer(),
          request_timeout: non_neg_integer(),
          idle_timeout: non_neg_integer()
        }

  @default_quote_ws_url "wss://openapi-quote.longbridge.com"
  @default_trade_ws_url "wss://openapi-trade.longbridge.com"

  @default_quote_ws_url_cn "wss://openapi-quote.longbridge.cn"
  @default_trade_ws_url_cn "wss://openapi-trade.longbridge.cn"

  @default_http_url "https://openapi.longbridge.com"
  @default_http_url_cn "https://openapi.longbridge.cn"

  @doc """
  Creates a new config struct.

  ## Options

  - `:token` — OAuth token for authentication
  - `:app_key` — Application key
  - `:app_secret` — Application secret
  - `:china` — Use mainland China endpoints (default: false)
  - `:quote_ws_url` — Override quote WebSocket URL
  - `:trade_ws_url` — Override trade WebSocket URL
  - `:gzip_threshold` — Min body size for gzip compression (bytes)
  - `:heartbeat_interval` — Heartbeat interval in ms (default: 15000)
  - `:request_timeout` — Request timeout in ms (default: 10000)
  - `:idle_timeout` — Close connection after this many ms of inactivity (default: 600000)
  - `:headers` — List of `{name, value}` tuples added to every HTTP
    and WebSocket request. Useful for injecting `X-Forwarded-For`,
    custom auth headers, or tenant routing headers. Mirrors
    `Config::header(key, value)` from `longbridge/openapi` Rust SDK
    (4.0.6).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    china = Keyword.get(opts, :china, false)
    defaults = region_defaults(china)

    %__MODULE__{
      china: china,
      token: opts[:token],
      app_key: opts[:app_key],
      app_secret: opts[:app_secret],
      expired_at: opts[:expired_at],
      quote_ws_url: opts[:quote_ws_url] || defaults[:quote_ws_url],
      trade_ws_url: opts[:trade_ws_url] || defaults[:trade_ws_url],
      http_url: opts[:http_url] || defaults[:http_url],
      gzip_threshold: opts[:gzip_threshold] || 1024,
      headers: normalize_headers(opts[:headers]),
      heartbeat_interval: opts[:heartbeat_interval] || 15_000,
      request_timeout: opts[:request_timeout] || 10_000,
      idle_timeout: opts[:idle_timeout] || 600_000
    }
  end

  defp normalize_headers(nil), do: nil

  defp normalize_headers(list) when is_list(list) do
    Enum.map(list, fn
      {k, v} when is_binary(k) and is_binary(v) -> {k, v}
      {k, v} when is_atom(k) and is_binary(v) -> {Atom.to_string(k), v}
      {k, v} when is_binary(k) and is_atom(v) -> {k, Atom.to_string(v)}
    end)
  end

  defp region_defaults(true) do
    [
      http_url: @default_http_url_cn,
      quote_ws_url: @default_quote_ws_url_cn,
      trade_ws_url: @default_trade_ws_url_cn
    ]
  end

  defp region_defaults(false) do
    [
      http_url: @default_http_url,
      quote_ws_url: @default_quote_ws_url,
      trade_ws_url: @default_trade_ws_url
    ]
  end

  @doc """
  Fetches a one-time-password (OTP) for socket authentication.

  The Longbridge socket protocol requires an OTP obtained via
  `GET /v1/socket/token`. Returns a new config with the OTP set
  as the `token` field, suitable for passing to `QuoteContext`
  or `TradeContext`.
  """
  @spec with_socket_token(t()) :: {:ok, t()} | {:error, term()}
  def with_socket_token(%__MODULE__{app_key: nil} = config), do: {:ok, config}
  def with_socket_token(%__MODULE__{app_secret: nil} = config), do: {:ok, config}

  def with_socket_token(%__MODULE__{token: token} = config)
      when is_binary(token) and byte_size(token) < 100 do
    {:ok, config}
  end

  def with_socket_token(%__MODULE__{} = config) do
    case Longbridge.HTTPClient.get_socket_token(config) do
      {:ok, otp} -> {:ok, %{config | token: otp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Refreshes the access token using the Longbridge `/v1/token/refresh` HTTP API.

  For **Legacy API Key** authentication only. The current `access_token`
  expires after 90 days by default. Call this before it expires to obtain
  a new one, then update your stored `LONGBRIDGE_ACCESS_TOKEN` (or persist
  the new config) accordingly.

  Returns `{:ok, new_config}` with the new `token` and `expired_at`, or
  `{:error, reason}`.

  ## Options

  - `:expired_at` — When the new token should expire (Unix timestamp, seconds).
    Defaults to 90 days from now. Longbridge allows up to 3 years.

  ## Example

      {:ok, new_config} =
        config
        |> Longbridge.Config.refresh_access_token()
  """
  @spec refresh_access_token(t(), keyword()) :: {:ok, t()} | {:error, term()}
  def refresh_access_token(%__MODULE__{} = config, opts \\ []) do
    case Longbridge.HTTPClient.refresh_access_token(config, opts) do
      {:ok, %{token: token, expired_at: expired_at}} ->
        {:ok, %{config | token: token, expired_at: expired_at}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
