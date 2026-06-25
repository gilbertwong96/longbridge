defmodule Longbridge.TradeContextExtraTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Longbridge.{Config, Protocol, TradeContext}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  defp build_auth_response(req_id, session_id, expires, status_code \\ 0) do
    auth_resp = %Ctrl.AuthResponse{session_id: session_id, expires: expires}
    {:ok, body_iodata, _} = Protox.encode(auth_resp)
    body = IO.iodata_to_binary(body_iodata)

    IO.iodata_to_binary(
      Protocol.pack(
        %Header{
          type: :response,
          body_length: byte_size(body),
          cmd_code: Protocol.cmd_auth(),
          request_id: req_id,
          status_code: status_code
        },
        body
      )
    )
  end

  defp build_response(cmd_code, req_id, body) do
    IO.iodata_to_binary(
      Protocol.pack(
        %Header{
          type: :response,
          body_length: byte_size(body),
          cmd_code: cmd_code,
          request_id: req_id,
          status_code: 0
        },
        body
      )
    )
  end

  defp start_server(session_id, handler_fn) do
    test_pid = self()
    expires = System.os_time(:second) + 3600

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

        {:ok, port} = :inet.port(listen)
        send(test_pid, {:port, port})
        run_server_session(listen, test_pid, session_id, expires, handler_fn)
      end)

    Process.unlink(pid)
    {:ok, pid}
  end

  defp run_server_session(listen, test_pid, session_id, expires, handler_fn) do
    {:ok, client} = :gen_tcp.accept(listen, 10_000)
    do_ws_upgrade(client)
    {:ok, _opcode, auth_payload} = ws_recv(client)
    {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)
    auth_resp = build_auth_response(auth_header.request_id, session_id, expires)
    :gen_tcp.send(client, ws_encode_binary(auth_resp))
    send(test_pid, {:auth_done, client})
    server_request_loop(client, test_pid, handler_fn)
    :gen_tcp.close(client)
    :gen_tcp.close(listen)
  end

  defp do_ws_upgrade(client) do
    {:ok, http_request} = read_http_request(client)
    ws_key = extract_header(http_request, "sec-websocket-key")
    ws_accept = compute_ws_accept(ws_key)
    :gen_tcp.send(client, build_upgrade_response(ws_accept))
  end

  defp build_upgrade_response(ws_accept) do
    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{ws_accept}\r\n\r\n"
  end

  defp server_request_loop(client, test_pid, handler_fn) do
    case ws_recv(client, 30_000) do
      {:ok, _opcode, payload} ->
        {:ok, %Header{request_id: req_id, cmd_code: cmd_code}, body, <<>>} =
          Protocol.unpack(payload)

        handler_fn.(client, test_pid, cmd_code, req_id, body)
        server_request_loop(client, test_pid, handler_fn)

      {:error, _} ->
        :ok
    end
  end

  defp await_port do
    assert_receive {:port, port}, 2_000
    port
  end

  defp start_ctx(port) do
    config = Config.new(token: "t", trade_ws_url: "ws://127.0.0.1:#{port}")
    {:ok, ctx} = TradeContext.start_link(config)
    ctx
  end

  defp connected_ctx(session_id, handler_fn) do
    {:ok, server} = start_server(session_id, handler_fn)
    port = await_port()
    ctx = start_ctx(port)
    wait_for_session(ctx)
    {server, ctx}
  end

  defp wait_for_session(_ctx) do
    Process.sleep(500)
  end

  defp cleanup(server, ctx) do
    Process.unlink(ctx)
    Process.exit(server, :kill)

    try do
      GenServer.stop(ctx, :normal, 3_000)
    catch
      :exit, _ -> :ok
    end

    Process.sleep(50)
  end

  # ── WebSocket helpers ────────────────────────────────────

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

  # ── Tests ────────────────────────────────────────────────

  defp encode_notification(notification) do
    {:ok, iodata, _size} = Protox.encode(notification)
    IO.iodata_to_binary(iodata)
  end

  describe "subscribe/2" do
    test "subscribe with default [:private] topic" do
      handler = fn client, test_pid, cmd_code, req_id, _body ->
        send(test_pid, {:cmd_code, cmd_code})
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-sub#{System.unique_integer([:positive])}", handler)
      assert :ok = TradeContext.subscribe(ctx)
      assert_receive {:cmd_code, 16}, 2_000
      cleanup(server, ctx)
    end

    test "subscribe with custom topics" do
      handler = fn client, test_pid, cmd_code, req_id, _body ->
        send(test_pid, {:cmd_code, cmd_code})
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-sub2#{System.unique_integer([:positive])}", handler)
      assert :ok = TradeContext.subscribe(ctx, [:private, :public])
      assert_receive {:cmd_code, 16}, 2_000
      cleanup(server, ctx)
    end
  end

  describe "unsubscribe/2" do
    test "unsubscribe with default [:private] topic" do
      handler = fn client, test_pid, cmd_code, req_id, _body ->
        send(test_pid, {:cmd_code, cmd_code})
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-unsub#{System.unique_integer([:positive])}", handler)
      assert :ok = TradeContext.unsubscribe(ctx)
      assert_receive {:cmd_code, 17}, 2_000
      cleanup(server, ctx)
    end
  end

  describe "push callbacks" do
    test "on_order_changed sets callback" do
      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-cb#{System.unique_integer([:positive])}", handler)
      TradeContext.on_order_changed(ctx, fn _event -> :ok end)
      cleanup(server, ctx)
    end

    test "set_default_push_callback and remove_push_callback" do
      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-dcb#{System.unique_integer([:positive])}", handler)
      TradeContext.set_default_push_callback(ctx, fn _event -> :ok end)
      TradeContext.remove_callback(ctx, :private)
      cleanup(server, ctx)
    end
  end

  describe "config/1" do
    test "returns the config" do
      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-cfg#{System.unique_integer([:positive])}", handler)
      assert %Config{} = GenServer.call(ctx, :config)
      cleanup(server, ctx)
    end
  end

  describe "session/1" do
    test "returns the live session id from the WS connection" do
      sid = "sess-ls#{System.unique_integer([:positive])}"

      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx(sid, handler)
      wait_for_session(ctx)
      assert {:ok, ^sid, _} = TradeContext.session(ctx)
      cleanup(server, ctx)
    end

    test "returns {:ok, nil, nil} when started with skip_connection" do
      config = Config.new(token: "t", trade_ws_url: "ws://127.0.0.1:1")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      Process.sleep(50)
      assert {:ok, nil, nil} = TradeContext.session(ctx)
      Process.exit(ctx, :kill)
    end
  end

  describe "subscribe / unsubscribe with binary topic passthrough" do
    test "subscribe accepts a binary topic string" do
      handler = fn client, test_pid, cmd_code, req_id, body ->
        send(test_pid, {:cmd_code, cmd_code})
        send(test_pid, {:body, body})
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-bs#{System.unique_integer([:positive])}", handler)
      assert :ok = TradeContext.subscribe(ctx, ["custom_topic"])
      assert_receive {:cmd_code, 16}
      assert_receive {:body, body}
      {:ok, decoded} = Protox.decode(body, Longbridge.Trade.V1.Sub)
      assert "custom_topic" in decoded.topics
      cleanup(server, ctx)
    end

    test "unsubscribe accepts a binary topic string" do
      handler = fn client, test_pid, cmd_code, req_id, body ->
        send(test_pid, {:cmd_code, cmd_code})
        send(test_pid, {:body, body})
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} = connected_ctx("sess-bu#{System.unique_integer([:positive])}", handler)
      assert :ok = TradeContext.unsubscribe(ctx, ["custom_topic"])
      assert_receive {:cmd_code, 17}
      assert_receive {:body, body}
      {:ok, decoded} = Protox.decode(body, Longbridge.Trade.V1.Unsub)
      assert "custom_topic" in decoded.topics
      cleanup(server, ctx)
    end
  end

  describe "subscribe error path" do
    test "returns the error from the underlying WS connection" do
      # Server that drops the connection before responding
      handler = fn client, _tp, _cc, _ri, _body ->
        :gen_tcp.close(client)
      end

      {server, ctx} =
        connected_ctx("sess-err#{System.unique_integer([:positive])}", handler)

      Process.sleep(50)
      assert {:error, _} = TradeContext.subscribe(ctx, [:private])
      cleanup(server, ctx)
    end
  end

  describe "unsubscribe error path" do
    test "returns the error from the underlying WS connection" do
      handler = fn client, _tp, _cc, _ri, _body ->
        :gen_tcp.close(client)
      end

      {server, ctx} =
        connected_ctx("sess-uerr#{System.unique_integer([:positive])}", handler)

      Process.sleep(50)
      assert {:error, _} = TradeContext.unsubscribe(ctx, [:private])
      cleanup(server, ctx)
    end
  end

  describe "set_callback (legacy alias)" do
    test "set_callback populates the order-changed callback" do
      config = Config.new(token: "t", trade_ws_url: "ws://127.0.0.1:1")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      Process.sleep(50)

      parent = self()
      GenServer.cast(ctx, {:set_callback, fn _e -> send(parent, :got) end})
      Process.sleep(50)

      # Trigger a push with matching topic and assert the legacy callback runs
      notif = %Longbridge.Trade.V1.Notification{
        topic: "/v1/trade/order_changed",
        content_type: :CONTENT_JSON,
        dispatch_type: :DISPATCH_DIRECT,
        data: ~s({"order_id":"abc"})
      }

      send(
        ctx,
        {:longbridge, ctx, {:push, 18, encode_notification(notif)}}
      )

      assert_receive :got, 1_000
      Process.exit(ctx, :kill)
    end
  end

  describe "default push callback" do
    test "non-JSON body is silently dropped" do
      config = Config.new(token: "t", trade_ws_url: "ws://127.0.0.1:1")
      {:ok, ctx} = TradeContext.start_link(config, skip_connection: true)
      Process.sleep(50)

      parent = self()
      TradeContext.set_default_push_callback(ctx, fn e -> send(parent, {:default, e}) end)

      # A push with a non-JSON body to a topic with no registered callback —
      # exercises the `dispatch_push({:push, _cmd, body}, _cb, default)` branch
      # that falls into `_ -> :ok`.
      send(ctx, {:longbridge, ctx, {:push, 99, "not-json-at-all"}})
      refute_receive {:default, _}, 500
      Process.exit(ctx, :kill)
    end
  end
end
