defmodule Longbridge.WSConnection do
  @moduledoc """
  WebSocket connection process for the Longbridge protocol.

  Mirrors `Longbridge.Connection` but transports the same binary
  protocol frames over a WebSocket connection (used when `:transport`
  is set to `:websocket` in the config).

  Wire-format details:
    * Each protocol packet is wrapped as a 32-bit-big-endian length
      prefix plus payload and sent as a single WebSocket binary message.
    * A single WebSocket binary message may contain multiple
      length-prefixed packets concatenated together; this module
      splits them on receive.

  All other behaviour — handshake, auth with retry, request/response
  pairing, push dispatch, heartbeat, idle timeout, reconnection with
  exponential backoff — is identical to `Longbridge.Connection`.
  """

  use GenServer
  require Logger

  alias Longbridge.Connection.Session
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol
  alias Longbridge.Protocol.Header
  alias Mint.HTTP
  alias Mint.WebSocket

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
  @spec get_session(pid()) :: {:ok, String.t(), integer()} | {:error, term()}
  def get_session(pid) do
    GenServer.call(pid, :get_session)
  end

  # ── GenServer Callbacks ──────────────────────────────────

  @impl true
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    type = Keyword.fetch!(opts, :type)
    parent = Keyword.fetch!(opts, :parent)

    {ws_url, _ws_path} =
      case type do
        :quote -> {config.quote_ws_url, "/v2"}
        :trade -> {config.trade_ws_url, "/v2"}
      end

    state = %{
      config: config,
      type: type,
      ws_url: ws_url,
      socket: nil,
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

    case do_connect(state) do
      {:ok, state} ->
        state = %{state | connection_state: :handshaking}
        {:ok, state, {:continue, :handshake}}

      {:error, reason} ->
        _ = schedule_reconnect(state, reason)
        {:ok, state}
    end
  end

  @impl true
  def handle_continue(:handshake, state) do
    case do_handshake(state) do
      {:ok, state} ->
        state = %{state | connection_state: :authenticating}
        {:noreply, state, {:continue, :auth}}

      {:error, reason} ->
        Logger.warning("[Longbridge.#{state.type}] Handshake failed: #{inspect(reason)}")
        state = handle_connection_failure(state, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_continue(:auth, state) do
    case Session.do_auth_with_retry(state, &do_auth/1) do
      {:ok, state} ->
        state = %{state | connection_state: :active, reconnect_attempts: 0}
        state = schedule_idle_timer(state)
        Logger.info("[Longbridge.#{state.type}] Authenticated, session: #{state.session_id}")
        broadcast(state, {:connected, state.session_id})
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("[Longbridge.#{state.type}] Auth failed: #{inspect(reason)}")
        state = handle_connection_failure(state, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:request, cmd_code, body, timeout}, from, state) do
    if state.connection_state == :active do
      req_id = next_request_id(state)

      header = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: byte_size(body),
        cmd_code: cmd_code,
        request_id: req_id,
        timeout: timeout
      }

      ref = Process.send_after(self(), {:request_timeout, req_id}, timeout)
      packet = Protocol.pack(header, body)
      encoded = encode_frame(IO.iodata_to_binary(packet))

      case send_frame(state, encoded) do
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
  def handle_info(:idle_timeout, state) do
    Logger.warning("[Longbridge.#{state.type}] Connection idle timeout")

    do_disconnect(state, :idle_timeout)
  end

  @impl true
  def handle_info(:reconnect, state) do
    state = %{state | reconnect_timer: nil}

    case do_connect(state) do
      {:ok, state} ->
        state = %{state | connection_state: :handshaking}
        {:noreply, state, {:continue, :handshake}}

      {:error, reason} ->
        _ = schedule_reconnect(state, reason)
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
    if state.connection_state == :active do
      _ = send_heartbeat(state)
    end

    Process.send_after(self(), :heartbeat, state.config.heartbeat_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(message, state) do
    case WebSocket.stream(state.mint_conn, message) do
      {:ok, mint_conn, responses} ->
        state = state |> Map.put(:mint_conn, mint_conn) |> handle_responses(responses)
        {:noreply, state}

      {:error, mint_conn, reason, _responses} ->
        state = Map.put(state, :mint_conn, mint_conn)
        handle_disconnect(state, {:mint_error, reason})

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    state = cancel_idle_timer(state)

    cancel_reconnect_timer(state)
    _ = cleanup_socket(state)
    :ok
  end

  defdelegate cancel_reconnect_timer(state), to: Session

  # ── WebSocket I/O ────────────────────────────────────────

  defp do_connect(%{ws_url: nil} = _state) do
    {:error, :no_ws_url}
  end

  defp do_connect(state) do
    {scheme, host, port, path} = parse_ws_url(state.ws_url, "/v2")
    http_scheme = if scheme == :wss, do: :https, else: :http

    case HTTP.connect(http_scheme, host, port, mode: :passive) do
      {:ok, mint_conn} ->
        case WebSocket.upgrade(scheme, mint_conn, path, []) do
          {:ok, mint_conn, ref} ->
            state = %{state | mint_conn: mint_conn, request_ref: ref}
            finish_upgrade(state)

          {:error, _mint_conn, reason} ->
            {:error, {:upgrade, reason}}
        end

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  defp finish_upgrade(state) do
    ref = state.request_ref

    case WebSocket.recv(state.mint_conn, 0, @handshake_timeout) do
      {:ok, mint_conn, responses} ->
        state = Map.put(state, :mint_conn, mint_conn)

        case responses do
          [{:status, ^ref, status} | _rest] ->
            state = handle_responses(state, responses, status)

            case state.connection_state do
              :upgrading -> finish_upgrade(state)
              _ -> {:ok, %{state | connection_state: :upgrading}}
            end

          _other_responses ->
            finish_upgrade(state)
        end
    end
  end

  defp do_handshake(state) do
    # Send the same 2-byte handshake as TCP — embedded in a WS binary frame.
    handshake = Protocol.handshake()
    encoded = encode_frame(IO.iodata_to_binary(handshake))

    case send_frame(state, encoded) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp handle_responses(state, responses, status \\ nil)

  defp handle_responses(%{request_ref: ref} = state, [{:status, ref, status} | rest], _old) do
    handle_responses(%{state | connection_state: :upgrading}, rest, status)
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
          %{state | mint_conn: mint_conn, websocket: websocket, connection_state: :handshaking},
          rest,
          nil
        )

      {:error, mint_conn, reason} ->
        state = Map.put(state, :mint_conn, mint_conn)
        handle_disconnect(state, {:upgrade, reason})
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
        handle_disconnect(state, {:decode, reason})
    end
  end

  defp handle_responses(state, [_response | rest], status) do
    handle_responses(state, rest, status)
  end

  defp handle_responses(state, [], _status), do: state

  defp handle_frames(state, frames) do
    Enum.reduce(frames, state, fn
      {:ping, data}, state ->
        case send_frame(state, encode_frame(data)) do
          {:ok, state} -> state
          {:error, _} -> state
        end

      {:pong, _data}, state ->
        state

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
    # Each WS binary message is one or more length-prefixed protocol packets.
    (state.buffer <> data)
    |> decode_frames()
    |> Enum.reduce(state, fn packet, state ->
      case Protocol.unpack(packet) do
        {:ok, header, body, _rest} ->
          dispatch_packet(state, header, body)

        {:error, :incomplete_header} ->
          # Should not happen — frames are sized. Treat as protocol error.
          Logger.warning("[Longbridge.#{state.type}] Incomplete header in WS frame")
          state

        {:error, reason} ->
          Logger.warning("[Longbridge.#{state.type}] Bad frame: #{inspect(reason)}")
          state
      end
    end)
  end

  # Length-prefix codec: <<length::32-big, payload::binary>>
  defp encode_frame(payload) when is_binary(payload) do
    <<byte_size(payload)::32-big, payload::binary>>
  end

  defp decode_frames(data), do: do_decode_frames(data, [])

  defp do_decode_frames(<<>>, acc), do: Enum.reverse(acc)

  defp do_decode_frames(<<size::32-big, rest::binary>>, acc) do
    decode_one_frame(size, rest, acc)
  end

  defp decode_one_frame(size, rest, acc) when byte_size(rest) >= size do
    payload = :binary.part(rest, 0, size)
    remaining = :binary.part(rest, size, byte_size(rest) - size)
    do_decode_frames(remaining, [payload | acc])
  end

  defp decode_one_frame(_size, _rest, acc), do: Enum.reverse(acc)

  # ── Wire format (identical to Longbridge.Connection) ──────

  defp do_auth(state) do
    token = state.config.token

    if token do
      {data, req_id} = build_auth_request(state, token)
      encoded = encode_frame(IO.iodata_to_binary(data))

      case send_frame(state, encoded) do
        {:ok, state} ->
          state = %{state | request_id: req_id}
          # Wait for the auth response to arrive as a WS frame.
          wait_for_auth_response(state)

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_token}
    end
  end

  defp wait_for_auth_response(state) do
    receive do
      {:ws_packet, packet} ->
        state = %{state | buffer: state.buffer <> packet}

        case Protocol.unpack(state.buffer) do
          {:ok, header, body, rest} ->
            state = %{state | buffer: rest}

            if header.cmd_code == Protocol.cmd_auth() and header.status_code == 0 do
              auth_resp = Protox.decode!(body, Ctrl.AuthResponse)
              state = %{state | session_id: auth_resp.session_id, expires: auth_resp.expires}
              # Process any extra packets bundled into the same TCP frame.
              state = process_data(state, rest)
              {:ok, state}
            else
              {:error, {:auth_failed, header.status_code}}
            end

          {:error, reason} ->
            {:error, {:unpack, reason}}
        end
    after
      @auth_timeout -> {:error, :auth_timeout}
    end
  end

  defp build_auth_request(state, token) do
    auth_body = %Ctrl.AuthRequest{token: token, metadata: %{}}
    {:ok, iodata, _size} = Protox.encode(auth_body)
    req_id = next_request_id(state)

    header = %Header{
      type: :request,
      verify: false,
      gzip: false,
      body_length: 0,
      cmd_code: Protocol.cmd_auth(),
      request_id: req_id,
      timeout: @auth_timeout
    }

    {Protocol.pack(header, IO.iodata_to_binary(iodata)), req_id}
  end

  defp send_heartbeat(state) do
    header = %Header{
      type: :request,
      verify: false,
      gzip: false,
      body_length: 0,
      cmd_code: Protocol.cmd_heartbeat(),
      request_id: 0,
      timeout: 5_000
    }

    timestamp = System.os_time(:millisecond)
    body = %Ctrl.Heartbeat{timestamp: timestamp}

    case Protox.encode(body) do
      {:ok, iodata, _size} ->
        packet = Protocol.pack(header, IO.iodata_to_binary(iodata))
        _ = send_frame(state, encode_frame(IO.iodata_to_binary(packet)))
        :ok

      _ ->
        :ok
    end
  end

  # ── Packet Processing ────────────────────────────────────

  # WS-specific: each binary message is one or more length-prefixed
  # protocol packets. (TCP version of this uses Process.unpack-style
  # streaming buffering instead.)
  defp process_data(state, data) when byte_size(data) == 0, do: state

  defp process_data(state, data) do
    data
    |> decode_frames()
    |> Enum.reduce(state, fn packet, state ->
      case Protocol.unpack(packet) do
        {:ok, header, body, _rest} -> dispatch_packet(state, header, body)
        {:error, _reason} -> state
      end
    end)
  end

  # WS-specific: server-initiated ping broadcasts as a heartbeat event
  # for diagnostics. Response/push dispatch is shared via Session.
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

  # ── Connection Lifecycle ─────────────────────────────────

  defp handle_disconnect(state, reason) do
    state = do_disconnect(state, reason)
    {:noreply, state}
  end

  defp do_disconnect(state, reason) do
    _ = cleanup_socket(state)
    _ = fail_pending_requests(state, reason)

    state =
      state
      |> cancel_idle_timer()
      |> Map.merge(%{
        connection_state: :disconnected,
        session_id: nil,
        buffer: <<>>
      })

    broadcast(state, {:disconnected, reason})
    _ = schedule_reconnect(state, reason)
    state
  end

  defp handle_connection_failure(state, reason) do
    state =
      state
      |> cancel_idle_timer()
      |> cleanup_socket()
      |> Map.put(:connection_state, :disconnected)
      |> Map.put(:session_id, nil)
      |> Map.put(:buffer, <<>>)

    broadcast(state, {:disconnected, reason})
    _ = schedule_reconnect(state, reason)
    :ok
  end

  defp cleanup_socket(state) do
    if state.mint_conn do
      _ = HTTP.close(state.mint_conn)
      :ok
    end

    %{state | mint_conn: nil, websocket: nil, request_ref: nil, socket: nil}
  end

  defdelegate fail_pending_requests(state, reason), to: Session
  defdelegate schedule_reconnect(state, reason), to: Session
  defdelegate schedule_idle_timer(state), to: Session

  defdelegate cancel_idle_timer(state), to: Session

  defdelegate broadcast(state, message), to: Session

  # ── Misc ─────────────────────────────────────────────────

  defdelegate next_request_id(state), to: Session

  defp parse_ws_url(url, default_path) when is_binary(url) do
    uri = URI.parse(url)
    scheme = ws_scheme(uri.scheme)
    port = uri.port || ws_default_port(scheme)
    {scheme, uri.host || "localhost", port, uri.path || default_path}
  end

  defp ws_scheme("wss"), do: :wss
  defp ws_scheme("ws"), do: :ws
  defp ws_scheme("https"), do: :wss
  defp ws_scheme("http"), do: :ws
  defp ws_scheme(_), do: :wss

  defp ws_default_port(:wss), do: 443
  defp ws_default_port(_), do: 80
end
