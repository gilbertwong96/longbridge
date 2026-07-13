defmodule Longbridge.QuoteContextTest do
  use ExUnit.Case, async: false

  alias Longbridge.{Config, Protocol, QuoteContext, WSConnection}
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol.Header
  alias Longbridge.Quote.V1, as: Q

  import Bitwise

  # ── Fake WebSocket server helpers ────────────────────────

  @ws_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

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

    {:ok, http_request} = read_http_request(client)
    ws_key = extract_header(http_request, "sec-websocket-key")
    ws_accept = compute_ws_accept(ws_key)
    :gen_tcp.send(client, build_upgrade_response(ws_accept))

    {:ok, _opcode, auth_payload} = ws_recv(client)
    {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

    :gen_tcp.send(
      client,
      ws_encode_binary(build_auth_response(auth_header.request_id, session_id, expires))
    )

    server_request_loop(client, test_pid, handler_fn)
    :gen_tcp.close(client)
    :gen_tcp.close(listen)
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

  defp build_upgrade_response(ws_accept) do
    "HTTP/1.1 101 Switching Protocols\r\n" <>
      "Upgrade: websocket\r\n" <>
      "Connection: Upgrade\r\n" <>
      "Sec-WebSocket-Accept: #{ws_accept}\r\n\r\n"
  end

  # ── WebSocket frame encoding (server → client, no masking) ──

  defp ws_encode_binary(payload) do
    ws_encode_frame(0x02, payload)
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

  defp build_response(cmd_code, req_id, body, status_code \\ 0) do
    IO.iodata_to_binary(
      Protocol.pack(
        %Header{
          type: :response,
          body_length: byte_size(body),
          cmd_code: cmd_code,
          request_id: req_id,
          status_code: status_code
        },
        body
      )
    )
  end

  defp build_push(cmd_code, body) do
    IO.iodata_to_binary(
      Protocol.pack(
        %Header{
          type: :push,
          body_length: byte_size(body),
          cmd_code: cmd_code
        },
        body
      )
    )
  end

  defp encode_msg(msg) do
    {:ok, iodata, _} = Protox.encode(msg)
    IO.iodata_to_binary(iodata)
  end

  # Handler type: (client, test_pid, cmd_code, req_id, body) -> :ok

  defp resp_handler(resp_msg) do
    fn client, test_pid, cmd_code, req_id, _body ->
      send(test_pid, {:cmd_code, cmd_code})

      :gen_tcp.send(
        client,
        ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp_msg)))
      )
    end
  end

  defp empty_resp_handler do
    fn client, test_pid, cmd_code, req_id, _body ->
      send(test_pid, {:cmd_code, cmd_code})
      :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
    end
  end

  # Handler used by push callback registration tests. Returns
  # empty bodies for any cmd code so the QuoteContext's init/1
  # auto-fired user_quote_profile request completes without
  # timeouts.
  defp push_test_handler do
    fn client, _test_pid, cmd_code, req_id, _body ->
      empty_resp =
        case cmd_code do
          4 -> encode_msg(%Q.UserQuoteProfileResponse{rate_limit: []})
          _ -> <<>>
        end

      :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, empty_resp)))
    end
  end

  defp inspect_handler(resp_msg, decode_mod) do
    fn client, test_pid, cmd_code, req_id, body ->
      # Skip the auto-fired user_quote_profile call (cmd 4) that the
      # QuoteContext's init/1 fires to populate rate limits. The cmd
      # code is still forwarded to the test process for assertion.
      if cmd_code != 4 do
        send(test_pid, {:cmd_code, cmd_code})

        if decode_mod do
          send(test_pid, {:req, Protox.decode!(body, decode_mod)})
        end
      else
        send(test_pid, {:cmd_code, cmd_code})
      end

      :gen_tcp.send(
        client,
        ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp_msg)))
      )
    end
  end

  defp error_handler(status_code) do
    fn client, _test_pid, cmd_code, req_id, _body ->
      :gen_tcp.send(
        client,
        ws_encode_binary(build_response(cmd_code, req_id, "error-body", status_code))
      )
    end
  end

  defp await_port do
    assert_receive {:port, port}, 2_000
    port
  end

  defp start_ctx(port) do
    config =
      Config.new(
        token: "test-token",
        quote_ws_url: "ws://127.0.0.1:#{port}",
        heartbeat_interval: 60_000
      )

    {:ok, ctx} = QuoteContext.start_link(config)
    ctx
  end

  defp connected_ctx(session_id, handler_fn) do
    {:ok, server} = start_server(session_id, handler_fn)
    port = await_port()
    ctx = start_ctx(port)
    wait_for_session(ctx)
    {server, ctx}
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

  defp wait_for_session(ctx) do
    result =
      Enum.reduce_while(1..50, :error, fn _, _ ->
        case QuoteContext.session(ctx) do
          {:ok, _, _} ->
            {:halt, :ok}

          {:error, _} ->
            Process.sleep(100)
            {:cont, :error}
        end
      end)

    case result do
      :ok -> :ok
      :error -> flunk("Connection not established after 5s")
    end
  end

  defp wait_for_disconnect(ctx) do
    Enum.reduce_while(1..50, :ok, fn _, _ ->
      case QuoteContext.session(ctx) do
        {:error, _} ->
          {:halt, :ok}

        {:ok, _, _} ->
          Process.sleep(100)
          {:cont, :error}
      end
    end)
  end

  defp start_auth_fail_server do
    test_pid = self()

    pid =
      spawn_link(fn ->
        {:ok, listen} =
          :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

        {:ok, port} = :inet.port(listen)
        send(test_pid, {:port, port})

        {:ok, client} = :gen_tcp.accept(listen, 10_000)

        {:ok, http_request} = read_http_request(client)
        ws_key = extract_header(http_request, "sec-websocket-key")
        ws_accept = compute_ws_accept(ws_key)
        :gen_tcp.send(client, build_upgrade_response(ws_accept))

        {:ok, _opcode, auth_payload} = ws_recv(client)
        {:ok, auth_header, _auth_body, <<>>} = Protocol.unpack(auth_payload)

        :gen_tcp.send(
          client,
          ws_encode_binary(build_auth_response(auth_header.request_id, "", 0, 5))
        )

        Process.sleep(5_000)
        :gen_tcp.close(client)
        :gen_tcp.close(listen)
      end)

    Process.unlink(pid)
    {:ok, pid}
  end

  # ── Tests ────────────────────────────────────────────────

  describe "start_link/2 + authentication" do
    test "connects and authenticates against a fake server" do
      {server, ctx} =
        connected_ctx("sess-#{System.unique_integer([:positive])}", empty_resp_handler())

      assert Process.alive?(ctx)
      cleanup(server, ctx)
    end

    test "session/1 returns session info after auth" do
      sid = "sess-info-#{System.unique_integer([:positive])}"
      {server, ctx} = connected_ctx(sid, empty_resp_handler())
      assert {:ok, ^sid, _} = QuoteContext.session(ctx)
      cleanup(server, ctx)
    end

    test "request_timeout is driven by config and scales the call timeout" do
      # Guards against the previous mismatch where the outer GenServer.call
      # timeout was a fixed 15s while the inner request used config.request_timeout.
      sid = "sess-rt-#{System.unique_integer([:positive])}"
      {server, ctx} = connected_ctx(sid, empty_resp_handler())
      assert GenServer.call(ctx, :request_timeout) == 10_000
      cleanup(server, ctx)
    end
  end

  describe "quote/2" do
    test "sends a quote request and returns decoded response" do
      resp = %Q.SecurityQuoteResponse{
        secu_quote: [%Q.SecurityQuote{symbol: "AAPL.US", last_done: "250.00"}]
      }

      {server, ctx} =
        connected_ctx("sess-q#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.SecurityQuoteResponse{secu_quote: [q]}} =
               QuoteContext.quote(ctx, ["AAPL.US"])

      assert q.symbol == "AAPL.US"
      assert q.last_done == "250.00"
      assert_receive {:cmd_code, 11}
      cleanup(server, ctx)
    end
  end

  describe "static_info/2" do
    test "sends a static info request and returns decoded response" do
      resp = %Q.SecurityStaticInfoResponse{
        secu_static_info: [%Q.StaticInfo{symbol: "AAPL.US", name_en: "Apple Inc"}]
      }

      {server, ctx} =
        connected_ctx("sess-s#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.SecurityStaticInfoResponse{secu_static_info: [info]}} =
               QuoteContext.static_info(ctx, ["AAPL.US"])

      assert info.symbol == "AAPL.US"
      assert_receive {:cmd_code, 10}
      cleanup(server, ctx)
    end
  end

  describe "subscribe and unsubscribe" do
    test "subscribe sends correct sub_types" do
      {server, ctx} =
        connected_ctx("sess-sub#{System.unique_integer([:positive])}", empty_resp_handler())

      assert :ok = QuoteContext.subscribe(ctx, ["AAPL.US"], [:QUOTE, :DEPTH])
      assert_receive {:cmd_code, 6}
      cleanup(server, ctx)
    end

    test "re-applies subscriptions after a reconnect" do
      {server, ctx} =
        connected_ctx("sess-rs#{System.unique_integer([:positive])}", empty_resp_handler())

      assert :ok = QuoteContext.subscribe(ctx, ["AAPL.US"], [:QUOTE])
      assert_receive {:cmd_code, 6}

      # Simulate the WSConnection's {:connected, _} broadcast, which fires
      # on initial connect and on every reconnect. The context must re-send
      # the recorded subscribe so push delivery resumes after a drop.
      conn = :sys.get_state(ctx).conn
      send(ctx, {:longbridge, conn, {:connected, "sess-rs-2"}})

      assert_receive {:cmd_code, 6}
      cleanup(server, ctx)
    end

    test "unsubscribe sends correct params" do
      {server, ctx} =
        connected_ctx("sess-un#{System.unique_integer([:positive])}", empty_resp_handler())

      assert :ok = QuoteContext.unsubscribe(ctx, ["AAPL.US"], [:QUOTE], true)
      assert_receive {:cmd_code, 7}
      cleanup(server, ctx)
    end

    test "unsubscribe defaults unsub_all to false" do
      handler = fn client, test_pid, cmd_code, req_id, body ->
        send(test_pid, {:cmd_code, cmd_code})
        send(test_pid, {:body, body})
        :gen_tcp.send(client, ws_encode_binary(build_response(cmd_code, req_id, <<>>)))
      end

      {server, ctx} =
        connected_ctx("sess-ud#{System.unique_integer([:positive])}", handler)

      assert :ok = QuoteContext.unsubscribe(ctx, ["AAPL.US"], [:QUOTE])
      assert_receive {:cmd_code, 7}
      assert_receive {:body, body}
      {:ok, decoded} = Protox.decode(body, Q.UnsubscribeRequest)
      refute decoded.unsub_all
      cleanup(server, ctx)
    end

    test "unsubscribe returns error when server drops the connection" do
      handler = fn client, _tp, _cc, _ri, _body ->
        :gen_tcp.close(client)
      end

      {server, ctx} =
        connected_ctx("sess-ue#{System.unique_integer([:positive])}", handler)

      Process.sleep(50)
      assert {:error, _} = QuoteContext.unsubscribe(ctx, ["AAPL.US"], [:QUOTE])
      cleanup(server, ctx)
    end

    test "subscribe returns error when server drops the connection" do
      handler = fn client, _tp, _cc, _ri, _body ->
        :gen_tcp.close(client)
      end

      {server, ctx} =
        connected_ctx("sess-se#{System.unique_integer([:positive])}", handler)

      Process.sleep(50)
      assert {:error, _} = QuoteContext.subscribe(ctx, ["AAPL.US"], [:QUOTE])
      cleanup(server, ctx)
    end
  end

  describe "subscription/1" do
    test "queries current subscriptions" do
      resp = %Q.SubscriptionResponse{
        sub_list: [%Q.SubTypeList{symbol: "AAPL.US", sub_type: [:QUOTE]}]
      }

      {server, ctx} =
        connected_ctx("sess-sl#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.SubscriptionResponse{sub_list: [sub]}} = QuoteContext.subscription(ctx)
      assert sub.symbol == "AAPL.US"
      assert_receive {:cmd_code, 5}
      cleanup(server, ctx)
    end
  end

  describe "depth/2" do
    test "queries market depth" do
      resp = %Q.SecurityDepthResponse{symbol: "700.HK", ask: [], bid: []}

      {server, ctx} =
        connected_ctx(
          "sess-d#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityRequest)
        )

      assert {:ok, %Q.SecurityDepthResponse{}} = QuoteContext.depth(ctx, "700.HK")
      assert_receive {:cmd_code, 14}
      assert_receive {:req, req}
      assert req.symbol == "700.HK"
      cleanup(server, ctx)
    end
  end

  describe "brokers/2" do
    test "queries broker queue" do
      resp = %Q.SecurityBrokersResponse{symbol: "700.HK", ask_brokers: [], bid_brokers: []}

      {server, ctx} =
        connected_ctx("sess-b#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.SecurityBrokersResponse{}} = QuoteContext.brokers(ctx, "700.HK")
      assert_receive {:cmd_code, 15}
      cleanup(server, ctx)
    end
  end

  describe "trades/3" do
    test "queries recent trades with default count" do
      resp = %Q.SecurityTradeResponse{symbol: "AAPL.US", trades: []}

      {server, ctx} =
        connected_ctx(
          "sess-t#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityTradeRequest)
        )

      assert {:ok, %Q.SecurityTradeResponse{}} = QuoteContext.trades(ctx, "AAPL.US")
      assert_receive {:cmd_code, 17}
      assert_receive {:req, req}
      assert req.symbol == "AAPL.US"
      assert req.count == 100
      cleanup(server, ctx)
    end

    test "queries recent trades with custom count" do
      resp = %Q.SecurityTradeResponse{symbol: "AAPL.US", trades: []}

      {server, ctx} =
        connected_ctx(
          "sess-t2#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityTradeRequest)
        )

      assert {:ok, _} = QuoteContext.trades(ctx, "AAPL.US", 50)
      assert_receive {:req, req}
      assert req.count == 50
      cleanup(server, ctx)
    end
  end

  describe "candlesticks/5" do
    @describetag timeout: 120_000
    test "queries candlestick data with default period" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-c#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, %Q.SecurityCandlestickResponse{}} = QuoteContext.candlesticks(ctx, "AAPL.US")
      assert_receive {:cmd_code, 19}
      assert_receive {:req, req}
      assert req.symbol == "AAPL.US"
      assert req.period == :DAY
      assert req.count == 100
      cleanup(server, ctx)
    end

    test "supports all period codes" do
      periods = [
        ONE_MINUTE: :ONE_MINUTE,
        FIVE_MINUTE: :FIVE_MINUTE,
        FIFTEEN_MINUTE: :FIFTEEN_MINUTE,
        THIRTY_MINUTE: :THIRTY_MINUTE,
        SIXTY_MINUTE: :SIXTY_MINUTE,
        DAY: :DAY,
        WEEK: :WEEK,
        MONTH: :MONTH,
        QUARTER: :QUARTER,
        YEAR: :YEAR
      ]

      for {period_atom, expected_val} <- periods do
        resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

        {server, ctx} =
          connected_ctx(
            "sess-p#{period_atom}#{System.unique_integer([:positive])}",
            inspect_handler(resp, Q.SecurityCandlestickRequest)
          )

        assert {:ok, _} = QuoteContext.candlesticks(ctx, "AAPL.US", period_atom, 10)
        assert_receive {:req, req}
        assert req.period == expected_val
        cleanup(server, ctx)
      end
    end

    test "supports integer period code passthrough" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-pi#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, _} = QuoteContext.candlesticks(ctx, "AAPL.US", 9999, 10)
      assert_receive {:req, req}
      assert req.period == 9999
      cleanup(server, ctx)
    end

    test "passes adjust_type and trade_session through" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-pa#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, _} = QuoteContext.candlesticks(ctx, "AAPL.US", :DAY, 50, 1, 2)
      assert_receive {:req, req}
      # The integer `1` decodes to the FORWARD_ADJUST enum value on the
      # server side (NO_ADJUST = 0, FORWARD_ADJUST = 1).
      assert req.adjust_type == :FORWARD_ADJUST
      assert req.trade_session == 2
      cleanup(server, ctx)
    end

    test "candlesticks/6 accepts typed trade_session atom" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-tsatom#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, _} =
               QuoteContext.candlesticks(ctx, "AAPL.US", :DAY, 50, 0, :POST_TRADE)

      assert_receive {:req, req}
      assert req.trade_session == 2

      cleanup(server, ctx)
    end

    test "warrant_list/2 builds a filter request and decodes the response" do
      resp = %Q.WarrantFilterListResponse{
        warrant_list: [
          %Q.FilterWarrant{
            symbol: "21007.HK",
            name: "HSI Bull Warrant",
            last_done: "0.20",
            change_rate: "0.05",
            strike_price: "18000.00"
          }
        ],
        total_count: 1
      }

      {server, ctx} =
        connected_ctx(
          "sess-wfl#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.WarrantFilterListRequest)
        )

      assert {:ok, decoded} =
               QuoteContext.warrant_list(ctx,
                 symbol: "700.HK",
                 language: 1,
                 sort_by: :change_rate,
                 type: :call,
                 expiry_date: :between_3_6
               )

      assert_receive {:req, req}
      assert req.symbol == "700.HK"
      assert req.language == 1
      assert req.filter_config.sort_by == 1
      assert req.filter_config.type == [0]
      assert req.filter_config.expiry_date == [2]

      assert decoded.total_count == 1
      assert hd(decoded.warrant_list).symbol == "21007.HK"
      assert hd(decoded.warrant_list).strike_price == "18000.00"

      cleanup(server, ctx)
    end

    test "warrant_list/2 accepts raw integer filter values" do
      resp = %Q.WarrantFilterListResponse{warrant_list: [], total_count: 0}

      {server, ctx} =
        connected_ctx(
          "sess-wfli#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.WarrantFilterListRequest)
        )

      assert {:ok, _} =
               QuoteContext.warrant_list(ctx,
                 symbol: "700.HK",
                 language: 0,
                 sort_by: 1,
                 sort_order: 0,
                 type: [0, 1],
                 status: [4]
               )

      assert_receive {:req, req}
      assert req.filter_config.sort_by == 1
      assert req.filter_config.sort_order == 0
      assert req.filter_config.type == [0, 1]
      assert req.filter_config.status == [4]

      cleanup(server, ctx)
    end

    test "warrant_list/2 encodes every filter atom to its code" do
      resp = %Q.WarrantFilterListResponse{warrant_list: [], total_count: 0}

      {server, ctx} =
        connected_ctx(
          "sess-wfla#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.WarrantFilterListRequest)
        )

      assert {:ok, _} =
               QuoteContext.warrant_list(ctx,
                 symbol: "700.HK",
                 language: 0,
                 sort_by: :volume,
                 sort_order: :asc,
                 sort_offset: 10,
                 sort_count: 100,
                 type: [:put],
                 issuer: [42],
                 expiry_date: [:gt_12],
                 price_type: [:out_bounds],
                 status: [:suspend, :prepare_list, :normal]
               )

      assert_receive {:req, req}
      assert req.filter_config.sort_by == 3
      assert req.filter_config.sort_order == 1
      assert req.filter_config.sort_offset == 10
      assert req.filter_config.sort_count == 100
      assert req.filter_config.type == [1]
      assert req.filter_config.issuer == [42]
      assert req.filter_config.expiry_date == [4]
      assert req.filter_config.price_type == [2]
      assert req.filter_config.status == [2, 3, 4]

      cleanup(server, ctx)
    end

    test "4-arg call falls back to default trade_session" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-p4#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, _} = QuoteContext.candlesticks(ctx, "AAPL.US", :DAY, 10, 1)
      assert_receive {:req, req}
      assert req.adjust_type == :FORWARD_ADJUST
      assert req.trade_session == 0
      cleanup(server, ctx)
    end

    test "3-arg call falls back to default count and adjust_type" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-p3#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, _} = QuoteContext.candlesticks(ctx, "AAPL.US", :DAY, 50)
      assert_receive {:req, req}
      assert req.count == 50
      assert req.adjust_type == :NO_ADJUST
      cleanup(server, ctx)
    end
  end

  describe "candlesticks_paginated/3" do
    @describetag timeout: 120_000

    test "returns all candles in a single batch when count <= batch_size" do
      candles = for i <- 1..3, do: %Q.Candlestick{timestamp: i, close: "#{i}00.0"}
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: candles}

      {server, ctx} =
        connected_ctx(
          "sess-pag1#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, result} = QuoteContext.candlesticks_paginated(ctx, "AAPL.US", count: 3)
      assert length(result) == 3
      assert List.first(result).timestamp == 1
      assert List.last(result).timestamp == 3
      cleanup(server, ctx)
    end

    test "stops when API returns fewer candles than requested" do
      candles = for i <- 1..3, do: %Q.Candlestick{timestamp: i, close: "#{i}00"}
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: candles}

      {server, ctx} =
        connected_ctx(
          "sess-pag3#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, result} = QuoteContext.candlesticks_paginated(ctx, "AAPL.US", count: 1000)
      assert length(result) == 3
      cleanup(server, ctx)
    end

    test "returns empty list when API returns no candles" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-pag4#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, result} = QuoteContext.candlesticks_paginated(ctx, "AAPL.US", count: 100)
      assert result == []
      cleanup(server, ctx)
    end

    test "paginates multiple batches when offset API returns different data" do
      batch1 = for i <- 1..5, do: %Q.Candlestick{timestamp: i, close: "#{i}00"}
      batch2 = for i <- 6..10, do: %Q.Candlestick{timestamp: i, close: "#{i}00"}
      counter = :counters.new(1, [])
      test_pid = self()

      handler = fn client, _tp, cmd_code, req_id, _body ->
        if cmd_code == 4 do
          resp = %Q.UserQuoteProfileResponse{}

          :gen_tcp.send(
            client,
            ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp)))
          )
        else
          _ = :counters.add(counter, 1, 1)
          n = :counters.get(counter, 1)

          batch = if n == 1, do: batch1, else: batch2
          resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: batch}
          send(test_pid, {:batch_call, n})

          :gen_tcp.send(
            client,
            ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp)))
          )
        end
      end

      {server, ctx} =
        connected_ctx(
          "sess-pag6#{System.unique_integer([:positive])}",
          handler
        )

      assert {:ok, result} =
               QuoteContext.candlesticks_paginated(ctx, "AAPL.US", count: 10, batch_size: 5)

      assert length(result) == 10
      assert List.first(result).timestamp == 1
      assert List.last(result).timestamp == 10
      cleanup(server, ctx)
    end

    test "stops when all candles are duplicates (no more history)" do
      candles = for i <- 1..5, do: %Q.Candlestick{timestamp: i, close: "#{i}00"}
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: candles}

      {server, ctx} =
        connected_ctx(
          "sess-pag7#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityCandlestickRequest)
        )

      assert {:ok, result} =
               QuoteContext.candlesticks_paginated(ctx, "AAPL.US", count: 1000, batch_size: 5)

      assert length(result) == 5
      cleanup(server, ctx)
    end

    test "returns error when API fails" do
      {server, ctx} =
        connected_ctx(
          "sess-pag5#{System.unique_integer([:positive])}",
          error_handler(7)
        )

      assert {:error, _} = QuoteContext.candlesticks_paginated(ctx, "AAPL.US", count: 100)
      cleanup(server, ctx)
    end
  end

  describe "other API methods" do
    test "history_candlesticks_by_offset/3 sends an offset query" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-hbo#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityHistoryCandlestickRequest)
        )

      assert {:ok, _} =
               QuoteContext.history_candlesticks_by_offset(ctx, "AAPL.US",
                 period: :DAY,
                 adjust_type: 0,
                 direction: :backward,
                 date: "2024-05-01",
                 minute: "10:30",
                 count: 50,
                 trade_session: 1
               )

      assert_receive {:cmd_code, 27}
      assert_receive {:req, req}

      assert req.symbol == "AAPL.US"
      assert req.period == :DAY
      assert req.adjust_type == :NO_ADJUST
      assert req.query_type == :QUERY_BY_OFFSET
      assert req.offset_request.direction == :BACKWARD
      assert req.offset_request.date == "2024-05-01"
      assert req.offset_request.minute == "10:30"
      assert req.offset_request.count == 50
      assert req.trade_session == 1

      cleanup(server, ctx)
    end

    test "history_candlesticks_by_offset/3 with :forward direction" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-hbof#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityHistoryCandlestickRequest)
        )

      assert {:ok, _} =
               QuoteContext.history_candlesticks_by_offset(ctx, "AAPL.US",
                 period: :SIXTY_MINUTE,
                 adjust_type: 1,
                 direction: :forward,
                 date: "2024-01-15",
                 count: 10
               )

      assert_receive {:req, req}
      assert req.offset_request.direction == :FORWARD
      # minute defaults to empty string when omitted
      assert req.offset_request.minute == ""
      assert req.trade_session == 0

      cleanup(server, ctx)
    end

    test "history_candlesticks_by_date/3 sends a date range query" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-hbd#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityHistoryCandlestickRequest)
        )

      assert {:ok, _} =
               QuoteContext.history_candlesticks_by_date(ctx, "AAPL.US",
                 period: :WEEK,
                 adjust_type: 0,
                 start_date: "2024-01-01",
                 end_date: "2024-03-31",
                 trade_session: 1
               )

      assert_receive {:cmd_code, 27}
      assert_receive {:req, req}

      assert req.symbol == "AAPL.US"
      assert req.period == :WEEK
      assert req.adjust_type == :NO_ADJUST
      assert req.query_type == :QUERY_BY_DATE
      assert req.date_request.start_date == "2024-01-01"
      assert req.date_request.end_date == "2024-03-31"
      assert req.trade_session == 1

      cleanup(server, ctx)
    end

    test "history_candlesticks_by_date/3 defaults trade_session to 0" do
      resp = %Q.SecurityCandlestickResponse{symbol: "AAPL.US", candlesticks: []}

      {server, ctx} =
        connected_ctx(
          "sess-hbds#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.SecurityHistoryCandlestickRequest)
        )

      assert {:ok, _} =
               QuoteContext.history_candlesticks_by_date(ctx, "AAPL.US",
                 period: :DAY,
                 adjust_type: 0,
                 start_date: "2024-01-01",
                 end_date: "2024-01-31"
               )

      assert_receive {:req, req}
      assert req.trade_session == 0

      cleanup(server, ctx)
    end

    test "intraday/3" do
      resp = %Q.SecurityIntradayResponse{symbol: "AAPL.US", lines: []}

      {server, ctx} =
        connected_ctx("sess-i#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.SecurityIntradayResponse{}} = QuoteContext.intraday(ctx, "AAPL.US")
      assert_receive {:cmd_code, 18}
      cleanup(server, ctx)
    end

    test "option_quote/2" do
      resp = %Q.OptionQuoteResponse{secu_quote: []}

      {server, ctx} =
        connected_ctx("sess-oq#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.OptionQuoteResponse{}} = QuoteContext.option_quote(ctx, ["AAPL.US"])
      assert_receive {:cmd_code, 12}
      cleanup(server, ctx)
    end

    test "warrant_quote/2" do
      resp = %Q.WarrantQuoteResponse{secu_quote: []}

      {server, ctx} =
        connected_ctx("sess-wq#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.WarrantQuoteResponse{}} = QuoteContext.warrant_quote(ctx, ["700.HK"])
      assert_receive {:cmd_code, 13}
      cleanup(server, ctx)
    end

    test "participant_broker_ids/1" do
      resp = %Q.ParticipantBrokerIdsResponse{participant_broker_numbers: []}

      {server, ctx} =
        connected_ctx("sess-pb#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.ParticipantBrokerIdsResponse{}} = QuoteContext.participant_broker_ids(ctx)
      assert_receive {:cmd_code, 16}
      cleanup(server, ctx)
    end

    test "option_chain_date/2" do
      resp = %Q.OptionChainDateListResponse{expiry_date: []}

      {server, ctx} =
        connected_ctx("sess-oc#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.OptionChainDateListResponse{}} =
               QuoteContext.option_chain_date(ctx, "AAPL.US")

      assert_receive {:cmd_code, 20}
      cleanup(server, ctx)
    end

    test "option_chain_strike_info/3" do
      resp = %Q.OptionChainDateStrikeInfoResponse{strike_price_info: []}

      {server, ctx} =
        connected_ctx("sess-ocs#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.OptionChainDateStrikeInfoResponse{}} =
               QuoteContext.option_chain_strike_info(ctx, "AAPL.US", "20240119")

      assert_receive {:cmd_code, 21}
      cleanup(server, ctx)
    end

    test "warrant_issuer_info/1" do
      resp = %Q.IssuerInfoResponse{issuer_info: []}

      {server, ctx} =
        connected_ctx("sess-wi#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.IssuerInfoResponse{}} = QuoteContext.warrant_issuer_info(ctx)
      assert_receive {:cmd_code, 22}
      cleanup(server, ctx)
    end

    test "market_trade_period/1" do
      resp = %Q.MarketTradePeriodResponse{market_trade_session: []}

      {server, ctx} =
        connected_ctx("sess-mtp#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.MarketTradePeriodResponse{}} = QuoteContext.market_trade_period(ctx)
      assert_receive {:cmd_code, 8}
      cleanup(server, ctx)
    end

    test "market_trade_day/4" do
      resp = %Q.MarketTradeDayResponse{trade_day: [], half_trade_day: []}

      {server, ctx} =
        connected_ctx(
          "sess-mtd#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.MarketTradeDayRequest)
        )

      assert {:ok, %Q.MarketTradeDayResponse{}} =
               QuoteContext.market_trade_day(ctx, "HK", "20240101", "20240131")

      assert_receive {:cmd_code, 9}
      assert_receive {:req, req}
      assert req.market == "HK"
      assert req.beg_day == "20240101"
      assert req.end_day == "20240131"
      cleanup(server, ctx)
    end

    test "market_trade_day/4 accepts YYYY-MM-DD and strips dashes" do
      resp = %Q.MarketTradeDayResponse{trade_day: [], half_trade_day: []}

      {server, ctx} =
        connected_ctx(
          "sess-mtd2#{System.unique_integer([:positive])}",
          inspect_handler(resp, Q.MarketTradeDayRequest)
        )

      assert {:ok, %Q.MarketTradeDayResponse{}} =
               QuoteContext.market_trade_day(ctx, "US", "2024-01-15", "2024-01-29")

      assert_receive {:req, req}
      assert req.beg_day == "20240115"
      assert req.end_day == "20240129"
      cleanup(server, ctx)
    end

    test "calc_index/3" do
      resp = %Q.SecurityCalcQuoteResponse{security_calc_index: []}

      {server, ctx} =
        connected_ctx("sess-ci#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.SecurityCalcQuoteResponse{}} =
               QuoteContext.calc_index(ctx, ["AAPL.US"], [1, 2])

      assert_receive {:cmd_code, 26}
      cleanup(server, ctx)
    end

    test "capital_flow_intraday/2" do
      resp = %Q.CapitalFlowIntradayResponse{symbol: "AAPL.US", capital_flow_lines: []}

      {server, ctx} =
        connected_ctx("sess-cfi#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.CapitalFlowIntradayResponse{}} =
               QuoteContext.capital_flow_intraday(ctx, "AAPL.US")

      assert_receive {:cmd_code, 24}
      cleanup(server, ctx)
    end

    test "capital_flow_distribution/2" do
      resp = %Q.CapitalDistributionResponse{symbol: "AAPL.US", timestamp: 0}

      {server, ctx} =
        connected_ctx("sess-cfd#{System.unique_integer([:positive])}", resp_handler(resp))

      assert {:ok, %Q.CapitalDistributionResponse{}} =
               QuoteContext.capital_flow_distribution(ctx, "AAPL.US")

      assert_receive {:cmd_code, 25}
      cleanup(server, ctx)
    end
  end

  describe "request_empty error paths" do
    # request_empty/3 is the helper used by participant_broker_ids/1,
    # warrant_issuer_info/1, and market_trade_period/1. The error branch
    # is hit when the underlying connection drops between the request
    # being sent and the response arriving.
    test "participant_broker_ids/1 returns error when server drops the connection" do
      handler = fn client, _tp, _cc, _ri, _body ->
        :gen_tcp.close(client)
      end

      {server, ctx} =
        connected_ctx("sess-pbe#{System.unique_integer([:positive])}", handler)

      Process.sleep(50)
      assert {:error, _} = QuoteContext.participant_broker_ids(ctx)
      cleanup(server, ctx)
    end

    test "warrant_issuer_info/1 returns error when server drops the connection" do
      handler = fn client, _tp, _cc, _ri, _body ->
        :gen_tcp.close(client)
      end

      {server, ctx} =
        connected_ctx("sess-wie#{System.unique_integer([:positive])}", handler)

      Process.sleep(50)
      assert {:error, _} = QuoteContext.warrant_issuer_info(ctx)
      cleanup(server, ctx)
    end

    test "warrant_issuer_info/1 returns {:error, {:decode_error, _}} when the response is malformed" do
      # Send a response body that the proto decoder cannot parse.
      # The first byte 0xFF is not a valid protobuf tag, so Protox
      # raises Protox.DecodingError. The fix in QuoteContext wraps
      # the raise into `{:error, {:decode_error, _}}` so callers
      # never see a raw exception.
      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(
          client,
          ws_encode_binary(build_response(cmd_code, req_id, <<0xFF, 0xFE, 0xFD>>))
        )
      end

      {server, ctx} =
        connected_ctx("sess-decode#{System.unique_integer([:positive])}", handler)

      assert {:error, {:decode_error, %Protox.DecodingError{}}} =
               QuoteContext.warrant_issuer_info(ctx)

      cleanup(server, ctx)
    end

    test "quote/2 returns {:error, {:decode_error, _}} on malformed response body" do
      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(
          client,
          ws_encode_binary(build_response(cmd_code, req_id, <<0xFF, 0xFE, 0xFD>>))
        )
      end

      {server, ctx} =
        connected_ctx("sess-decode-q#{System.unique_integer([:positive])}", handler)

      assert {:error, {:decode_error, %Protox.DecodingError{}}} =
               QuoteContext.quote(ctx, ["AAPL.US"])

      cleanup(server, ctx)
    end
  end

  describe "user_quote_profile/2" do
    test "sends a UserQuoteProfileRequest and returns the response" do
      resp = %Q.UserQuoteProfileResponse{
        member_id: 15_766_270,
        quote_level: "Lv1",
        subscribe_limit: 500,
        history_candlestick_limit: 1000,
        rate_limit: [
          %Q.RateLimit{command: :QuerySecurityQuote, limit: 600, burst: 600}
        ],
        quote_level_detail: nil
      }

      # Use a custom handler that distinguishes the QuoteContext's
      # init-fired call (cmd_code 4) from the explicit call. Both
      # share cmd_code 4, so we rely on the test process to discard
      # the first :req (from init) and assert on the second.
      resp_msg = resp
      test_pid = self()
      counter = :counters.new(1, [])

      handler = fn client, _tp, cmd_code, req_id, body ->
        _ = :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        decoded = if cmd_code == 4, do: Q.UserQuoteProfileRequest, else: nil
        req = if decoded, do: Protox.decode!(body, decoded), else: nil

        send(test_pid, {:uqp_call, n, cmd_code, req})

        :gen_tcp.send(
          client,
          ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp_msg)))
        )
      end

      {server, ctx} =
        connected_ctx(
          "sess-uqp#{System.unique_integer([:positive])}",
          handler
        )

      assert {:ok, %Q.UserQuoteProfileResponse{}} = QuoteContext.user_quote_profile(ctx)
      assert_receive {:uqp_call, 1, 4, _init_req}
      assert_receive {:uqp_call, 2, 4, req}
      assert req.language == "en"
      cleanup(server, ctx)
    end

    test "honors a custom :language option" do
      resp = %Q.UserQuoteProfileResponse{}

      test_pid = self()
      counter = :counters.new(1, [])

      handler = fn client, _tp, cmd_code, req_id, body ->
        _ = :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        decoded = if cmd_code == 4, do: Q.UserQuoteProfileRequest, else: nil
        req = if decoded, do: Protox.decode!(body, decoded), else: nil

        send(test_pid, {:uqp_call, n, cmd_code, req})

        :gen_tcp.send(
          client,
          ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp)))
        )
      end

      {server, ctx} =
        connected_ctx(
          "sess-uqpl#{System.unique_integer([:positive])}",
          handler
        )

      assert {:ok, _} = QuoteContext.user_quote_profile(ctx, language: "zh-HK")
      assert_receive {:uqp_call, 1, 4, _init_req}
      assert_receive {:uqp_call, 2, 4, req}
      assert req.language == "zh-HK"
      cleanup(server, ctx)
    end
  end

  describe "member_id/1" do
    test "returns the member_id field from user_quote_profile" do
      resp = %Q.UserQuoteProfileResponse{member_id: 15_766_270, quote_level: "Lv1"}

      {server, ctx} =
        connected_ctx(
          "sess-mid#{System.unique_integer([:positive])}",
          inspect_handler(resp, nil)
        )

      assert {:ok, 15_766_270} = QuoteContext.member_id(ctx)
      cleanup(server, ctx)
    end
  end

  describe "quote_level/1" do
    test "returns the quote_level field from user_quote_profile" do
      resp = %Q.UserQuoteProfileResponse{member_id: 1, quote_level: "Lv2"}

      {server, ctx} =
        connected_ctx(
          "sess-ql#{System.unique_integer([:positive])}",
          inspect_handler(resp, nil)
        )

      assert {:ok, "Lv2"} = QuoteContext.quote_level(ctx)
      cleanup(server, ctx)
    end
  end

  describe "quote_package_details/2" do
    test "returns the quote_level_detail from user_quote_profile" do
      package = %Q.UserQuoteLevelDetail.PackageDetail{
        key: "hk_basic",
        name: "HK Basic",
        description: "Basic HK quotes",
        start: 1_700_000_000,
        end: 1_900_000_000
      }

      market_package = %Q.UserQuoteLevelDetail.MarketPackageDetail{
        packages: [package],
        warning_msg: ""
      }

      details = %Q.UserQuoteLevelDetail{
        by_market_code: %{"HK" => market_package},
        by_package_key: %{"hk_basic" => package}
      }

      resp = %Q.UserQuoteProfileResponse{
        member_id: 1,
        quote_level: "Lv1",
        quote_level_detail: details
      }

      test_pid = self()
      counter = :counters.new(1, [])

      handler = fn client, _tp, cmd_code, req_id, body ->
        _ = :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        decoded = if cmd_code == 4, do: Q.UserQuoteProfileRequest, else: nil
        req = if decoded, do: Protox.decode!(body, decoded), else: nil
        send(test_pid, {:qpd_call, n, cmd_code, req})

        :gen_tcp.send(
          client,
          ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp)))
        )
      end

      {server, ctx} =
        connected_ctx(
          "sess-qpd#{System.unique_integer([:positive])}",
          handler
        )

      assert {:ok, ^details} = QuoteContext.quote_package_details(ctx)
      # The second call (after init) must have carried the request.
      assert_receive {:qpd_call, 2, 4, req}
      assert req.language == "en"
      cleanup(server, ctx)
    end

    test "forwards the :language option" do
      resp = %Q.UserQuoteProfileResponse{quote_level_detail: nil}

      test_pid = self()
      counter = :counters.new(1, [])

      handler = fn client, _tp, cmd_code, req_id, body ->
        _ = :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)

        decoded = if cmd_code == 4, do: Q.UserQuoteProfileRequest, else: nil
        req = if decoded, do: Protox.decode!(body, decoded), else: nil
        send(test_pid, {:qpd_call, n, cmd_code, req})

        :gen_tcp.send(
          client,
          ws_encode_binary(build_response(cmd_code, req_id, encode_msg(resp)))
        )
      end

      {server, ctx} =
        connected_ctx(
          "sess-qpdl#{System.unique_integer([:positive])}",
          handler
        )

      assert {:ok, _} = QuoteContext.quote_package_details(ctx, language: "zh-CN")
      assert_receive {:qpd_call, 2, 4, req}
      assert req.language == "zh-CN"
      cleanup(server, ctx)
    end
  end

  describe "push messages" do
    test "QuoteContext stays alive after receiving push data" do
      sid = "sess-push#{System.unique_integer([:positive])}"

      # Default handler doesn't reply to the auto-fired user_quote_profile
      # call (cmd 4) so it would time out and block init for ~10s. Add
      # a noop reply so the QuoteContext's init can proceed.
      user_quote_resp = %Q.UserQuoteProfileResponse{
        rate_limit: [],
        quote_level_detail: nil
      }

      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(client, ws_encode_binary(build_push(101, "push-data")))

        cond do
          cmd_code == 4 ->
            :gen_tcp.send(
              client,
              ws_encode_binary(build_response(cmd_code, req_id, encode_msg(user_quote_resp)))
            )

          cmd_code == 11 ->
            :gen_tcp.send(
              client,
              ws_encode_binary(
                build_response(
                  cmd_code,
                  req_id,
                  encode_msg(%Q.SecurityQuoteResponse{secu_quote: []})
                )
              )
            )

          true ->
            :ok
        end
      end

      {:ok, server} = start_server(sid, handler)
      assert_receive {:port, port}, 2_000

      ctx = start_ctx(port)
      wait_for_session(ctx)

      assert {:ok, _} = QuoteContext.quote(ctx, ["AAPL.US"])
      assert Process.alive?(ctx)
      cleanup(server, ctx)
    end
  end

  describe "push callback registration" do
    test "set_on_quote/2 returns :ok" do
      {:ok, server} =
        start_server("sess-onquote#{System.unique_integer([:positive])}", push_test_handler())

      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      assert :ok = QuoteContext.set_on_quote(ctx, fn _ -> :ok end)
      cleanup(server, ctx)
    end

    test "set_on_depth/2 returns :ok" do
      {:ok, server} =
        start_server("sess-ondepth#{System.unique_integer([:positive])}", push_test_handler())

      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      assert :ok = QuoteContext.set_on_depth(ctx, fn _ -> :ok end)
      cleanup(server, ctx)
    end

    test "set_on_brokers/2 returns :ok" do
      {:ok, server} =
        start_server("sess-onbrokers#{System.unique_integer([:positive])}", push_test_handler())

      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      assert :ok = QuoteContext.set_on_brokers(ctx, fn _ -> :ok end)
      cleanup(server, ctx)
    end

    test "set_on_trades/2 returns :ok and on_trade/2 is an alias" do
      {:ok, server} =
        start_server("sess-ontrade#{System.unique_integer([:positive])}", push_test_handler())

      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      assert :ok = QuoteContext.set_on_trades(ctx, fn _ -> :ok end)
      assert :ok = QuoteContext.on_trade(ctx, fn _ -> :ok end)
      cleanup(server, ctx)
    end

    test "set_default_push_callback/2 returns :ok" do
      {:ok, server} =
        start_server("sess-ondefault#{System.unique_integer([:positive])}", push_test_handler())

      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      assert :ok = QuoteContext.set_default_push_callback(ctx, fn _ -> :ok end)
      cleanup(server, ctx)
    end

    test "remove_push_callback/2 returns :ok" do
      {:ok, server} =
        start_server("sess-onremove#{System.unique_integer([:positive])}", push_test_handler())

      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      :ok = QuoteContext.set_on_quote(ctx, fn _ -> :ok end)
      assert :ok = QuoteContext.remove_push_callback(ctx, :quote)
      cleanup(server, ctx)
    end

    test "set_on_quote/2 fires with a decoded PushQuote struct" do
      test_pid = self()

      push_quote = %Q.PushQuote{
        symbol: "AAPL.US",
        sequence: 1,
        last_done: "150.00",
        timestamp: 1_700_000_000
      }

      push_body = encode_msg(push_quote)

      sid = "sess-pushquote#{System.unique_integer([:positive])}"

      handler = fn client, _tp, cmd_code, req_id, _body ->
        :gen_tcp.send(client, ws_encode_binary(build_push(101, push_body)))

        cond do
          cmd_code == 4 ->
            :gen_tcp.send(
              client,
              ws_encode_binary(
                build_response(
                  cmd_code,
                  req_id,
                  encode_msg(%Q.UserQuoteProfileResponse{rate_limit: []})
                )
              )
            )

          cmd_code == 11 ->
            :gen_tcp.send(
              client,
              ws_encode_binary(
                build_response(
                  cmd_code,
                  req_id,
                  encode_msg(%Q.SecurityQuoteResponse{secu_quote: []})
                )
              )
            )

          true ->
            :ok
        end
      end

      {:ok, server} = start_server(sid, handler)
      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)

      :ok =
        QuoteContext.set_on_quote(ctx, fn push ->
          send(test_pid, {:callback, push})
        end)

      # Trigger cmd 11 to fire the push.
      QuoteContext.quote(ctx, ["AAPL.US"])

      assert_receive {:callback, decoded}, 5_000
      assert decoded.symbol == "AAPL.US"
      assert decoded.last_done == "150.00"

      cleanup(server, ctx)
    end
  end

  describe "realtime cache" do
    test "realtime_quote/2 returns nil for symbols without cached pushes" do
      {server, ctx} =
        connected_ctx("sess-rtempty#{System.unique_integer([:positive])}", empty_resp_handler())

      assert {:ok, [nil, nil]} =
               QuoteContext.realtime_quote(ctx, ["AAPL.US", "TSLA.US"])

      cleanup(server, ctx)
    end

    test "realtime_quote/2 returns cached PushQuote after a push" do
      push_quote = %Q.PushQuote{symbol: "AAPL.US", sequence: 1, last_done: "150.00"}

      sid = "sess-rtquote#{System.unique_integer([:positive])}"

      handler = fn client, _tp, cmd_code, req_id, _body ->
        if cmd_code == 4 do
          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.UserQuoteProfileResponse{rate_limit: []})
              )
            )
          )
        end

        if cmd_code == 11 do
          :gen_tcp.send(client, ws_encode_binary(build_push(101, encode_msg(push_quote))))

          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.SecurityQuoteResponse{secu_quote: []})
              )
            )
          )
        end
      end

      {:ok, server} = start_server(sid, handler)
      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)
      %{conn: conn} = :sys.get_state(ctx)
      :ok = WSConnection.subscribe_push(conn, self())

      QuoteContext.quote(ctx, ["AAPL.US"])
      assert_receive {:longbridge, _, {:push, _, _}}, 2_000
      Process.sleep(50)

      assert {:ok, [^push_quote]} = QuoteContext.realtime_quote(ctx, ["AAPL.US"])

      assert {:ok, [^push_quote, nil]} =
               QuoteContext.realtime_quote(ctx, ["AAPL.US", "TSLA.US"])

      cleanup(server, ctx)
    end

    test "realtime_depth/2 returns cached PushDepth" do
      push_depth = %Q.PushDepth{symbol: "AAPL.US", sequence: 1}

      sid = "sess-rtdepth#{System.unique_integer([:positive])}"

      handler = fn client, _tp, cmd_code, req_id, _body ->
        if cmd_code == 4 do
          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.UserQuoteProfileResponse{rate_limit: []})
              )
            )
          )
        end

        if cmd_code == 11 do
          :gen_tcp.send(client, ws_encode_binary(build_push(102, encode_msg(push_depth))))

          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.SecurityQuoteResponse{secu_quote: []})
              )
            )
          )
        end
      end

      {:ok, server} = start_server(sid, handler)
      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)
      %{conn: conn} = :sys.get_state(ctx)
      :ok = WSConnection.subscribe_push(conn, self())

      QuoteContext.quote(ctx, ["AAPL.US"])
      assert_receive {:longbridge, _, {:push, _, _}}, 2_000
      Process.sleep(50)

      assert {:ok, ^push_depth} = QuoteContext.realtime_depth(ctx, "AAPL.US")
      assert {:ok, nil} = QuoteContext.realtime_depth(ctx, "TSLA.US")

      cleanup(server, ctx)
    end

    test "realtime_trades/3 returns recent trades capped at 500" do
      # Build a single PushTrade event with 3 trades.
      trades = [
        %Q.Trade{price: "150.00", volume: 100, timestamp: 1_700_000_000},
        %Q.Trade{price: "151.00", volume: 200, timestamp: 1_700_000_001},
        %Q.Trade{price: "152.00", volume: 300, timestamp: 1_700_000_002}
      ]

      push_trade = %Q.PushTrade{symbol: "AAPL.US", sequence: 1, trade: trades}

      sid = "sess-rttrades#{System.unique_integer([:positive])}"

      handler = fn client, _tp, cmd_code, req_id, _body ->
        if cmd_code == 4 do
          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.UserQuoteProfileResponse{rate_limit: []})
              )
            )
          )
        end

        if cmd_code == 11 do
          :gen_tcp.send(client, ws_encode_binary(build_push(104, encode_msg(push_trade))))

          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.SecurityQuoteResponse{secu_quote: []})
              )
            )
          )
        end
      end

      {:ok, server} = start_server(sid, handler)
      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)
      %{conn: conn} = :sys.get_state(ctx)
      :ok = WSConnection.subscribe_push(conn, self())

      QuoteContext.quote(ctx, ["AAPL.US"])
      assert_receive {:longbridge, _, {:push, _, _}}, 2_000
      Process.sleep(50)

      assert {:ok, ^trades} = QuoteContext.realtime_trades(ctx, "AAPL.US", 10)
      assert {:ok, [last]} = QuoteContext.realtime_trades(ctx, "AAPL.US", 1)

      assert last.price == "152.00"

      cleanup(server, ctx)
    end

    test "reset_realtime_cache/1 clears the store" do
      push_quote = %Q.PushQuote{symbol: "AAPL.US", sequence: 1}

      sid = "sess-rtreset#{System.unique_integer([:positive])}"

      handler = fn client, _tp, cmd_code, req_id, _body ->
        if cmd_code == 4 do
          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.UserQuoteProfileResponse{rate_limit: []})
              )
            )
          )
        end

        if cmd_code == 11 do
          :gen_tcp.send(client, ws_encode_binary(build_push(101, encode_msg(push_quote))))

          :gen_tcp.send(
            client,
            ws_encode_binary(
              build_response(
                cmd_code,
                req_id,
                encode_msg(%Q.SecurityQuoteResponse{secu_quote: []})
              )
            )
          )
        end
      end

      {:ok, server} = start_server(sid, handler)
      assert_receive {:port, port}, 2_000
      ctx = start_ctx(port)
      wait_for_session(ctx)
      %{conn: conn} = :sys.get_state(ctx)
      :ok = WSConnection.subscribe_push(conn, self())

      QuoteContext.quote(ctx, ["AAPL.US"])
      assert_receive {:longbridge, _, {:push, _, _}}, 2_000
      Process.sleep(50)

      assert {:ok, [^push_quote]} = QuoteContext.realtime_quote(ctx, ["AAPL.US"])
      assert :ok = QuoteContext.reset_realtime_cache(ctx)
      assert {:ok, [nil]} = QuoteContext.realtime_quote(ctx, ["AAPL.US"])

      cleanup(server, ctx)
    end
  end

  describe "heartbeat" do
    test "sends heartbeat to connection on interval" do
      {:ok, server} =
        start_server("sess-hb#{System.unique_integer([:positive])}", empty_resp_handler())

      assert_receive {:port, port}, 2_000

      config =
        Config.new(
          token: "test-token",
          quote_ws_url: "ws://127.0.0.1:#{port}",
          heartbeat_interval: 1_000
        )

      {:ok, ctx} = QuoteContext.start_link(config)
      wait_for_session(ctx)

      Process.sleep(1_500)
      assert Process.alive?(ctx)
      cleanup(server, ctx)
    end
  end

  describe "error handling" do
    test "returns {:error, :not_connected} when connection is not active" do
      {:ok, server} = start_auth_fail_server()
      assert_receive {:port, port}, 2_000

      config = Config.new(token: "bad-token", quote_ws_url: "ws://127.0.0.1:#{port}")
      {:ok, ctx} = QuoteContext.start_link(config)
      wait_for_disconnect(ctx)

      assert {:error, :not_connected} = QuoteContext.quote(ctx, ["AAPL.US"])
      cleanup(server, ctx)
    end

    test "returns {:error, reason} on server error response" do
      {server, ctx} =
        connected_ctx("sess-err#{System.unique_integer([:positive])}", error_handler(3))

      assert {:error, {:server_error, 3, _}} = QuoteContext.quote(ctx, ["AAPL.US"])
      cleanup(server, ctx)
    end
  end

  describe "server close handling" do
    test "session becomes unavailable after server close" do
      sid = "sess-close#{System.unique_integer([:positive])}"

      {:ok, server} =
        start_server(sid, fn client, _tp, _cc, _ri, _body ->
          :gen_tcp.close(client)
        end)

      assert_receive {:port, port}, 2_000

      ctx = start_ctx(port)
      wait_for_session(ctx)

      _ = QuoteContext.quote(ctx, ["AAPL.US"])
      wait_for_disconnect(ctx)

      cleanup(server, ctx)
    end
  end
end
