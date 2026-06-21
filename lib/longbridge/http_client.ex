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
  """
  @spec request(atom(), String.t(), String.t(), Config.t(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def request(method, path, body, %Config{} = config, opts \\ []) do
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

    request_headers = [
      {"x-api-key", config.app_key},
      {"authorization", config.token},
      {"x-timestamp", ts},
      {"x-api-signature", signature_header}
    ]

    do_request(method, http_url, path_with_query, request_headers, body, opts)
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
          {:ok, map()} | {:error, term()}
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
