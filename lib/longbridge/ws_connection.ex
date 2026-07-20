defmodule Longbridge.WSConnection do
  @moduledoc """
  WebSocket connection process for the Longbridge protocol.

  Manages a WebSocket connection to a Longbridge endpoint,
  handling handshake, auth, heartbeat, request/response pairing, and push dispatch.

  Wire-format details:
    * Each protocol packet is wrapped as a 32-bit-big-endian length
      prefix plus payload and sent as a single WebSocket binary message.
    * A single WebSocket binary message may contain multiple
      length-prefixed packets concatenated together; this module
      splits them on receive.

  ## Handshake

  WebSocket handshake is sent via URL query parameters
  (`?version=1&codec=1&platform=9`) per the Longbridge spec, rather
  than the 2-byte binary handshake used by TCP connections.
  """

  use GenServer
  require Logger

  alias Longbridge.Connection.Session
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol
  alias Longbridge.Protocol.Header
  alias Longbridge.WSConnection.RateLimit
  alias Mint.HTTP
  alias Mint.WebSocket
  import Mint.HTTP, only: [put_private: 3]

  @handshake_timeout 5_000
  @auth_timeout 10_000

  # ── Client API (internal, used by contexts) ──────────────

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  @spec request(pid(), non_neg_integer(), binary(), non_neg_integer()) ::
          {:ok, binary(), non_neg_integer()} | {:error, term()}
  def request(pid, cmd_code, body, timeout \\ 10_000) do
    GenServer.call(pid, {:request, cmd_code, body, timeout}, timeout + 5_000)
  end

  @doc false
  @spec subscribe_push(pid(), pid()) :: :ok
  def subscribe_push(pid, subscriber) do
    GenServer.call(pid, {:subscribe_push, subscriber})
  end

  @doc false
  @spec apply_rate_limits(pid(), [map()]) :: :ok
  def apply_rate_limits(pid, entries) when is_list(entries) do
    GenServer.call(pid, {:apply_rate_limits, entries})
  end

  @doc false
  @spec get_session(pid()) :: {:ok, String.t(), integer()} | {:error, term()}
  def get_session(pid) do
    GenServer.call(pid, :get_session)
  end

  @doc false
  @spec connected?(pid()) :: boolean()
  def connected?(pid) do
    GenServer.call(pid, :is_connected)
  end

  @doc false
  @spec reconnect_now(pid()) :: :ok
  def reconnect_now(pid) do
    GenServer.cast(pid, :reconnect_now)
  end

  # ── GenServer Callbacks ──────────────────────────────────

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    type = Keyword.fetch!(opts, :type)
    parent = Keyword.fetch!(opts, :parent)

    RateLimit.init()

    state = %{
      config: config,
      socket_token: nil,
      type: type,
      ws_url: ws_url_for(config, type),
      ws_host: nil,
      mint_conn: nil,
      websocket: nil,
      request_ref: nil,
      session_id: nil,
      expires: nil,
      request_id: 0,
      pending: %{},
      subscribers: MapSet.new([parent]),
      buffer: <<>>,
      connection_state: :disconnected,
      reconnect_attempts: 0,
      reconnect_timer: nil,
      idle_timer: nil,
      refresh_token_fn:
        Keyword.get(opts, :refresh_token_fn, fn config ->
          Longbridge.Config.refresh_access_token(config, [])
        end)
    }

    case do_connect_and_auth(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason, state} ->
        Logger.warning("[Longbridge.#{state.type}] Auth failed: #{inspect(reason)}")
        state = cleanup_socket(state)
        state = %{state | connection_state: :disconnected, session_id: nil, buffer: <<>>}
        broadcast(state, {:disconnected, reason})
        {:ok, maybe_reconnect(state, reason)}
    end
  end

  # Shared by init and handle_info(:reconnect, ...).
  # Connects, upgrades, and authenticates in a single blocking flow.
  # Returns {:ok, state} on success, or {:error, reason, state} on failure.
  defp do_connect_and_auth(state) do
    case fetch_socket_token(state) do
      {:ok, state} ->
        do_connect_and_auth_after_token(state)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp fetch_socket_token(state) do
    case Longbridge.Config.with_socket_token(state.config) do
      {:ok, new_config} ->
        # Store the OTP separately; keep config.token as the original JWT
        # so reconnects can fetch a fresh OTP.
        {:ok, %{state | socket_token: new_config.token}}

      {:error, reason} ->
        Logger.warning(
          "[Longbridge.#{state.type}] Failed to fetch socket OTP: #{inspect(reason)}"
        )

        {:error, {:otp_fetch_failed, reason}}
    end
  end

  defp do_connect_and_auth_after_token(state) do
    case do_connect(state) do
      {:ok, state} ->
        case Session.do_auth_with_retry(%{state | connection_state: :authenticating}, &do_auth/1) do
          {:ok, state} ->
            state = %{state | connection_state: :active, reconnect_attempts: 0}
            state = schedule_idle_timer(state)
            state = activate_socket(state)
            Logger.info("[Longbridge.#{state.type}] Authenticated, session: #{state.session_id}")
            broadcast(state, {:connected, state.session_id})
            {:ok, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        Logger.error("[Longbridge.#{state.type}] WS connect failed: #{inspect(reason)}")
        state = schedule_reconnect(state, reason)
        {:error, reason, state}
    end
  end

  @impl true
  def handle_call({:request, cmd_code, body, timeout}, from, state) do
    if state.connection_state == :active do
      # Per-command-code leaky-bucket throttle. Returns 0 when the
      # bucket has a token; otherwise the milliseconds the caller
      # must wait. The bucket is decremented before the sleep so a
      # queued caller can't race past an empty bucket.
      case RateLimit.wait_ms(cmd_code) do
        :infinity ->
          :ok

        0 ->
          :ok

        ms when is_integer(ms) and ms > 0 ->
          Process.sleep(ms)
      end

      req_id = next_request_id(state)
      {packed_body, gzipped} = maybe_gzip(body, state.config.gzip_threshold)

      header = %Header{
        type: :request,
        verify: false,
        gzip: gzipped,
        body_length: 0,
        cmd_code: cmd_code,
        request_id: req_id,
        timeout: timeout
      }

      ref = Process.send_after(self(), {:request_timeout, req_id}, timeout)
      raw_packet = IO.iodata_to_binary(Protocol.pack(header, packed_body))

      case send_frame(state, raw_packet) do
        {:ok, state} ->
          {:noreply,
           %{
             state
             | pending: Map.put(state.pending, req_id, %{from: from, ref: ref}),
               request_id: req_id
           }}

        {:error, reason} ->
          _ = Process.cancel_timer(ref)
          {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call({:subscribe_push, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: MapSet.put(state.subscribers, pid)}}
  end

  @impl true
  def handle_call(:get_session, _from, state) do
    {:reply, {:ok, state.session_id, state.expires}, state}
  end

  @impl true
  def handle_call(:is_connected, _from, state) do
    {:reply, state.connection_state == :active, state}
  end

  @impl true
  def handle_call({:apply_rate_limits, entries}, _from, state) do
    RateLimit.set_limits(entries)
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(:reconnect_now, state) do
    if state.connection_state == :active do
      {:noreply, state}
    else
      _ =
        if state.reconnect_timer do
          Process.cancel_timer(state.reconnect_timer)
        end

      Logger.info("[Longbridge.#{state.type}] Immediate reconnect requested")
      send(self(), :reconnect)
      {:noreply, %{state | reconnect_timer: nil}}
    end
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    Logger.warning("[Longbridge.#{state.type}] Connection idle timeout")
    {:noreply, do_disconnect(state, :idle_timeout)}
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}

    case do_connect_and_auth(state) do
      {:ok, state} ->
        {:noreply, state}

      {:error, reason, state} ->
        Logger.warning("[Longbridge.#{state.type}] Reconnect auth failed: #{inspect(reason)}")

        state =
          state
          |> cleanup_socket()
          |> then(&%{&1 | connection_state: :disconnected, session_id: nil, buffer: <<>>})

        broadcast(state, {:disconnected, reason})
        state = maybe_reconnect(state, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:request_timeout, req_id}, state) do
    case Map.pop(state.pending, req_id) do
      {nil, state} ->
        {:noreply, state}

      {%{from: from}, state} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Driven by the owning context's heartbeat timer (QuoteContext /
    # TradeContext schedule :heartbeat and forward it here). We only send
    # the WS ping; we do NOT reschedule — the context owns the cadence so
    # the connection isn't pinged at 2x the configured rate.
    state =
      if state.connection_state == :active do
        send_heartbeat(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    # A stale :tcp/:ssl message can arrive after cleanup_socket has
    # nilled mint_conn (e.g. in-flight socket data delivered during a
    # reconnect). Streaming into a nil connection crashes, so drop it.
    if state.mint_conn == nil do
      {:noreply, state}
    else
      case WebSocket.stream(state.mint_conn, message) do
        {:ok, mint_conn, responses} ->
          state =
            state
            |> Map.put(:mint_conn, mint_conn)
            |> activate_socket()
            |> handle_responses(responses)

          {:noreply, state}

        {:error, mint_conn, reason, _responses} ->
          state = Map.put(state, :mint_conn, mint_conn)
          handle_disconnect(state, {:mint_error, reason})

        :unknown ->
          {:noreply, state}
      end
    end
  end

  @impl true
  def terminate(_reason, state) do
    _ = if Map.has_key?(state, :idle_timer), do: cancel_idle_timer(state)
    _ = if Map.has_key?(state, :reconnect_timer), do: cancel_reconnect_timer(state)
    _ = if Map.get(state, :mint_conn), do: cleanup_socket(state)
    :ok
  end

  defdelegate cancel_reconnect_timer(state), to: Session

  # ── WebSocket I/O ────────────────────────────────────────

  defp do_connect(%{ws_url: nil} = _state) do
    {:error, :no_ws_url}
  end

  defp do_connect(state) do
    {scheme, host, port} = parse_ws_url(state.ws_url)
    http_scheme = if scheme == :wss, do: :https, else: :http

    case HTTP.connect(http_scheme, host, port, mode: :passive, protocols: [:http1]) do
      {:ok, mint_conn} ->
        do_ws_upgrade(
          %{state | mint_conn: mint_conn, ws_host: host},
          scheme
        )

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  # Bypass mint_web_socket upgrade and do the WebSocket upgrade manually.
  # Longbridge uses URL query params for handshake per:
  # https://open.longbridge.com/docs/socket/protocol/handshake
  defp do_ws_upgrade(state, scheme) do
    ws_key = Base.encode64(:crypto.strong_rand_bytes(16))
    path = "/?version=1&codec=1&platform=9"

    headers =
      [
        {"host", state.ws_host},
        {"upgrade", "websocket"},
        {"connection", "upgrade"},
        {"sec-websocket-key", ws_key},
        {"sec-websocket-version", "13"}
      ] ++ (state.config.headers || [])

    # Store the nonce in Mint's private data so WebSocket.new can validate it.
    mint_conn =
      state.mint_conn
      |> put_private(:sec_websocket_key, ws_key)
      |> put_private(:extensions, [])
      |> put_private(:scheme, scheme)

    case HTTP.request(mint_conn, "GET", path, headers, nil) do
      {:ok, mint_conn, ref} ->
        finish_upgrade(%{state | mint_conn: mint_conn, request_ref: ref})

      {:error, mint_conn, reason} ->
        _ = HTTP.close(mint_conn)
        {:error, {:upgrade_request, reason}}
    end
  end

  defp finish_upgrade(state) do
    # Passive mode: read raw data from the SSL socket, then stream it
    # through Mint to get the HTTP upgrade response.
    socket = HTTP.get_socket(state.mint_conn)

    case socket_recv(socket, 0, @handshake_timeout) do
      {:ok, data} ->
        case HTTP.stream(state.mint_conn, socket_msg(socket, data)) do
          {:ok, mint_conn, responses} ->
            state = %{state | mint_conn: mint_conn}
            process_upgrade_response(state, responses)

          {:error, mint_conn, reason, _responses} ->
            _ = HTTP.close(mint_conn)
            {:error, {:upgrade_stream, reason}}

          :unknown ->
            {:error, {:upgrade, :unknown_response}}
        end

      {:error, reason} ->
        _ = HTTP.close(state.mint_conn)
        {:error, {:ssl_recv, reason}}
    end
  end

  defp process_upgrade_response(state, responses) do
    {status, headers} =
      Enum.reduce(responses, {nil, []}, fn
        {:status, _ref, s}, {_, h} -> {s, h}
        {:headers, _ref, h}, {s, _} -> {s, h}
        _other, acc -> acc
      end)

    Logger.debug(
      "[Longbridge.#{state.type}] WS upgrade response: status=#{inspect(status)}, headers=#{inspect(headers)}"
    )

    if status == 101 do
      case WebSocket.new(state.mint_conn, state.request_ref, status, headers, mode: :passive) do
        {:ok, mint_conn, websocket} ->
          {:ok, %{state | mint_conn: mint_conn, websocket: websocket}}

        {:error, mint_conn, reason} ->
          Logger.warning("[Longbridge.#{state.type}] WS new failed: #{inspect(reason)}")
          _ = HTTP.close(mint_conn)
          {:error, {:upgrade, reason}}
      end
    else
      {:error, {:upgrade, {:bad_status, status}}}
    end
  end

  # Compresses the request body when it meets `gzip_threshold`, mirroring
  # the server's behaviour so large requests (e.g. option-chain lists)
  # don't burn bandwidth.
  @spec maybe_gzip(binary(), non_neg_integer() | nil) :: {binary(), boolean()}
  defp maybe_gzip(body, threshold)
       when is_binary(body) and is_integer(threshold) and threshold > 0 do
    if byte_size(body) >= threshold do
      {:zlib.gzip(body), true}
    else
      {body, false}
    end
  end

  defp maybe_gzip(body, _threshold), do: {body, false}

  defp send_frame(state, payload) when is_binary(payload) do
    case WebSocket.encode(state.websocket, {:binary, payload}) do
      {:ok, websocket, data} ->
        case WebSocket.stream_request_body(state.mint_conn, state.request_ref, data) do
          {:ok, mint_conn} ->
            {:ok, %{state | websocket: websocket, mint_conn: mint_conn}}

          {:error, _mint_conn, reason} ->
            {:error, reason}
        end

      {:error, _websocket, reason} ->
        {:error, reason}
    end
  end

  # ── Mint message / response handling ─────────────────────

  defp handle_responses(state, responses, status \\ nil)

  defp handle_responses(%{request_ref: ref} = state, [{:status, ref, status} | rest], _old) do
    handle_responses(state, rest, status)
  end

  defp handle_responses(
         %{request_ref: ref} = state,
         [{:headers, ref, _resp_headers} | rest],
         status
       ) do
    handle_responses(state, rest, status)
  end

  defp handle_responses(%{request_ref: ref} = state, [{:done, ref} | rest], status) do
    case WebSocket.new(state.mint_conn, ref, status, [], mode: :passive) do
      {:ok, mint_conn, websocket} ->
        handle_responses(
          %{state | mint_conn: mint_conn, websocket: websocket},
          rest,
          nil
        )

      {:error, mint_conn, reason} ->
        state = Map.put(state, :mint_conn, mint_conn)
        do_disconnect(state, {:upgrade, reason})
    end
  end

  defp handle_responses(
         %{request_ref: ref, websocket: ws} = state,
         [{:data, ref, data} | rest],
         nil
       )
       when ws != nil do
    case WebSocket.decode(ws, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        state = handle_frames(state, frames)
        handle_responses(state, rest, nil)

      {:error, websocket, reason} ->
        state = %{state | websocket: websocket}
        do_disconnect(state, {:decode, reason})
    end
  end

  defp handle_responses(state, [_response | rest], status) do
    handle_responses(state, rest, status)
  end

  defp handle_responses(state, [], _status), do: state

  defp handle_frames(state, frames) do
    Enum.reduce(frames, state, fn
      {:ping, data}, state ->
        # WebSocket native ping/pong for keepalive.
        case WebSocket.encode(state.websocket, {:pong, data}) do
          {:ok, websocket, pong_data} ->
            case WebSocket.stream_request_body(state.mint_conn, state.request_ref, pong_data) do
              {:ok, mint_conn} -> %{state | websocket: websocket, mint_conn: mint_conn}
              {:error, _mint_conn, _reason} -> state
            end

          {:error, _websocket, _reason} ->
            state
        end

      {:pong, _data}, state ->
        # A pong reply means the connection is alive even if no
        # business data arrived — reset the idle timer so a quiet
        # market (e.g. overnight, weekend) doesn't trigger a
        # spurious idle_timeout disconnect.
        schedule_idle_timer(state)

      {:close, _code, _reason}, state ->
        do_disconnect(state, :peer_closed)

      {:binary, data}, state ->
        state = process_binary_frame(state, data)
        schedule_idle_timer(state)

      {:text, _text}, state ->
        state
    end)
  end

  defp process_binary_frame(state, data) do
    process_data(%{state | buffer: <<>>}, state.buffer <> data)
  end

  # ── WS wire format ───────────────────────────────────────

  # WebSocket binary messages contain raw protocol packets.
  # WS frame boundaries provide the framing (no 4-byte length prefix).

  # ── Wire format ──────────────────────────────────────────

  defp do_auth(state) do
    token = state.socket_token || state.config.token

    if token do
      {data, req_id} = build_auth_request(state, token)
      # Send the raw protocol packet as a WS binary message.
      # The 4-byte length prefix wrapping is handled by WebSocket.encode.
      raw_packet = IO.iodata_to_binary(data)

      Logger.debug(
        "[Longbridge.#{state.type}] Sending auth request (#{byte_size(raw_packet)} bytes)"
      )

      case send_frame(state, raw_packet) do
        {:ok, state} ->
          state = %{state | request_id: req_id}
          Logger.debug("[Longbridge.#{state.type}] Auth request sent, waiting for response...")
          wait_for_auth_response(state)

        {:error, reason} ->
          Logger.warning("[Longbridge.#{state.type}] send_frame failed: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :no_token}
    end
  end

  defp wait_for_auth_response(state) do
    # Passive mode: read raw data from the SSL socket and stream through
    # Mint to get WebSocket frames until we find the auth response.
    socket = HTTP.get_socket(state.mint_conn)

    case socket_recv(socket, 0, @auth_timeout) do
      {:ok, data} ->
        Logger.debug(
          "[Longbridge.#{state.type}] Received #{byte_size(data)} bytes after auth, hex: #{Base.encode16(data)}"
        )

        case WebSocket.stream(state.mint_conn, socket_msg(socket, data)) do
          {:ok, mint_conn, responses} ->
            Logger.debug("[Longbridge.#{state.type}] Stream responses: #{inspect(responses)}")
            state = %{state | mint_conn: mint_conn}
            extract_auth_from_responses(state, responses)

          {:error, mint_conn, reason, _responses} ->
            _ = HTTP.close(mint_conn)
            {:error, {:stream_error, reason}}

          :unknown ->
            {:error, :unknown_message}
        end

      {:error, :closed} ->
        {:error, {:tcp_closed, :during_auth}}

      {:error, reason} ->
        {:error, {:ssl_recv, reason}}
    end
  end

  defp extract_auth_from_responses(state, [{:data, _ref, data} | _rest]) do
    ws = state.websocket

    case WebSocket.decode(ws, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}

        case frames do
          [{:binary, frame_data} | _] ->
            parse_auth_frame(state, frame_data)

          _other ->
            wait_for_auth_response(state)
        end

      {:error, _websocket, reason} ->
        {:error, {:decode, reason}}
    end
  end

  defp extract_auth_from_responses(state, [{:status, _ref, _status} | rest]) do
    extract_auth_from_responses(state, rest)
  end

  defp extract_auth_from_responses(state, [{:headers, _ref, _headers} | rest]) do
    extract_auth_from_responses(state, rest)
  end

  defp extract_auth_from_responses(state, [{:done, _ref} | rest]) do
    extract_auth_from_responses(state, rest)
  end

  defp extract_auth_from_responses(state, [_other | rest]) do
    extract_auth_from_responses(state, rest)
  end

  defp extract_auth_from_responses(state, []) do
    wait_for_auth_response(state)
  end

  defp parse_auth_frame(state, frame_data) do
    # WebSocket binary messages contain the raw protocol packet directly
    # (no 4-byte length prefix — WS frame boundaries provide framing).
    case Protocol.unpack(frame_data) do
      {:ok, header, body, _rest} ->
        if header.cmd_code == Protocol.cmd_auth() and header.status_code == 0 do
          decode_auth_body(state, body)
        else
          {:error, {:auth_failed, header.status_code}}
        end

      {:error, reason} ->
        {:error, {:unpack, reason}}
    end
  end

  defp decode_auth_body(state, body) do
    auth_resp = Protox.decode!(body, Ctrl.AuthResponse)
    state = %{state | session_id: auth_resp.session_id, expires: auth_resp.expires}
    {:ok, state}
  rescue
    exception in [Protox.DecodingError] ->
      Logger.warning(
        "[Longbridge.#{state.type}] Auth response decode failed: #{Exception.message(exception)}"
      )

      {:error, {:auth_decode_failed, exception}}
  end

  defp build_auth_request(state, token) do
    auth_body = %Ctrl.AuthRequest{token: token, metadata: %{}}
    {:ok, iodata, _size} = Protox.encode(auth_body)
    encoded = IO.iodata_to_binary(iodata)
    {packed_body, gzipped} = maybe_gzip(encoded, state.config.gzip_threshold)
    req_id = next_request_id(state)

    header = %Header{
      type: :request,
      verify: false,
      gzip: gzipped,
      body_length: 0,
      cmd_code: Protocol.cmd_auth(),
      request_id: req_id,
      timeout: @auth_timeout
    }

    {Protocol.pack(header, packed_body), req_id}
  end

  defp send_heartbeat(state) do
    # WebSocket uses native ping/pong for keepalive per Longbridge spec:
    # https://open.longbridge.com/docs/socket/diff_ws_tcp
    case WebSocket.encode(state.websocket, :ping) do
      {:ok, websocket, data} ->
        case WebSocket.stream_request_body(state.mint_conn, state.request_ref, data) do
          {:ok, mint_conn} ->
            %{state | websocket: websocket, mint_conn: mint_conn}

          {:error, _mint_conn, _reason} ->
            state
        end

      {:error, _websocket, _reason} ->
        state
    end
  end

  # ── Packet Processing ────────────────────────────────────

  defp process_data(state, data) when byte_size(data) == 0, do: state

  defp process_data(state, data) do
    case Protocol.unpack(data) do
      {:ok, header, body, rest} ->
        state = dispatch_packet(state, header, body)
        process_data(state, rest)

      {:error, :incomplete_header} ->
        %{state | buffer: state.buffer <> data}

      {:error, :incomplete_body} ->
        # Header parsed but the body straddles a WS frame boundary.
        # Re-buffer the remainder so the next frame completes it;
        # re-parsing the header on resume is idempotent.
        %{state | buffer: state.buffer <> data}

      {:error, _reason} ->
        state
    end
  end

  defp dispatch_packet(state, %Header{type: :response} = header, body) do
    Session.dispatch_response(state, header, body)
  end

  defp dispatch_packet(state, %Header{type: :push} = header, body) do
    Session.dispatch_push(state, header, body)
  end

  defp dispatch_packet(state, %Header{type: :request} = header, body) do
    if Protocol.heartbeat?(header.cmd_code) do
      broadcast(state, {:heartbeat, body})
    end

    state
  end

  # ── Socket management ────────────────────────────────────

  defp activate_socket(%{mint_conn: nil} = state), do: state

  defp activate_socket(state) do
    socket = HTTP.get_socket(state.mint_conn)
    _ = socket && socket_set_active_once(socket)
    state
  end

  defp socket_recv(socket, len, timeout)
       when is_tuple(socket),
       do: :ssl.recv(socket, len, timeout)

  defp socket_recv(socket, len, timeout)
       when is_port(socket),
       do: :gen_tcp.recv(socket, len, timeout)

  defp socket_set_active_once(socket) when is_tuple(socket),
    do: :ssl.setopts(socket, active: :once)

  defp socket_set_active_once(socket) when is_port(socket),
    do: :inet.setopts(socket, active: :once)

  defp socket_msg(socket, data) when is_tuple(socket), do: {:ssl, socket, data}
  defp socket_msg(socket, data) when is_port(socket), do: {:tcp, socket, data}

  # ── Connection Lifecycle ─────────────────────────────────

  defp handle_disconnect(state, reason) do
    state = do_disconnect(state, reason)
    {:noreply, state}
  end

  defp do_disconnect(state, reason) do
    cleaned =
      state
      |> cleanup_socket()
      |> then(fn s ->
        _ = fail_pending_requests(s, reason)
        s
      end)
      |> cancel_idle_timer()
      |> Map.merge(%{
        connection_state: :disconnected,
        session_id: nil,
        buffer: <<>>
      })

    broadcast(cleaned, {:disconnected, reason})
    schedule_reconnect(cleaned, reason)
  end

  defp cleanup_socket(state) do
    if state.mint_conn do
      _ = HTTP.close(state.mint_conn)
      :ok
    end

    %{state | mint_conn: nil, websocket: nil, request_ref: nil}
  end

  defdelegate fail_pending_requests(state, reason), to: Session
  defdelegate schedule_reconnect(state, reason), to: Session
  defdelegate schedule_idle_timer(state), to: Session

  defp maybe_reconnect(state, reason) do
    if Session.fatal_error?(reason) do
      Logger.error("[Longbridge.#{state.type}] Fatal auth error, giving up: #{inspect(reason)}")
      broadcast(state, :reconnect_exhausted)
      state
    else
      schedule_reconnect(state, reason)
    end
  end

  defdelegate cancel_idle_timer(state), to: Session

  defdelegate broadcast(state, message), to: Session

  # ── Misc ─────────────────────────────────────────────────

  defdelegate next_request_id(state), to: Session

  defp ws_url_for(config, :quote), do: config.quote_ws_url
  defp ws_url_for(config, :trade), do: config.trade_ws_url

  defp parse_ws_url(url) when is_binary(url) do
    uri = URI.parse(url)
    scheme = ws_scheme(uri.scheme)
    port = uri.port || ws_default_port(scheme)
    {scheme, uri.host || "localhost", port}
  end

  defp ws_scheme("wss"), do: :wss
  defp ws_scheme("ws"), do: :ws
  defp ws_scheme("https"), do: :wss
  defp ws_scheme("http"), do: :ws
  defp ws_scheme(_), do: :wss

  defp ws_default_port(:wss), do: 443
  defp ws_default_port(_), do: 80
end
