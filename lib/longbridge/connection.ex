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
      buffer: <<>>
    }

    case do_connect(state) do
      {:ok, state} -> {:ok, state, {:continue, :handshake}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:handshake, state) do
    case do_handshake(state) do
      {:ok, state} -> {:noreply, state, {:continue, :auth}}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  @impl true
  def handle_continue(:auth, state) do
    case do_auth(state) do
      {:ok, state} ->
        Logger.info("[Longbridge.#{state.type}] Authenticated, session: #{state.session_id}")
        broadcast(state, {:connected, state.session_id})
        {:noreply, state}

      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  @impl true
  def handle_call({:request, cmd_code, body, timeout}, from, state) do
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
    {:noreply, %{state | buffer: <<>>}}
  end

  @impl true
  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    Logger.warning("[Longbridge.#{state.type}] Connection closed")
    broadcast(state, :disconnected)
    {:stop, :tcp_closed, state}
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    Logger.error("[Longbridge.#{state.type}] TCP error: #{inspect(reason)}")
    broadcast(state, {:error, reason})
    {:stop, reason, state}
  end

  @impl true
  def handle_info({:request_timeout, req_id}, state) do
    case Map.pop(state.pending, req_id) do
      {{%{from: from}, _ref}, state} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, state}

      {nil, state} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
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
    :ok = :gen_tcp.send(state.socket, data)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
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
      auth_body = %Ctrl.AuthRequest{
        token: token,
        metadata: %{}
      }

      {:ok, iodata, _size} = Protox.encode(auth_body)

      header = %Header{
        type: :request,
        verify: false,
        gzip: false,
        body_length: 0,
        cmd_code: Protocol.cmd_auth(),
        request_id: next_request_id(state),
        timeout: @auth_timeout
      }

      req_id = header.request_id
      data = Protocol.pack(header, IO.iodata_to_binary(iodata))
      :ok = :gen_tcp.send(state.socket, data)

      state = %{state | request_id: req_id}

      # Wait synchronously for auth response
      receive do
        {:tcp, socket, raw} ->
          state = %{state | socket: socket}

          case Protocol.unpack(raw) do
            {:ok, resp_header, body, _rest} ->
              if resp_header.cmd_code == Protocol.cmd_auth() and resp_header.status_code == 0 do
                auth_resp = Protox.decode!(body, Ctrl.AuthResponse)
                {:ok, %{state | session_id: auth_resp.session_id, expires: auth_resp.expires}}
              else
                {:error, {:auth_failed, resp_header.status_code}}
              end

            {:error, reason} ->
              {:error, {:unpack, reason}}
          end
      after
        @auth_timeout -> {:error, :auth_timeout}
      end
    else
      {:error, :no_token}
    end
  end

  # ── Packet Processing ────────────────────────────────────

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

  defp dispatch_packet(state, %Header{type: :response} = header, body) do
    req_id = header.request_id

    case Map.pop(state.pending, req_id) do
      {%{from: from, ref: ref}, state} ->
        _ = Process.cancel_timer(ref)

        if header.status_code == Protocol.status_success() do
          GenServer.reply(from, {:ok, body, req_id})
        else
          GenServer.reply(from, {:error, {:server_error, header.status_code, body}})
        end

        state

      {nil, state} ->
        Logger.warning("[Longbridge.#{state.type}] Unexpected response for req_id: #{req_id}")
        state
    end
  end

  defp dispatch_packet(state, %Header{type: :push} = header, body) do
    broadcast(state, {:push, header.cmd_code, body})
    state
  end

  defp dispatch_packet(state, %Header{type: :request} = header, body) do
    # Server-initiated heartbeat (ping)
    if Protocol.heartbeat?(header.cmd_code) do
      # Echo back as response
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
      :ok = :gen_tcp.send(state.socket, data)
    end

    state
  end

  # ── Helpers ──────────────────────────────────────────────

  defp next_request_id(state) do
    id = state.request_id + 1
    if id > 4_294_967_295, do: 1, else: id
  end

  defp broadcast(state, message) do
    for pid <- state.subscribers, do: send(pid, {:longbridge, self(), message})
    :ok
  end
end
