defmodule Longbridge.OAuth do
  @moduledoc """
  OAuth 2.0 Authorization Code flow with PKCE for Longbridge OpenAPI.

  ## Desktop / interactive (browser available)

      {:ok, config} = Longbridge.OAuth.authorize("your-client-id")
      {:ok, ctx} = Longbridge.QuoteContext.start_link(config)

  The first call opens a browser, exchanges the code for a token, and
  persists the token to disk. Subsequent calls reuse the cached token
  transparently.

  ## Server / headless (no browser)

  1. Run the authorization flow on a machine with a browser:

         Longbridge.OAuth.authorize("your-client-id")

     This writes the token to `~/.longbridge/openapi/tokens/<client_id>`.

  2. Copy that file to the server (same path).

  3. On the server, load the persisted token:

         {:ok, config} = Longbridge.OAuth.load_token("your-client-id")

     Tokens auto-refresh via the `refresh_token` grant when expired.
     No browser, no interaction needed after the initial copy.

  ## CLI compatibility

  If you already ran `longbridge auth login`, the token is stored at
  the same path. `load_token/1` picks it up transparently.

  ## Token storage

  Tokens are persisted as JSON under:

      ~/.longbridge/openapi/tokens/<client_id>

  The file stores `access_token`, `refresh_token`, `expires_at`,
  `token_type`, and (when provided) the `http_url` used at auth time.

  ## Registering a client

  If you don't have a client_id yet:

      {:ok, client_id} = Longbridge.OAuth.register_client("My App")
  """

  alias Longbridge.Config
  alias Longbridge.OAuth.FileTokenStorage

  @oauth_base_url "https://openapi.longbridge.com"
  @oauth_base_url_cn "https://openapi.longbridge.cn"

  @authorize_path "/oauth2/authorize"
  @token_path "/oauth2/token"
  @register_path "/oauth2/register"

  @default_callback_port 60_355
  @callback_timeout 5 * 60_000
  @authorize_scope "3"

  @success_html """
  <!DOCTYPE html>
  <html><head><meta charset="utf-8"><title>Longbridge</title></head>
  <body style="font-family:sans-serif;text-align:center;margin-top:80px">
  <h2>✓ Authorization successful</h2>
  <p>You may close this window and return to your application.</p>
  </body></html>
  """

  @error_html """
  <!DOCTYPE html>
  <html><head><meta charset="utf-8"><title>Longbridge</title></head>
  <body style="font-family:sans-serif;text-align:center;margin-top:80px">
  <h2>✗ Authorization failed</h2>
  <p>%s</p>
  </body></html>
  """

  # ── Public API ──────────────────────────────────────────

  @doc """
  Runs the full OAuth 2.0 Authorization Code flow with PKCE.

  Starts a local callback server, opens the user's browser, waits for
  the callback, exchanges the code for a token, and persists the
  token to disk. Returns a `Longbridge.Config` ready for use.

  ## Options

  - `:callback_port` — TCP port for the local callback server
    (default 60355). Must match a registered redirect URI.
  - `:scope` — OAuth scope (default `"3"`).
  - `:china` — Use the `.longbridge.cn` endpoint (default `false`).
  - `:http_url` — Override the OAuth base URL.
  - `:open_url_fn` — Override the "open browser" function
    (default: `&open_browser/1`). Tests can pass a no-op.
  - `:timeout` — How long to wait for the user to approve
    (default 5 minutes).
  - `:storage` — Custom `Longbridge.OAuth.TokenStorage` implementation.
    Defaults to `Longbridge.OAuth.FileTokenStorage` (writes to
    `~/.longbridge/openapi/tokens/<client_id>`).
  """
  @spec authorize(String.t(), keyword()) ::
          {:ok, Config.t()} | {:error, term()}
  def authorize(client_id, opts \\ []) do
    http_url = Keyword.get(opts, :http_url, oauth_base_url(opts))
    callback_port = Keyword.get(opts, :callback_port, @default_callback_port)
    timeout = Keyword.get(opts, :timeout, @callback_timeout)
    redirect_uri = "http://127.0.0.1:#{callback_port}/callback"

    {verifier, challenge, state} = build_pkce_triple()

    url =
      authorize_url(client_id, redirect_uri, state, challenge,
        http_url: http_url,
        scope: Keyword.get(opts, :scope, @authorize_scope)
      )

    case start_callback_server(callback_port, timeout) do
      {:ok, listen, _port, _pid} ->
        try do
          run_authorize_flow(
            url,
            state,
            timeout,
            client_id,
            redirect_uri,
            verifier,
            http_url,
            opts
          )
        after
          :ok = stop_callback_listener(listen)
        end

      {:error, _reason} = err ->
        err
    end
  end

  defp run_authorize_flow(url, state, timeout, client_id, redirect_uri, verifier, http_url, opts) do
    with :ok <- Keyword.get(opts, :open_url_fn, &open_browser/1).(url),
         {:ok, code} <- await_callback(state, timeout) do
      complete_authorization(client_id, code, redirect_uri, verifier, http_url, opts)
    end
  end

  defp complete_authorization(client_id, code, redirect_uri, verifier, http_url, opts) do
    case exchange_code(client_id, code, redirect_uri, verifier,
           http_url: http_url,
           finch: Keyword.get(opts, :finch, Longbridge.Finch)
         ) do
      {:ok, token} -> persist_and_return(client_id, token, http_url, opts)
      {:error, _} = err -> err
    end
  end

  defp build_pkce_triple do
    verifier = generate_code_verifier()
    {verifier, pkce_challenge(verifier), generate_state()}
  end

  defp await_callback(expected_state, timeout) do
    receive do
      {:callback, code, ^expected_state} -> {:ok, code}
      {:callback, :error, message} -> {:error, {:callback_error, message}}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Generates the authorization URL for the OAuth flow.

  The user must open this URL in a browser and approve the request.
  After approval the browser redirects to `redirect_uri` with a `code`
  parameter.

  `code_challenge` is the PKCE S256 challenge, produced by
  `pkce_challenge(verifier)`.
  """
  @spec authorize_url(String.t(), String.t(), String.t(), String.t(), keyword()) :: String.t()
  def authorize_url(client_id, redirect_uri, state, code_challenge, opts \\ []) do
    http_url = Keyword.get(opts, :http_url, oauth_base_url(opts))

    params = %{
      client_id: client_id,
      redirect_uri: redirect_uri,
      response_type: "code",
      state: state,
      scope: Keyword.get(opts, :scope, @authorize_scope),
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }

    "#{http_url}#{@authorize_path}?#{URI.encode_query(params)}"
  end

  @doc """
  Exchanges an authorization code for an access token.

  Returns `{:ok, token_map}` with keys `:access_token`, `:refresh_token`,
  `:expires_at`, `:token_type`, and any other fields returned by the
  server (`scope`, `user_id`, `sub_accounts`).
  """
  @spec exchange_code(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def exchange_code(client_id, code, redirect_uri, code_verifier, opts \\ []) do
    http_url = Keyword.get(opts, :http_url, oauth_base_url(opts))
    finch = Keyword.get(opts, :finch, Longbridge.Finch)

    body =
      URI.encode_query(%{
        grant_type: "authorization_code",
        client_id: client_id,
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: code_verifier
      })

    with {:ok, data} <- http_form_post(http_url <> @token_path, body, finch) do
      parse_token_response(data)
    end
  end

  @doc """
  Refreshes an expired access token using the persisted refresh token.

  If `client_id` is given, reads the refresh token from disk first.
  Returns `{:ok, token_map}` or `{:error, reason}`.
  """
  @spec refresh_token(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def refresh_token(client_id, opts \\ []) do
    storage = resolve_storage(opts)
    finch = Keyword.get(opts, :finch, Longbridge.Finch)

    with {:ok, refresh_token, stored_http_url} <- read_refresh_token(client_id, storage) do
      # Prefer an explicit override, then the http_url persisted with the
      # token (so a .cn token refreshes against .cn even without
      # `china: true`), then the derived default.
      http_url = opts[:http_url] || stored_http_url || oauth_base_url(opts)

      body =
        URI.encode_query(%{
          grant_type: "refresh_token",
          client_id: client_id,
          refresh_token: refresh_token
        })

      with {:ok, data} <- http_form_post(http_url <> @token_path, body, finch) do
        case parse_token_response(data) do
          {:ok, token} -> persist_and_return(client_id, token, http_url, opts)
          error -> error
        end
      end
    end
  end

  @doc """
  Registers a new OAuth client and returns the `client_id`.

  The client is registered with the default PKCE settings and a
  localhost redirect URI. Use this to obtain a `client_id` before
  calling `authorize/2` for the first time.

  ## Options

  - `:client_name` — Display name (default `"My Longbridge OpenAPI"`).
  - `:redirect_uris` — List of redirect URIs (default
    `["http://127.0.0.1:60355/callback"]`).
  - `:http_url` — Override the OAuth base URL.
  """
  @spec register_client(keyword()) :: {:ok, String.t()} | {:error, term()}
  def register_client(opts \\ []) do
    http_url = Keyword.get(opts, :http_url, oauth_base_url(opts))
    finch = Keyword.get(opts, :finch, Longbridge.Finch)

    body =
      JSON.encode!(%{
        client_name: Keyword.get(opts, :client_name, "My Longbridge OpenAPI"),
        redirect_uris: Keyword.get(opts, :redirect_uris, ["http://127.0.0.1:60355/callback"]),
        token_endpoint_auth_method: "none",
        grant_types: ["authorization_code", "refresh_token"],
        response_types: ["code"]
      })

    with {:ok, data} <- http_json_post(http_url <> @register_path, body, finch) do
      case Map.get(data, "client_id") do
        id when is_binary(id) and id != "" -> {:ok, id}
        _ -> {:error, {:missing_client_id, data}}
      end
    end
  end

  @doc """
  Loads the persisted OAuth token and returns a `Longbridge.Config`.

  Designed for server-side programs that cannot open a browser.
  The token file must have been written by a previous `authorize/2`
  call (e.g. on a developer's workstation).

  If the access token is expired (or within `:refresh_skew` seconds
  of expiry), attempts a refresh via the stored `refresh_token`
  before returning.

  ## Options

    * `:storage` — A `Longbridge.OAuth.TokenStorage` implementation
      (default `Longbridge.OAuth.FileTokenStorage`).
    * `:refresh_skew` — Seconds before expiry to proactively refresh.
      Default `0` (only refresh after expiry). Set to e.g. `300`
      to refresh 5 minutes early.
    * `:http_url` — Override the OAuth base URL.

  ## Error cases

    * `{:error, :not_found}` — No token persisted for this client_id.
    * `{:error, {:refresh_failed, reason}}` — Refresh attempted but
      failed for a non-OAuth reason (e.g. network error).
    * `{:error, {:refresh_token_revoked, error, description}}` —
      The refresh_token was rejected by the OAuth server
      (`invalid_grant` or similar). User must re-authorize.
  """
  @spec load_token(String.t(), keyword()) ::
          {:ok, Config.t()}
          | {:error,
             :not_found
             | {:refresh_failed, term()}
             | {:refresh_token_revoked, String.t(), String.t() | nil}}
  def load_token(client_id, opts \\ []) do
    storage = resolve_storage(opts)

    with {:ok, token} <- storage.load(client_id) do
      config = config_from_token(client_id, token)

      if token_expired?(token, opts) do
        case refresh_token(client_id, opts) do
          {:ok, _} = ok ->
            ok

          {:error, :no_refresh_token} ->
            {:error, {:refresh_failed, :no_refresh_token}}

          {:error, {:oauth_error, error, description}} ->
            {:error, {:refresh_token_revoked, error, description}}

          {:error, reason} ->
            {:error, {:refresh_failed, reason}}
        end
      else
        {:ok, config}
      end
    end
  end

  @doc """
  Exports the persisted token as a map.

  Useful when copying a token from a developer workstation to
  a production server, or when loading it into a secret manager.

  Returns `{:ok, token_map}` or `{:error, reason}`.
  """
  @spec export_token(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export_token(client_id, opts \\ []) do
    storage = resolve_storage(opts)

    with {:ok, token} <- storage.load(client_id) do
      {:ok, Map.put(token, :client_id, client_id)}
    end
  end

  @doc """
  Generates a PKCE code verifier (43-128 character URL-safe string).

  The output is 86 characters of base64url-encoded randomness, which
  is within the RFC 7636 range (43-128 chars).
  """
  @spec generate_code_verifier() :: String.t()
  def generate_code_verifier do
    rand = :crypto.strong_rand_bytes(64)
    Base.url_encode64(rand, padding: false)
  end

  @doc """
  Computes the PKCE S256 code challenge from a verifier.

  Challenge = base64url(sha256(verifier)) without padding, per RFC 7636.
  """
  @spec pkce_challenge(String.t()) :: String.t()
  def pkce_challenge(verifier) do
    Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)
  end

  # ── Internal helpers ────────────────────────────────────

  defp oauth_base_url(opts) do
    cond do
      url = Keyword.get(opts, :http_url) -> url
      Keyword.get(opts, :china, false) -> @oauth_base_url_cn
      true -> @oauth_base_url
    end
  end

  defp generate_state do
    Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  defp start_callback_server(port, _timeout) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, packet: :raw]) do
      {:ok, listen} ->
        parent = self()

        pid =
          spawn_link(fn ->
            loop = fn loop ->
              case :gen_tcp.accept(listen) do
                {:ok, socket} ->
                  handle_callback(socket, parent)
                  loop.(loop)

                {:error, :closed} ->
                  :ok
              end
            end

            loop.(loop)
          end)

        Process.unlink(pid)
        {:ok, listen, port, pid}

      {:error, reason} ->
        {:error, {:listen_failed, reason}}
    end
  end

  # Closes the callback listen socket so the spawned acceptor's
  # :gen_tcp.accept/1 returns {:error, :closed} and its loop exits,
  # freeing the callback port. Called from authorize/2's try/after so
  # the listener is torn down on success, user decline, and timeout.
  defp stop_callback_listener(listen) do
    :gen_tcp.close(listen)
  end

  # Splits "GET /path?query HTTP/1.1\r\n..." into {method, path, body}.
  defp parse_callback_request(request) do
    [head, body] = String.split(request, "\r\n\r\n", parts: 2)
    [request_line | _header_lines] = String.split(head, "\r\n", parts: 2)
    [method, path, _version] = String.split(request_line, " ", parts: 3)
    {method, path, body}
  end

  defp handle_callback(socket, parent) do
    case recv_request(socket) do
      {:ok, request} ->
        {method, path, _body} = parse_callback_request(request)
        respond(socket, parent, method, path)

      {:error, reason} ->
        :gen_tcp.close(socket)
        send(parent, {:callback, :error, "request recv failed: #{inspect(reason)}"})
    end
  end

  defp respond(socket, parent, method, path) do
    response = build_response(parent, method, path)
    :ok = :gen_tcp.send(socket, response)
    :gen_tcp.close(socket)
    :ok
  end

  defp build_response(parent, method, path) do
    case {method, path} do
      {"GET", _} -> handle_get(parent, path)
      _ -> http_response(405, "method not allowed")
    end
  end

  defp handle_get(parent, path) do
    case extract_query_params(path) do
      %{"code" => code, "state" => state} ->
        send(parent, {:callback, code, state})
        http_response(200, @success_html)

      %{"error" => error, "error_description" => desc} ->
        send(parent, {:callback, :error, "#{error}: #{desc}"})
        http_response(400, error_html("#{error}: #{desc}"))

      other ->
        send(parent, {:callback, :error, "missing code in callback: #{inspect(other)}"})
        http_response(400, error_html("missing `code` parameter"))
    end
  end

  defp recv_request(socket) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, data} ->
        if String.contains?(data, "\r\n\r\n") do
          {:ok, data}
        else
          case :gen_tcp.recv(socket, 0, 5_000) do
            {:ok, more} -> {:ok, data <> more}
            {:error, _} -> {:ok, data}
          end
        end

      error ->
        error
    end
  end

  defp extract_query_params(path) do
    case String.split(path, "?", parts: 2) do
      [_path, query] -> URI.decode_query(query)
      [_path] -> %{}
    end
  end

  defp http_response(status, body) when is_binary(body) do
    reason = if status == 200, do: "OK", else: "Bad Request"

    "HTTP/1.1 #{status} #{reason}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
  end

  defp error_html(message) do
    String.replace(@error_html, "%s", message)
  end

  # ── Token persistence ──────────────────────────────────

  # Resolves the storage backend from `opts`. Falls back to
  # `Longbridge.OAuth.FileTokenStorage` when no `:storage` option is
  # given. Users can pass any module implementing the
  # `Longbridge.OAuth.TokenStorage` behaviour to plug in their own
  # backend (Redis, Vault, KMS, in-memory cache for tests, etc.).
  defp resolve_storage(opts) do
    Keyword.get(opts, :storage, FileTokenStorage)
  end

  # Backwards-compatible path helper. Kept as `token_path/1` because
  # it was previously a public function and may be used externally.
  # Delegates to `FileTokenStorage.token_path/1`, which is the
  # canonical accessor for the on-disk path.
  @doc false
  defdelegate token_path(client_id), to: FileTokenStorage

  defp read_refresh_token(client_id, storage) do
    case storage.load(client_id) do
      {:ok, %{refresh_token: refresh_token} = token} when is_binary(refresh_token) ->
        {:ok, refresh_token, Map.get(token, :http_url)}

      {:ok, _} ->
        {:error, :no_refresh_token}

      {:error, _} = err ->
        err
    end
  end

  defp token_expired?(token, opts) do
    skew = Keyword.get(opts, :refresh_skew, 0)

    case token do
      %{expires_at: nil} ->
        false

      %{expires_at: expires_at} ->
        expires_at <= System.system_time(:second) + skew
    end
  end

  defp config_from_token(_client_id, token) do
    http_url = token[:http_url] || @oauth_base_url
    china = String.contains?(http_url, ".cn")

    Config.new(
      token: token.access_token,
      expired_at: token.expires_at,
      http_url: http_url,
      china: china
    )
  end

  defp persist_and_return(client_id, token, http_url, opts) do
    storage = resolve_storage(opts)
    token = Map.put(token, :http_url, http_url)
    :ok = storage.save(client_id, token)
    {:ok, config_from_token(client_id, token)}
  end

  # ── HTTP helpers (Finch, no signing) ───────────────────

  defp http_form_post(url, body, finch) do
    headers = [{"content-type", "application/x-www-form-urlencoded"}]
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        case JSON.decode(resp_body) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:error, :invalid_json}
        end

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        case JSON.decode(resp_body) do
          {:ok, data} -> parse_token_response(data)
          {:error, _} -> {:error, {:http_status, status, resp_body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_json_post(url, body, finch) do
    headers = [{"content-type", "application/json"}]
    request = Finch.build(:post, url, headers, body)

    case Finch.request(request, finch, receive_timeout: 15_000) do
      {:ok, %Finch.Response{status: status, body: resp_body}} when status in 200..299 ->
        JSON.decode(resp_body)

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_status, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  @spec parse_token_response(map()) :: {:ok, map()} | {:error, term()}
  def parse_token_response(%{"access_token" => access_token} = data) do
    {:ok,
     %{
       access_token: access_token,
       refresh_token: Map.get(data, "refresh_token"),
       expires_at: compute_expires_at(Map.get(data, "expires_in")),
       token_type: Map.get(data, "token_type", "Bearer"),
       scope: Map.get(data, "scope"),
       user_id: Map.get(data, "user_id"),
       sub_accounts: Map.get(data, "sub_accounts")
     }}
  end

  def parse_token_response(%{"error" => err, "error_description" => desc}) do
    {:error, {:oauth_error, err, desc}}
  end

  def parse_token_response(%{"error" => err}) do
    {:error, {:oauth_error, err, nil}}
  end

  def parse_token_response(data), do: {:error, {:unexpected_response, data}}

  defp compute_expires_at(nil), do: nil

  defp compute_expires_at(expires_in) when is_integer(expires_in) do
    System.system_time(:second) + expires_in
  end

  # ── Browser launcher ───────────────────────────────────

  @doc false
  @spec open_browser(String.t()) :: :ok | {:error, term()}
  def open_browser(url) when is_binary(url) do
    {cmd, args} = browser_command(url)

    case System.cmd(cmd, args) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:browser_exit, code}}
    end
  end

  defp browser_command(url) do
    case :os.type() do
      {:win32, _} -> {"cmd", ["/c", "start", url]}
      {:unix, :darwin} -> {"open", [url]}
      {:unix, _} -> {"xdg-open", [url]}
    end
  end
end
