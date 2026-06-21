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

  - Quote: `tcp://openapi-quote.longbridge.com:2020`
  - Trade: `tcp://openapi-trade.longbridge.com:2020`

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
    :quote_host,
    :quote_port,
    :trade_host,
    :trade_port,
    :quote_ws_url,
    :trade_ws_url,
    :http_url,
    :transport,
    :gzip_threshold,
    heartbeat_interval: 15_000,
    request_timeout: 10_000,
    idle_timeout: 60_000
  ]

  @type t :: %__MODULE__{
          token: String.t() | nil,
          app_key: String.t() | nil,
          app_secret: String.t() | nil,
          expired_at: non_neg_integer() | nil,
          china: boolean(),
          quote_host: String.t(),
          quote_port: non_neg_integer(),
          trade_host: String.t(),
          trade_port: non_neg_integer(),
          quote_ws_url: String.t() | nil,
          trade_ws_url: String.t() | nil,
          http_url: String.t(),
          transport: :tcp | :websocket,
          gzip_threshold: non_neg_integer() | nil,
          heartbeat_interval: non_neg_integer(),
          request_timeout: non_neg_integer(),
          idle_timeout: non_neg_integer()
        }

  @default_quote_host "openapi-quote.longbridge.com"
  @default_quote_port 2020
  @default_trade_host "openapi-trade.longbridge.com"
  @default_trade_port 2020

  @default_quote_host_cn "openapi-quote.longbridge.cn"
  @default_trade_host_cn "openapi-trade.longbridge.cn"

  @default_http_url "https://openapi.longbridge.com"
  @default_http_url_cn "https://openapi.longbridge.cn"

  @doc """
  Creates a new config struct.

  ## Options

  - `:token` — OAuth token for authentication
  - `:app_key` — Application key
  - `:app_secret` — Application secret
  - `:china` — Use mainland China endpoints (default: false)
  - `:transport` — `:tcp` (default) or `:websocket`
  - `:quote_host` — Override quote server host
  - `:quote_port` — Override quote server port
  - `:trade_host` — Override trade server host
  - `:trade_port` — Override trade server port
  - `:gzip_threshold` — Min body size for gzip compression (bytes)
  - `:heartbeat_interval` — Heartbeat interval in ms (default: 15000)
  - `:request_timeout` — Request timeout in ms (default: 10000)
  - `:idle_timeout` — Close connection after this many ms of inactivity (default: 60000)
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    china = Keyword.get(opts, :china, false)

    {default_quote_host, default_trade_host, default_http_url} =
      if china do
        {@default_quote_host_cn, @default_trade_host_cn, @default_http_url_cn}
      else
        {@default_quote_host, @default_trade_host, @default_http_url}
      end

    %__MODULE__{
      token: Keyword.get(opts, :token),
      app_key: Keyword.get(opts, :app_key),
      app_secret: Keyword.get(opts, :app_secret),
      expired_at: Keyword.get(opts, :expired_at),
      china: china,
      transport: Keyword.get(opts, :transport, :tcp),
      quote_host: Keyword.get(opts, :quote_host, default_quote_host),
      quote_port: Keyword.get(opts, :quote_port, @default_quote_port),
      trade_host: Keyword.get(opts, :trade_host, default_trade_host),
      trade_port: Keyword.get(opts, :trade_port, @default_trade_port),
      quote_ws_url: Keyword.get(opts, :quote_ws_url),
      trade_ws_url: Keyword.get(opts, :trade_ws_url),
      http_url: Keyword.get(opts, :http_url, default_http_url),
      gzip_threshold: Keyword.get(opts, :gzip_threshold, 1024),
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, 15_000),
      request_timeout: Keyword.get(opts, :request_timeout, 10_000),
      idle_timeout: Keyword.get(opts, :idle_timeout, 60_000)
    }
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

  Updates the `http_url` if the response contains a different endpoint
  (rare; only when the SDK region auto-detection changes).
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
