defmodule Longbridge.WSConnection.RateLimitThrottleTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, Protocol, WSConnection}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header
  alias Longbridge.WSConnection.RateLimit

  import Bitwise

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  setup do
    RateLimit.reset()
    on_exit(fn -> RateLimit.reset() end)
    :ok
  end

  defp start_fake_server(opts) do
    test_pid = self()
    session_id = Keyword.get(opts, :session_id, "sess-#{System.unique_integer([:positive])}")
    expires = Keyword.get(opts, :expires, System.os_time(:second) + 3600)

    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, port} = :inet.port(listen_socket)

    spawn_link(fn ->
      {:ok, client} = :gen_tcp.accept(listen_socket, 10_000)
      send(test_pid, {:server, :accepted})

      {:ok, http_request} = read_http_request(client)
      ws_key = extract_header(http_request, "sec-websocket-key")
      ws_accept = compute_ws_accept(ws_key)
      :gen_tcp.send(client, build_upgrade_response(ws_accept))
      send(test_pid, {:server, :upgrade_sent})

      request_loop(client, test_pid)
      :gen_tcp.close(client)
      :gen_tcp.close(listen_socket)
    end)

    Process.unlink(spawn(fn -> :ok end))
    {:ok, port, session_id, expires}
  end

  defp request_loop(client, test_pid) do
    case ws_recv(client, 5_000) do
      {:ok, _opcode, payload} ->
        case Protocol.unpack(payload) do
          {:ok, %Header{request_id: req_id, cmd_code: cmd_code}, body, <<>>} ->
            send(test_pid, {:server, :received, cmd_code, req_id, body})

            resp =
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

  defp compute_ws_accept(ws_key), do: Base.encode64(:crypto.hash(:sha, ws_key <> @ws_guid))

  defp build_upgrade_response(ws_accept) do
    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{ws_accept}\r\n\r\n"
  end

  defp ws_encode_binary(payload) do
    len = byte_size(payload)
    header = if len < 126, do: <<0x82, len::8>>, else: <<0x82, 126, len::16-big>>
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

  defp ws_config(port) do
    Config.new(
      token: "test-token",
      quote_ws_url: "ws://127.0.0.1:#{port}",
      heartbeat_interval: 60_000,
      request_timeout: 5_000
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

  describe "rate-limit throttling" do
    test "applies server-supplied rate limits and throttles subsequent calls" do
      # Configure a tight rate limit: burst=1, refill=2 tokens/sec.
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 2, burst: 1}
      ])

      {:ok, port, _, _} = start_fake_server([])
      config = ws_config(port)
      {:ok, conn} = WSConnection.start_link(config: config, type: :quote, parent: self())

      assert_receive {:server, :accepted}, 2_000
      assert_receive {:server, :upgrade_sent}, 2_000

      # First request: bucket has 1 token, no wait. The server's auth
      # request consumed req_id 1, so the first user request gets req_id 2.
      t0 = System.monotonic_time(:millisecond)
      result1 = WSConnection.request(conn, 11, "body-1", 5_000)
      t1 = System.monotonic_time(:millisecond)
      assert {:ok, _, 2} = result1
      assert t1 - t0 < 200, "first call should be fast, took #{t1 - t0}ms"

      # Second request: bucket is empty, must wait ~500ms for refill.
      t2 = System.monotonic_time(:millisecond)
      result2 = WSConnection.request(conn, 11, "body-2", 5_000)
      t3 = System.monotonic_time(:millisecond)
      assert {:ok, _, 3} = result2
      assert t3 - t2 >= 400, "second call should wait, took #{t3 - t2}ms"
      assert t3 - t2 < 2_000, "second call should not over-wait, took #{t3 - t2}ms"

      stop_server(conn)
    end

    test "returns :infinity wait when no limit is configured (no throttling)" do
      RateLimit.reset()
      assert RateLimit.wait_ms(11) == :infinity
    end

    test "throttling is per-cmd-code, not global" do
      RateLimit.set_limits([
        %{command: :QuerySecurityQuote, limit: 2, burst: 1},
        %{command: :QueryDepth, limit: 100, burst: 100}
      ])

      assert RateLimit.wait_ms(11) == 0
      assert RateLimit.wait_ms(11) > 0
      # Different cmd_code has its own bucket
      assert RateLimit.wait_ms(14) == 0
    end
  end
end
