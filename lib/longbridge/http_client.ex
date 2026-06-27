defmodule Longbridge.HTTPClient do
  @moduledoc """
  HTTP client for the Longbridge OpenAPI REST API.

  Used for:
  - Refreshing the legacy API Key `access_token` via `/v1/token/refresh`
  - Arbitrary HTTP calls (e.g. `/v1/trade/execution/today`)

  HTTP requests are signed with HMAC-SHA256 using the configured
  `app_secret`. OAuth 2.0 access tokens are passed directly via the
  `Authorization: Bearer` header (no signing required).

  This module uses [Finch](https://github.com/sneako/finch) under the hood.

  ## Examples

      config = Longbridge.Config.new(
        token: "current-access-token",
        app_key: "your-app-key",
        app_secret: "your-app-secret"
      )

      {:ok, %{token: new_token, expired_at: ts}} =
        Longbridge.HTTPClient.refresh_access_token(config)
  """

  alias Longbridge.Config

  @default_finch Longbridge.Finch
  @default_expired_at_seconds 60 * 60 * 24 * 90

  @typedoc """
  Optional OAuth token refresher.

  Called by `request/5` to obtain a fresh token before retrying a
  request that returned an auth error. The refresher receives the
  current config and returns either a new config with a fresh
  token (which `request/5` will use to retry the request once) or
  an error tuple (which `request/5` returns unchanged).

  Used together with the `:refresh_on_401` option.
  """
  @type token_refresher :: (Config.t() -> {:ok, Config.t()} | {:error, term()})

  @doc """
  Refreshes the legacy API Key `access_token`.

  Calls `GET /v1/token/refresh?expired_at=<unix>` with the current
  `app_key` / `app_secret` / `access_token` and returns the new
  token and expiry.

  ## Options

  - `:expired_at` — When the new token should expire (Unix timestamp,
    seconds). Defaults to 90 days from now.
  - `:http_url` — Override the HTTP base URL (default from config).
  - `:finch` — Override the Finch instance (default `Longbridge.Finch`).

  Returns `{:ok, %{token: String.t(), expired_at: non_neg_integer()}}`
  or `{:error, reason}`.
  """
  @spec refresh_access_token(Config.t(), keyword()) ::
          {:ok, %{token: String.t(), expired_at: non_neg_integer()}}
          | {:error, term()}
  def refresh_access_token(%Config{} = config, opts \\ []) do
    expired_at = Keyword.get_lazy(opts, :expired_at, &default_expired_at/0)
    params = "expired_at=#{expired_at}"

    case request(:get, "/v1/token/refresh", "", config, Keyword.put(opts, :params, params)) do
      {:ok, body} -> parse_refresh_response(body)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Obtains a one-time-password (OTP) token for socket authentication.

  The Longbridge socket protocol requires an OTP token obtained via
  `GET /v1/socket/token`. The legacy access token (`config.token`)
  cannot be used directly for socket auth — it must be exchanged
  for an OTP first.

  Returns `{:ok, otp_token}` or `{:error, reason}`.
  """
  @spec get_socket_token(Config.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def get_socket_token(%Config{} = config, opts \\ []) do
    case request_json(:get, "/v1/socket/token", "", config, opts) do
      {:ok, %{"otp" => otp}} -> {:ok, otp}
      {:ok, _} -> {:error, {:missing_otp, "socket token response missing otp field"}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Performs a signed HTTP request to the Longbridge REST API.

  Signs the request with HMAC-SHA256 using `config.app_secret` and
  the Longbridge signing scheme. Returns the parsed JSON body on
  success, or `{:error, reason}`.

  `body` is a binary (the raw HTTP body, e.g. JSON-encoded string).
  Pass `""` for GET requests.

  ## Options

  - `:http_url` — Override the HTTP base URL.
  - `:params` — URL query string to append to the path (e.g. `"a=1&b=2"`).
  - `:finch` — Override the Finch instance (default `Longbridge.Finch`).
  - `:token_refresher` — A `(Config.t() -> {:ok, Config.t()} | {:error, term()})`
    function called once if the request returns a token-expired error.
    On success, the request is retried once with the new token.
  - `:on_token_refresh` — A `(Config.t() -> any())` function called
    after a successful token refresh, with the new config. Useful
    for updating a parent GenServer's state.

  ## Token refresh retry

  When a `:token_refresher` is provided and the server responds with
  a token-expired error, the refresher is called and the request is
  retried exactly once with the new token. If the refresher fails or
  the retry also fails, the original error is returned.
  """
  @spec request(atom(), String.t(), String.t(), Config.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(method, path, body, %Config{} = config, opts \\ []) do
    case send_signed(method, path, body, config, opts) do
      {:error, {:token_expired, original_err}} ->
        retry_with_refresh(method, path, body, config, opts, original_err)

      other ->
        other
    end
  end

  defp send_signed(method, path, body, %Config{} = config, opts) do
    http_url = Keyword.get(opts, :http_url, config.http_url)
    raw_query = Keyword.get(opts, :params, "")
    ts = unix_timestamp()
    signed_headers = "authorization;x-api-key;x-timestamp"

    path_with_query =
      case raw_query do
        "" -> path
        qs -> path <> "?" <> qs
      end

    signature_header =
      sign(
        method,
        path,
        %{
          "authorization" => config.token,
          "x-api-key" => config.app_key,
          "x-timestamp" => ts
        },
        raw_query,
        body,
        config.app_secret,
        signed_headers
      )

    request_headers =
      [
        {"x-api-key", config.app_key},
        {"authorization", config.token},
        {"x-timestamp", ts},
        {"x-api-signature", signature_header}
      ] ++ (config.headers || [])

    do_signed_request(method, http_url, path_with_query, request_headers, body, opts)
  end

  defp do_signed_request(method, http_url, path_with_query, headers, body, opts) do
    case do_request(method, http_url, path_with_query, headers, body, opts) do
      {:error, {:http_status, 401, _body}} = err ->
        if Keyword.has_key?(opts, :token_refresher),
          do: {:error, {:token_expired, err}},
          else: err

      other ->
        other
    end
  end

  defp retry_with_refresh(method, path, body, config, opts, original_err) do
    refresher = Keyword.get(opts, :token_refresher)

    if is_function(refresher, 1) do
      case refresher.(config) do
        {:ok, new_config} ->
          if callback = Keyword.get(opts, :on_token_refresh),
            do: callback.(new_config)

          case send_signed(method, path, body, new_config, opts) do
            {:error, {:token_expired, _}} ->
              original_err

            result ->
              result
          end

        {:error, _reason} ->
          original_err
      end
    else
      original_err
    end
  end

  @doc false
  @spec parse_refresh_response(term()) ::
          {:ok, %{token: String.t(), expired_at: non_neg_integer()}}
          | {:error, term()}
  def parse_refresh_response(%{"code" => 0, "data" => %{"token" => token, "expired_at" => exp}}) do
    {:ok, %{token: token, expired_at: exp}}
  end

  def parse_refresh_response(%{"code" => code, "message" => msg}) do
    {:error, {:api_error, code, msg}}
  end

  def parse_refresh_response(body) do
    {:error, {:unexpected_response, body}}
  end

  defp do_request(method, http_url, path_with_query, headers, body, opts) do
    finch = Keyword.get(opts, :finch, @default_finch)
    url = http_url <> path_with_query

    request = Finch.build(method, url, headers, body)

    case Finch.request(request, finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:ok, resp_body}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_status, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Computes the Longbridge HMAC-SHA256 signature header.

  Public for testing. The signing scheme matches the official Python SDK:

      canonical = METHOD|URI|PARAMS|authorization:TOKEN
                            \\nx-api-key:KEY
                            \\nx-timestamp:TS
                            \\n|authorization;x-api-key;x-timestamp|
      if body != "": canonical += sha1(body).hex
      sign_str = "HMAC-SHA256|" + sha1(canonical).hex
      signature = hmac_sha256(secret, sign_str).hex
      header = "HMAC-SHA256 SignedHeaders=..., Signature={sig}"
  """
  @spec sign(atom(), String.t(), map(), String.t(), String.t(), String.t(), String.t()) ::
          String.t()
  def sign(method, uri, headers, params, body, secret, signed_headers) do
    mtd = method |> to_string() |> String.upcase()

    headers_lines =
      signed_headers
      |> String.split(";", trim: true)
      |> Enum.map(fn h -> "#{h}:#{Map.fetch!(headers, h)}" end)

    headers_block = Enum.join(headers_lines, "\n")

    canonical_base =
      mtd <>
        "|" <>
        uri <>
        "|" <>
        params <>
        "|" <>
        headers_block <>
        "\n" <>
        "|" <> signed_headers <> "|"

    canonical = if body == "", do: canonical_base, else: canonical_base <> sha1_hex(body)

    sign_str = "HMAC-SHA256|" <> sha1_hex(canonical)
    signature = hmac_sha256_hex(secret, sign_str)

    "HMAC-SHA256 SignedHeaders=#{signed_headers}, Signature=#{signature}"
  end

  defp sha1_hex(binary) do
    Base.encode16(:crypto.hash(:sha, binary), case: :lower)
  end

  defp hmac_sha256_hex(secret, data) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, data), case: :lower)
  end

  @doc """
  Performs a signed HTTP request and unwraps the Longbridge response envelope.

  Longbridge REST API responses all share the form:
    `{"code": 0, "data": {...}}`

  This helper calls `request/5` and extracts the `"data"` field on success
  (code 0), or returns an `{:error, {:api_error, code, message}}` tuple.
  """
  @spec request_json(atom(), String.t(), String.t(), Config.t(), keyword()) ::
          {:ok, map() | list()} | {:error, term()}
  def request_json(method, path, body, %Config{} = config, opts \\ []) do
    case request(method, path, body, config, opts) do
      {:ok, %{"code" => 0, "data" => data}} -> {:ok, data}
      {:ok, %{"code" => code, "message" => msg}} -> {:error, {:api_error, code, msg}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Builds a URL query string from a keyword list.

  Nil values are filtered out. Values are URI-encoded.

  ## Example

      iex> Longbridge.HTTPClient.build_query(market: "US", symbol: nil)
      "market=US"
  """
  @spec build_query(keyword()) :: String.t()
  def build_query(kw) do
    kw
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
  end

  defp default_expired_at do
    System.system_time(:second) + @default_expired_at_seconds
  end

  defp unix_timestamp do
    Integer.to_string(System.system_time(:second))
  end
end
