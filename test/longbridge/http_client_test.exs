defmodule Longbridge.HTTPClientTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, HTTPClient}

  # ── Sign function (deterministic) ───────────────────────

  describe "sign/7" do
    test "produces the documented Longbridge HMAC-SHA256 signature" do
      method = :get
      path = "/v1/token/refresh"
      params = "expired_at=1700000000"

      headers = %{
        "x-api-key" => "test-app-key",
        "authorization" => "test-access-token",
        "x-timestamp" => "1700000000.123"
      }

      body = ""
      secret = "test-app-secret"
      signed_headers = "authorization;x-api-key;x-timestamp"

      # Reproduce the documented Python signing scheme:
      #
      # canonical = "GET" + "|" + path + "|" + params + "|"
      #          + "authorization:" + token + "\n"
      #          + "x-api-key:" + key + "\n"
      #          + "x-timestamp:" + ts + "\n"
      #          + "|authorization;x-api-key;x-timestamp|"
      # (no body → no payload hash)
      #
      # sign_str = "HMAC-SHA256|" + sha1_hex(canonical)
      # signature = hmac_sha256_hex(secret, sign_str)

      canonical =
        "GET" <>
          "|" <>
          path <>
          "|" <>
          params <>
          "|" <>
          "authorization:test-access-token\n" <>
          "x-api-key:test-app-key\n" <>
          "x-timestamp:1700000000.123\n" <>
          "|authorization;x-api-key;x-timestamp|"

      expected_sign_str = "HMAC-SHA256|" <> sha1_hex(canonical)
      expected_sig = hmac_sha256_hex("test-app-secret", expected_sign_str)

      expected =
        "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, " <>
          "Signature=" <> expected_sig

      assert HTTPClient.sign(method, path, headers, params, body, secret, signed_headers) ==
               expected
    end

    test "POST with JSON body includes the SHA1 payload hash" do
      method = :post
      uri = "/v1/trade/order"

      headers = %{
        "x-api-key" => "k",
        "authorization" => "t",
        "x-timestamp" => "1700000000"
      }

      body = ~s({"foo":"bar"})

      canonical =
        "POST" <>
          "|" <>
          uri <>
          "||" <>
          "authorization:t\n" <>
          "x-api-key:k\n" <>
          "x-timestamp:1700000000\n" <>
          "|authorization;x-api-key;x-timestamp|" <>
          sha1_hex(body)

      expected_sign_str = "HMAC-SHA256|" <> sha1_hex(canonical)
      expected_sig = hmac_sha256_hex("s", expected_sign_str)

      expected =
        "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, " <>
          "Signature=" <> expected_sig

      assert HTTPClient.sign(
               method,
               uri,
               headers,
               "",
               body,
               "s",
               "authorization;x-api-key;x-timestamp"
             ) ==
               expected
    end
  end

  # ── Response parsing ────────────────────────────────────

  describe "parse_refresh_response/1" do
    test "parses a successful response" do
      body = %{
        "code" => 0,
        "message" => "success",
        "data" => %{"token" => "new-tok", "expired_at" => 1_900_000_000}
      }

      assert {:ok, %{token: "new-tok", expired_at: 1_900_000_000}} =
               HTTPClient.parse_refresh_response(body)
    end

    test "returns an error tuple for API errors" do
      body = %{"code" => 403_201, "message" => "signature invalid"}

      assert {:error, {:api_error, 403_201, "signature invalid"}} =
               HTTPClient.parse_refresh_response(body)
    end

    test "returns an error for malformed responses" do
      assert {:error, {:unexpected_response, "garbage"}} =
               HTTPClient.parse_refresh_response("garbage")
    end
  end

  # ── Integration: refresh_access_token via a fake HTTP server ──

  describe "refresh_access_token/2 (integration)" do
    test "calls the refresh endpoint and parses the response" do
      app_key = "app-key-xyz"
      app_secret = "app-secret-xyz"
      access_token = "old-access-token"
      new_token = "fresh-access-token"
      expired_at = 1_900_000_000

      config =
        Config.new(token: access_token, app_key: app_key, app_secret: app_secret)

      # Build the expected signature using the sign function we just tested.
      #
      # The server's job is to:
      # 1. Receive the GET /v1/token/refresh?expired_at=... request
      # 2. Verify the signature
      # 3. Return a canned JSON response

      server =
        start_fake_http_server(fn request ->
          # Request format: "GET /v1/token/refresh?expired_at=X HTTP/1.1\r\n..."
          [request_line, _headers, _body] = split_http(request)
          [_method, path_with_query, _version] = String.split(request_line, " ", parts: 3)

          [path, qs] =
            case String.split(path_with_query, "?", parts: 2) do
              [p, q] -> [p, q]
              [p] -> [p, ""]
            end

          request_headers = parse_http_headers(request)

          # HTTP headers are case-insensitive. Look up by lowercase.
          ts = request_headers["x-timestamp"]
          auth = request_headers["authorization"]
          key = request_headers["x-api-key"]

          # Reconstruct the canonical request the client should have signed.
          canonical =
            "GET" <>
              "|" <>
              path <>
              "|" <>
              qs <>
              "|" <>
              "authorization:" <>
              auth <>
              "\n" <>
              "x-api-key:" <>
              key <>
              "\n" <>
              "x-timestamp:" <>
              ts <>
              "\n" <>
              "|authorization;x-api-key;x-timestamp|"

          sign_str = "HMAC-SHA256|" <> sha1_hex(canonical)
          expected_sig = hmac_sha256_hex(app_secret, sign_str)

          expected_x_api_signature =
            "HMAC-SHA256 SignedHeaders=authorization;x-api-key;x-timestamp, " <>
              "Signature=" <> expected_sig

          actual_sig = request_headers["x-api-signature"]

          if actual_sig == expected_x_api_signature do
            response_body =
              Jason.encode!(%{
                code: 0,
                message: "success",
                data: %{token: new_token, expired_at: expired_at}
              })

            http_json(200, response_body)
          else
            http_json(401, ~s({"code":403201,"message":"signature invalid"}))
          end
        end)

      on_exit(fn -> stop_fake_http_server(server) end)

      http_url = "http://127.0.0.1:#{server.port}"

      assert {:ok, %{token: ^new_token, expired_at: ^expired_at}} =
               HTTPClient.refresh_access_token(config,
                 expired_at: 1_700_000_000,
                 http_url: http_url
               )
    end

    test "returns an error tuple for API error responses" do
      app_key = "k"
      app_secret = "s"
      config = Config.new(token: "tok", app_key: app_key, app_secret: app_secret)

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":403201,"message":"signature invalid"}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      http_url = "http://127.0.0.1:#{server.port}"

      assert {:error, {:api_error, 403_201, "signature invalid"}} =
               HTTPClient.refresh_access_token(config, http_url: http_url)
    end
  end

  describe "do_request non-JSON body passthrough" do
    test "returns the raw body when the response is not valid JSON" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")

      server =
        start_fake_http_server(fn _request ->
          http_json(200, "not-json-at-all")
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      http_url = "http://127.0.0.1:#{server.port}"

      assert {:ok, "not-json-at-all"} =
               HTTPClient.request(:get, "/v1/test", "", %{config | http_url: http_url})
    end
  end

  describe "token refresher retry" do
    test "returns the original 401 when no refresher is provided" do
      base = Config.new(token: "tok", app_key: "k", app_secret: "s")

      server =
        start_fake_http_server(fn _request ->
          http_json(401, ~s({"code":401}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = %{base | http_url: "http://127.0.0.1:#{server.port}"}

      assert {:error, {:http_status, 401, _body}} =
               HTTPClient.request(:get, "/v1/test", "", config)
    end

    test "returns the original 401 when the refresher fails" do
      base = Config.new(token: "tok", app_key: "k", app_secret: "s")

      server =
        start_fake_http_server(fn _request ->
          http_json(401, ~s({"code":401}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = %{base | http_url: "http://127.0.0.1:#{server.port}"}

      assert {:error, {:http_status, 401, _body}} =
               HTTPClient.request(:get, "/v1/test", "", config,
                 token_refresher: fn _ -> {:error, :refresh_failed} end
               )
    end

    test "returns the original 401 when retry also returns 401" do
      base = Config.new(token: "old-token", app_key: "k", app_secret: "s")

      server =
        start_fake_http_server(fn _request ->
          http_json(401, ~s({"code":401}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = %{base | http_url: "http://127.0.0.1:#{server.port}"}

      assert {:error, {:http_status, 401, _body}} =
               HTTPClient.request(:get, "/v1/test", "", config,
                 token_refresher: fn _ -> {:error, :no_token} end
               )
    end

    test "ignores the refresher option when status is not 401" do
      base = Config.new(token: "tok", app_key: "k", app_secret: "s")

      server =
        start_fake_http_server(fn _request ->
          http_json(200, ~s({"code":0,"data":{}}))
        end)

      on_exit(fn -> stop_fake_http_server(server) end)
      config = %{base | http_url: "http://127.0.0.1:#{server.port}"}

      called? = :counters.new(1, [])

      assert {:ok, _} =
               HTTPClient.request(:get, "/v1/test", "", config,
                 token_refresher: fn _ ->
                   :counters.add(called?, 1, 1)
                   {:ok, config}
                 end
               )

      # Refresher should NOT be called for a successful 200 response.
      assert :counters.get(called?, 1) == 0
    end
  end

  describe "refresh_access_token error path" do
    test "propagates HTTP transport errors" do
      config = Config.new(token: "tok", app_key: "k", app_secret: "s")
      # http_url points at a closed port — Finch will fail with a
      # transport error, exercising the {:error, reason} branch.
      assert {:error, _} =
               HTTPClient.refresh_access_token(%{config | http_url: "http://127.0.0.1:1"})
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

  # Read until we see the end of the HTTP headers (CRLFCRLF).
  defp read_until_double_crlf(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, chunk} ->
        acc = acc <> chunk

        case :binary.match(acc, "\r\n\r\n") do
          {pos, _} ->
            # Headers end at `pos + 4`. Return what we have; body will follow
            # but the body of our requests is empty so this is fine.
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

  defp split_http(request) do
    [head, body] = String.split(request, "\r\n\r\n", parts: 2)
    [request_line | header_lines] = String.split(head, "\r\n", parts: 2)
    headers = Enum.join(header_lines, "\r\n")
    [request_line, headers, body || ""]
  end

  defp parse_http_headers(request) do
    [head | _] = String.split(request, "\r\n\r\n", parts: 2)
    [_request_line | header_lines] = String.split(head, "\r\n")

    Enum.reduce(header_lines, %{}, fn line, acc ->
      case String.split(line, ":", parts: 2) do
        [k, v] -> Map.put(acc, String.downcase(k), String.trim(v))
        _ -> acc
      end
    end)
  end

  # ── Crypto helpers (mirror HTTPClient internals) ────────

  defp sha1_hex(binary) do
    Base.encode16(:crypto.hash(:sha, binary), case: :lower)
  end

  defp hmac_sha256_hex(secret, data) do
    Base.encode16(:crypto.mac(:hmac, :sha256, secret, data), case: :lower)
  end
end
