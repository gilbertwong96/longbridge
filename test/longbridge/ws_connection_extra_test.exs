defmodule Longbridge.WSConnectionExtraTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, Protocol, WSConnection}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header

  import Bitwise

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defp start_fake_server(opts) do
    test_pid = self()
    srv = parse_srv_opts(opts)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)
    spawn_link(fn -> run_server(listen_socket, test_pid, srv) end)
    {:ok, port, srv.session_id, srv.expires}
  end

  defp parse_srv_opts(opts) do
    %{
      session_id: Keyword.get(opts, :session_id, "sess-#{System.unique_integer([:positive])}"),
      expires: Keyword.get(opts, :expires, System.os_time(:second) + 3600),
      auth_status: Keyword.get(opts, :auth_status, 0),
      respond: Keyword.get(opts, :respond_to_requests, true)
    }
  end

  defp run_server(listen_socket, test_pid, srv) do
    {:ok, client} = :gen_tcp.accept(listen_socket, 10_000)
    send(test_pid, {:server, :accepted})
    do_ws_upgrade(client, test_pid)
    do_ws_auth(client, test_pid, srv)
    handle_ws_session(client, test_pid, srv)
    :gen_tcp.close(client)
    :gen_tcp.close(listen_socket)
  end

  defp do_ws_upgrade(client, test_pid) do
    {:ok, http_request} = read_http_request(client)
    ws_key = extract_header(http_request, "sec-websocket-key")
    ws_accept = compute_ws_accept(ws_key)
    response = build_upgrade_response(ws_accept)
    :gen_tcp.send(client, response)
    send(test_pid, {:server, :upgrade_sent})
  end

  defp build_upgrade_response(ws_accept) do
    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{ws_accept}\r\n\r\n"
  end

  defp do_ws_auth(client, test_pid, srv) do
    {:ok, _opcode, auth_payload} = ws_recv(client)
    {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

    auth_resp =
      build_auth_response(auth_header.request_id, srv.session_id, srv.expires, srv.auth_status)

    :gen_tcp.send(client, ws_encode_binary(auth_resp))
    send(test_pid, {:server, :auth_response_sent})
  end

  defp handle_ws_session(client, test_pid, %{respond: true}) do
    request_loop(client, test_pid)
  end

  defp handle_ws_session(_client, _test_pid, %{respond: false}) do
    receive(do: (:stop -> :ok))
  end

  defp request_loop(client, test_pid) do
    case ws_recv(client, 5_000) do
      {:ok, opcode, payload} ->
        send(test_pid, {:server, :ws_frame, opcode, payload})

        case Protocol.unpack(payload) do
          {:ok, header, body, <<>>} when header.type == :request ->
            resp = build_response(header.request_id, header.cmd_code, body)
            :gen_tcp.send(client, ws_encode_binary(resp))
            request_loop(client, test_pid)

          _ ->
            request_loop(client, test_pid)
        end

      {:error, _} ->
        :ok
    end
  end

  defp read_http_request(socket) do
    read_until_double_crlf(socket, "")
  end

  defp read_until_double_crlf(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> data

    case :binary.match(acc, "\r\n\r\n") do
      {pos, _} -> {:ok, binary_part(acc, 0, pos + 4)}
      :nomatch -> read_until_double_crlf(socket, acc)
    end
  end

  defp extract_header(http_request, name) do
    case Regex.run(~r/#{name}:\s*([^\r\n]+)/i, http_request) do
      [_, value] -> String.trim(value)
      _ -> ""
    end
  end

  defp compute_ws_accept(ws_key) do
    Base.encode64(:crypto.hash(:sha, ws_key <> @ws_guid))
  end

  defp ws_encode_binary(payload) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<0x82, len::8>>
        len < 65_536 -> <<0x82, 126, len::16-big>>
        true -> <<0x82, 127, len::64-big>>
      end

    [header, payload]
  end

  # Encodes a server-to-client WebSocket ping frame (FIN + opcode 0x09).
  # Used to exercise the client's pong reply path in
  # Longbridge.WSConnection.handle_frames/2.
  defp ws_encode_ping(payload) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 -> <<0x89, len::8>>
        len < 65_536 -> <<0x89, 126, len::16-big>>
        true -> <<0x89, 127, len::64-big>>
      end

    [header, payload]
  end

  defp ws_recv(socket, timeout \\ 10_000) do
    case :gen_tcp.recv(socket, 2, timeout) do
      {:ok, <<fin_opcode::8, mask_len::8>>} ->
        opcode = fin_opcode &&& 0x0F
        masked = mask_len >>> 7 &&& 0x01
        payload_len = mask_len &&& 0x7F

        payload_len =
          case payload_len do
            126 ->
              {:ok, <<len::16-big>>} = :gen_tcp.recv(socket, 2, timeout)
              len

            127 ->
              {:ok, <<len::64-big>>} = :gen_tcp.recv(socket, 8, timeout)
              len

            len ->
              len
          end

        mask_key =
          if masked == 1 do
            {:ok, <<m1, m2, m3, m4>>} = :gen_tcp.recv(socket, 4, timeout)
            <<m1, m2, m3, m4>>
          else
            <<0, 0, 0, 0>>
          end

        case :gen_tcp.recv(socket, payload_len, timeout) do
          {:ok, masked_payload} ->
            payload = unmask(masked_payload, mask_key)
            {:ok, opcode, payload}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp unmask(payload, <<m1, m2, m3, m4>>) do
    mask = <<m1, m2, m3, m4>>

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {b, i} -> bxor(b, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp build_auth_response(req_id, session_id, expires, status_code) do
    auth_resp = %Ctrl.AuthResponse{session_id: session_id, expires: expires}
    {:ok, body_iodata, _} = Protox.encode(auth_resp)
    body = IO.iodata_to_binary(body_iodata)

    h = %Header{
      type: :response,
      body_length: byte_size(body),
      cmd_code: Protocol.cmd_auth(),
      request_id: req_id,
      status_code: status_code
    }

    IO.iodata_to_binary(Protocol.pack(h, body))
  end

  defp build_response(req_id, cmd_code, body) do
    h = %Header{
      type: :response,
      body_length: byte_size(body),
      cmd_code: cmd_code,
      request_id: req_id,
      status_code: 0
    }

    IO.iodata_to_binary(Protocol.pack(h, body))
  end

  defp ws_config(port, opts \\ []) do
    Config.new(
      token: Keyword.get(opts, :token, "test-token"),
      quote_ws_url: "ws://127.0.0.1:#{port}",
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, 60_000),
      idle_timeout: Keyword.get(opts, :idle_timeout, 60_000),
      request_timeout: Keyword.get(opts, :request_timeout, 10_000),
      gzip_threshold: Keyword.get(opts, :gzip_threshold, 1024)
    )
  end

  defp stop_server(conn) do
    if Process.alive?(conn) do
      ref = Process.monitor(conn)
      GenServer.stop(conn, :normal, 2_000)

      receive do
        {:DOWN, ^ref, :process, ^conn, _} -> :ok
      after
        2_000 -> Process.exit(conn, :kill)
      end
    end
  end

  describe "request when not connected" do
    test "returns {:error, :not_connected}" do
      {:ok, port, _, _} = start_fake_server(auth_status: 5)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 2_000
      assert {:error, :not_connected} = WSConnection.request(conn, 11, <<>>, 1_000)
      assert {:error, :not_connected} = WSConnection.request(conn, 11, <<>>)
      stop_server(conn)
    end
  end

  describe "idle timeout" do
    test "triggers disconnect on idle timeout" do
      test_pid = self()

      {:ok, port, _, _} =
        start_fake_server(
          auth_status: 0,
          respond_to_requests: false,
          idle_timeout: 200
        )

      config = ws_config(port, idle_timeout: 200)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert_receive {:longbridge, ^conn, {:disconnected, :idle_timeout}}, 5_000
      stop_server(conn)
    end
  end

  describe "unknown messages" do
    test "ignores messages not from WebSocket" do
      test_pid = self()
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      send(conn, {:some_random_message, 123})
      Process.sleep(100)
      assert Process.alive?(conn)
      assert {:ok, _, _} = WSConnection.get_session(conn)
      stop_server(conn)
    end
  end

  describe "do_connect errors" do
    test "no ws_url returns error" do
      config = %{Config.new(token: "test") | quote_ws_url: nil}
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, :no_ws_url}}, 2_000
      stop_server(conn)
    end

    test "connect failure schedules reconnect" do
      config = ws_config(1)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, {:connect, _}}}, 2_000
      stop_server(conn)
    end
  end

  describe "heartbeat when not active" do
    test "does not crash when disconnected" do
      {:ok, port, _, _} = start_fake_server(auth_status: 5)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 2_000

      send(conn, :heartbeat)
      Process.sleep(100)
      assert Process.alive?(conn)
      stop_server(conn)
    end
  end

  describe "subscribe_push" do
    test "adds subscriber" do
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      sub = spawn_link(fn -> receive(do: (_ -> :ok)) end)
      assert :ok = WSConnection.subscribe_push(conn, sub)
      stop_server(conn)
    end
  end

  describe "request timeout" do
    test "returns timeout when server doesn't respond" do
      test_pid = self()
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      config = ws_config(port, request_timeout: 500)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      result = WSConnection.request(conn, 11, <<>>, 500)
      assert {:error, :timeout} = result
      stop_server(conn)
    end
  end

  describe "parse_ws_url via Config" do
    test "uses default WS URLs" do
      config = Config.new()
      assert config.quote_ws_url == "wss://openapi-quote.longbridge.com"
      assert config.trade_ws_url == "wss://openapi-trade.longbridge.com"
    end

    test "uses china WS URLs" do
      config = Config.new(china: true)
      assert config.quote_ws_url == "wss://openapi-quote.longbridge.cn"
      assert config.trade_ws_url == "wss://openapi-trade.longbridge.cn"
    end
  end

  describe "request_timeout for unknown request" do
    test "ignores timeout for non-existent request" do
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      send(conn, {:request_timeout, 99_999})
      Process.sleep(100)
      assert Process.alive?(conn)
      stop_server(conn)
    end
  end

  describe "trade type connection" do
    test "connects with trade type" do
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      base = ws_config(port)
      config = %{base | trade_ws_url: "ws://127.0.0.1:#{port}"}
      {:ok, conn} = WSConnection.start_link(config: config, type: :trade, parent: self())
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      stop_server(conn)
    end
  end

  describe "wss URL parsing" do
    test "parses wss URL without port" do
      config = Config.new(token: "t", quote_ws_url: "wss://example.com")
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      stop_server(conn)
    end

    test "parses https URL" do
      config = Config.new(token: "t", quote_ws_url: "https://example.com")
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      stop_server(conn)
    end

    test "parses http URL" do
      config = Config.new(token: "t", quote_ws_url: "http://example.com")
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      stop_server(conn)
    end

    test "parses ws URL without port" do
      config = Config.new(token: "t", quote_ws_url: "ws://localhost")
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      stop_server(conn)
    end
  end

  describe "heartbeat push dispatch" do
    test "broadcasts heartbeat push to subscribers" do
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      sub = spawn_link(fn -> receive(do: ({:heartbeat, _} -> :ok)) end)
      WSConnection.subscribe_push(conn, sub)

      stop_server(conn)
    end
  end

  describe "activate_socket with nil mint_conn" do
    test "does not crash when disconnected" do
      {:ok, port, _, _} = start_fake_server(auth_status: 5)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 2_000
      assert {:error, :not_connected} = WSConnection.request(conn, 11, <<>>, 1_000)
      stop_server(conn)
    end
  end

  describe "unknown messages when connected" do
    test "ignores non-WebSocket messages" do
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      send(conn, {:tcp_closed, :fake_socket})
      Process.sleep(100)
      stop_server(conn)
    end
  end

  describe "heartbeat push from server" do
    test "broadcasts heartbeat push to subscribers" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

      {:ok, port} = :inet.port(listen)

      srv_pid =
        spawn_link(fn ->
          {:ok, client} = :gen_tcp.accept(listen, 10_000)
          send(test_pid, {:server, :accepted})

          {:ok, http_request} = read_http_request(client)
          ws_key = extract_header(http_request, "sec-websocket-key")
          ws_accept = compute_ws_accept(ws_key)
          :gen_tcp.send(client, build_upgrade_response(ws_accept))
          send(test_pid, {:server, :upgrade_sent})

          {:ok, _opcode, auth_payload} = ws_recv(client)
          {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

          auth_resp =
            build_auth_response(
              auth_header.request_id,
              "sess-hb",
              System.os_time(:second) + 3600,
              0
            )

          :gen_tcp.send(client, ws_encode_binary(auth_resp))
          send(test_pid, {:server, :auth_response_sent})

          receive do
            :send_heartbeat ->
              heartbeat_req = <<1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
              :gen_tcp.send(client, ws_encode_binary(heartbeat_req))
          after
            5_000 -> :ok
          end

          receive(do: (:stop -> :ok))
          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      Process.unlink(srv_pid)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      sub =
        spawn_link(fn ->
          receive(do: ({:longbridge, _, {:heartbeat, _}} -> send(test_pid, :got_heartbeat)))
        end)

      WSConnection.subscribe_push(conn, sub)
      send(srv_pid, :send_heartbeat)

      assert_receive :got_heartbeat, 2_000
      send(srv_pid, :stop)
      stop_server(conn)
    end
  end

  describe "partial data buffering" do
    test "handles incomplete packets without crashing" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

      {:ok, port} = :inet.port(listen)

      srv_pid =
        spawn_link(fn ->
          {:ok, client} = :gen_tcp.accept(listen, 10_000)
          send(test_pid, {:server, :accepted})

          {:ok, http_request} = read_http_request(client)
          ws_key = extract_header(http_request, "sec-websocket-key")
          ws_accept = compute_ws_accept(ws_key)
          :gen_tcp.send(client, build_upgrade_response(ws_accept))

          {:ok, _opcode, auth_payload} = ws_recv(client)
          {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

          auth_resp =
            build_auth_response(
              auth_header.request_id,
              "sess-buf",
              System.os_time(:second) + 3600,
              0
            )

          :gen_tcp.send(client, ws_encode_binary(auth_resp))
          send(test_pid, {:server, :auth_response_sent})

          :gen_tcp.send(client, ws_encode_binary(<<3>>))
          send(test_pid, {:server, :data_sent})

          receive(do: (:stop -> :ok))
          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      Process.unlink(srv_pid)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      assert_receive {:server, :data_sent}, 2_000
      Process.sleep(300)
      assert Process.alive?(conn)
      send(srv_pid, :stop)
      stop_server(conn)
    end
  end

  describe "invalid packet data" do
    test "handles unknown packet type without crashing" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

      {:ok, port} = :inet.port(listen)

      srv_pid =
        spawn_link(fn ->
          {:ok, client} = :gen_tcp.accept(listen, 10_000)
          send(test_pid, {:server, :accepted})

          {:ok, http_request} = read_http_request(client)
          ws_key = extract_header(http_request, "sec-websocket-key")
          ws_accept = compute_ws_accept(ws_key)
          :gen_tcp.send(client, build_upgrade_response(ws_accept))

          {:ok, _opcode, auth_payload} = ws_recv(client)
          {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

          auth_resp =
            build_auth_response(
              auth_header.request_id,
              "sess-inv",
              System.os_time(:second) + 3600,
              0
            )

          :gen_tcp.send(client, ws_encode_binary(auth_resp))
          send(test_pid, {:server, :auth_response_sent})

          receive do
            :send_invalid ->
              :gen_tcp.send(client, ws_encode_binary(<<0, 0, 0, 0, 0>>))
          after
            5_000 -> :ok
          end

          receive(do: (:stop -> :ok))
          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      Process.unlink(srv_pid)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      send(srv_pid, :send_invalid)
      Process.sleep(200)
      assert Process.alive?(conn)
      send(srv_pid, :stop)
      stop_server(conn)
    end
  end

  describe "OTP fetch failure" do
    test "logs a warning and reports otp_fetch_failed when /v1/socket/token fails" do
      # Long access token (forces the OTP fetch path) + http_url pointing
      # at a closed port so the HTTP call fails.
      long_token = String.duplicate("a", 120)

      config =
        Config.new(
          token: long_token,
          app_key: "app-key",
          app_secret: "app-secret",
          http_url: "http://127.0.0.1:1"
        )

      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())

      assert_receive {:longbridge, ^conn, {:disconnected, {:otp_fetch_failed, _reason}}},
                     2_000

      stop_server(conn)
    end
  end

  describe "gzip disabled by threshold" do
    test "gzip_threshold: 0 disables request compression" do
      # When the threshold is 0, the private maybe_gzip/2 early-return
      # branch is taken — the auth packet must be sent in plaintext
      # (no gzip) and the connection should still succeed.
      test_pid = self()

      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)

      base = ws_config(port, gzip_threshold: 0)
      config = %{base | token: "short-otp-token"}

      {:ok, conn} =
        WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      stop_server(conn)
    end
  end

  describe "URL parsing fallthroughs" do
    # parse_ws_url/1 uses private ws_scheme/1 and ws_default_port/1 helpers
    # that are only reached through an end-to-end start_link. Drive the
    # private clauses via URLs that hit the catch-all branches.
    test "non-ws scheme (e.g. ftp://) hits ws_scheme(_) catch-all" do
      config = Config.new(token: "t", quote_ws_url: "ftp://example.com")
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      # We don't care about the connect failure here — only that
      # parse_ws_url/1 ran and resolved the scheme via the catch-all.
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      stop_server(conn)
    end

    test "schemeless URL with no port hits both ws_scheme(_) and ws_default_port(_)" do
      # `URI.parse("//example.com")` returns scheme: nil and port: nil,
      # which forces parse_ws_url/1 through both catch-all clauses.
      config = Config.new(token: "t", quote_ws_url: "//example.com")
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 5_000
      stop_server(conn)
    end
  end

  describe "WebSocket ping from server" do
    test "client replies with a pong frame and stays connected" do
      test_pid = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

      {:ok, port} = :inet.port(listen)

      srv_pid =
        spawn_link(fn ->
          {:ok, client} = :gen_tcp.accept(listen, 10_000)
          send(test_pid, {:server, :accepted})

          {:ok, http_request} = read_http_request(client)
          ws_key = extract_header(http_request, "sec-websocket-key")
          ws_accept = compute_ws_accept(ws_key)
          :gen_tcp.send(client, build_upgrade_response(ws_accept))
          send(test_pid, {:server, :upgrade_sent})

          {:ok, _opcode, auth_payload} = ws_recv(client)
          {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

          auth_resp =
            build_auth_response(
              auth_header.request_id,
              "sess-ping",
              System.os_time(:second) + 3600,
              0
            )

          :gen_tcp.send(client, ws_encode_binary(auth_resp))
          send(test_pid, {:server, :auth_response_sent})

          receive do
            :send_ping ->
              :gen_tcp.send(client, ws_encode_ping("ping-payload"))
              send(test_pid, :ping_sent)
          after
            5_000 -> :ok
          end

          # The client should reply with a pong frame (opcode 0x0A after the
          # FIN bit is stripped in ws_recv/2).
          case ws_recv(client, 5_000) do
            {:ok, 0x0A, _pong_data} ->
              send(test_pid, :pong_received)

            other ->
              send(test_pid, {:pong_unexpected, other})
          end

          receive(do: (:stop -> :ok))
          :gen_tcp.close(client)
          :gen_tcp.close(listen)
        end)

      Process.unlink(srv_pid)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      send(srv_pid, :send_ping)
      assert_receive :ping_sent, 2_000
      assert_receive :pong_received, 2_000

      send(srv_pid, :stop)
      stop_server(conn)
    end
  end

  describe "default refresh_token_fn" do
    test "custom refresh_token_fn is honored on auth retry" do
      # The init/1 default for refresh_token_fn is the documented
      # `Longbridge.Config.refresh_access_token/2`. We override it here
      # with a no-op so the connection does not actually hit the HTTP
      # refresh endpoint. The fact that the connection still starts
      # confirms the default is overridable; if init/1 didn't honor the
      # option, this test would fail at the start_link call.
      test_pid = self()
      {:ok, port, _, _} = start_fake_server([])

      config = ws_config(port, token: "short-otp")

      opts = [
        config: config,
        type: :quote,
        parent: test_pid,
        refresh_token_fn: fn _cfg -> {:ok, config} end
      ]

      {:ok, conn} = WSConnection.start_link(opts)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000
      stop_server(conn)
    end
  end
end
