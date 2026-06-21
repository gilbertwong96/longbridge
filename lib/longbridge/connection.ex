defmodule Longbridge.Connection do
  @moduledoc """
  TCP connection process for the Longbridge protocol.

  Manages a raw TCP socket connection to a Longbridge endpoint,
  handling handshake, authentication, request/response pairing,
  push data dispatch, and heartbeat.

  This is a `GenServer` that owns the TCP socket lifecycle.
  Users interact via `Longbridge.QuoteContext` and `Longbridge.TradeContext`
  which wrap this connection.

  ## Lifecycle

  1. `connect/2` opens a TCP connection
  2. Sends 2-byte handshake
  3. Sends AuthRequest with token
  4. Receives AuthResponse with session_id
  5. Enters active mode — ready for requests and pushes
  """

  use GenServer
  require Logger

  alias Longbridge.Connection.Session
  alias Longbridge.Control.V1, as: Ctrl
  alias Longbridge.Protocol
  alias Longbridge.Protocol.Header

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

    {host, port} =
      case type do
        :quote -> {config.quote_host, config.quote_port}
        :trade -> {config.trade_host, config.trade_port}
      end

    state = %{
      config: config,
      type: type,
      host: host,
      port: port,
      socket: nil,
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
        _ = handle_connection_failure(state, reason)
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
        _ = handle_connection_failure(state, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:request, cmd_code, body, timeout}, from, state) do
    if state.connection_state == :active do
      req_id = next_request_id(state)
      ref = Process.send_after(self(), {:request_timeout, req_id}, timeout)

      packet_header = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: cmd_code,
        request_id: req_id,
        timeout: min(timeout, 60_000)
      }

      data = Protocol.pack(packet_header, body)
      :ok = :gen_tcp.send(state.socket, data)

      state =
        state
        |> put_in([:pending, req_id], %{from: from, ref: ref})
        |> then(&%{&1 | request_id: req_id})

      {:noreply, state}
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call({:subscribe_push, pid}, _from, state) do
    {:reply, :ok, update_in(state.subscribers, &MapSet.put(&1, pid))}
  end

  @impl true
  def handle_call(:get_session, _from, state) do
    if state.session_id do
      {:reply, {:ok, state.session_id, state.expires}, state}
    else
      {:reply, {:error, :not_authenticated}, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    state = process_data(state, state.buffer <> data)
    {:noreply, schedule_idle_timer(%{state | buffer: <<>>})}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    Logger.warning("[Longbridge.#{state.type}] Connection idle timeout")
    handle_disconnect(state, :idle_timeout)
  end

  @impl true
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("[Longbridge.#{state.type}] Connection closed")
    handle_disconnect(state, :tcp_closed)
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("[Longbridge.#{state.type}] TCP error: #{inspect(reason)}")
    handle_disconnect(state, {:tcp_error, reason})
  end

  @impl true
  def handle_info({:tcp_closed, _other_socket}, state) do
    # Stale close event for an already-replaced socket. Ignore.
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp_error, _other_socket, _reason}, state) do
    # Stale error event for an already-replaced socket. Ignore.
    {:noreply, state}
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
      {%{from: from}, state} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, state}

      {nil, state} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    _ =
      if state.connection_state == :active do
        send_heartbeat(state)
      end

    {:noreply, state}
  end

  defp send_heartbeat(state) do
    heartbeat_header = %Header{
      type: :request,
      verify: false,
      gzip: false,
      body_length: 0,
      cmd_code: Protocol.cmd_heartbeat(),
      request_id: 0,
      timeout: 5_000
    }

    timestamp = System.os_time(:millisecond)
    heartbeat_body = %Ctrl.Heartbeat{timestamp: timestamp}
    {:ok, iodata, _size} = Protox.encode(heartbeat_body)
    data = Protocol.pack(heartbeat_header, IO.iodata_to_binary(iodata))
    _ = :gen_tcp.send(state.socket, data)
  end

  @impl true
  def terminate(_reason, state) do
    state = cancel_idle_timer(state)

    _ =
      if state.reconnect_timer do
        _ = Process.cancel_timer(state.reconnect_timer)
        :ok
      end

    _ = cleanup_socket(state)
    :ok
  end

  # ── Connection Lifecycle ─────────────────────────────────

  defp do_connect(state) do
    opts = [:binary, active: true, packet: :raw]

    case :gen_tcp.connect(String.to_charlist(state.host), state.port, opts, @handshake_timeout) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, reason} -> {:error, {:connect, reason}}
    end
  end

  defp handle_disconnect(state, reason) do
    _ = cleanup_socket(state)
    _ = fail_pending_requests(state, reason)

    state =
      state
      |> cancel_idle_timer()
      |> then(fn s -> %{s | connection_state: :disconnected, session_id: nil, buffer: <<>>} end)

    broadcast(state, {:disconnected, reason})
    _ = schedule_reconnect(state, reason)
    {:noreply, state}
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

  defdelegate fail_pending_requests(state, reason), to: Session
  defdelegate schedule_reconnect(state, reason), to: Session

  defp cleanup_socket(state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    %{state | socket: nil}
  end

  defp do_handshake(state) do
    case :gen_tcp.send(state.socket, Protocol.handshake()) do
      :ok ->
        # Brief pause to let server process the handshake
        Process.sleep(100)
        {:ok, state}

      {:error, reason} ->
        {:error, {:handshake, reason}}
    end
  end

  defp do_auth(state) do
    token = state.config.token

    if token do
      {data, req_id} = build_auth_request(state, token)
      :ok = :gen_tcp.send(state.socket, data)
      state = %{state | request_id: req_id}

      # Wait synchronously for auth response
      receive do
        {:tcp, socket, raw} ->
          handle_auth_response(%{state | socket: socket}, raw)
      after
        @auth_timeout -> {:error, :auth_timeout}
      end
    else
      {:error, :no_token}
    end
  end

  defp build_auth_request(state, token) do
    auth_body = %Ctrl.AuthRequest{
      token: token,
      metadata: %{}
    }

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

    data = Protocol.pack(header, IO.iodata_to_binary(iodata))
    {data, req_id}
  end

  defp handle_auth_response(state, raw) do
    case Protocol.unpack(raw) do
      {:ok, resp_header, body, rest} ->
        if resp_header.cmd_code == Protocol.cmd_auth() and resp_header.status_code == 0 do
          auth_resp = Protox.decode!(body, Ctrl.AuthResponse)
          state = %{state | session_id: auth_resp.session_id, expires: auth_resp.expires}
          state = process_data(state, rest)
          {:ok, state}
        else
          {:error, {:auth_failed, resp_header.status_code}}
        end

      {:error, reason} ->
        {:error, {:unpack, reason}}
    end
  end

  # ── Packet Processing ────────────────────────────────────

  # TCP-specific: buffers incomplete packets across chunks. WSConnection
  # does not need this since WS binary messages carry complete length-prefixed
  # frames.
  defp process_data(state, data) when byte_size(data) == 0, do: state

  defp process_data(state, data) do
    case Protocol.unpack(data) do
      {:ok, header, body, rest} ->
        state = dispatch_packet(state, header, body)
        process_data(state, rest)

      {:error, :incomplete_body} ->
        %{state | buffer: data}

      {:error, :incomplete_header} ->
        %{state | buffer: data}

      {:error, reason} ->
        Logger.error("[Longbridge.#{state.type}] Unpack error: #{inspect(reason)}")
        state
    end
  end

  # TCP-specific: dispatch_packet for :request echoes heartbeat back over the
  # socket. The shared response/push dispatching lives in Session.
  defp dispatch_packet(state, %Header{type: :response} = header, body) do
    Session.dispatch_response(state, header, body)
  end

  defp dispatch_packet(state, %Header{type: :push} = header, body) do
    Session.dispatch_push(state, header, body)
  end

  defp dispatch_packet(state, %Header{type: :request} = header, body) do
    # Server-initiated heartbeat (ping) — echo back over TCP
    if Protocol.heartbeat?(header.cmd_code) do
      resp_header = %Header{
        type: :response,
        verify: false,
        gzip: false,
        cmd_code: Protocol.cmd_heartbeat(),
        request_id: header.request_id,
        status_code: Protocol.status_success(),
        body_length: byte_size(body)
      }

      data = Protocol.pack(resp_header, body)
      _ = :gen_tcp.send(state.socket, data)
      :ok
    end

    state
  end

  # ── Helpers ──────────────────────────────────────────────

  defdelegate next_request_id(state), to: Session
  defdelegate schedule_idle_timer(state), to: Session
  defdelegate cancel_idle_timer(state), to: Session
  defdelegate broadcast(state, message), to: Session
end
