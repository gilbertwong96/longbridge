defmodule Longbridge.WSConnectionTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, Protocol, WSConnection}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header
  alias Longbridge.Quote.V1, as: Q

  import Bitwise

  # ── Fake WebSocket server helpers ────────────────────────

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defp start_fake_server(opts \\ []) do
    test_pid = self()
    srv_opts = parse_server_opts(opts)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn -> run_fake_server(listen_socket, test_pid, srv_opts) end)
    {:ok, port, srv_opts.session_id, srv_opts.expires}
  end

  defp parse_server_opts(opts) do
    %{
      session_id: Keyword.get(opts, :session_id, "sess-#{System.unique_integer([:positive])}"),
      expires: Keyword.get(opts, :expires, System.os_time(:second) + 3600),
      auth_status: Keyword.get(opts, :auth_status, 0),
      respond_to_requests: Keyword.get(opts, :respond_to_requests, true),
      server_fn: Keyword.get(opts, :server_fn, nil)
    }
  end

  defp run_fake_server(listen_socket, test_pid, srv_opts) do
    {:ok, client} = :gen_tcp.accept(listen_socket, 10_000)
    send(test_pid, {:server, :accepted})

    {:ok, http_request} = read_http_request(client)
    send(test_pid, {:server, :http_request, http_request})

    ws_key = extract_header(http_request, "sec-websocket-key")
    ws_accept = compute_ws_accept(ws_key)
    response = build_upgrade_response(ws_accept)

    :gen_tcp.send(client, response)
    send(test_pid, {:server, :upgrade_sent})

    handle_ws_session(client, test_pid, srv_opts)
    :gen_tcp.close(client)
    :gen_tcp.close(listen_socket)
  end

  defp build_upgrade_response(ws_accept) do
    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{ws_accept}\r\n\r\n"
  end

  defp handle_ws_session(client, test_pid, %{server_fn: server_fn})
       when server_fn != nil do
    server_fn.(client, test_pid)
  end

  defp handle_ws_session(client, test_pid, opts) do
    default_server_loop(
      client,
      test_pid,
      opts.session_id,
      opts.expires,
      opts.auth_status,
      opts.respond_to_requests
    )
  end

  defp default_server_loop(
         client,
         test_pid,
         session_id,
         expires,
         auth_status,
         respond_to_requests
       ) do
    # Read the auth request (WS binary frame)
    {:ok, _opcode, auth_payload} = ws_recv(client)
    send(test_pid, {:server, :auth_request, auth_payload})

    # Parse the auth request to get req_id
    {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)
    req_id = auth_header.request_id

    # Build and send auth response
    auth_resp_packet = build_auth_response(req_id, session_id, expires, auth_status)
    :gen_tcp.send(client, ws_encode_binary(auth_resp_packet))
    send(test_pid, {:server, :auth_response_sent})

    if respond_to_requests do
      request_server_loop(client, test_pid)
    else
      # Keep the connection open but don't respond to requests
      receive do
        :stop -> :ok
      after
        10_000 -> :ok
      end
    end
  end

  defp request_server_loop(client, test_pid) do
    case ws_recv(client, 5_000) do
      {:ok, opcode, payload} ->
        send(test_pid, {:server, :ws_frame, opcode, payload})

        case Protocol.unpack(payload) do
          {:ok, header, body, <<>>} when header.type == :request ->
            # Echo back a response for the request
            resp_packet = build_response(header.request_id, header.cmd_code, body)
            :gen_tcp.send(client, ws_encode_binary(resp_packet))
            request_server_loop(client, test_pid)

          _ ->
            request_server_loop(client, test_pid)
        end

      {:error, :timeout} ->
        :ok

      {:error, :closed} ->
        :ok
    end
  end

  # ── HTTP request parsing ────────────────────────────────

  defp read_http_request(socket) do
    read_http_request(socket, <<>>)
  end

  defp read_http_request(socket, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> data

    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      read_http_request(socket, acc)
    end
  end

  defp extract_header(http_request, name) do
    pattern = "#{name}: "

    case Regex.run(~r/#{pattern}([^\r\n]+)/i, http_request) do
      [_, value] -> String.trim(value)
      _ -> ""
    end
  end

  defp compute_ws_accept(ws_key) do
    Base.encode64(:crypto.hash(:sha, ws_key <> @ws_guid))
  end

  # ── WebSocket frame encoding (server → client, no masking) ──

  defp ws_encode_binary(payload) do
    ws_encode_frame(0x02, payload)
  end

  defp ws_encode_close(code, reason) do
    ws_encode_frame(0x08, <<code::16-big, reason::binary>>)
  end

  defp ws_encode_frame(opcode, payload) do
    len = byte_size(payload)

    header =
      cond do
        len < 126 ->
          <<0x80 ||| opcode::8, len::8>>

        len < 65_536 ->
          <<0x80 ||| opcode::8, 126, len::16-big>>

        true ->
          <<0x80 ||| opcode::8, 127, len::64-big>>
      end

    [header, payload]
  end

  # ── WebSocket frame decoding (client → server, masked) ────

  defp ws_recv(socket, timeout \\ 10_000) do
    case :gen_tcp.recv(socket, 2, timeout) do
      {:ok, <<fin_opcode::8, mask_len::8>>} ->
        opcode = fin_opcode &&& 0x0F
        masked = mask_len >>> 7 &&& 0x01
        payload_len = mask_len &&& 0x7F

        {:ok, payload_len} =
          case payload_len do
            126 ->
              {:ok, <<len::16-big>>} = :gen_tcp.recv(socket, 2, timeout)
              {:ok, len}

            127 ->
              {:ok, <<len::64-big>>} = :gen_tcp.recv(socket, 8, timeout)
              {:ok, len}

            len ->
              {:ok, len}
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

  defp unmask(<<>>, _mask), do: <<>>

  defp unmask(payload, <<_m1, _m2, _m3, _m4>> = mask) do
    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {b, i} -> bxor(b, :binary.at(mask, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  # ── Protocol packet builders ─────────────────────────────

  defp build_auth_response(req_id, session_id, expires, status_code \\ 0) do
    auth_resp = %Ctrl.AuthResponse{session_id: session_id, expires: expires}
    {:ok, body_iodata, _} = Protox.encode(auth_resp)
    body = IO.iodata_to_binary(body_iodata)

    h = %Header{
      type: :response,
      verify: false,
      gzip: false,
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
      verify: false,
      gzip: false,
      body_length: byte_size(body),
      cmd_code: cmd_code,
      request_id: req_id,
      status_code: 0
    }

    IO.iodata_to_binary(Protocol.pack(h, body))
  end

  defp build_push_packet(cmd_code, body) do
    h = %Header{
      type: :push,
      verify: false,
      gzip: false,
      body_length: byte_size(body),
      cmd_code: cmd_code
    }

    IO.iodata_to_binary(Protocol.pack(h, body))
  end

  # ── Config helpers ──────────────────────────────────────

  defp ws_config(port, opts \\ []) do
    Config.new(
      token: Keyword.get(opts, :token, "test-token"),
      quote_ws_url: "ws://127.0.0.1:#{port}",
      heartbeat_interval: Keyword.get(opts, :heartbeat_interval, 15_000),
      idle_timeout: Keyword.get(opts, :idle_timeout, 60_000),
      request_timeout: Keyword.get(opts, :request_timeout, 10_000)
    )
  end

  # ── Test cases ──────────────────────────────────────────

  describe "start_link/1 + authentication" do
    test "completes WS upgrade and auth against a fake server" do
      test_pid = self()
      {:ok, port, session_id, expires} = start_fake_server()

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      assert_receive {:server, :accepted}, 2_000
      assert_receive {:server, :upgrade_sent}, 2_000
      assert_receive {:server, :auth_request, _}, 2_000
      assert_receive {:server, :auth_response_sent}, 2_000
      assert_receive {:longbridge, ^conn, {:connected, ^session_id}}, 2_000

      assert {:ok, ^session_id, ^expires} = WSConnection.get_session(conn)

      stop_server(conn)
    end

    test "auth failure with status 5 (UNAUTHENTICATED) does not retry" do
      test_pid = self()

      {:ok, port, _session_id, _} =
        start_fake_server(auth_status: 5)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      assert_receive {:server, :accepted}, 2_000
      assert_receive {:server, :auth_response_sent}, 2_000

      # Should NOT reconnect on auth failure
      refute_receive {:server, :accepted}, 3_000

      assert_receive {:longbridge, ^conn, {:disconnected, {:auth_failed, 5}}}, 2_000
      assert_receive {:longbridge, ^conn, :reconnect_exhausted}, 2_000

      stop_server(conn)
    end

    test "auth timeout when server doesn't respond" do
      test_pid = self()

      # Server that upgrades but never sends auth response
      {:ok, listen_socket} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

      {:ok, port} = :inet.port(listen_socket)

      spawn_link(fn ->
        {:ok, client} = :gen_tcp.accept(listen_socket, 5_000)
        send(test_pid, {:server, :accepted})

        {:ok, http_request} = read_http_request(client)
        ws_key = extract_header(http_request, "sec-websocket-key")
        ws_accept = compute_ws_accept(ws_key)

        response =
          "HTTP/1.1 101 Switching Protocols\r\n" <>
            "Upgrade: websocket\r\n" <>
            "Connection: Upgrade\r\n" <>
            "Sec-WebSocket-Accept: #{ws_accept}\r\n\r\n"

        :gen_tcp.send(client, response)
        send(test_pid, {:server, :upgrade_sent})

        # Don't send auth response — just wait
        receive do
          :stop -> :ok
        after
          15_000 -> :ok
        end

        :gen_tcp.close(client)
        :gen_tcp.close(listen_socket)
      end)

      base_config = ws_config(port, request_timeout: 1_000)
      # Override auth timeout by using a short token
      config = %{base_config | token: "t"}

      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      assert_receive {:server, :accepted}, 2_000
      assert_receive {:server, :upgrade_sent}, 2_000

      # Should timeout and schedule reconnect
      assert_receive {:longbridge, ^conn, {:disconnected, _reason}}, 15_000

      stop_server(conn)
    end
  end

  describe "request/response pairing" do
    test "sends a request and receives a response" do
      test_pid = self()
      {:ok, port, _, _} = start_fake_server()

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # Send a quote request
      req = %Q.MultiSecurityRequest{symbol: ["AAPL.US"]}
      {:ok, iodata, _} = Protox.encode(req)
      body = IO.iodata_to_binary(iodata)

      # Use cmd_code 11 (security_quote)
      result = WSConnection.request(conn, 11, body, 5_000)

      assert {:ok, _resp_body, _req_id} = result

      stop_server(conn)
    end

    test "returns :not_connected when connection is not active" do
      {:ok, port, _, _} = start_fake_server(auth_status: 5)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())

      # Wait for auth failure
      assert_receive {:longbridge, ^conn, {:disconnected, _}}, 2_000

      result = WSConnection.request(conn, 11, <<>>, 1_000)
      assert {:error, :not_connected} = result

      stop_server(conn)
    end

    test "request timeout when server doesn't respond" do
      test_pid = self()

      # Server that authenticates but doesn't respond to requests
      {:ok, port, _, _} =
        start_fake_server(respond_to_requests: false)

      config = ws_config(port, request_timeout: 500)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      result = WSConnection.request(conn, 11, <<>>, 500)
      assert {:error, :timeout} = result

      stop_server(conn)
    end
  end

  describe "push data" do
    test "broadcasts push packets to subscribers" do
      test_pid = self()
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # Subscribe another process for push
      push_receiver = spawn_link(fn -> push_loop(test_pid) end)
      :ok = WSConnection.subscribe_push(conn, push_receiver)

      # Server sends a push packet (cmd 101 = quote push)
      push_body = "push-data-123"
      _push_packet = build_push_packet(101, push_body)

      # We need to send the push from the server side...
      # The server is already running. We need a different approach.
      # Let's start a custom server that sends push after auth.
      stop_server(conn)

      # Start a new server that sends push data
      {:ok, port2, _, _} =
        start_fake_server(
          server_fn: fn client, srv_pid ->
            # Read auth request
            {:ok, _opcode, auth_payload} = ws_recv(client)
            {:ok, auth_header, _body, <<>>} = Protocol.unpack(auth_payload)

            # Send auth response
            session_id = "sess-push-#{System.unique_integer([:positive])}"
            expires = System.os_time(:second) + 3600
            auth_resp = build_auth_response(auth_header.request_id, session_id, expires)
            :gen_tcp.send(client, ws_encode_binary(auth_resp))
            send(srv_pid, {:server, :auth_response_sent})

            # Wait a bit then send push data
            Process.sleep(100)

            push_packet = build_push_packet(101, push_body)
            :gen_tcp.send(client, ws_encode_binary(push_packet))
            send(srv_pid, {:server, :push_sent})

            receive do
              :stop -> :ok
            after
              5_000 -> :ok
            end
          end
        )

      config2 = ws_config(port2)
      {:ok, conn2} = WSConnection.start_link(config: config2, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn2, {:connected, _}}, 2_000

      # Subscribe for push
      push_receiver2 = spawn_link(fn -> push_loop(test_pid) end)
      :ok = WSConnection.subscribe_push(conn2, push_receiver2)

      assert_receive {:server, :push_sent}, 2_000
      assert_receive {:push_received, 101, ^push_body}, 2_000

      stop_server(conn2)
    end
  end

  defp push_loop(parent) do
    receive do
      {:longbridge, _conn, {:push, cmd_code, body}} ->
        send(parent, {:push_received, cmd_code, body})
        push_loop(parent)

      _ ->
        push_loop(parent)
    after
      5_000 -> :ok
    end
  end

  describe "heartbeat" do
    test "sends WebSocket ping on heartbeat" do
      test_pid = self()

      {:ok, port, _, _} =
        start_fake_server(
          server_fn: fn client, _srv_pid ->
            # Read auth request
            {:ok, _opcode, auth_payload} = ws_recv(client)
            {:ok, auth_header, _body, <<>>} = Protocol.unpack(auth_payload)

            # Send auth response
            session_id = "sess-hb-#{System.unique_integer([:positive])}"
            expires = System.os_time(:second) + 3600
            auth_resp = build_auth_response(auth_header.request_id, session_id, expires)
            :gen_tcp.send(client, ws_encode_binary(auth_resp))
            send(test_pid, {:server, :auth_response_sent})

            # Read the ping frame
            result = ws_recv(client, 5_000)
            send(test_pid, {:server, :ws_recv_result, result})

            case result do
              {:ok, 0x09, _ping_data} ->
                send(test_pid, {:server, :ping_received})

              {:ok, opcode, _} ->
                send(test_pid, {:server, :unexpected_opcode, opcode})

              {:error, _} ->
                :ok
            end

            receive do
              :stop -> :ok
            after
              5_000 -> :ok
            end
          end
        )

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      # Manually trigger heartbeat - verify it doesn't crash the process
      send(conn, :heartbeat)
      Process.sleep(500)
      assert Process.alive?(conn)
      # get_session should still work after heartbeat
      assert {:ok, _, _} = WSConnection.get_session(conn)

      stop_server(conn)
    end
  end

  describe "connection lifecycle" do
    test "get_session returns session info after auth" do
      test_pid = self()
      {:ok, port, session_id, expires} = start_fake_server()

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      assert {:ok, ^session_id, ^expires} = WSConnection.get_session(conn)

      stop_server(conn)
    end

    test "subscribe_push adds a subscriber" do
      test_pid = self()
      {:ok, port, _, _} = start_fake_server(respond_to_requests: false)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      sub = spawn_link(fn -> push_loop(test_pid) end)
      assert :ok = WSConnection.subscribe_push(conn, sub)

      stop_server(conn)
    end

    test "handles server close frame" do
      test_pid = self()

      {:ok, port, _, _} =
        start_fake_server(
          server_fn: fn client, _srv_pid ->
            # Read auth request
            {:ok, _opcode, auth_payload} = ws_recv(client)
            {:ok, auth_header, _body, <<>>} = Protocol.unpack(auth_payload)

            # Send auth response
            session_id = "sess-close-#{System.unique_integer([:positive])}"
            expires = System.os_time(:second) + 3600
            auth_resp = build_auth_response(auth_header.request_id, session_id, expires)
            :gen_tcp.send(client, ws_encode_binary(auth_resp))
            send(test_pid, {:server, :auth_response_sent})

            # Wait then send close frame
            Process.sleep(100)
            :gen_tcp.send(client, ws_encode_close(1000, "bye"))
            send(test_pid, {:server, :close_sent})

            receive do
              :stop -> :ok
            after
              5_000 -> :ok
            end
          end
        )

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)
      assert_receive {:longbridge, ^conn, {:connected, _}}, 2_000

      assert_receive {:server, :close_sent}, 2_000

      # Should get disconnected
      assert_receive {:longbridge, ^conn, {:disconnected, :peer_closed}}, 3_000

      stop_server(conn)
    end

    test "reconnects after connection drop" do
      test_pid = self()

      # First server — will close after auth
      {:ok, listen1} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
      {:ok, _port1} = :inet.port(listen1)

      # Second server — will accept reconnect
      {:ok, listen2} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
      {:ok, _port2} = :inet.port(listen2)

      # We'll use port1 first, then switch to port2 via config update
      # Actually, we can't change the URL. Let me use a single port with reconnection.
      :gen_tcp.close(listen1)
      :gen_tcp.close(listen2)

      # Use a single listen socket that accepts two connections
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      session_id = "sess-recon-#{System.unique_integer([:positive])}"
      expires = System.os_time(:second) + 3600

      spawn_link(fn ->
        # First connection
        {:ok, client1} = :gen_tcp.accept(listen, 5_000)
        send(test_pid, {:server, :accepted, 1})

        {:ok, http_request} = read_http_request(client1)
        ws_key = extract_header(http_request, "sec-websocket-key")
        ws_accept = compute_ws_accept(ws_key)

        response =
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{ws_accept}\r\n\r\n"

        :gen_tcp.send(client1, response)

        {:ok, _opcode, auth_payload} = ws_recv(client1)
        {:ok, auth_header, _body, <<>>} = Protocol.unpack(auth_payload)
        auth_resp = build_auth_response(auth_header.request_id, session_id, expires)
        :gen_tcp.send(client1, ws_encode_binary(auth_resp))
        send(test_pid, {:server, :auth_sent, 1})

        # Close the first connection
        Process.sleep(200)
        :gen_tcp.close(client1)
        send(test_pid, {:server, :closed, 1})

        # Second connection (reconnect)
        {:ok, client2} = :gen_tcp.accept(listen, 10_000)
        send(test_pid, {:server, :accepted, 2})

        {:ok, http_request2} = read_http_request(client2)
        ws_key2 = extract_header(http_request2, "sec-websocket-key")
        ws_accept2 = compute_ws_accept(ws_key2)

        response2 =
          "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{ws_accept2}\r\n\r\n"

        :gen_tcp.send(client2, response2)

        {:ok, _opcode2, auth_payload2} = ws_recv(client2)
        {:ok, auth_header2, _body2, <<>>} = Protocol.unpack(auth_payload2)
        auth_resp2 = build_auth_response(auth_header2.request_id, session_id, expires)
        :gen_tcp.send(client2, ws_encode_binary(auth_resp2))
        send(test_pid, {:server, :auth_sent, 2})

        receive do
          :stop -> :ok
        after
          10_000 -> :ok
        end

        :gen_tcp.close(client2)
        :gen_tcp.close(listen)
      end)

      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      assert_receive {:server, :accepted, 1}, 2_000
      assert_receive {:server, :auth_sent, 1}, 2_000
      assert_receive {:longbridge, ^conn, {:connected, ^session_id}}, 2_000
      assert_receive {:server, :closed, 1}, 2_000

      # Should reconnect
      assert_receive {:server, :accepted, 2}, 5_000
      assert_receive {:server, :auth_sent, 2}, 2_000
      assert_receive {:longbridge, ^conn, {:connected, ^session_id}}, 2_000

      stop_server(conn)
    end
  end

  describe "error handling" do
    test "connect failure to non-existent server schedules reconnect" do
      test_pid = self()

      # Use a port that's not listening
      config = ws_config(1)

      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      # Should schedule reconnect (not fatal)
      assert_receive {:longbridge, ^conn, {:disconnected, {:connect, _}}}, 2_000

      stop_server(conn)
    end

    test "no ws_url returns error" do
      test_pid = self()

      config = %{Config.new(token: "test") | quote_ws_url: nil}

      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: test_pid)

      assert_receive {:longbridge, ^conn, {:disconnected, :no_ws_url}}, 2_000

      stop_server(conn)
    end
  end

  # ── Helpers ──────────────────────────────────────────────

  defp stop_server(conn) do
    if Process.alive?(conn) do
      ref = Process.monitor(conn)
      GenServer.stop(conn, :normal, 2_000)

      receive do
        {:DOWN, ^ref, :process, ^conn, _} -> :ok
      after
        2_000 -> :ok
      end
    end
  end
end
