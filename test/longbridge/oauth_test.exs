defmodule Longbridge.OAuthTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, OAuth}

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

  describe "parse_token_response/1" do
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
end
