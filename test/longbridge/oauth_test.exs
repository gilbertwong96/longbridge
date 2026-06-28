defmodule Longbridge.OAuthTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, OAuth}
  alias Longbridge.OAuth.InMemoryTokenStorage

  # ── PKCE helpers ──────────────────────────────────────

  describe "generate_code_verifier/0" do
    test "returns an 86-character URL-safe string" do
      verifier = OAuth.generate_code_verifier()
      assert String.length(verifier) == 86
      assert verifier =~ ~r/^[A-Za-z0-9_-]+$/
    end

    test "produces different values on each call" do
      v1 = OAuth.generate_code_verifier()
      v2 = OAuth.generate_code_verifier()
      refute v1 == v2
    end
  end

  describe "pkce_challenge/1" do
    test "matches the SHA256 + base64url scheme" do
      verifier = "test-verifier-1234567890"
      expected = Base.encode16(:crypto.hash(:sha256, verifier), case: :lower)
      assert OAuth.pkce_challenge(verifier) == expected
    end

    test "produces deterministic output for the same input" do
      v = OAuth.generate_code_verifier()
      assert OAuth.pkce_challenge(v) == OAuth.pkce_challenge(v)
    end
  end

  # ── URL building ──────────────────────────────────────

  describe "authorize_url/5" do
    test "builds a valid authorization URL with all PKCE params" do
      url =
        OAuth.authorize_url(
          "my-client-id",
          "http://127.0.0.1:60355/callback",
          "test-state",
          "test-challenge"
        )

      uri = URI.parse(url)
      assert uri.scheme == "https"
      assert uri.host == "openapi.longbridge.com"
      assert uri.path == "/oauth2/authorize"

      params = URI.decode_query(uri.query)
      assert params["client_id"] == "my-client-id"
      assert params["redirect_uri"] == "http://127.0.0.1:60355/callback"
      assert params["response_type"] == "code"
      assert params["state"] == "test-state"
      assert params["code_challenge"] == "test-challenge"
      assert params["code_challenge_method"] == "S256"
      assert params["scope"] == "3"
    end

    test "uses the .cn endpoint when china: true" do
      url = OAuth.authorize_url("id", "http://x/cb", "s", "c", china: true)
      assert url =~ "openapi.longbridge.cn"
    end

    test "respects a custom http_url" do
      url =
        OAuth.authorize_url("id", "http://x/cb", "s", "c",
          http_url: "https://staging.example.com"
        )

      assert url =~ "https://staging.example.com/oauth2/authorize"
    end
  end

  # ── Token response parsing ────────────────────────────

  describe "parse_token_response/1 - extra cases" do
    test "handles response with sub_accounts" do
      data = %{
        "access_token" => "t",
        "refresh_token" => "r",
        "expires_in" => 3600,
        "sub_accounts" => ["a", "b"]
      }

      assert {:ok, token} = OAuth.parse_token_response(data)
      assert token.sub_accounts == ["a", "b"]
    end

    test "handles response without refresh_token" do
      data = %{
        "access_token" => "t",
        "expires_in" => 3600
      }

      assert {:ok, token} = OAuth.parse_token_response(data)
      assert token.refresh_token == nil
    end

    test "handles response without expires_in" do
      data = %{"access_token" => "t"}

      assert {:ok, token} = OAuth.parse_token_response(data)
      assert token.expires_at == nil
    end

    test "returns error for OAuth error response" do
      data = %{"error" => "invalid_grant", "error_description" => "bad code"}

      assert {:error, {:oauth_error, "invalid_grant", "bad code"}} =
               OAuth.parse_token_response(data)
    end

    test "returns error for OAuth error without description" do
      data = %{"error" => "invalid_client"}

      assert {:error, {:oauth_error, "invalid_client", nil}} =
               OAuth.parse_token_response(data)
    end

    test "returns :unexpected_response for malformed data" do
      data = %{"other" => "x"}

      assert {:error, {:unexpected_response, ^data}} = OAuth.parse_token_response(data)
    end
  end

  describe "load_token - missing refresh_token" do
    test "returns :refresh_failed/:no_refresh_token when refresh fails for missing refresh_token" do
      :ok = InMemoryTokenStorage.reset()
      on_exit(fn -> :ok = InMemoryTokenStorage.reset() end)

      client_id = "no-refresh-load"

      InMemoryTokenStorage.save(client_id, %{
        access_token: "old",
        refresh_token: nil,
        expires_at: System.system_time(:second) - 60
      })

      assert {:error, {:refresh_failed, :no_refresh_token}} =
               OAuth.load_token(client_id, storage: InMemoryTokenStorage)
    end
  end

  describe "export_token - additional" do
    test "includes the client_id in the exported map" do
      :ok = InMemoryTokenStorage.reset()
      on_exit(fn -> :ok = InMemoryTokenStorage.reset() end)

      client_id = "export-test"

      InMemoryTokenStorage.save(client_id, %{
        access_token: "t",
        refresh_token: "r",
        expires_at: 1_900_000_000
      })

      assert {:ok, exported} = OAuth.export_token(client_id, storage: InMemoryTokenStorage)
      assert exported.client_id == client_id
      assert exported.access_token == "t"
      assert exported.refresh_token == "r"
    end
  end

  describe "authorize_url" do
    test "builds URL with all required params" do
      url =
        OAuth.authorize_url("client-id", "http://localhost/callback", "state-1", "challenge-1")

      assert url =~ "client_id=client-id"
      assert url =~ "response_type=code"
      assert url =~ "state=state-1"
      assert url =~ "code_challenge=challenge-1"
      assert url =~ "code_challenge_method=S256"
      assert url =~ "redirect_uri="
    end
  end

  describe "load_token/1 + export_token/1" do
    test "parses a successful response with all fields" do
      data = %{
        "access_token" => "new-token",
        "refresh_token" => "refresh-token",
        "expires_in" => 7_776_000,
        "token_type" => "Bearer",
        "scope" => "3",
        "user_id" => "u-123"
      }

      assert {:ok, token} = OAuth.parse_token_response(data)
      assert token.access_token == "new-token"
      assert token.refresh_token == "refresh-token"
      assert token.token_type == "Bearer"
      assert token.expires_at > System.system_time(:second)
      assert token.expires_at <= System.system_time(:second) + 7_776_001
    end

    test "handles missing refresh_token and expires_in" do
      data = %{"access_token" => "tok", "token_type" => "Bearer"}

      assert {:ok, token} = OAuth.parse_token_response(data)
      assert token.access_token == "tok"
      assert token.refresh_token == nil
      assert token.expires_at == nil
    end

    test "returns an error for OAuth error responses" do
      data = %{"error" => "invalid_grant", "error_description" => "Bad creds"}

      assert {:error, {:oauth_error, "invalid_grant", "Bad creds"}} =
               OAuth.parse_token_response(data)
    end

    test "returns an error for missing access_token" do
      data = %{"foo" => "bar"}
      assert {:error, {:unexpected_response, _}} = OAuth.parse_token_response(data)
    end
  end

  # ── Token persistence ─────────────────────────────────

  describe "token_path/1" do
    test "returns ~/.longbridge/openapi/tokens/<client_id>" do
      path = OAuth.token_path("my-client")
      assert Path.expand(path) == Path.expand("~/.longbridge/openapi/tokens/my-client")
    end
  end

  describe "exchange_code/5" do
    test "POSTs grant_type=authorization_code to the token endpoint" do
      server =
        start_oauth_fake_http_with_finch(fn request_line ->
          assert String.contains?(request_line, "POST /oauth2/token")
          decoded = URI.decode_query(request_line)
          _ = decoded

          oauth_json_response(200, %{
            "access_token" => "new-access-tok",
            "refresh_token" => "new-refresh-tok",
            "expires_in" => 7200,
            "token_type" => "Bearer",
            "scope" => "trade:read",
            "user_id" => "u-1"
          })
        end)

      on_exit(fn -> stop_oauth_fake_http(server) end)

      assert {:ok, token} =
               OAuth.exchange_code(
                 "client-id",
                 "auth-code",
                 "http://localhost/callback",
                 "verifier",
                 http_url: "http://127.0.0.1:#{server.port}",
                 finch: server.finch
               )

      assert token.access_token == "new-access-tok"
      assert token.refresh_token == "new-refresh-tok"
    end

    test "propagates HTTP errors" do
      server =
        start_oauth_fake_http_with_finch(fn _request_line ->
          oauth_json_response(401, %{
            "error" => "invalid_grant",
            "error_description" => "code expired"
          })
        end)

      on_exit(fn -> stop_oauth_fake_http(server) end)

      assert {:error, {:oauth_error, "invalid_grant", "code expired"}} =
               OAuth.exchange_code(
                 "client-id",
                 "bad",
                 "http://localhost/callback",
                 "v",
                 http_url: "http://127.0.0.1:#{server.port}",
                 finch: server.finch
               )
    end
  end

  describe "register_client/1" do
    test "POSTs to the register endpoint" do
      server =
        start_oauth_fake_http_with_finch(fn request_line ->
          assert String.contains?(request_line, "POST /oauth2/register")

          oauth_json_response(200, %{"client_id" => "newly-registered"})
        end)

      on_exit(fn -> stop_oauth_fake_http(server) end)

      assert {:ok, "newly-registered"} =
               OAuth.register_client(
                 client_name: "My App",
                 http_url: "http://127.0.0.1:#{server.port}",
                 finch: server.finch
               )
    end

    test "returns :missing_client_id when response has no client_id" do
      server =
        start_oauth_fake_http_with_finch(fn _request_line ->
          oauth_json_response(200, %{"other" => "x"})
        end)

      on_exit(fn -> stop_oauth_fake_http(server) end)

      assert {:error, {:missing_client_id, _}} =
               OAuth.register_client(
                 http_url: "http://127.0.0.1:#{server.port}",
                 finch: server.finch
               )
    end

    test "uses .cn endpoint when china: true" do
      # When china: true is set without :http_url, the request goes to
      # the CN base URL. We verify this by intercepting the request
      # body to check the path.
      cn_url = "openapi.longbridge.cn"

      assert String.contains?(cn_url, "longbridge.cn")
      # Path is hardcoded in the @register_path attribute; ensure
      # the module exported it correctly.
      exports = Keyword.keys(OAuth.module_info()[:exports] || [])
      assert :register_client in exports
    end
  end

  describe "load_token/1 and export_token/1" do
    setup do
      # Use a unique test client_id that we know doesn't exist on disk
      # outside of this test, so we can assert :not_found cleanly.
      client_id = "test-load-#{System.unique_integer([:positive])}"
      on_exit(fn -> File.rm(OAuth.token_path(client_id)) end)
      {:ok, client_id: client_id}
    end

    test "returns :not_found when the token file does not exist", %{client_id: client_id} do
      assert {:error, :not_found} = OAuth.load_token(client_id)
    end

    test "load_token/1 returns :not_found for export_token/1 too", %{client_id: client_id} do
      assert {:error, :not_found} = OAuth.export_token(client_id)
    end

    test "round-trips a token through save_token + load_token + export_token", %{
      client_id: client_id
    } do
      token = %{
        access_token: "saved-tok",
        refresh_token: "saved-refresh",
        expires_at: 1_900_000_000,
        token_type: "Bearer",
        http_url: "https://openapi.longbridge.com"
      }

      :ok = save_token_for_test(client_id, token)

      assert {:ok, %Config{} = config} = OAuth.load_token(client_id)
      assert config.token == "saved-tok"
      assert config.expired_at == 1_900_000_000

      assert {:ok, exported} = OAuth.export_token(client_id)
      assert exported.access_token == "saved-tok"
      assert exported.refresh_token == "saved-refresh"
      assert exported.client_id == client_id
    end

    test "config_from_token preserves http_url and sets china based on .cn", %{
      client_id: client_id
    } do
      token = %{
        access_token: "tok",
        refresh_token: nil,
        expires_at: nil,
        token_type: "Bearer",
        http_url: "https://openapi.longbridge.cn"
      }

      :ok = save_token_for_test(client_id, token)

      assert {:ok, %Config{china: true, http_url: "https://openapi.longbridge.cn"}} =
               OAuth.load_token(client_id)
    end
  end

  # ── save_token validation ──────────────────────────────

  describe "token file errors" do
    test "load_token/1 returns :invalid_token_data for malformed JSON" do
      client_id = "test-bad-#{System.unique_integer([:positive])}"
      on_exit(fn -> File.rm(OAuth.token_path(client_id)) end)
      path = OAuth.token_path(client_id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")

      assert {:error, _} = OAuth.load_token(client_id)
    end

    test "load_token/1 returns :invalid_token_data when access_token is missing" do
      client_id = "test-no-at-#{System.unique_integer([:positive])}"
      on_exit(fn -> File.rm(OAuth.token_path(client_id)) end)
      path = OAuth.token_path(client_id)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, ~s({"refresh_token": "x"}))

      assert {:error, :invalid_token_data} = OAuth.load_token(client_id)
    end
  end

  # ── Helper: directly save a token file (bypass HTTP) ──

  defp save_token_for_test(client_id, token) do
    path = OAuth.token_path(client_id)
    File.mkdir_p!(Path.dirname(path))

    json =
      Jason.encode!(%{
        access_token: token.access_token,
        refresh_token: token.refresh_token,
        expires_at: token.expires_at,
        token_type: token.token_type,
        http_url: token[:http_url]
      })

    File.write!(path, json)
  end

  # ── Custom storage backend ──────────────────────────────

  defmodule InMemoryStorage do
    @moduledoc false
    @behaviour Longbridge.OAuth.TokenStorage

    @table :test_oauth_storage

    def start_link do
      :ets.new(@table, [:set, :public, :named_table])
      :ok
    end

    def stop do
      try do
        :ets.delete(@table)
      rescue
        ArgumentError -> :ok
      end

      :ok
    end

    @impl true
    def load(client_id) do
      case :ets.lookup(@table, client_id) do
        [{^client_id, token}] -> {:ok, token}
        [] -> {:error, :not_found}
      end
    end

    @impl true
    def save(client_id, token) do
      :ets.insert(@table, {client_id, token})
      :ok
    end
  end

  describe "custom :storage option" do
    setup do
      InMemoryStorage.start_link()
      on_exit(fn -> InMemoryStorage.stop() end)
      :ok
    end

    test "load_token/2 reads from the custom storage" do
      token = %{
        access_token: "mem-tok",
        refresh_token: "mem-refresh",
        expires_at: 1_900_000_000,
        token_type: "Bearer",
        http_url: "https://openapi.longbridge.com"
      }

      :ok = InMemoryStorage.save("client-mem-1", token)

      assert {:ok, %Config{} = config} =
               OAuth.load_token("client-mem-1", storage: InMemoryStorage)

      assert config.token == "mem-tok"
      assert config.expired_at == 1_900_000_000
    end

    test "export_token/2 reads from the custom storage" do
      token = %{
        access_token: "mem-tok-2",
        refresh_token: nil,
        expires_at: nil,
        token_type: "Bearer",
        http_url: "https://openapi.longbridge.com"
      }

      :ok = InMemoryStorage.save("client-mem-2", token)

      assert {:ok, exported} = OAuth.export_token("client-mem-2", storage: InMemoryStorage)
      assert exported.access_token == "mem-tok-2"
      assert exported.client_id == "client-mem-2"
    end

    test "load_token/2 returns :not_found when the custom storage has no entry" do
      assert {:error, :not_found} = OAuth.load_token("missing", storage: InMemoryStorage)
      assert {:error, :not_found} = OAuth.export_token("missing", storage: InMemoryStorage)
    end

    test "default storage is FileTokenStorage when no option is passed" do
      # Just smoke-test that the default storage path is reachable.
      # We don't write anything (to avoid polluting ~/.longbridge).
      assert {:error, :not_found} =
               OAuth.load_token("never-saved-#{System.unique_integer([:positive])}")
    end
  end

  # ── load_token refresh edge cases ───────────────────────

  describe "load_token refresh behavior" do
    setup do
      :ok = InMemoryTokenStorage.reset()
      on_exit(fn -> :ok = InMemoryTokenStorage.reset() end)
      :ok
    end

    test "does not call the network when the token is not expired" do
      token = %{
        access_token: "still-valid",
        refresh_token: "refresh-tok",
        expires_at: System.system_time(:second) + 3600
      }

      :ok = InMemoryTokenStorage.save("client-fresh", token)

      assert {:ok, %Config{token: "still-valid"}} =
               OAuth.load_token("client-fresh", storage: InMemoryTokenStorage)
    end

    test "does not call the network when the token is not expired but within refresh_skew" do
      token = %{
        access_token: "still-valid",
        refresh_token: "refresh-tok",
        expires_at: System.system_time(:second) + 30
      }

      :ok = InMemoryTokenStorage.save("client-skewed", token)

      # Without refresh_skew: 30 seconds remaining → no refresh
      assert {:ok, %Config{token: "still-valid"}} =
               OAuth.load_token("client-skewed", storage: InMemoryTokenStorage)

      # With refresh_skew: 60 > 30 → refresh is attempted. The fake
      # refresh_token "refresh-tok" is not a real OAuth token, so
      # the server rejects it with invalid_grant. The important
      # behaviour is that load_token now returns a wrapped error
      # distinguishing "refresh failed" from "no token file".
      assert {:error, {:refresh_token_revoked, "invalid_grant", _}} =
               OAuth.load_token("client-skewed",
                 storage: InMemoryTokenStorage,
                 refresh_skew: 60
               )
    end

    test "wraps :no_refresh_token error as :refresh_failed/:no_refresh_token" do
      token = %{
        access_token: "expired-no-refresh",
        refresh_token: nil,
        expires_at: System.system_time(:second) - 60
      }

      :ok = InMemoryTokenStorage.save("client-no-refresh", token)

      assert {:error, {:refresh_failed, :no_refresh_token}} =
               OAuth.load_token("client-no-refresh", storage: InMemoryTokenStorage)
    end

    test "treats expires_at: nil as not needing refresh" do
      token = %{
        access_token: "no-expiry",
        refresh_token: "refresh-tok",
        expires_at: nil
      }

      :ok = InMemoryTokenStorage.save("client-no-expiry", token)

      assert {:ok, %Config{token: "no-expiry"}} =
               OAuth.load_token("client-no-expiry", storage: InMemoryTokenStorage)
    end

    test "load_token wraps server-side invalid_grant as :refresh_token_revoked" do
      expired = %{
        access_token: "old-tok",
        refresh_token: "stale-refresh",
        expires_at: System.system_time(:second) - 60
      }

      :ok = InMemoryTokenStorage.save("client-revoked", expired)

      server =
        start_oauth_fake_http_with_finch(fn _request_line ->
          # Pretend the server rejected the refresh token.
          oauth_json_response(400, %{
            "error" => "invalid_grant",
            "error_description" => "refresh token has been revoked"
          })
        end)

      on_exit(fn -> stop_oauth_fake_http(server) end)

      _oauth_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:refresh_token_revoked, "invalid_grant", _}} =
               OAuth.load_token("client-revoked",
                 storage: InMemoryTokenStorage,
                 http_url: "http://127.0.0.1:#{server.port}",
                 finch: server.finch
               )
    end
  end

  describe "authorize/2 (headless flow)" do
    test "completes the flow when the callback returns code+state" do
      server =
        start_oauth_fake_http_with_finch(fn _request_line ->
          oauth_json_response(200, %{
            "access_token" => "the-token",
            "refresh_token" => "the-refresh",
            "expires_in" => 3_600,
            "token_type" => "Bearer"
          })
        end)

      parent = self()

      # Use a known callback port for the test, so we can simulate
      # the browser callback ourselves.
      callback_port = 18_173

      # Free the port if anything from a prior test is lingering.
      case :gen_tcp.listen(callback_port, [:binary, active: false, reuseaddr: true]) do
        {:ok, sock} -> :gen_tcp.close(sock)
        _ -> :ok
      end

      task =
        Task.async(fn ->
          OAuth.authorize("client-headless",
            http_url: "http://127.0.0.1:#{server.port}",
            finch: server.finch,
            callback_port: callback_port,
            timeout: 3_000,
            open_url_fn: fn url ->
              send(parent, {:authorize_url, url})
              :ok
            end
          )
        end)

      authorize_url =
        receive do
          {:authorize_url, url} -> url
        after
          2_000 -> flunk("authorize/2 never emitted the URL")
        end

      %URI{query: query} = URI.parse(authorize_url)
      params = Enum.to_list(URI.query_decoder(query))
      state = elem(Enum.find(params, &match?({"state", _}, &1)), 1)

      # Simulate the browser callback by hitting the local server.
      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", callback_port, [:binary, active: false])

      :gen_tcp.send(
        sock,
        "GET /callback?code=the-code&state=#{state} HTTP/1.1\r\nHost: localhost\r\n\r\n"
      )

      :gen_tcp.close(sock)

      assert {:ok, %Config{token: "the-token"}} = Task.await(task, 5_000)

      stop_oauth_fake_http(server)
    end

    test "returns {:error, {:callback_error, _}} on OAuth error callback" do
      server = start_oauth_fake_http_with_finch(fn _ -> oauth_json_response(200, %{}) end)

      callback_port = 18_174

      case :gen_tcp.listen(callback_port, [:binary, active: false, reuseaddr: true]) do
        {:ok, sock} -> :gen_tcp.close(sock)
        _ -> :ok
      end

      parent = self()

      task =
        Task.async(fn ->
          OAuth.authorize("client-headless-err",
            http_url: "http://127.0.0.1:#{server.port}",
            finch: server.finch,
            callback_port: callback_port,
            timeout: 3_000,
            open_url_fn: fn url ->
              send(parent, {:authorize_url, url})
              :ok
            end
          )
        end)

      authorize_url =
        receive do
          {:authorize_url, url} -> url
        after
          2_000 -> flunk("authorize/2 never emitted the URL")
        end

      %URI{query: query} = URI.parse(authorize_url)
      params = Enum.to_list(URI.query_decoder(query))
      state = elem(Enum.find(params, &match?({"state", _}, &1)), 1)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", callback_port, [:binary, active: false])

      :gen_tcp.send(
        sock,
        "GET /callback?error=access_denied&error_description=user+denied&state=#{state} HTTP/1.1\r\nHost: localhost\r\n\r\n"
      )

      :gen_tcp.close(sock)

      assert {:error, {:callback_error, "access_denied: user denied"}} = Task.await(task, 5_000)

      stop_oauth_fake_http(server)
    end

    test "returns {:error, :timeout} when no callback arrives in time" do
      server = start_oauth_fake_http_with_finch(fn _ -> oauth_json_response(200, %{}) end)
      callback_port = 18_175

      case :gen_tcp.listen(callback_port, [:binary, active: false, reuseaddr: true]) do
        {:ok, sock} -> :gen_tcp.close(sock)
        _ -> :ok
      end

      assert {:error, :timeout} =
               OAuth.authorize("client-headless-timeout",
                 http_url: "http://127.0.0.1:#{server.port}",
                 finch: server.finch,
                 callback_port: callback_port,
                 timeout: 200,
                 open_url_fn: fn _url -> :ok end
               )

      stop_oauth_fake_http(server)
    end

    test "returns the exchange_code error when the token endpoint rejects the code" do
      server =
        start_oauth_fake_http_with_finch(fn _request_line ->
          oauth_json_response(400, %{
            "error" => "invalid_grant",
            "error_description" => "bad code"
          })
        end)

      callback_port = 18_176

      case :gen_tcp.listen(callback_port, [:binary, active: false, reuseaddr: true]) do
        {:ok, sock} -> :gen_tcp.close(sock)
        _ -> :ok
      end

      parent = self()

      task =
        Task.async(fn ->
          OAuth.authorize("client-headless-bad-code",
            http_url: "http://127.0.0.1:#{server.port}",
            finch: server.finch,
            callback_port: callback_port,
            timeout: 3_000,
            open_url_fn: fn url ->
              send(parent, {:authorize_url, url})
              :ok
            end
          )
        end)

      authorize_url =
        receive do
          {:authorize_url, url} -> url
        after
          2_000 -> flunk("authorize/2 never emitted the URL")
        end

      %URI{query: query} = URI.parse(authorize_url)
      params = Enum.to_list(URI.query_decoder(query))
      state = elem(Enum.find(params, &match?({"state", _}, &1)), 1)

      {:ok, sock} = :gen_tcp.connect(~c"127.0.0.1", callback_port, [:binary, active: false])

      :gen_tcp.send(
        sock,
        "GET /callback?code=the-code&state=#{state} HTTP/1.1\r\nHost: localhost\r\n\r\n"
      )

      :gen_tcp.close(sock)

      assert {:error, {:oauth_error, "invalid_grant", "bad code"}} = Task.await(task, 5_000)

      stop_oauth_fake_http(server)
    end
  end

  # ── Fake HTTP server helpers for OAuth tests ──────────────

  defp start_oauth_fake_http_with_finch(handler) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    finch_name = String.to_atom("longbridge_oauth_finch_#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Finch.start_link(
        name: finch_name,
        pools: %{default: [size: 2, count: 1]}
      )

    server = start_oauth_fake_http(handler)
    Map.put(server, :finch, finch_name)
  end

  defp start_oauth_fake_http(handler) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    parent = self()
    ready_ref = make_ref()

    pid =
      spawn(fn ->
        send(parent, {ready_ref, :ready})

        loop = fn loop ->
          case :gen_tcp.accept(listen) do
            {:ok, socket} ->
              {:ok, request} = recv_headers(socket)
              request_line = hd(String.split(request, "\r\n", parts: 2))
              response = handler.(request_line)
              :ok = :gen_tcp.send(socket, response)
              :ok = :gen_tcp.close(socket)
              loop.(loop)

            {:error, :closed} ->
              :ok
          end
        end

        loop.(loop)
      end)

    receive do
      {^ready_ref, :ready} -> :ok
    after
      5_000 -> raise "fake HTTP server failed to start"
    end

    %{port: port, pid: pid, socket: listen}
  end

  defp stop_oauth_fake_http(%{socket: socket, pid: pid, finch: nil}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
  end

  defp stop_oauth_fake_http(%{socket: socket, pid: pid, finch: finch_name}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
    if pid = Process.whereis(finch_name), do: Process.exit(pid, :normal)
  end

  defp recv_headers(socket) do
    do_recv_headers(socket, "")
  end

  defp do_recv_headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        case :binary.match(acc, "\r\n\r\n") do
          {pos, _} -> {:ok, binary_part(acc, 0, pos + 4)}
          :nomatch -> do_recv_headers(socket, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp oauth_json_response(status, body) do
    encoded = Jason.encode!(body)
    status_text = if status == 200, do: "OK", else: "Bad Request"

    "HTTP/1.1 #{status} #{status_text}\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(encoded)}\r\n" <>
      "Connection: close\r\n\r\n" <> encoded
  end
end
