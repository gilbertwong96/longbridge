defmodule Longbridge.ConfigHTTPTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, HTTPClient}

  # ── Config.new/1 ─────────────────────────────────────────

  describe "Config.new/1 defaults" do
    test "sets international endpoints by default" do
      config = Config.new()

      assert config.http_url == "https://openapi.longbridge.com"
      assert config.quote_ws_url == "wss://openapi-quote.longbridge.com"
      assert config.trade_ws_url == "wss://openapi-trade.longbridge.com"
    end

    test "defaults timing fields" do
      config = Config.new()

      assert config.heartbeat_interval == 15_000
      assert config.request_timeout == 10_000
      assert config.idle_timeout == 600_000
      assert config.gzip_threshold == 1024
    end

    test "defaults token fields to nil" do
      config = Config.new()

      assert config.token == nil
      assert config.app_key == nil
      assert config.app_secret == nil
      assert config.expired_at == nil
    end

    test "struct default idle_timeout matches Config.new/1 (600_000)" do
      # The defstruct default and Config.new/1 must agree — a 60_000 vs
      # 600_000 mismatch previously made %Config{} drop connections 10x
      # too fast.
      assert %Config{}.idle_timeout == Config.new().idle_timeout
      assert %Config{}.idle_timeout == 600_000
    end
  end

  describe "Config.new/1 china endpoints" do
    test "uses .cn domains when china: true" do
      config = Config.new(china: true)

      assert config.china == true
      assert config.http_url == "https://openapi.longbridge.cn"
      assert config.quote_ws_url == "wss://openapi-quote.longbridge.cn"
      assert config.trade_ws_url == "wss://openapi-trade.longbridge.cn"
    end
  end

  describe "Config.new/1 overrides" do
    test "honours custom WS URLs" do
      custom_ws = "wss://custom.example.com"

      config =
        Config.new(
          quote_ws_url: custom_ws,
          trade_ws_url: custom_ws
        )

      assert config.quote_ws_url == custom_ws
      assert config.trade_ws_url == custom_ws
    end

    test "honours custom WS URL overrides" do
      config =
        Config.new(
          quote_ws_url: "wss://q.example.com",
          trade_ws_url: "wss://t.example.com"
        )

      assert config.quote_ws_url == "wss://q.example.com"
      assert config.trade_ws_url == "wss://t.example.com"
    end

    test "honours custom timing overrides" do
      config =
        Config.new(
          heartbeat_interval: 5_000,
          request_timeout: 30_000,
          idle_timeout: 120_000,
          gzip_threshold: 512
        )

      assert config.heartbeat_interval == 5_000
      assert config.request_timeout == 30_000
      assert config.idle_timeout == 120_000
      assert config.gzip_threshold == 512
    end

    test "honours custom http_url" do
      config = Config.new(http_url: "https://custom.api.com")
      assert config.http_url == "https://custom.api.com"
    end

    test "stores custom headers as a list of tuples" do
      config =
        Config.new(headers: [{"X-Forwarded-For", "1.2.3.4"}, {"X-Tenant", "acme"}])

      assert config.headers == [{"X-Forwarded-For", "1.2.3.4"}, {"X-Tenant", "acme"}]
    end

    test "normalises atom keys to strings" do
      config =
        Config.new(headers: [{:"X-Forwarded-For", "1.2.3.4"}, {:x_tenant, "acme"}])

      assert config.headers == [{"X-Forwarded-For", "1.2.3.4"}, {"x_tenant", "acme"}]
    end

    test "defaults headers to nil" do
      config = Config.new()
      assert config.headers == nil
    end
  end

  # ── Config.with_socket_token/1 ──────────────────────────

  describe "Config.with_socket_token/1" do
    test "returns {:ok, config} unchanged when app_key is nil" do
      config = Config.new(token: "long-token-value-here")

      assert {:ok, ^config} = Config.with_socket_token(config)
    end

    test "returns {:ok, config} unchanged when app_secret is nil" do
      config = Config.new(token: "long-token-value-here", app_key: "key")

      assert {:ok, ^config} = Config.with_socket_token(config)
    end

    test "returns {:ok, config} unchanged when token is already short (OTP-like)" do
      otp = "15766270:21526413:0984363c4eb9ded15f7055cd49953c52"

      config =
        Config.new(
          token: otp,
          app_key: "app-key",
          app_secret: "app-secret"
        )

      assert {:ok, ^config} = Config.with_socket_token(config)
    end

    test "fetches OTP from HTTP API when token is long and credentials present" do
      otp = "12345:67890:abcdef"
      long_token = String.duplicate("a", 120)

      config =
        Config.new(
          token: long_token,
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":0,"data":{"otp":"#{otp}"}}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:ok, new_config} = Config.with_socket_token(%{config | http_url: http_url})
      assert new_config.token == otp
      assert new_config.app_key == "app-key"
    end

    test "returns error when HTTP API fails" do
      long_token = String.duplicate("a", 120)

      config =
        Config.new(
          token: long_token,
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(401, ~s({"code":401004,"message":"token invalid"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:http_status, 401, _}} =
               Config.with_socket_token(%{config | http_url: http_url})
    end
  end

  # ── Config.refresh_access_token/2 ───────────────────────

  describe "Config.refresh_access_token/2" do
    test "returns updated config with new token and expiry" do
      new_token = "fresh-access-token"
      expired_at = 1_900_000_000

      config =
        Config.new(
          token: "old-token",
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(
            200,
            ~s({"code":0,"data":{"token":"#{new_token}","expired_at":#{expired_at}}})
          )
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:ok, new_config} =
               Config.refresh_access_token(%{config | http_url: http_url},
                 expired_at: 1_700_000_000
               )

      assert new_config.token == new_token
      assert new_config.expired_at == expired_at
    end

    test "returns error when API rejects" do
      config =
        Config.new(
          token: "old-token",
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":403201,"message":"signature invalid"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:api_error, 403_201, "signature invalid"}} =
               Config.refresh_access_token(%{config | http_url: http_url})
    end
  end

  # ── HTTPClient.get_socket_token/1 ───────────────────────

  describe "HTTPClient.get_socket_token/1" do
    test "returns OTP on success" do
      otp = "12345:67890:abcdef"

      config =
        Config.new(
          token: "access-token",
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":0,"data":{"otp":"#{otp}"}}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:ok, ^otp} = HTTPClient.get_socket_token(%{config | http_url: http_url})
    end

    test "returns error on HTTP 401" do
      config =
        Config.new(
          token: "access-token",
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(401, ~s({"code":401004,"message":"token invalid"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:http_status, 401, _}} =
               HTTPClient.get_socket_token(%{config | http_url: http_url})
    end

    test "returns error when otp field is missing" do
      config =
        Config.new(
          token: "access-token",
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":0,"data":{"something":"else"}}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:missing_otp, _}} =
               HTTPClient.get_socket_token(%{config | http_url: http_url})
    end

    test "returns error on API error code" do
      config =
        Config.new(
          token: "access-token",
          app_key: "app-key",
          app_secret: "app-secret"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":500,"message":"internal error"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:api_error, 500, "internal error"}} =
               HTTPClient.get_socket_token(%{config | http_url: http_url})
    end
  end

  # ── HTTPClient.request_json/5 ───────────────────────────

  describe "HTTPClient.request_json/5" do
    test "returns {:ok, data} when code is 0" do
      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":0,"data":{"key":"val"}}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:ok, %{"key" => "val"}} =
               HTTPClient.request_json(:get, "/v1/test", "", %{config | http_url: http_url})
    end

    test "returns {:error, {:api_error, code, msg}} when code is non-zero" do
      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":403,"message":"forbidden"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:api_error, 403, "forbidden"}} =
               HTTPClient.request_json(:get, "/v1/test", "", %{config | http_url: http_url})
    end

    test "returns error on HTTP non-200" do
      config =
        Config.new(
          token: "tok",
          app_key: "k",
          app_secret: "s"
        )

      server =
        start_fake_http_server(fn _request ->
          http_json(500, ~s({"error":"server error"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:http_status, 500, _}} =
               HTTPClient.request_json(:get, "/v1/test", "", %{config | http_url: http_url})
    end
  end

  # ── HTTPClient.build_query/1 ────────────────────────────

  describe "HTTPClient.build_query/1" do
    test "builds a query string from a keyword list" do
      assert HTTPClient.build_query(market: "US", symbol: "AAPL") ==
               "market=US&symbol=AAPL"
    end

    test "filters out nil values" do
      assert HTTPClient.build_query(market: "US", symbol: nil) ==
               "market=US"
    end

    test "URI-encodes values" do
      assert HTTPClient.build_query(q: "hello world&foo") ==
               "q=hello+world%26foo"
    end

    test "handles empty keyword list" do
      assert HTTPClient.build_query([]) == ""
    end

    test "handles integer values" do
      assert HTTPClient.build_query(count: 42) == "count=42"
    end
  end

  # ── HTTPClient.sign/7 ───────────────────────────────────

  describe "HTTPClient.sign/7" do
    test "GET with no body omits payload hash" do
      method = :get
      path = "/v1/socket/token"

      headers = %{
        "authorization" => "tok",
        "x-api-key" => "key",
        "x-timestamp" => "123"
      }

      result =
        HTTPClient.sign(
          method,
          path,
          headers,
          "",
          "",
          "secret",
          "authorization;x-api-key;x-timestamp"
        )

      assert String.starts_with?(
               result,
               "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, Signature="
             )

      canonical = canonical_no_body(method, path, headers)
      expected_sig = hmac_sha256_hex("secret", "HMAC-SHA256|" <> sha1_hex(canonical))

      assert result ==
               "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, Signature=#{expected_sig}"
    end

    test "POST with body includes payload hash" do
      method = :post
      path = "/v1/trade/order"
      body = ~s({"symbol":"AAPL"})

      headers = %{
        "authorization" => "tok",
        "x-api-key" => "key",
        "x-timestamp" => "123"
      }

      result =
        HTTPClient.sign(
          method,
          path,
          headers,
          "",
          body,
          "secret",
          "authorization;x-api-key;x-timestamp"
        )

      assert String.starts_with?(result, "HMAC-SHA256 SignedHeaders=")
    end

    test "produces deterministic output for same inputs" do
      headers = %{
        "authorization" => "tok",
        "x-api-key" => "key",
        "x-timestamp" => "123"
      }

      sig1 =
        HTTPClient.sign(
          :get,
          "/v1/test",
          headers,
          "",
          "",
          "secret",
          "authorization;x-api-key;x-timestamp"
        )

      sig2 =
        HTTPClient.sign(
          :get,
          "/v1/test",
          headers,
          "",
          "",
          "secret",
          "authorization;x-api-key;x-timestamp"
        )

      assert sig1 == sig2
    end
  end

  # ── Fake HTTP server (raw TCP) ──────────────────────────

  defp start_fake_http_server(handler) do
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
              {:ok, request} = recv_http_request(socket)
              response = handler.(request)
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

  defp stop_fake_http_server(%{socket: socket, pid: pid}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(socket)
  end

  defp recv_http_request(socket) do
    read_until_double_crlf(socket, "")
  end

  defp read_until_double_crlf(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        case :binary.match(acc, "\r\n\r\n") do
          {pos, _} ->
            {:ok, binary_part(acc, 0, pos + 4)}

          :nomatch ->
            read_until_double_crlf(socket, acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp http_json(status, body) do
    status_text = if status == 200, do: "OK", else: "Bad Request"

    "HTTP/1.1 #{status} #{status_text}\r\n" <>
      "Content-Type: application/json\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n" <>
      "Connection: close\r\n\r\n" <> body
  end

  # ── Crypto helpers ──────────────────────────────────────

  defp sha1_hex(binary) do
    Base.encode16(:crypto.hash(:sha, binary), case: :lower)
  end

  defp hmac_sha256_hex(secret, data) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, data), case: :lower)
  end

  defp canonical_no_body(method, path, headers) do
    mtd = method |> to_string() |> String.upcase()

    mtd <>
      "|" <>
      path <>
      "||" <>
      "authorization:#{headers["authorization"]}\n" <>
      "x-api-key:#{headers["x-api-key"]}\n" <>
      "x-timestamp:#{headers["x-timestamp"]}\n" <>
      "|authorization;x-api-key;x-timestamp|"
  end
end
